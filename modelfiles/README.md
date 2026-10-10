# Model files by host

Place a Modelfile directly under `modelfiles/` only when it is intended and
validated for all supported hosts. Put hardware-specific variants under a
host directory such as `modelfiles/legion5/` or `modelfiles/y520/`.

The Qwen3.6 variants are Legion 5 Pro-tuned and live under `legion5/`.
Gemma 4's Y520 E4B profile and historical 26B A4B comparison profiles live
under `y520/`. Their context, batch size, thread count, and output limits
are recorded in their Modelfiles and benchmarked in
`docs/tuning-results__y520.md`. Current Y520 tuning guidance is in
`docs/tuning-guide__y520.md`.

`build-model.sh` can build a single model directory, a host directory, or
all Modelfiles under the current directory. For example:

```sh
./modelfiles/build-model.sh modelfiles/legion5
```

The containing model directory maps to the Ollama name, with `__` replaced
by `:` (for example, `qwen3.6__35b-a3b-32k-standalone` becomes
`qwen3.6:35b-a3b-32k-standalone`).
