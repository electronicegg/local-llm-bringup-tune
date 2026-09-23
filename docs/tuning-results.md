# Tuning Results: Qwen3.6-35B-A3B Context Length Experiments

Host: Legion 5 Pro — RTX 4070 Laptop (8GB VRAM), AMD Ryzen 9 7945HX, 32GB DDR5.
Ollama running on Windows 11, tested from WSL2 Ubuntu 22.04 via
`http://localhost:11434`. Model: `qwen3.6:35b-a3b` (Q4_K_M, ~22.6GB on disk).

## Background
The Ollama Windows desktop app had its global **Context length** setting at
**262144 (256K)**. This is suspected to be the root cause of an earlier
silent stall (model stopped responding mid-chat, no error) — a large
`num_ctx` causes Ollama to reserve a correspondingly large KV cache, which
can push total host RAM usage to the brink, at which point Windows begins
paging rather than raising a clean OOM error.

## Method
For each `num_ctx` value, the same test was run:
1. Fully unload any loaded model (`keep_alive: 0`) and confirm a clean
   baseline via `powershell.exe` querying `Win32_OperatingSystem`
   (`TotalVisibleMemorySize` / `FreePhysicalMemory`) — this reads the true
   Windows host RAM, since WSL2's own `free -h` only reflects WSL's capped
   view, not the host.
2. Start `monitor.sh` (lightweight 2-second sampler, see below) logging to
   CSV: timestamp, RAM used/total/%, VRAM used/total, GPU utilization.
3. Send one identical prompt via `/api/generate` with `"options": {"num_ctx":
   <value>}`, `stream: false`.
4. Record peak RAM/VRAM from the monitor log, then unload before the next run.

`monitor.sh` lives at the repo root — samples `nvidia-smi` (VRAM/GPU%,
works directly from WSL2 via GPU passthrough) and a single lightweight CIM
query via `powershell.exe` (host RAM), every N seconds, appending CSV rows.

## Results

### Raw peak values
| num_ctx | Peak RAM | Peak RAM % | Peak VRAM | Load time |
|---|---|---|---|---|
| 8,192 | 26.77GB | 83% | 6.94GB | 41s |
| 16,384 | 27.17GB | 85% | 6.90GB | 38s |
| 32,768 | 27.44GB | 85% | 6.97GB | 36s |
| 65,536 | 27.96GB | 87% | 6.91GB | 35s |
| 131,072 | 29.17GB | 91% | 6.81GB | 36s |
| 262,144 (prior app default) | 31.87GB | **99%** ⚠️ | 6.62GB | 66s |

### Baseline-normalized deltas
Baseline RAM varied slightly run to run (9.69–10.59GB, depending on ambient
Windows/WSL2 state), so raw peaks alone can be misleading. Delta = peak −
that run's own pre-load baseline, isolating the model+context's true cost:

| num_ctx | Baseline | Peak | **Delta (model cost)** | Delta vs 8K |
|---|---|---|---|---|
| 8,192 | 9.70GB | 26.77GB | 16.67GB | — |
| 16,384 | 9.69GB | 27.17GB | 17.07GB | +0.40GB |
| 32,768 | 9.79GB | 27.44GB | 17.23GB | +0.56GB |
| 65,536 | 9.88GB | 27.96GB | 17.66GB | +0.99GB |
| 131,072 | 9.91GB | 29.17GB | 18.80GB | +2.13GB |
| 262,144 | 10.59GB | 31.87GB | 20.78GB | +4.11GB |

## Findings
- The model's baseline memory cost (weights + minimal context) is
  ~16.7GB regardless of context setting.
- Growth from 8K → 64K context is gentle: only **+0.99GB** total across an
  8x increase in context window.
- Growth accelerates sharply beyond 64K: **+1.14GB** from 64K→128K, then
  **+1.98GB** from 128K→256K — a clear inflection point.
- At 256K (the prior app default), peak RAM hit **99%**, leaving almost no
  headroom for the OS/browser/other apps — the most likely explanation for
  the earlier silent stall.
- A parallel test of `deepseek-coder-v2:16b` run at its untouched default
  (163,840 context) also hit 99% RAM despite the model itself being much
  smaller on disk (8.9GB vs 22.6GB) — confirming this is a `num_ctx`
  problem, not specific to one model.

## Recommendation
Set Ollama's context length to **65536 (64K)**:
- Only +0.99GB over the practical floor (8K), a small cost for 8x more
  usable context — enough headroom for long chats, RAG chunks, and
  multi-file coding context.
- Peak RAM stays at 87%, leaving a real ~4GB margin for Chrome/other apps,
  vs. essentially no margin at 256K.
- Avoid 128K+ unless a specific task needs it and other apps are closed —
  RAM headroom drops fast beyond 64K.

Where to apply this:
- Ollama Windows app: **Settings → Context length → 65536** (user opted for
  **32768** as the app-wide default; see multi-turn results below for why
  both are viable).
- Model variants built via Modelfile, one per context size, so API/agentic
  use gets a consistent value regardless of the app's GUI setting:
  `qwen3.6__35b-a3b-ctx8k`, `-ctx16k`, `-ctx32k`, `-ctx64k`
  (tags: `qwen3.6:35b-a3b-ctx{8k,16k,32k,64k}`).

## Multi-turn conversation test (ctx32k vs ctx64k)
The single-prompt tests above only measure KV cache *allocation* cost, not
whether a growing real conversation stays stable. Tested with
`multi-turn-test.sh` (see repo root) — a 5-turn conversation via `/api/chat`
with growing message history (chat intro → KV cache explainer → write a
function → write tests → summarize), each turn logged for latency and
token counts, while `monitor.sh` sampled RAM/VRAM throughout.

| | ctx32k | ctx64k | ctx8k (10-turn, partial) |
|---|---|---|---|
| Turns completed | 5/5 ✅ | 5/5 ✅ | 6/10 (stopped for time) ✅ |
| Peak RAM | 89% (28.64GB) | 92% (29.49GB) | 92% (29.55GB) |
| Delta over baseline | 16.9GB | 16.75GB | ~17GB |
| Peak VRAM | 7.89GB | 7.87GB | 7.89GB |
| Final cumulative tokens | 2,819 | 2,948 | 4,115 (turn 6) |
| Longest single turn | 222s (2,824 gen tokens) | 200s (2,630 gen tokens) | 213s (2,932 gen tokens) |

**Findings**:
- No stalls, crashes, or memory spikes across any of the three runs. RAM
  climbed gradually and smoothly as conversation history grew — consistent
  with the single-prompt test's behavior, not a runaway leak.
- Turns that appeared to "time out" at 120s in an earlier test attempt were
  **not stalls** — `nvidia-smi` showed continuous GPU utilization (30-70%)
  throughout, confirming the model was still actively generating a long
  response (up to ~2,900 tokens in one turn). Raising the client timeout to
  240s resolved this; the model itself never froze.
- ctx32k retains a few percent more RAM headroom (89% vs 92% peak) for the
  same conversation shape; ctx64k trades that headroom for 2x the usable
  context ceiling.

**Conclusion**: both ctx32k and ctx64k are validated as stable for real
multi-turn use, not just cold-start allocation. Recommended split:
- **ctx32k** — daily driver / general chat & coding (max headroom).
- **ctx64k** — reserved for tasks needing more context (RAG with many
  chunks, long documents, multi-file review).
- Avoid 128K+ for regular use per the single-prompt results above.

## Open follow-up
- Not yet tested: 98304/196608 (to pinpoint the inflection more precisely
  between 128K and 256K) — optional, since 64K already looks like a
  comfortable, well-justified choice.
- Not yet tested: full 10-turn conversations at ctx32k/ctx64k (only 5-turn
  run so far, due to per-turn generation being verbose/slow) — could be
  revisited if longer real sessions raise concerns later.

## Update: migration to native Ubuntu (dual boot)

All results above were measured on Windows 11 / WSL2. The host has since been
dual-booted into native Ubuntu, with Ollama's model store pointed at the
existing Windows-side files (`OLLAMA_MODELS=/mnt/windows11/Users/nikko/.ollama/models`,
via an ntfs3 mount) to avoid duplicating ~100GB+ of model blobs across OSes.

### Issue 1: `num_gpu` in Modelfiles broke model loading on Ubuntu
The Windows-tuned Modelfiles included `PARAMETER num_gpu 20`. On this Ubuntu
host, that caused load failures. Root cause: the host now sets GPU offload
globally via systemd/env vars instead —
`OLLAMA_NUM_GPU=99` (let Ollama consider up to ~all layers) and
`OLLAMA_MAX_VRAM=7500` (cap actual VRAM used to 7.5GB, leaving ~700MB
headroom out of 8GB). This computes a safe per-model layer count from real
free VRAM at load time. A static Modelfile-level `num_gpu` fought with that
mechanism. **Fix applied**: removed `num_gpu` from all Modelfiles; GPU
offload is now controlled solely by the host-wide env vars. All variants
rebuilt and confirmed loading successfully after the fix.

### Issue 2: `ollama create` failing on the NTFS-mounted model store
`ollama create` (rebuilding a Modelfile) failed with:
```
Error: 500 Internal Server Error: chtimes .../blobs/sha256-...: operation not permitted
```
Root cause: Ollama was running as a systemd service under the dedicated
`ollama` system user (uid 997), while the ntfs3-mounted model directory is
owned by the interactive user (`peanut`, uid 1000). The ntfs3 driver
requires the calling process to own the file for `chtimes`/`utimes`, even
with group-write permission — so builds failed regardless of Unix
permission bits.

**Fix applied**: stopped and disabled the `ollama` systemd service, and now
run `ollama serve` manually as the interactive user, carrying over the same
env vars previously set in the systemd drop-in
(`OLLAMA_MODELS`, `OLLAMA_KEEP_ALIVE=-1`, `OLLAMA_NUM_GPU=99`,
`OLLAMA_MAX_VRAM=7500`, `OLLAMA_FLASH_ATTENTION=1`, `OLLAMA_NUM_PAR=1`).
Confirmed `ollama create` succeeds under this setup.

### Model lineup change
- Dropped **ctx8k** — lowest tier no longer needed; 16K is a low enough
  floor in practice.
- Kept **ctx16k** as the new floor.
- **ctx32k** confirmed as the sweet spot (daily driver).
- **ctx64k** kept as a conditional/task-dependent option.
- Added and validated **ctx128k** (see below) as a working long-context
  option, previously flagged as "avoid" based on Windows single-prompt data
  alone.

### ctx128k validation on Ubuntu
Built `qwen3.6:35b-a3b-ctx128k` (`num_ctx 131072`, `num_batch 128`, no
`num_gpu`). Tested with a real prompt (not just cold-load):
- Loaded and responded successfully; `ollama ps` showed `87%/13% CPU/GPU`
  split, 22GB total model size, context 131072.
- First call (`think` enabled, `num_predict 150`) hit the token limit while
  still inside the model's internal reasoning (`thinking` field) — this is
  expected Qwen3.6 reasoning behavior, not a memory failure.
- Second call (`"think": false`, `num_predict 300`) returned a correct,
  complete one-sentence answer in ~1.4s.
- RAM pressure (`total - available`, see monitor.sh note below) held at
  ~17-18% throughout; swap usage stayed flat at 2.1GB (pre-existing, not
  growing). VRAM steady at ~6.9GB/8GB.

**Conclusion**: ctx128k is validated as a working long-context option on
this native Ubuntu host — the earlier Windows-based "avoid 128K+" guidance
was specific to the Windows host's memory accounting/headroom and does not
carry over directly.

### monitor.sh accounting fix (Linux vs Windows)
The original Windows/WSL2 monitoring queried host RAM via `powershell.exe`
(true committed memory). Ported naively to native Ubuntu using `free -m`'s
"used" column, it under-reported usage: Ollama mmaps model weight files, so
Linux counts those pages as reclaimable `buff/cache`, not `used` — a 22GB
loaded model could show as little as ~18% RAM "used". Fixed `monitor.sh` to
compute pressure as `(total - available) / total`, using `free`'s
`available` column (which already accounts for reclaim cost), and added a
`swap_used_mb` column since swap growth is a more reliable early warning
sign of real memory pressure on Linux than the raw "used" figure.

### ctx128k multi-turn conversation test
Ran `multi-turn-test.sh qwen3.6:35b-a3b-ctx128k` (5 turns: intro → KV cache
explainer → write a function → write tests → summarize), with `monitor.sh`
sampling throughout.

| Turn | Latency | Prompt tokens | Gen tokens | Turn total¹ |
|---|---|---|---|---|
| 1 | 28.8s | 26 | 724 | 750 |
| 2 | 77.4s | 152 | 1,879 | 2,031 |
| 3 | 71.9s | 793 | 1,435 | 2,228 |
| 4 | 99.2s | 1,262 | 2,270 | 3,532 |
| 5 | 49.3s | 2,187 | 829 | 3,016 |

¹ "Turn total" = that turn's own prompt+gen tokens, **not** a running
cumulative sum across turns (script column name is misleading) — growing
`prompt_tokens` per turn (26→152→793→1,262→2,187) is what shows the context
actually accumulating conversation history correctly.

**Peak resource usage across the whole run**: RAM pressure 21%, swap flat at
2,130MB (unchanged from idle — no growth), VRAM 7,008MB/8,188MB. `ollama ps`
showed `87%/13% CPU/GPU` throughout.

**Result**: all 5 turns completed successfully, no stalls/timeouts, no
memory growth beyond the single-prompt test's levels. **ctx128k is
validated for real multi-turn use on this Ubuntu host**, not just cold-load
— consistent with the earlier ctx32k/ctx64k multi-turn validation.

## Token accounting, thinking-split, and real context-window behavior
Artifacts for all tests below: `tests/token-tests/` (prompts, raw responses, and
CSV summaries per turn — kept as files for inspection, not just logged here).

### Token usage of the ctx128k multi-turn test (from the run above)
| Metric | Value |
|---|---|
| Total output tokens generated (5 turns) | 7,137 |
| Sum of prompt_tokens across calls (nominal, not unique) | 4,420 |
| Actual context occupied at end of conversation | 3,016 tokens |
| % of ctx128k (131,072) window used at end | 2.3% |

Note: `prompt_tokens` per turn is the *cumulative* history resent on every
`/api/chat` call (Ollama has no cross-call KV cache reuse across separate
requests by default), so summing it across turns overstates unique content —
the meaningful number is the **last turn's** prompt+gen total.

### Thinking vs. response token split (`tests/token-tests/01-*`)
Tested `qwen3.6:35b-a3b-ctx16k` with `think: true` and a generous
`num_predict: 4096` (vs. the earlier 150-token test that cut off mid-thought)
on the prompt "explain transformer attention in detail."

| | Tokens (estimated from char-ratio of exact eval_count) | Share |
|---|---|---|
| Thinking | ~1,473 | 46% |
| Final response | ~1,745 | 54% |
| **Total (exact, from API)** | **3,218** | 100% |

**This directly explains the "big thinking step, no output shown" issue**:
Qwen3.6 reasoning can consume roughly half (sometimes more) of the output
token budget before it starts the visible answer. If `num_predict` (or a
client-side token/time limit) is set too low, generation gets cut off
entirely inside the thinking phase — the user sees nothing, even though the
model was working correctly. **Practical fix**: set `num_predict` generously
(2000+) for reasoning-heavy prompts, or pass `"think": false` when you don't
need the reasoning trace and just want a fast direct answer (confirmed
working in this same test set — see context-probe tests below, all run with
`think: false` and no truncation issues).

### Real context-window capacity probe (`tests/token-tests/02-*`, `03-*`)
Goal: find out what actually happens as a conversation approaches/exceeds
`num_ctx`, using a "needle in haystack" method — plant a unique secret
phrase in turn 1, grow the conversation with large filler turns, then ask
the model to recall the secret.

**Round 1** (`02-context-probe*`, ctx16k, ~946 tokens filler/turn, 7 turns):
reached only 5,770 tokens (35% of 16,384) — secret recalled correctly.
Confirms no issues well under the limit.

**Round 2** (`03-context-probe-v2*` + manual continuation, ctx16k, ~2,800
tokens filler/turn, pushed to 18 turns): the key finding —

| Turns sent (cumulative filler) | Reported `prompt_tokens` |
|---|---|
| Up to ~14,000 tokens worth sent | 14,063 |
| Continued sending filler turns 10-17 (each ~2,800 more tokens) | **stayed at 13,937–14,063** — never grew further, despite far more content being sent |

Ollama/llama-server (running with `--context-shift --keep 4`, visible in
the systemd unit's launch flags) **silently drops the oldest turns** once
the conversation nears the configured `num_ctx`, capping actual resident
context at roughly **85-86% of num_ctx** (14,063 / 16,384) rather than
erroring or growing past it. The recall test confirms this directly:
- At 68.7% and 86.1% of `num_ctx`: secret still recalled correctly.
- After forcing several more filler turns past the plateau (turn 18): model
  answered **"I don't know"** — a clean, honest admission that the turn 1
  content had been silently evicted from context. No hallucination.

**Practical implications**:
1. **`num_ctx` is a ceiling, not a hard error boundary** — Ollama won't
   crash or throw an error when a conversation grows past it; it quietly
   forgets the oldest turns instead (context-shift). This is safer than
   crashing, but means long conversations can silently lose early
   instructions/context without any warning.
2. The effective usable context is a bit less than the configured `num_ctx`
   (~85-86% in this test) — the server reserves some headroom rather than
   filling 100%.
3. If a task depends on the model remembering something from early in a
   long conversation (e.g. a system-prompt-like instruction given mid-chat,
   or an early code snippet), **re-state it periodically** or raise
   `num_ctx` for that session, since it can be silently dropped well before
   the conversation "feels" long.
4. This behavior was not observed as a crash/stall in any test — it's a
   silent truncation, not the OOM/stall failure mode investigated earlier
   in this document (that was specifically about oversized default context
   reservations, not context-shift eviction).

### Peak resource usage across all token/context tests
RAM pressure stayed ≤28%, VRAM steady ~7.0GB/8.2GB, no swap growth observed
throughout — all failures/behaviors observed above were context-window
logic, not memory exhaustion.

## Output-side testing (all prior tests above mainly exercised the input side)
All context-probe tests above grew the conversation via large *user* turns
while keeping assistant replies tiny ("OK"). The tests below specifically
stress the *output* side, using `qwen3.6:35b-a3b-ctx16k` via single-shot
`/api/generate` calls (no chat history). Artifacts: `tests/token-tests/04-*`
through `06-*`.

### Test 1: unconstrained long-form output (`04-long-output-*`)
Prompt: "write an extremely long essay on the history of computing,"
`num_predict: -1` (unlimited), `think: false`.
- Result: model **self-terminated naturally** (`done_reason: stop`) at
  **5,239 output tokens** (32% of 16,384) — well short of any ceiling.
  ~24 tokens/sec generation speed.
- Takeaway: even with no cap, the model may stop on its own long before
  the context window is an issue — natural EOS is one of (at least) three
  distinct stop causes, alongside `num_predict` and `num_ctx`.

### Test 2: forced-continuation task (`05-forced-output-*`)
Prompt: "count from 1 to 100,000, one per line, don't stop." Result: the
model **refused** after 90 tokens, explaining the request exceeded
practical output length and offering a script instead. This is a model
alignment/practicality behavior, not a context or technical limit — a
reminder that "the model stopped" doesn't always mean a system limit was
hit.

### Test 3: forcing the real output-side ceiling (`06-near-ceiling-*`)
To actually reach the ceiling, input was pre-filled to ~11.5K tokens
(large filler text the model was told to ignore), then it was asked for an
open-ended long-form story (a task it *will* comply with at length),
`num_predict: -1`.

| Metric | Value |
|---|---|
| `prompt_eval_count` (input) | 11,581 |
| `eval_count` (output) | 4,803 |
| **input + output** | **16,384 — exactly `num_ctx`** |
| `done_reason` | `length` |
| Generation speed | ~17.4 tokens/sec |
| Output ending | cut off **mid-sentence** ("...He talked to ARIA every day. They discussed") |

**This is the clean confirmation of the output-side ceiling**: for a
single-shot `/api/generate` call (no chat history to evict from), `num_ctx`
is a **hard, exact cap on input+output combined**. When hit, generation
stops immediately and silently — mid-word/mid-sentence, no error, no
warning — the opposite of the multi-turn chat case (Test 2/3 above) where
`--context-shift` evicts old *history* to keep generating instead of
truncating the current output.

### Combined picture: three different "why did it stop" causes
| Cause | Symptom | Where observed |
|---|---|---|
| Natural EOS | Clean stop, `done_reason: stop`, well under any limit | Test 1 above |
| Model self-limit/refusal | Explains why it won't continue | Test 2 above |
| `num_predict` reached | `done_reason: length`, can cut off mid-*thinking* if budget too small | Earlier thinking-split test (150-token cutoff) |
| `num_ctx` reached (single-shot) | `done_reason: length`, cuts off mid-*response*, input+output hits exactly num_ctx | Test 3 above |
| `num_ctx` approached (multi-turn chat) | No error; oldest turns silently evicted (`--context-shift`), current turn completes normally | Context-probe v1/v2 above |

**Practical guidance**: don't assume a short/truncated reply means the
model "broke" — check `done_reason` and `prompt_eval_count + eval_count`
in the API response to tell these apart. For long-form single-shot
generation tasks, budget `num_ctx` for input + desired output combined,
not just the input size.


## Update: tuning for no-swap host

Swap was disabled on this host (NVMe write-cycle concern): `swapoff -a`,
`/etc/fstab` swap line commented out (`/swap.img` kept on disk, unused, as a
backup in case swap is re-enabled later). This removes the previous
graceful-degradation path (spill to disk) — memory over-commit now risks a
hard OOM-kill instead.

**Findings:**
- `systemd-oomd` was already active on this host and is **not
  swap-dependent** for its main defense: `user@<uid>.service` carries
  `ManagedOOMMemoryPressure=kill` with a 50% PSI threshold — triggers off
  live memory-pressure stalls, not swap occupancy. No extra config needed;
  it continues to function with swap=0.
- Real-world concurrent load matters more here than earlier (Windows-era)
  assumptions accounted for: this host runs Steam/steamwebhelper, Firefox,
  gnome-shell, 1Password, and the Copilot CLI alongside Ollama — a genuine
  desktop session, not an idle box. `ps aux` showed `llama-server` RSS at
  24.7GB (77% of system) while `free`'s `available` still reported ~19GB
  (63%) free — a reminder that RSS overstates real pressure due to
  mmap'd/reclaimable model weight pages; `available` remains the metric to
  trust.
- `OLLAMA_KEEP_ALIVE` was `-1` (forever/never-unload). Changed to `30m` and
  restarted `ollama serve` — confirmed via `ollama ps` that a freshly loaded
  model now reports `UNTIL: 29 minutes from now` instead of `Forever`. This
  is the main mitigation: it guarantees the ~22GB resident model is released
  automatically after a period of inactivity, rather than permanently
  reserving memory that other apps (games, browser tabs) may need, now that
  there's no swap to fall back on if something else spikes.

**Practical guidance going forward:**
- Default to ctx16k/ctx32k for daily use — lowest, most predictable memory
  footprint from all prior tests.
- Watch `free -h`'s `available` column (via `monitor.sh`); keep a ~3-4GB
  floor before starting large/long jobs.
- zram (compressed RAM swap, no disk writes) remains an open option if hard
  OOM kills start happening in practice — not implemented, flagged as a
  follow-up decision rather than assumed.

## Update: Copilot CLI static overhead forces ctx64k for agentic use

Testing the 32k-standalone config (16384/16384 prompt/output split) via
Copilot CLI produced a hard error on the very first message:
```
Static system messages and tool definitions exceed the model's usable context budget.
Reduce static context or switch to a larger-context model.
```

**Measured the actual cost** via `copilot -p "hi, just reply OK"
--usage-output-file`: **21,504 input tokens** consumed before any real
conversation — this is Copilot CLI's system prompt plus all built-in tool
schemas (bash, edit, view, grep, glob, task) plus the GitHub MCP server's
tool definitions, all sent as static context on every request.

**Implication:** 21.5K tokens is 65% of a 32K window by itself — leaves
essentially no room for `MAX_PROMPT_TOKENS`+`MAX_OUTPUT_TOKENS` to both be
meaningful. Disabling the GitHub MCP server (`--disable-builtin-mcps`)
reduced it somewhat but still left static content at ~80% of the 16384
prompt budget — still too tight, and loses PR/issue tooling.

**Fix:** built a `qwen3.6:35b-a3b-64k-agentic` model (num_ctx 65536,
num_predict 16384, same graceful-output SYSTEM prompt as 32k-standalone) and a
matching `configs/copilot/copilot-byok-64k-agentic.env` (`MAX_PROMPT_TOKENS=49152`,
`MAX_OUTPUT_TOKENS=16384`). Verified end-to-end: `copilot -p "hi, just
reply OK"` succeeded cleanly, `inputTokens: 21506`, `outputTokens: 23` — no
error, plenty of headroom (49152 - 21506 ≈ 27.6K left for conversation
growth even after static overhead, before context-shift/compaction would
need to kick in).

**Updated recommendation:** use `ctx32k`/`32k-standalone` for plain `ollama
run`/direct-chat use (no tool-schema overhead there). Use `64k-agentic` as
the floor for Copilot CLI or opencode agentic use, specifically *because*
of this large, fixed static-context tax — not because of conversation
length. This also means the earlier "32K is the sweet spot" daily-driver
recommendation applies to chat-only use; agentic/tool-using sessions should
default to 64K.

## Update: model set consolidated to base + 2 "safe" variants

Rationale: every non-"-safe" variant (`ctx16k`, `ctx32k`, `ctx64k`,
`ctx128k`) was built without `num_predict` capped (defaults to
-1/unbounded) and without the graceful-output SYSTEM prompt — i.e. each one
carries the same "terminated mid-think / truncated output" risk that
`32k-standalone`/`64k-agentic` were specifically built to fix. Once the -safe
variants proved out (see above), there was no reason to keep the
unprotected originals around.

**Deleted** (`ollama rm` + removed their Modelfile directories):
`qwen3.6:35b-a3b-ctx16k`, `qwen3.6:35b-a3b-ctx32k`, `qwen3.6:35b-a3b-ctx64k`,
`qwen3.6:35b-a3b-ctx128k`, `qwen3.6:35b-a3b_16k_custom` (an older
pre-systematic experiment predating the tuning workflow in this repo).

**Kept:**
- `qwen3.6:35b-a3b` — base model, required as the `FROM` source for all
  Modelfiles; deleting it would force a ~22GB re-pull on next rebuild.
- `qwen3.6:35b-a3b-32k-standalone` — daily driver for plain chat (`ollama run`,
  no agentic tool-schema overhead).
- `qwen3.6:35b-a3b-64k-agentic` — default for Copilot CLI / opencode
  agentic use (needed for the ~21.5K static tool-schema overhead — see
  above).

**Kept but not built:** `qwen3.6__35b-a3b-ctx128k/Modelfile` directory only,
as a template for a possible future 128K variant (e.g. large-document/RAG
work) — flagged in its own header comment that it needs the same
num_predict-cap + SYSTEM-prompt treatment before being trusted, and isn't
currently registered in `ollama list`.

Fixed a stale reference to the deleted `ctx16k` model in
`opencode.json.example` (and the live `~/.config/opencode/opencode.json`)
left over from before this cleanup.

## Update: repo restructure + rename (`-safe` → `32k-standalone`/`64k-agentic`)

Reorganized into `modelfiles/`, `configs/{copilot,opencode,ollama}/`,
`tests/token-tests/`, `bin/`, `docs/`. Renamed the confusing `-safe` suffix:
`ctx32k-safe` → `32k-standalone` (plain `ollama run`, not usable with
Copilot CLI — its window can't fit the static tool overhead below), and
`ctx64k-safe` → `64k-agentic` (the floor for tool-calling/CLI-agent use).
Rebuilt both Ollama models under the new tags — confirmed cheap: `ollama
create` reused all existing 22GB weight layers, only writing small new
param/manifest layers (no re-download or re-quantization).

Added `bin/copilot-agentic` and `bin/opencode-agentic` launcher scripts that
source/point at the repo-tracked configs directly (`OPENCODE_CONFIG` env var
for opencode, replacing a previously synced copy at
`~/.config/opencode/opencode.json`). Added `configs/ollama/dev-server.env.sh`
(current manual `ollama serve` env, dev/test use only — systemd is disabled
on this host due to an NTFS `chtimes` permission issue) plus a matching
`ollama.service.d-override.conf.sample` + README for a future real
deployment once that's resolved.

**Data loss note:** a chained shell command misfired mid-restructure and
deleted the untracked `tests/token-tests/` artifacts from tests 01–07
(prompt/response/monitor files, plus the `context-probe-test*.sh` driver
scripts) — never git-tracked, not recovered. The narrative findings from
those tests are preserved above; only the raw artifacts and driver scripts
are gone. Test 08's prompt was recreated from session context and re-added.

## Update: output-token headroom + static-overhead audit for agentic configs

### Is 16,384 `num_predict` (the 64k-agentic default) enough?
Ran the real `tests/token-tests/08-copilot-byok-test-prompt.txt` (a
deliberately heavy "design a distributed rate limiter" prompt) directly
against `qwen3.6:35b-a3b-64k-agentic` via `/api/generate` with the full
16,384 budget available:

| Metric | Value |
|---|---|
| `done_reason` | `stop` (natural, not cut off) |
| `eval_count` (output tokens used) | **8,011 / 16,384 (49%)** |

Combined with earlier natural-stop data (essay task: 5,239/16,384 = 32%;
transformer explanation: 3,218/4,096 = 79% of a *much smaller* budget),
**16,384 has never been hit by a natural stop in any test run so far, even
on a deliberately heavy design-doc prompt.** Current recommendation: keep
16,384 as-is — it's generous, not tight. No evidence yet supports raising
it; the earlier truncation complaints were against the old 8,192 cap, not
16,384.

### Copilot CLI static overhead — decomposed
Measured with `copilot -p "hi, just reply OK" --usage-output-file` under
`configs/copilot/copilot-byok-64k-agentic.env`:

| Configuration | `inputTokens` |
|---|---|
| Default (6 core tools + GitHub MCP server) | 21,505 |
| `--disable-builtin-mcps` (MCP removed) | 14,271 |

| Component | Tokens | Share |
|---|---|---|
| GitHub MCP server tool schemas | **7,234** | 34% |
| System prompt + core built-in tools (bash/edit/view/grep/glob/task) | **14,271** | 66% |

No CLI flag exists to strip individual built-in tool schemas (only
permission-gating via `--allow-tool`, which doesn't shrink what's sent), so
the 14,271 core figure can't be decomposed further without intercepting the
raw HTTP request Copilot sends to Ollama (not done — flagged as a possible
future deep-dive if needed).

Also observed `cacheReadTokens: 8,448` on a repeat call — part of the
static cost is served from KV cache on subsequent calls (saves compute),
but it still counts against `num_ctx`/the context budget every time; caching
doesn't shrink the usable window.

### Skill token cost — measured directly
Copilot skills are lazy-loaded: only each skill's `name` + `description`
(from `SKILL.md` frontmatter) sit in the system prompt/tool listing at all
times; the full `SKILL.md` body only loads into context when the skill is
actually invoked. Confirmed by adding one throwaway test skill and
re-measuring: `21,505 → 21,574` input tokens (**+69 tokens** for one
skill). Cost scales roughly with (number of skills) × (description
length), not skill complexity — a handful of skills is cheap; dozens would
start to add up meaningfully against the ~44K headroom after the static
floor.

### opencode baseline — confirmed from session data
Queried opencode's local sqlite DB (`~/.local/share/opencode/opencode.db`,
`message` table) for a genuine cold-cache first call (no `cache.read`):
**7,322 input tokens** — matching the earlier live-test measurement exactly.

| Client | Static overhead (input tokens) |
|---|---|
| Copilot CLI (default: 6 core tools + GitHub MCP) | 21,505 |
| Copilot CLI (`--disable-builtin-mcps`) | 14,271 |
| **opencode (default toolset, no bundled MCP)** | **7,322** |

opencode's baseline is roughly 1/3 of Copilot CLI's default — the lighter
built-in toolset and lack of a bundled GitHub MCP server account for the
difference. For local-model use specifically (where every static token
comes out of a comparatively small context budget), **opencode is the more
context-efficient client** of the two — worth favoring it over Copilot CLI
when the task doesn't specifically need Copilot's GitHub MCP tooling.

## Update: host memory footprint tuning

User observation: `free -h`'s "free" column dipping to ~295-500Mi looked
worrying ahead of heavier multitasking (browser + devtools during app dev).

### "free" vs "available" — not actually a problem
```
total   used   free   shared  buff/cache  available
30Gi    9.0Gi  ~500Mi 392Mi   21Gi        21Gi
```
Linux deliberately fills spare RAM with page cache (including the mmap'd
22GB model weight file) since unused RAM is wasted RAM — it's reclaimed
instantly when a process needs it. **`available` is the real headroom
metric** (~21-23GB here), not `free`. With no swap, the only real risk is
`available` itself running low (triggering OOM-kill), not a low `free`
number by itself.

### `OLLAMA_MAX_VRAM` 7500 → 7750MB: tested live, no effect
Killed/restarted `ollama serve` with `OLLAMA_MAX_VRAM=7750`, reloaded
`64k-agentic`, compared against the 7500 baseline:

| Config | VRAM used | CPU/GPU split | Host RSS |
|---|---|---|---|
| `MAX_VRAM=7500` (baseline) | 7,012 MiB | 81%/19% | ~22.5 GiB |
| `MAX_VRAM=7750` | 7,054 MiB | 78%/22% | ~21.7 GiB |

Identical to the q8_0-only result below — meaning the 250MB bump itself
contributed nothing; GPU layer offload is gated by whole-layer granularity
(a layer can't be partially offloaded), not by how much cap headroom
exists above what's already used. **Not recommended**: no measured
benefit, and it would cost desktop/browser GPU headroom (free VRAM was
already only ~795MiB out of 8,188MiB total) for nothing. Reverted to 7500.

### `OLLAMA_KV_CACHE_TYPE=q8_0` — real win, applied
Ollama supports quantizing the K/V attention cache (default `f16`). Tested
by restarting `ollama serve` with `OLLAMA_KV_CACHE_TYPE=q8_0` and reloading
the model:

| Config | VRAM used | CPU/GPU split | Host RSS (llama-server) |
|---|---|---|---|
| f16 (default, baseline) | 7,012 MiB | 81%/19% | ~22.5 GiB |
| **q8_0** | 7,054 MiB (~same) | **78%/22%** | **~21.7 GiB (−750MB)** |

VRAM usage stayed essentially flat, but the smaller KV-cache buffer freed
enough VRAM headroom for Ollama's auto-balancer to shift a couple more
weight layers from CPU→GPU — same VRAM budget, less CPU-side weight
storage, ~750MB lower host RSS at idle. Also tested with a 30K-token filler
prompt pushed through context: VRAM stayed flat (the KV-cache buffer is
pre-allocated for the full `num_ctx` at load time, not grown incrementally)
and RSS grew by only ~350MB for 30K tokens of live context — confirms the
quantized cache keeps incremental context growth cheap too.

No quality regression observed in testing so far (q8_0 K/V is a widely-used,
low-risk setting in the llama.cpp ecosystem). **Applied**: added to
`configs/ollama/dev-server.env.sh` and the systemd override sample; current
running server has it active.

### Other RAM-reduction levers considered, not (yet) changed
- **Lower `OLLAMA_KEEP_ALIVE`** below 30m would free the ~9GB idle
  footprint sooner when not actively using a model — tradeoff is reload
  latency on next use. Left as-is; revisit if idle RAM pressure becomes a
  real problem (not yet observed).
- **Host-level, non-LLM RAM use**: `ps aux` showed multiple Steam/
  steamwebhelper zygote processes consuming a non-trivial combined RSS
  during this session — unrelated to the LLM stack, but worth closing
  during heavier dev-session multitasking if `available` ever gets tight.

## Unsloth-alignment: sampling params + reasoning-effort skill tiers

Following up on the [Unsloth Qwen3.6 docs](https://unsloth.ai/docs/models/qwen3.6),
which publish per-mode recommended sampling tables, we cross-checked our
Modelfiles against them.

### Sampling parameters

Checked our custom models' fully-merged effective parameters via
`ollama show <model> --parameters` (this merges `FROM` base-model defaults
with our Modelfile's `PARAMETER` overrides). Findings:

- The official `qwen3.6:35b-a3b` Ollama-library base model already ships
  with near-Unsloth-recommended defaults: `top_k=20`, `min_p=0`,
  `repeat_penalty=1`, `top_p=0.95`, `temperature=1`. Our own Modelfiles were
  only overriding `temperature`/`top_p`, silently inheriting the rest — so
  most of the "tuning" here is about *not accidentally clobbering* good
  defaults, not adding new ones.
- One genuine mismatch found: the base model's `presence_penalty=1.5` is
  Unsloth's **non-thinking/instruct** mode value. Our models run in
  **thinking mode** by default (visible "Thinking... / ...done thinking."
  wrapper in output) — Unsloth's thinking-mode tables all recommend
  `presence_penalty=0.0`, since penalizing repeated tokens is counter-
  productive during legitimate reasoning/code repetition.

**Applied** to both `qwen3.6__35b-a3b-64k-agentic/Modelfile` and
`.../32k-standalone/Modelfile` (Unsloth's "thinking mode, precise coding" row):

| Param | Old | New |
|---|---|---|
| `temperature` | 0.7 | **0.6** |
| `top_p` | 0.9 | **0.95** |
| `presence_penalty` | (inherited 1.5) | **0.0** (explicit) |

`top_k`, `min_p`, `repeat_penalty` left unset/inherited — already match
Unsloth's table via the base model. Both models rebuilt (cheap — only the
small params/manifest layer changed, all 22GB weight layers reused).
Verified merged params post-rebuild match the table exactly, and spot-
tested both for coherent, non-gibberish output (relevant since Unsloth's
docs flag KV-cache quantization as a possible gibberish source, and we run
`OLLAMA_KV_CACHE_TYPE=q8_0`) — no issues observed.

### Reasoning-effort tiers via Copilot CLI skills

No local equivalent exists for hosted models' `reasoning_effort` API
parameter — Ollama/Qwen3.6 only exposes binary `enable_thinking`, soft
SYSTEM-prompt nudging, and hard `num_predict` caps, none of which give
real graduated control. As a practical substitute, built two Copilot CLI
**custom skills** under `configs/copilot/skills/`:

- **`quick`**: triggered by `/quick` or quick/fast/brief phrasing; instructs
  the model to cap internal reasoning to 1-2 steps and skip alternative
  exploration.
- **`thorough`**: triggered by `/thorough` or deep/careful phrasing;
  instructs extensive reasoning, edge-case/tradeoff consideration, and
  self-checking before finalizing.

Registered via `copilot skill add configs/copilot/skills/<name>`.
**How it actually works** (confirmed via `--log-level debug` wire-request
inspection): Copilot CLI embeds every registered skill's `name` +
`description` directly into the system instructions as an
`<available_skills>` list — the model reads this list itself and matches
the literal token/phrasing against the current message; no separate
"invoke skill" tool call happens for this kind of natural-language nudge.

**Empirically verified both tiers**, end-to-end with `bin/copilot-agentic`:
- `/quick` prompt ("just a /quick consideration: what's 17 * 23?") —
  model's own reasoning trace explicitly said *"they've used the /quick
  signal, so I should just give a direct answer"*, then answered in ~97
  output tokens.
- `/thorough` prompt (Go worker-pool mutex-vs-channel design question) —
  model produced a much longer, more deliberate answer (~1,000+ output
  tokens) covering tradeoffs and example code.

Skill token cost confirmed cheap (see earlier "skill token cost" section):
name+description only sit in context; full `SKILL.md` body never loads for
this style of skill since there's no tool invocation to trigger it.

**opencode compatibility**: not yet verified whether opencode has an
equivalent skill-discovery mechanism. Until confirmed, treat `/quick` and
`/thorough` as Copilot-CLI-only.

### opencode skill support — confirmed, different mechanism than Copilot CLI

opencode has its own native skill system (`opencode debug skill` lists
discovered skills; `.opencode/skill(s)/<name>/SKILL.md` project/global
convention, same frontmatter shape as Copilot CLI's). Key difference from
Copilot CLI: **opencode surfaces skills as literal slash commands**
(`/quick`, `/thorough`) rather than relying purely on the model matching a
natural-language description — the skill's `name` becomes an actual
invocable command.

**Setup**: rather than duplicating `SKILL.md` files, `configs/opencode/
opencode.json.example` points opencode at the existing
`configs/copilot/skills/` directory via:
```json
"skills": { "paths": ["{env:OPENCODE_SKILLS_DIR}"] }
```
`{env:VAR}` interpolation (documented for MCP headers, confirmed here to
also work for `skills.paths`) resolves at launch time — `bin/opencode-
agentic` now exports `OPENCODE_SKILLS_DIR=$REPO_ROOT/configs/copilot/
skills` before exec'ing opencode, so this works regardless of which
project directory opencode is launched from. Note this path resolves
relative to opencode's **cwd at launch**, not relative to the config
file's own directory — a plain relative path (`"../copilot/skills"`)
silently resolved against the wrong base and found nothing.

**Verified working** via `bin/opencode-agentic run "/quick ..."` and
`"/thorough ..."`:
- `/quick what's 17 * 23?` → terse `391`, no elaboration.
- `/thorough should I use a mutex or channel for a go worker pool?` → long,
  structured answer covering both options, code examples, and a rule of
  thumb.

Confirmed via `opencode debug skill` that both `quick` and `thorough` are
discovered (alongside opencode's built-in `customize-opencode` skill) with
`location` correctly pointing at the shared `configs/copilot/skills/`
files — no duplication needed between the two CLI tools.

## 128K feasibility test — new default agentic tier

Tested whether we could push past 64K (96K? straight to 128K?) while
keeping headroom for other RAM use (browser + devtools) — with the goal
of finding the memory-cost curve, not just "does it load".

### Idle-load memory (fresh, ~0 tokens context)

| Config | num_batch | VRAM | Host RSS | GPU split |
|---|---|---|---|---|
| 64K (baseline) | 256 | 7,056 MiB | ~21.7 GB | 78/22 |
| 96K | 256 (default) | 5,722 MiB | ~22.8 GB | degraded (more CPU) |
| 96K | **128** | 7,096 MiB | ~21.9 GB | 78/22 |
| 128K | **128** | 7,050 MiB | ~22.0 GB | 81/19 |

**Key finding**: `num_batch=256` (used by 32k-standalone/64k-agentic)
breaks Ollama's CPU/GPU auto-balancer above ~64K context — the larger
prompt-processing buffer needed at that batch size competes with KV-cache
VRAM at load time, pushing weight layers CPU-ward and *increasing* host
RSS despite lower VRAM use. Dropping to `num_batch=128` fixes this
completely: 96K and 128K then both measure at essentially the **same**
footprint as 64K.

### Under filled context (warm model, same ~18K-token prompt)

All three (with `num_batch=128` where relevant) land around 21.9–22.0 GB
RSS — no meaningful difference by context size once batch is tuned.
Pushed further: a ~57K-token fill on the 128K config only grew RSS to
~22.1 GB (+~150MB over the 18K-token baseline) — confirms q8_0 KV-cache
growth stays cheap even much deeper into a large window. `available` RAM
(the real headroom metric) stayed ~21-22GB in every configuration tested.

### Does num_batch=128 help at 64K too? No — tested, no benefit

Asked whether 64k-agentic should also drop to `num_batch=128` for extra
headroom. Measured on a warm model with the same ~18K-token filler prompt:

| batch | prompt-eval speed | Host RSS | VRAM/split |
|---|---|---|---|
| 256 (current, kept) | ~244 tok/s (75.2s) | ~22.0 GB | 7,056 MiB, 78/22 |
| 128 | ~146 tok/s (125.3s) | ~21.9 GB | 7,036 MiB, 78/22 |

At 64K the auto-balancer already gets a good split at `num_batch=256` —
the degradation only appears at ≥96K. So `num_batch=128` at 64K costs
~40% slower prompt ingestion for no memory benefit. **Left 64k-agentic's
Modelfile unchanged** (`num_batch=256`).

### Decision: 128K is the new default agentic tier

Since 96K (tuned) and 128K cost the same, went straight to 128K instead of
adding 96K as an intermediate step — no reason to stop short of the
larger ceiling. Built `qwen3.6__35b-a3b-128k-agentic` (replaces the old
untested `qwen3.6__35b-a3b-ctx128k` template):
- `num_ctx 131072`, `num_batch 128`, same Unsloth-aligned sampling as the
  other tiers (`temperature 0.6`, `top_p 0.95`, `presence_penalty 0.0`).
- `num_predict` raised to **32768** (vs 16384 in the other tiers) — matches
  Qwen3.6/Unsloth's general recommended output length, practical here
  since 128K leaves 98,304 tokens for input even at the full output cap.
- Same graceful-output SYSTEM prompt as the other tiers.

128k-agentic was built and initially made the default in both tools, then
**reverted back to 64k-agentic as default** after the tok/s comparison and
model-switching investigation below. See "64K vs 128K: final tok/s
comparison and default decision" for the reasoning.

### 64K vs 128K: final tok/s comparison and default decision

Measured generation speed (not just prompt-eval) on both warm models,
same ~18K-token filler prompt + short summary ask:

| tier | prompt-eval | generation |
|---|---|---|
| 64k-agentic (batch=256) | 247.1 tok/s | 36.6 tok/s |
| 128k-agentic (batch=128) | 137.4 tok/s | 34.6 tok/s |

Generation speed is roughly comparable (~35-37 tok/s either way) — the
real cost of 128K is prompt-*ingestion* throughput, ~44% slower. That
matters more for long documents/large-context dumps than for typical
conversational turns.

**Model-switching investigation**: wanted 64K as the default for
performance, with the ability to switch to 128K on the fly within the
same session depending on the task. Investigated both tools:

- **opencode**: real per-session `/model` switching — its
  `provider.<name>.models` map is a genuine multi-model catalog, and
  `/model` can switch between any configured models, including both of
  our Ollama BYOK-style tiers. Already verified working with skills
  testing in a prior session.
- **Copilot CLI**: **BYOK is single-model-per-process — no in-session
  switching is possible.** Confirmed via multiple angles:
  1. `copilot help providers` only documents singular env vars
     (`COPILOT_MODEL`, `COPILOT_PROVIDER_MODEL_ID`,
     `COPILOT_PROVIDER_WIRE_MODEL`,
     `COPILOT_PROVIDER_MAX_PROMPT_TOKENS`/`MAX_OUTPUT_TOKENS`) — no
     array/multi-model config form exists.
  2. `~/.copilot/settings.json` / `config.json` have no BYOK model-catalog
     structure to populate.
  3. Live interactive test via `pexpect` (spawning a real `copilot`
     process with a pty and driving `/model`) showed the picker only
     surfaces GitHub's own hosted cloud catalog (claude-\*, gpt-\*,
     gemini-\*, etc.) — never the local BYOK model.
  4. `copilot help config`'s enumerated `model` choices, run **with the
     BYOK env sourced**, still listed only cloud model names — zero
     local/Ollama entries. Confirms `/model` is designed for switching
     within GitHub's hosted catalog only, not custom BYOK endpoints.
  - Env vars are read once at process startup, so the only way to switch
    tiers in Copilot CLI is to exit and relaunch with a different script.

**Decision**: `bin/copilot-agentic` and opencode's default `model` were
both reverted/set to **64k-agentic** (performance default). 128K stays
available as:
- Copilot CLI: a separate launcher, `bin/copilot-agentic-128k` (restart
  required to switch — no live switching possible per above).
- opencode: a second entry in the `models` map, real `/model` switching
  mid-session (no restart needed).

`32k-standalone` remains excluded from both CLI configs — its window
can't fit either tool's static tool overhead, so it's `ollama run`-only.

## Update: qwen3.5:9b tuning (dense model, host now Windows+WSL2 again)

**Host note**: the host has moved off the native-Ubuntu dual-boot setup
described above and is back on Windows 11 + WSL2 (this repo's shell now
runs *in* WSL2, confirmed via `uname -a` showing `microsoft-standard-WSL2`
and `ollama serve` **not** appearing in WSL2's own `ps aux` — the server is
the native Windows Ollama app, reached over the shared `localhost:11434`).
This means the Ubuntu-specific env vars documented above
(`OLLAMA_NUM_GPU`/`OLLAMA_MAX_VRAM`/`OLLAMA_KV_CACHE_TYPE=q8_0`, the no-swap
`systemd-oomd` tuning) are **not currently active** — GPU offload below is
Ollama's own Windows-side auto-balancer, unmodified. Worth re-running
`monitor.sh`-style host RAM checks if real instability shows up again; not
done here since qwen3.5:9b's footprint is small enough that it wasn't
necessary to reach a working tuning.

**Model**: `qwen3.5:9b` — 9.7B params, **dense** (unlike `qwen3.6:35b-a3b`'s
MoE), Q4_K_M, ~6.6GB on disk. `ollama show -v` reveals a hybrid
attention/SSM architecture (`qwen35.block_count 32`,
`full_attention_interval 4` — only 8 of 32 layers use full quadratic
attention, the rest are SSM/linear-attention layers), plus a vision tower
(`qwen35.vision.*`) — same `completion`/`vision`/`tools`/`thinking`
capability set as `qwen3.6:35b-a3b`.

### Measured GPU/CPU split vs. context size (no `num_gpu` override)
| num_ctx | GPU split | total size | gen tok/s | prompt-eval tok/s |
|---|---|---|---|---|
| 8,192 | **100% GPU** | 5.5 GB | 41.6 | 194.2 |
| 12,288 | **100% GPU** | 5.6 GB | (untested, same tier) | — |
| 16,384 | 88%/12% CPU/GPU | 6.3 GB | (not measured) | — |
| 32,768 | 81%/19% CPU/GPU | 6.7 GB | 29.5 | 143.3 |
| 65,536 | 74%/26% CPU/GPU | 7.6 GB | 22.3 | 98.9 |
| 131,072 | 57%/43% CPU/GPU | 9.2 GB | (not measured) | — |

Tested `num_batch=128` (the fix that helped `qwen3.6:35b-a3b` at ≥96K) at
65,536 and 131,072 for this model too — **no measurable difference either
time** (splits identical to `num_batch=256`). Left at 256 (better
prompt-eval throughput) in both new tiers.

### Key finding: dense models degrade far harder than MoE once they spill off-GPU
Comparing at the *same* 65,536 context, same host, same quant tier:

| Model | GPU split | gen tok/s | prompt-eval tok/s |
|---|---|---|---|
| `qwen3.5:9b` (dense, 9.7B) | 74%/26% | **22.3** | 98.9 |
| `qwen3.6:35b-a3b` (MoE, ~3B active) | 78%/22% | **36.6** | 247.1 |

Despite being ~4x the total size, the MoE model is *faster* at equal
context/split — because only its ~3B active experts run on the
CPU-offloaded fraction, while the dense model must run **all** 9.7B params
on whatever fraction lands on CPU. Practical implication: `qwen3.5:9b`'s
real advantage on this host is staying **100% GPU-resident** at small
context (where it's genuinely faster than the MoE model — 41.6 vs 36.6
gen tok/s) — not as a large-context/agentic workhorse, where
`qwen3.6:35b-a3b-*-agentic` remains the better throughput choice even
while partially CPU-offloaded.

### Tiers built
- **`qwen3.5:9b-12k-standalone`** (`modelfiles/qwen3.5__9b-12k-standalone/`)
  — `num_ctx 12288` (last confirmed 100%-GPU point), `num_predict 6144`
  (50/50 split, same rationale as `32k-standalone`), same Unsloth-aligned
  sampling and graceful-output SYSTEM prompt as the qwen3.6 tiers. Daily
  driver for plain `ollama run`/quick chat/coding — the max-speed tier.

### Update: Copilot CLI support dropped for this model, opencode-only agentic tiers
Initially built a `64k-agentic` tier mirroring `qwen3.6:35b-a3b-64k-agentic`
(sized for Copilot CLI's ~21.5K static-overhead floor). Decision reversed:
dropped Copilot CLI support for `qwen3.5:9b` entirely and focused only on
opencode, whose default toolset (no bundled MCP) measures only **~7,322**
static input tokens (vs. Copilot CLI's ~21,505) — see the "opencode
baseline" section above. Since this dense model degrades hard per context
tier (unlike the MoE `qwen3.6:35b-a3b`), there's no reason to pay for a 64K
floor just to satisfy a client this model no longer targets.

Removed: `modelfiles/qwen3.5__9b-64k-agentic/`,
`configs/copilot/copilot-byok-9b-64k-agentic.env`, `bin/copilot-agentic-9b`.

Measured 32K/48K/64K to pick the new opencode-only default:
| num_ctx | GPU split | gen tok/s | prompt-eval tok/s | size |
|---|---|---|---|---|
| 32,768 | 81%/19% | 29.5 | 143.3 | 6.7 GB |
| 49,152 | 78%/22% | 26.0 | 188.4 | 7.1 GB |
| 65,536 | 74%/26% | 22.3 | 98.9 | 7.6 GB |

Both 32K and 48K leave 4-5x opencode's ~7,322-token static overhead in
headroom, so the choice comes down to speed vs. context ceiling, not
fitting a hard floor (unlike the Copilot CLI case). Built both as
opencode-switchable tiers rather than picking one:
- **`qwen3.5:9b-32k-agentic`** (`modelfiles/qwen3.5__9b-32k-agentic/`) —
  `num_ctx 32768`, `num_predict 8192` (25% split, matching the qwen3.6
  agentic tiers' proportion). Default — best speed of the three.
- **`qwen3.5:9b-48k-agentic`** (`modelfiles/qwen3.5__9b-48k-agentic/`) —
  `num_ctx 49152`, `num_predict 12288`. opencode `/model`-switchable
  option for longer tool-use sessions/more file context, trading ~12%
  gen speed for 50% more context room.
- **64K rejected** as the new default: costs the most speed (22.3 tok/s,
  ~24% slower than 32K) for context headroom that opencode's low static
  overhead doesn't actually require.

Both new tiers wired into `configs/opencode/opencode.json.example` only
(no Copilot equivalents) — `qwen3.5:9b-12k-standalone` remains
`ollama run`-only, same reasoning as `32k-standalone` for the 35B model.

## Update: qwen3.5:4b tuning (closest smaller alternative to 9B)

Follow-up to the above: `qwen3.5:9b`'s dense-model cliff (100% GPU only up
to 13,312 context, confirmed by further binary search — 13,824 already
88%/12%) leaves too little headroom once opencode's ~7,322-token static
overhead is subtracted (~6,000 tokens left at a hypothetical tight 13K
tier — rejected as too tight for real multi-step tool-calling, e.g. a
single file read/diff could exceed it). Checked whether Qwen3.5 ships a
7B/8B size to split the difference: it doesn't — the official lineup is
**0.8B / 2B / 4B / 9B / 27B / 35B / 122B / 397B-A17B**, confirmed via
`ollama.com/library/qwen3.5/tags`. 4B is the closest smaller option.

**Model**: `qwen3.5:4b` — 4.7B params, dense, Q4_K_M, 3.4GB on disk. Same
hybrid attention/SSM "qwen35" architecture as 9B (32 layers,
`full_attention_interval 4`), just narrower (`embedding_length` 2560 vs
9B's 4096). Pulled and confirmed via `ollama show -v` to match the
official tag exactly (hash `2a654d98e6fb`).

### Measured GPU/CPU split vs. context size (no `num_gpu` override)
| num_ctx | GPU split | total size | gen tok/s | prompt-eval tok/s |
|---|---|---|---|---|
| 32,768 | **100% GPU** | 3.7 GB | 70.9 | 238.5 |
| 65,536 | **100% GPU** | 4.4 GB | 70.7 | 237.0 |
| 98,304 | **100% GPU** | 5.1 GB | (not separately timed) | — |
| 114,688 | **100% GPU** | 5.5 GB | (not separately timed) | — |
| 122,880 | **100% GPU** | 5.7 GB | (not separately timed) | — |
| 126,976 | **100% GPU** | 5.7 GB | 70.8 | 224.2 |
| 131,072 | 89%/11% CPU/GPU | 6.5 GB | (not measured) | — |

### Key finding: 4B stays 100%-GPU-resident ~10x further out than 9B, at flat speed
9B's 100%-GPU cliff falls at 13,312 context. 4B's cliff falls between
126,976 and 131,072 — nearly **10x further out**. And unlike 9B (which
loses gen speed sharply once split — 41.6 tok/s at 8K down to 22.3 tok/s
at 65K), 4B's gen tok/s is essentially **flat across its entire
100%-GPU-resident range** (70.7–70.9 tok/s from 32K through 127K) —
because it never has to CPU-offload in the first place at any context
size that matters for agentic use on this host. This makes 4B, not 9B,
the model that actually satisfies "small + fast + fits opencode's agentic
context comfortably" on this 8GB-VRAM host. It's also faster in absolute
terms than either larger model at real agentic context: ~70.8 gen tok/s
at 122,880 vs. `qwen3.6:35b-a3b`'s 36.6 tok/s at 65,536 or `qwen3.5:9b`'s
22.3 tok/s at 65,536. The tradeoff is capability, not speed — 4B is a
materially smaller/less capable model per-token than either 9B or 35b-a3b,
appropriate for quick/light tasks rather than deep reasoning.

### Tiers built
- **`qwen3.5:4b-32k-standalone`** (`modelfiles/qwen3.5__4b-32k-standalone/`)
  — `num_ctx 32768`, `num_predict 16384` (50/50 split). Plain `ollama
  run`/chat use, matching the `*-standalone` naming convention; picked to
  match `qwen3.6:35b-a3b-32k-standalone`'s size even though 4B could go
  much larger here too.
- **`qwen3.5:4b-120k-agentic`** (`modelfiles/qwen3.5__4b-120k-agentic/`) —
  `num_ctx 122880`, `num_predict 30720` (25% split). Picked with an
  ~8,192-token safety margin below the measured 126,976→131,072 cliff
  (same margin-below-cliff practice as `qwen3.5:9b-12k-standalone`'s
  12,288 vs. its 13,312 cliff) since these cliffs are sharp/binary, not
  gradual — leaves room for GPU memory variance from other apps. At
  122,880 total context minus opencode's ~7,322-token overhead, that's
  >115K tokens of real tool-calling headroom, at full 100%-GPU speed.
  No Copilot CLI variant, same reasoning as the 9B tiers.

Both wired into `configs/opencode/opencode.json.example` (opencode-only,
default `model` left unchanged at `qwen3.6:35b-a3b-64k-agentic`) as
additional `/model`-switchable options alongside the existing qwen3.5:9b
and qwen3.6:35b-a3b tiers — not a replacement for either, since 4B trades
capability for its speed/context advantage.

## Update: gemma4:26b tuning (real MoE, RAM-headroom alternative)

Motivated by a concrete host problem, not a speed goal: running
`qwen3.6:35b-a3b-64k-agentic` (the existing default) leaves Windows with
only ~1.3GB free system RAM at steady state — measured via
`Get-CimInstance Win32_OperatingSystem` and `Get-Process` on the native
Windows Ollama host, with `llama-server`'s working set at ~17.9GB for an
80%/20% CPU/GPU split at 65,536 context. Too tight alongside normal desktop
use (Chrome, etc). `gemma4:26b` was checked as a lower-footprint MoE
alternative.

**Model**: `gemma4:26b` — officially "Gemma 4 26B A4B", real MoE: 25.2B
total params, **3.8B active** + 1 shared expert (128 total experts, 8
active per token), 30 layers, Gemma-family sliding-window attention
(1024-token window — keeps KV cache small regardless of context), 256K
context ceiling, vision-capable. See
[ollama.com/library/gemma4](https://ollama.com/library/gemma4) ("Best
Practices"): sampling defaults (`temperature=1.0, top_p=0.95, top_k=64`)
already match the base tag's shipped params — no Unsloth-style override
needed here, unlike the Qwen3.x models. Thinking mode is controlled by
Ollama's chat template from the API's `think` field (inserts/omits a
`<|think|>` control token), not manual prompt engineering.

### Measured GPU/CPU split, VRAM, and Windows-side system RAM (no `num_gpu` override)
| num_ctx | CPU/GPU split | GPU VRAM used | free system RAM | gen tok/s | prompt-eval tok/s |
|---|---|---|---|---|---|
| 65,536 | 24%/76% | 7.3/8.2 GB | ~6.7 GB | 33–36 | 72.1 (7.2 cold-start) |
| 131,072 | 22%/78% | 7.7/8.2 GB | ~6.0 GB | 33.1 | 40.3 |

Compare directly to `qwen3.6:35b-a3b-64k-agentic` at the same 65,536
context: 80%/20% CPU/GPU, only ~1.3GB free system RAM, `llama-server`
working set ~17.9GB, but faster (46.6 gen tok/s, 92.9 prompt-eval).

### Key finding: real MoE + sliding-window attention fits far more on this 8GB GPU
Despite being a smaller model overall (25.2B vs 35B total params), the
deciding factor is architecture, not size: `gemma4:26b`'s smaller total
footprint plus its 1024-token sliding-window attention (vs. qwen3.6's
larger full-attention KV cache) lets Ollama's auto-balancer place ~76-78%
of it on GPU instead of qwen3.6's ~20%. That difference alone frees up
~5GB of Windows system RAM. Tradeoff: gen speed is ~25-30% lower, and
there's a real cold-start prompt-eval penalty (~7.2 tok/s on the very
first call after load, jumping to ~72.1 tok/s afterward) caused by sparse
experts lazy-loading via mmap from disk as they're first touched —
subsequent calls stay fast since pages are already resident.

### Tier built (agentic only, per request)
- **`gemma4:26b-64k-agentic`** (`modelfiles/gemma4__26b-64k-agentic/`) —
  `num_ctx 65536`, `num_predict 16384` (25% split, matching the other
  agentic tiers' proportion), sampling pinned to the base's own shipped
  defaults for clarity (not an override). Picked 65,536 over 131,072:
  GPU VRAM is already 94% full at 131,072 (little margin left), and
  prompt-eval tok/s roughly halves (72.1 -> 40.3) — a real cost for
  agentic tool-calling where each turn re-ingests file/diff context.
  65,536 leaves more GPU headroom and much faster prompt ingestion for
  only slightly less free RAM (6.7 vs 6.0 GB).

Wired into `configs/opencode/opencode.json.example` as an additional
`/model`-switchable option — not a replacement for
`qwen3.6:35b-a3b-64k-agentic` (still the default), since the two make
opposite tradeoffs (speed vs. RAM headroom). No standalone tier built
(agentic-only, per request).

## Update: MTP (multi-token prediction / speculative decoding) — already in use, verified beneficial

Prompted by Unsloth's docs (https://unsloth.ai/docs/models/gemma-4,
https://unsloth.ai/docs/models/mtp): MTP lets a model draft several
upcoming tokens at once, which the same model then verifies in parallel,
cutting the number of full forward passes needed per generated token
(quality-neutral — only verified tokens are kept). Unsloth claims ~1.4-2.2x
speedup on GGUFs.

**Finding: we're already running it, without having configured anything.**
`ollama show <model> -v` reveals a `draft_num_predict` parameter baked into
some (not all) of this host's model tags — this is Ollama's native
speculative-decoding knob, set automatically whenever the pulled GGUF
includes a compatible MTP draft head:

| Model | `draft_num_predict` shipped? |
|---|---|
| `qwen3.6:35b-a3b` | **2** (MTP enabled by default) |
| `gemma4:26b` | **3** (MTP enabled by default) |
| `qwen3.5:9b` | not present — no MTP draft head in this Ollama library tag |
| `qwen3.5:4b` | not present — same |
| `gemma4:e4b` | not present — same |

None of this repo's existing Modelfiles set `draft_num_predict` explicitly,
so every `qwen3.6:35b-a3b-*` and `gemma4:26b-64k-agentic` tier has been
using MTP **by default all along**, inherited silently from the base tag.

**Caveat checked and ruled out**: Ollama 0.34.2 (this host's exact
installed version, confirmed via `ollama --version`) has a known GitHub
issue (ollama/ollama#18541) reporting MTP causing a **4x slowdown** (75.1
-> 17.4 tok/s) on `qwen3.8:27b` (a Qwen3.5-architecture model) due to
near-total draft-token rejection. Verified this does **not** affect either
model in active use here — A/B tested MTP on vs. off at equal 65,536
context, same prompt, this host:

| Model | MTP off (`draft_num_predict 0`) | MTP on (shipped default) |
|---|---|---|
| `qwen3.6:35b-a3b` | 37.9 gen tok/s | 41.5-42.0 gen tok/s |
| `gemma4:26b` | 27.5-27.9 gen tok/s | 33.6-36.8 gen tok/s |

MTP gives a real, consistent ~10% (qwen3.6) to ~20-30% (gemma4) speedup on
this host for both models — well short of Unsloth's claimed 2x (that's
likely measured on beefier GPUs, e.g. their RTX 6000 Qwen3.6 benchmark of
240 tok/s), but a genuine free win, not the regression seen on `qwen3.8:27b`.

**Action taken: none needed** — leaving `draft_num_predict` unset (inherit
base tag default) in all existing Modelfiles is already correct. Doesn't
apply to the `qwen3.5:9b`/`qwen3.5:4b` tiers since Ollama's library tags
for those sizes don't ship an MTP draft head (Unsloth's separate MTP GGUF
uploads for the Qwen3.5 family aren't what `ollama pull` fetches). If a
future MTP-enabled small Qwen3.5 tag appears in Ollama's library, worth
re-checking.

## Update: gemma4:26b agentic-coding viability + system prompt / thinking-control review

Investigated three things: whether our Modelfile's `SYSTEM` prompt actually
restricts opencode usage, whether gemma4:26b's native function-calling
works end-to-end through opencode, and how to best control
general-purpose vs. coding/thinking behavior.

### Finding: client-supplied system messages fully replace the Modelfile `SYSTEM` default — for every model, not just gemma4
Tested via `/v1/chat/completions` directly: a request with no `system`
message uses the Modelfile's baked-in `SYSTEM` text (confirmed via its
content shaping the response), but a request that **includes** a `system`
message replaces it entirely — verified with an adversarial test (client
system message "You are a pirate, respond only in pirate speak" fully took
over; the model's own reasoning trace explicitly cited that instruction
with zero trace of our "keep reasoning efficient" text). This is Ollama's
general OpenAI-compat behavior, not gemma4-specific — it equally applies to
every `qwen3.6:35b-a3b-*`/`qwen3.5:*` tier in this repo.

**Practical implication**: since opencode always sends its own system
prompt (with tool definitions/agent instructions), **our Modelfiles'
`SYSTEM` graceful-stop text has zero effect during opencode sessions** —
it only matters for bare `ollama run`/raw-API use without a client system
message. Nothing is "restricting" agentic use here; the instruction is
simply inert in that context, superseded by opencode's own (evidently
adequate — see below) system prompt. No fix needed/attempted — opencode's
default instructions already produce correct tool-calling behavior.

### Finding: `think:false` doesn't fully suppress thinking via the OpenAI-compat endpoint — `reasoning_effort:"none"` does
- Native `/api/chat` + `"think": false` → `thinking` field empty, no
  deliberation overhead. Works as expected.
- `/v1/chat/completions` (what opencode's `@ai-sdk/openai-compatible`
  provider uses) + top-level `"think": false` → **thinking still happens**
  (589-char reasoning trace observed on a trivial question) — this field
  isn't honored on this path.
- `/v1/chat/completions` + `"chat_template_kwargs": {"enable_thinking":
  false}` (the llama-server-native flag per Unsloth's docs) → partially
  reduces it (105 chars) but doesn't fully suppress.
- `/v1/chat/completions` + **`"reasoning_effort": "none"`** → **fully
  suppresses reasoning** (0-length trace), confirmed for both
  `gemma4:26b-64k-agentic` and `qwen3.6:35b-a3b-64k-agentic`.

This **corrects** the earlier "Unsloth-alignment" section's claim that "no
local equivalent exists for hosted models' `reasoning_effort` API
parameter" — this Ollama version (0.34.2) does support it via the
OpenAI-compat endpoint. Not yet confirmed whether opencode's own config/UI
exposes a way to set `reasoning_effort` per-request or per-model (its
schema has a generic untyped `options` object at the agent-config level
that may be the mechanism — unconfirmed). Worth revisiting if default
thinking verbosity becomes a practical latency/token problem in real usage
— for now, `num_predict`'s generous 25%-of-context budget on the agentic
tiers absorbs it without truncation.

### Confirmed: gemma4:26b's native function-calling works correctly end-to-end via opencode
Ran two real agentic tasks against `gemma4:26b-64k-agentic` through
`bin/opencode-agentic run -m ollama/gemma4:26b-64k-agentic "..."`:
- **Glob + Read**: asked to list files and read README.md — correctly
  called `Glob`, then `Read`, then correctly reported the file didn't
  exist (verified true — no false positive/hallucination).
- **Write + Read (real coding task)**: asked to create a Python file with
  a `reverse_string` function + docstring, then read it back — correctly
  called `Write`, produced clean idiomatic code, then `Read` to verify.

Both completed without tool-schema errors, malformed calls, or retries —
**gemma4:26b is viable for real agentic coding work through opencode**, not
just benchmarks-on-paper.

### Recommendation: general-purpose + coding on gemma4:26b
No Modelfile changes needed. In practice:
- Leave thinking **on** (opencode's default) for actual coding/agentic
  work — Unsloth/Google's own benchmarks (LiveCodeBench 77.1%, Codeforces
  ELO 1718) and our own successful tool-calling tests were both with
  thinking enabled; the reasoning budget is what drives code-quality gains.
- The `SYSTEM` prompt tuning that matters for Qwen3.x agentic use doesn't
  transfer here — don't bother customizing it further for opencode use,
  since opencode's own system prompt fully overrides it regardless of what
  it says.
- If a future session shows gemma4 spending too much time/tokens
  "overthinking" simple requests during agentic loops, `reasoning_effort`
  is the confirmed working lever (not `think`/`chat_template_kwargs`) —
  worth testing whether opencode's per-agent `options` field can set it,
  or whether a lower-effort variant tier is worth building.
