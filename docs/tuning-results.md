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
