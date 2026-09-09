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
