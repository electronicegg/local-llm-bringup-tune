# Tuning Guide: Legion 5 Pro (8GB VRAM / 32GB RAM)

## Note: on native Ubuntu, run Ollama as your user, not the systemd service
The packaged `ollama.service` runs as a dedicated `ollama` system user. If
your model store lives on a mounted filesystem owned by your own account
(e.g. an ntfs3-mounted Windows partition, shared to avoid duplicating model
files across a dual boot), `ollama create`/rebuild will fail with a
`chtimes: operation not permitted` error — the mount's owning user and the
service's user don't match, and ntfs3 requires ownership (not just group
write) to update file timestamps.

Fix: stop/disable the systemd service and run `ollama serve` manually as
your own user, carrying over the same env vars the systemd drop-in used
(`OLLAMA_MODELS`, `OLLAMA_KEEP_ALIVE`, `OLLAMA_NUM_GPU`, `OLLAMA_MAX_VRAM`,
`OLLAMA_FLASH_ATTENTION`, `OLLAMA_NUM_PARALLEL`, etc.):
```bash
sudo systemctl stop ollama && sudo systemctl disable ollama
source ~/.ollama-logs/env.sh   # your saved copy of the same env vars
nohup ollama serve > ~/.ollama-logs/serve.log 2>&1 &
disown
```
See tuning-results__legion5.md ("Update: migration to native Ubuntu") for the full
diagnosis. This also means `num_gpu` should **not** be set per-Modelfile on
this host — it's controlled globally via `OLLAMA_NUM_GPU`/`OLLAMA_MAX_VRAM`
env vars instead; a static Modelfile value conflicts with that and can
break loading.

## Note: OLLAMA_KEEP_ALIVE — tightened to 30m now that swap is disabled
This host previously ran `OLLAMA_KEEP_ALIVE=-1` (never unload — kept the
model warm forever to skip the ~45-60s cold-load delay on every request).
**Changed to `30m`** after disabling swap (see "Tuning without swap" below)
— with no swap cushion, an indefinitely-resident ~22GB model permanently
locks away memory that other desktop apps (this host runs Steam, Firefox,
etc. alongside Ollama) may need, with no graceful degradation path if
something else spikes. 30 minutes still avoids reloading on every single
request during an active session, but frees memory automatically once
you've moved on.
- To free memory immediately without waiting: `curl
  http://localhost:11434/api/generate -d '{"model":"<name>","keep_alive":0}'`
- Check current state any time with `ollama ps` — the `UNTIL` column shows
  the countdown (or `Forever` if something still has the old setting).

## Step 0: Measure before you tune
Before changing anything, get baseline numbers:
```powershell
# Windows PowerShell, while a model is loaded/running
nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu --format=csv -l 2
```
```powershell
ollama ps          # shows which models are loaded, and how memory is split GPU/CPU
```
`ollama ps` output shows a `PROCESSOR` column like `100% GPU`, `43%/57%
CPU/GPU` — this tells you immediately if a model is spilling into RAM.

## Step 1: The #1 fix — cap `num_ctx` explicitly
Large modern models (Qwen3.x family) often default to huge context windows
(up to 256K). Ollama allocates KV cache for the **requested** context size,
not what you actually use — so an idle 256K context reservation can eat
10-20GB+ of memory by itself, on top of model weights. This is the most
likely cause of your silent stalls.

Set a realistic cap per use case:
- Chat/coding day-to-day: `num_ctx 8192` or `16384`
- RAG with several doc chunks: `num_ctx 16384`–`32768`
- Only raise beyond that when a specific task actually needs it (e.g.
  summarizing a huge file) — don't leave it maxed by default.

Set via API/CLI per-request:
```bash
curl http://localhost:11434/api/generate -d '{
  "model": "qwen3.6:35b-a3b",
  "prompt": "hello",
  "options": { "num_ctx": 8192, "num_gpu": 999, "num_batch": 256 }
}'
```
Or persist it in a custom Modelfile:
```
FROM qwen3.6:35b-a3b
PARAMETER num_ctx 8192
PARAMETER num_batch 256
```
```bash
ollama create qwen3.6-tuned -f Modelfile
```

## Step 2: Control GPU/CPU split explicitly
> **On this Ubuntu host: skip Modelfile-level `num_gpu`.** GPU offload is
> controlled globally via `OLLAMA_NUM_GPU`/`OLLAMA_MAX_VRAM` env vars
> instead (see the note at the top of this file) — a static per-model
> `num_gpu` conflicts with that and can break loading. The guidance below
> (originally written for the Windows setup) still applies conceptually,
> just applied via env vars rather than the Modelfile.
- `num_gpu` = number of layers offloaded to GPU. Ollama auto-picks this, but
  auto-detection can be wrong for MoE models (it may try to fit too much).
- Start conservative, then increase: e.g. begin with `num_gpu 20`, watch
  `nvidia-smi`, increase until VRAM sits ~90% used (leave headroom for KV
  cache growth during generation).
- For a ~20GB Q4 MoE model with 8GB VRAM: expect roughly 1/3 of layers on
  GPU, rest on CPU/RAM — this is normal and still much faster than full CPU.

## Step 3: Pick the right quantization
- Q4_K_M: best default balance (size vs quality) — start here.
- Q5_K_M: if quality feels lacking and you have headroom (adds ~20% size).
- Q3_K_M / Q2_K: only if you must shrink further; noticeable quality loss.
- Rule of thumb size estimate: `params(B) × bits/8 × 1.0-1.1 overhead`
  e.g. 35B at Q4 (~4.5 bits effective with K-quants) ≈ 20GB.

## Step 4: Batch size and threads
- `num_batch` (prompt processing batch): lower (128-256) reduces peak memory
  during prompt ingestion; raise only if prompt processing feels slow and
  memory allows.
- `num_thread`: set to your physical core count for CPU-offloaded layers
  (7945HX: try 16, since it's 16 cores/32 threads — hyperthreads rarely help
  llama.cpp inference).

## Step 5: Close the memory gap on the Windows side
- Check Task Manager for what's using the "idle" 40-50% RAM (browser tabs,
  background services) — closing Chrome tabs before a heavy local-model
  session directly gives that memory back to Ollama.
- Consider a lightweight browser profile or closing Chrome entirely during
  MoE model sessions — you're competing for the same 32GB pool.

## Step 6: A repeatable tuning loop for Qwen3.6-35B-A3B
1. Set `num_ctx 8192`, let Ollama auto-pick `num_gpu`, run a 10-turn chat.
2. Watch `nvidia-smi` + Task Manager RAM the whole time (not just at load).
3. If stable → try raising `num_ctx` to 16384, repeat.
4. If it stalls → note *when* (long response? long conversation building up
   KV cache? big pasted input?) — that tells you whether it's KV cache
   growth (lower `num_ctx`) or model+context total (lower `num_gpu` or drop
   quant to Q3).
5. Once stable, lock those values into a custom Modelfile so you don't lose
   the tuning next time you pull an update.

## Quick reference: safe starting config
```
PARAMETER num_ctx 8192
PARAMETER num_gpu 20        # adjust after watching nvidia-smi
PARAMETER num_batch 256
PARAMETER num_thread 16
```
Adjust `num_gpu` upward in small steps (e.g. +4) until VRAM usage plateaus
near capacity without OOM/stalling.

## Tuning without swap (native Ubuntu host)
Swap was disabled on this host to protect NVMe write cycles (`swapoff -a` +
commented `/etc/fstab` entry; the 8GB `/swap.img` file is kept on disk but
inactive). No swap means the safety net for over-committing memory is gone —
Linux's OOM-killer will hard-kill a process instead of degrading gracefully
into swap. Recommendations, given the empirical test results in
`tuning-results__legion5.md`:

1. **`OLLAMA_KEEP_ALIVE` lowered from `-1` (forever) to `30m`.** Done — see
   note above. This is the single biggest lever: it guarantees memory is
   reclaimed automatically within 30 minutes of the last request, rather than
   being held indefinitely while you use other RAM-heavy apps (Steam,
   Firefox, etc. all run on this host alongside Ollama).
2. **`systemd-oomd` is already active and still effective without swap.**
   Checked `user@<uid>.service` drop-in: `ManagedOOMMemoryPressure=kill` at
   a 50% PSI (pressure-stall) threshold — this triggers off actual memory
   pressure, not swap occupancy, so it continues to provide a safety net
   with swap fully disabled. No config change needed here.
3. **Prefer ctx16k/ctx32k as daily-driver defaults.** Both showed the
   lowest, most predictable RAM pressure in testing (well under 30%
   available-memory pressure even mid multi-turn conversation). Reserve
   ctx64k/ctx128k for tasks that actually need the longer window — the
   larger the `num_ctx`, the bigger the fixed KV-cache allocation taken at
   *load* time, before you've even sent a token, and now that allocation
   has no swap fallback if something else on the desktop spikes.
4. **Watch `free -h`'s `available` column, not `used`.** Model weights are
   mmap'd and show as reclaimable `buff/cache`; `available` is the only
   trustworthy "how much headroom do I actually have" number (see
   `monitor.sh`, fixed earlier to use it). As a rule of thumb from testing:
   keep `available` above ~3-4GB before kicking off a large/long job, since
   that's your only remaining cushion with no swap.
5. **Optional, not yet done: consider zram** (compressed RAM-backed swap)
   as a middle-ground safety net — it satisfies the original "avoid NVMe
   wear" concern (it's RAM-only, no disk writes) while still giving the
   kernel a degrade-gracefully option before OOM-killing. Costs some CPU for
   compression and a slice of RAM for the compressed pool. Worth raising as
   a follow-up decision if hard OOM kills start happening in practice.

## Client integration: `ollama launch copilot` / `ollama launch opencode`
Confirmed on this host (Ollama v0.34.0) — `ollama launch <integration>` is a
real, built-in wrapper (`ollama launch --help` lists supported integrations:
`copilot`, `opencode`, `claude`, `codex`, and others). It launches the target
CLI pointed at your local Ollama server automatically.

**What `ollama launch copilot --model <name>` actually sets** (confirmed by
inspecting the child process's environment):
```
COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:11434/v1
COPILOT_PROVIDER_API_KEY=            # empty — not needed for local Ollama
COPILOT_PROVIDER_WIRE_API=responses
COPILOT_MODEL=<name>
```
This confirms Copilot CLI genuinely supports **BYOK (bring your own key)**
custom model providers — `copilot help providers` documents the full set of
`COPILOT_PROVIDER_*` env vars. Earlier guidance in this doc that Copilot CLI
"doesn't support local models" was wrong; corrected here.

**Gap to fix manually:** the launcher does **not** set
`COPILOT_PROVIDER_MAX_PROMPT_TOKENS` / `COPILOT_PROVIDER_MAX_OUTPUT_TOKENS`.
Without these, Copilot CLI doesn't know your custom model's real context
window and falls back to a generic default — which may not match our tuned
`num_ctx`/`num_predict`, undermining the same graceful-compaction goal as
the Modelfile tuning above.

**Critical finding — Copilot CLI's own static overhead is large.** Measured
directly (`--usage-output-file`, trivial "hi" prompt): the system prompt +
all built-in tool schemas (bash, edit, view, grep, glob, task, plus the
GitHub MCP server) cost **21,504 input tokens before any real conversation
happens.** That's 65% of a 32K window by itself. Setting
`MAX_PROMPT_TOKENS=16384` on the 32k-standalone model hit a hard error:
```
Static system messages and tool definitions exceed the model's usable context budget.
Reduce static context or switch to a larger-context model.
```
**Fix: use the 64k-agentic model for Copilot CLI / opencode agentic use, not
ctx32k.** 64K leaves ~44K after the ~21.5K static floor — comfortably
workable. ctx32k(-safe) is still fine for plain `ollama run` chat (no tool
schemas to worry about), just not for the full agentic CLI tool loadout.

```bash
export COPILOT_PROVIDER_BASE_URL=http://127.0.0.1:11434/v1
export COPILOT_MODEL=qwen3.6:35b-a3b-64k-agentic
export COPILOT_PROVIDER_MAX_PROMPT_TOKENS=49152   # 65536 - 16384; covers ~21.5K static + growth room
export COPILOT_PROVIDER_MAX_OUTPUT_TOKENS=16384   # matches num_predict in the Modelfile
copilot
```
**Note these two don't need to split "input vs. output of one exchange"** —
`MAX_OUTPUT_TOKENS` caps a single turn's thinking+response, while
`MAX_PROMPT_TOKENS` caps how much *accumulated* content (static overhead +
conversation/tool-context) Copilot will let build up before triggering its
own compaction. `num_predict` in the Modelfile is capped at 16384 (not
-1/unbounded) so the model itself won't cut generation short before
Copilot's own limit would — same fix as 32k-standalone, applied after
repeated real-world "terminated mid-think / truncated output" incidents.
The conversation-history side can afford to shrink relative to num_ctx
because it already degrades gracefully on its own (Ollama's context-shift
evicts oldest turns, confirmed via context-probe testing) — it's the fixed
~21.5K static cost that actually forced the move to ctx64k, not the
history-growth side.

Saved as a template in this repo: `configs/copilot/copilot-byok-64k-agentic.env`
(the only supported Copilot CLI config — 32k-standalone's window can't fit
Copilot CLI's static tool overhead, so it's `ollama run`-only). `source` it
before running `copilot`, or use `bin/copilot-agentic` which does this for
you, or use `ollama launch copilot --model <name>` for convenience and
accept its default (untuned) token-limit behavior.

**For opencode**: use the `provider.ollama.models.<id>.limit` config
(`context`/`output`) shown in `opencode.json.example` in this repo — same
purpose as the two Copilot env vars above, but opencode's own schema calls
it `limit.context`/`limit.output` and additionally exposes a top-level
`compaction.reserved` buffer. opencode's own tool set differs from Copilot
CLI's, so its actual static overhead may not be identical — worth measuring
the same way if you hit a similar error there. `ollama launch opencode`
will auto-populate a basic `~/.config/opencode/opencode.json` provider
entry but — same caveat — won't set `limit`, so add it manually.
