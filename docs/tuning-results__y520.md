# Y520 Gemma 4 tuning results

Host: Lenovo Legion Y520, Intel i7-7700HQ (4C/8T), 32GB RAM, GTX 1050 Ti
Laptop (4GB VRAM), Ubuntu Server 24.04.5 LTS, NVIDIA 580.178.04, Ollama
0.35.1, OpenCode 1.18.34. The machine had an 8GB swap file enabled and
showed about 0.02GiB swap used, unchanged during the focused E4B probes.

## Historical candidate comparison

The candidates were tested sequentially with one Ollama request at a time,
4 CPU threads, `num_batch=128`, and thinking disabled. Each run sent the
same short Python coding prompt followed by a one-tool function-call
request. `tests/benchmark-ollama-agentic.py` sampled `/proc` runner RSS and
`nvidia-smi` every 250ms. Rates are Ollama per-request token counters.
Prompts were short (about 42-133 tokens), so prompt-processing rates are
indicative rather than representative of large code inputs.

Reproduce the 32K measurements after building the host model aliases with:

```sh
python3 tests/benchmark-ollama-agentic.py \
  gemma4:26b-a4b-y520-agentic-32k \
  --context 32768 --batch 128 --threads 4 --output 1024 --thinking off
python3 tests/benchmark-ollama-agentic.py \
  gemma4:e4b-y520-agentic-32k \
  --context 32768 --batch 128 --threads 4 --output 1024 --thinking off
```

| Model | Context | Tag size / quant | Runner RSS peak | VRAM peak | Prompt tok/s | Generation tok/s | Tool call |
|---|---:|---:|---:|---:|---:|---:|---|
| Gemma 4 E4B | 8K | 6.6GB, Q4_K_M | 5.52GiB | 3.24GiB | 77.33 | 20.85 | 1/1 |
| Gemma 4 26B A4B | 8K | 15GB, Q4_0 | 14.28GiB | 3.24GiB | 23.71 | 12.15 | 1/1 |
| Gemma 4 E4B | 32K | 6.6GB, Q4_K_M | 5.52GiB | 3.23GiB | 105.22 | 19.74 | 1/1 |
| Gemma 4 26B A4B | 32K | 15GB, Q4_0 | 14.74GiB | 3.09GiB | 35.09 | 11.82 | 1/1 |
| Gemma 4 26B A4B | 32K | 17GB, Q4_K_M | 17.15GiB | 3.07GiB | 32.61 | 11.03 | 1/1 |

The 26B A4B runner's RSS confirms useful RAM offload with GPU acceleration;
`ollama ps` reported 87% CPU / 13% GPU at 8K and 88% CPU / 12% GPU at 16K.
E4B loaded fully on GPU (`ollama ps`: 100% GPU). Both variants completed
the bounded coding task and returned the requested function call with
thinking disabled.

## E4B tuning probes

These were one sequential run per setting, using the same short coding and
tool-call prompts, thinking off, and 1,024 max output tokens. As above, the
75-token coding prompt is not representative for comparing prompt ingestion;
the short run is a screening result, not a final ranking.

| Context | Batch | Threads | Runner RSS peak | VRAM peak | Coding prompt tok/s | Coding generation tok/s | Tool-call generation tok/s |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 32K | 128 | 4 | 5.52GiB | 3.23GiB | 105.72 | 16.47 | 19.33 |
| 32K | 256 | 4 | 5.52GiB | 3.27GiB | 101.07 | 17.78 | 21.52 |
| 32K | 128 | 8 | 5.52GiB | 3.27GiB | 101.38 | 8.96 | 9.78 |
| 64K | 128 | 4 | 6.20GiB | 3.42GiB | 82.61 | 15.05 | 18.39 |

The 64K request completed, using about 0.68GiB more runner RSS and 0.19GiB
more VRAM than the 32K/128/4 probe. That verifies loading and short-request
completion at the larger configured limit, not actual 64K populated-context
quality or stability. Eight threads substantially reduced measured
generation speed, so the Y520's four physical cores remain the safer setting.
Batch 256 was modestly faster on these two short generation samples, but
prompt rates did not improve consistently and there was only one run per
setting; it remains an optional speed experiment rather than the default.

## Current profile choice

At 16K context with thinking enabled and a 1,024-token output cap, the MoE
used 14.57GiB peak runner RSS and 3.08GiB VRAM. It reached the output cap
inside its reasoning on the coding prompt without producing a final answer,
though the tool-call test succeeded. Disabling thinking let the bounded
coding answer and tool call complete at 32K, with 14.74GiB peak runner RSS
and 3.09GiB VRAM. No swap was used in these runs.

The Y520 owner reports that E4B feels acceptably responsive in OpenCode, so
`gemma4:e4b-y520-agentic-32k` is now the default in
`configs/opencode/opencode-y520.json`. E4B loaded fully on the GPU in testing
and used substantially less host RAM than either MoE candidate. The 26B
measurements above remain as historical comparisons; the larger models are
no longer included in the Y520 OpenCode model picker.

The selected profile uses a 32K context limit, a 1,024-token output cap,
4 threads, batch 128, and thinking disabled. Ollama honored `think=false`;
the E4B profile completed an OpenCode `bash` tool call with zero reported
reasoning tokens. The OpenCode request used about 7K input tokens including
tool definitions, leaving room under the configured context limit. Verify
this again when upgrading either runtime.

The OpenCode picker also offers a batch-256 32K variant and a 64K context
variant. The former is an experimental speed option; the latter completed
short API probes but still needs a long-context, multi-step OpenCode test
before being treated as a validated daily profile. Both use the same E4B
weights as the 32K default.

Follow [`tuning-guide__y520.md`](tuning-guide__y520.md) for the next
controlled tests of thread count, batch size, populated context length, and
multi-step OpenCode behavior. The current token-rate measurements used very
short prompts and are not sufficient to select larger-batch or larger-context
settings.

## Caveats and follow-up

- Linux's `free` memory pressure does not describe model memory well because
  mmap-backed model pages count as reclaimable cache; runner RSS is the more
  useful per-model footprint.
- VRAM readings are sampled at 250ms intervals; brief peaks may be missed.
- The tool test verifies a single valid function call, not a full OpenCode
  edit/test/repair cycle. The 32K default, batch-256 option, and 64K option
  each passed an end-to-end OpenCode `bash` call.
- The 26B A4B QAT candidate is slower than E4B in these tests; its local Ollama
  tags were removed after E4B became the preferred Y520 model.
- Longer multi-turn sessions and populated 64K context should be benchmarked
  before promoting the 64K option to the default.
