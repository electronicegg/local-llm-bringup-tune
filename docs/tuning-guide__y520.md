# Y520 Gemma 4 tuning guide

## Hardware and current baseline

The Y520 has an i7-7700HQ (4 physical cores / 8 threads), 32GB RAM, and a
GTX 1050 Ti with 4GB VRAM. The tested E4B Q4_K_M profile uses 4 threads,
`num_batch=128`, a 32K context limit, and thinking disabled. At 32K it
measured 5.52GiB peak runner RSS and 3.23GiB peak VRAM; the short benchmark
prompts measured 19.74 generated tokens/second. See
[`tuning-results__y520.md`](tuning-results__y520.md) for the complete
measurements and caveats.

Keep this separate from [`tuning-guide__legion5.md`](tuning-guide__legion5.md):
its 8GB GPU, 16-core CPU, Windows/WSL, and global GPU-offload guidance do not
describe the Y520's hardware or Ollama setup.

## What to measure

Treat each setting as a separate experiment and record the exact model tag,
Ollama/OpenCode versions, context, batch, threads, thinking mode, prompt and
output token counts, and whether the request was a cold or warm load.

- **Prompt evaluation:** measure with realistic long inputs. The existing
  benchmark prompts are only about 42-133 tokens; their prompt tokens/second
  figures are too noisy to compare prompt-processing settings. Use repeatable
  4K, 8K, and 16K-token inputs, including representative OpenCode tool
  definitions and repository context.
- **Generation:** request a fixed, substantial output (for example 256-512
  tokens) and compare generated tokens/second. Keep prompt and output lengths
  constant across candidates. `num_batch` mainly affects prompt ingestion;
  do not expect it by itself to improve token-by-token generation speed.
- **Memory headroom:** sample runner RSS, VRAM, available system RAM, swap,
  and GPU utilization throughout load, prompt ingestion, and generation.
  Compare both short and long populated contexts. A configured context limit
  is not the same as a test that actually fills that context.
- **Agent behavior:** after API-level timing, test OpenCode with the same
  small repository task: inspect files, make a bounded edit, run the relevant
  test, and report the result. A single successful tool call checks basic
  compatibility but not multi-step coding reliability.
- **Cold and warm use:** record first-load latency separately from
  generation speed. Repeat warm runs to see normal interactive latency and
  confirm the model unloads as expected when idle.

Run one request at a time. Alternate candidate settings or repeat each
setting at least three times, then compare medians rather than one best run.
Avoid concurrent model requests and other heavy workloads during comparisons.
On a laptop, note thermal or power throttling during sustained tests; a short
run may not predict a long coding session.

## Recommended tuning order

Change one variable at a time, retaining the current 32K / batch 128 / 4
thread profile as the control:

1. **Threads:** compare 4 against 8 at the same context and batch. The CPU
   has four physical cores and eight logical threads; hyperthreads may or may
   not help, especially while E4B is mostly or fully GPU-offloaded.
2. **Batch:** compare 128 against 256 using long prompt inputs. Try 512 only
   if 256 is stable and prompt ingestion remains a bottleneck. Stop increasing
   if memory headroom shrinks or requests fail; a higher batch is not
   automatically a faster generation setting.
3. **Context:** keep 32K as the default unless the use case needs more. Test
   larger limits stepwise (for example 48K, then 64K) with long populated
   prompts and an OpenCode task. Record memory and latency at each step; do
   not infer long-context capacity from an empty prompt sent with a large
   `num_ctx`.
4. **Combined candidate:** only combine the best individually tested thread,
   batch, and context settings after measuring their interaction. Re-run the
   same end-to-end OpenCode task and check for errors, truncation, or
   unacceptable response latency.

Keep `think=false` for the current responsive agent profile. Thinking-on
should be evaluated separately with a suitable output budget and tasks that
need reasoning; otherwise the model can spend the budget thinking without
returning a usable answer.

## Resource and quality guardrails

E4B already approaches the GTX 1050 Ti's VRAM capacity at the 32K baseline.
Leave headroom for context/KV cache and desktop/system use; if a larger
context or batch causes load errors, VRAM exhaustion, swapping, or unstable
latency, return to the last known-good profile rather than trying to force
more GPU offload.

Compare answer correctness and completion as well as speed. Use a small,
repeatable set of representative coding tasks and verify generated changes
with tests. Record failed, incomplete, or truncated runs; do not discard them
as outliers without identifying a cause.
