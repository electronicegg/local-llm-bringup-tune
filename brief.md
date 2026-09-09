# Local LLM Task Brief

## Goal
Run local LLMs reliably on a Legion 5 Pro laptop for coding assistance, general
chat, agentic/tool-use workflows, RAG over personal docs, writing, and learning
LLM internals — without freezing the host or leaving tasks incomplete.

## Hardware
| Component | Spec | Note |
|---|---|---|
| GPU | RTX 4070 Laptop | **8GB VRAM** (confirmed) — the main bottleneck |
| CPU | AMD Ryzen 9 7945HX @ 2.5GHz | 16c/32t, strong for CPU-offload inference |
| RAM | 32GB DDR5 | Windows idles at 40-50% used (~13-16GB free before any LLM work) |
| OS today | Windows 11 host + WSL2 Ubuntu 22.04 (dev work happens here) | |

**Implication**: Effective usable memory for a model is roughly 8GB VRAM +
~10-14GB free RAM (after Windows/WSL2/Chrome overhead) — this is why the
35B-A3B MoE model maxed out both and failed to complete a task.

## Open questions from you (answered)
- Use cases: coding, chat, agentic, RAG, writing, learning internals (all of them)
- OS preference: **undecided** — need a recommendation (see below)
- Model size preference: **both** a reliable daily driver + an occasional
  push-the-limits option
- Tuning scope: quantization selection + runtime params (context length, GPU
  offload layers, batch size)

## Decisions to research/produce
1. **Ollama vs llama.cpp** — recommendation with rationale (convenience vs
   control/config availability).
2. **WSL2 vs native Ubuntu vs Windows-native** — recommendation, considering
   your dev workflow already lives in WSL2, and GPU passthrough behavior.
3. **Model shortlist** — for 8GB VRAM/32GB RAM, per use case, each with:
   name, org/company, country, license, size, why it fits or doesn't.
4. **Quantization + runtime tuning guide** — concrete settings (quant level,
   `num_gpu`/`n_gpu_layers`, context length, batch size) to stay stable and
   avoid VRAM/RAM overflow.
5. **Reference glossary** — done (`glossary.md`).

## Non-goals (unless you say otherwise)
- Training a model from scratch.
- Multi-GPU / cloud offload setups.
- Production-grade serving (this is single-user local use).

## Deliverables
- `glossary.md` — done.
- `brief.md` — this file.
- `research-notes.md` (proposed next) — tool comparison + model shortlist with
  org/country, sized for your hardware.
- `tuning-guide.md` (proposed next) — practical config recipes per tool.

## Open items — answered
1. **WSL2 GPU passthrough**: Works. Tried both WSL2 and Windows-side Ollama;
   currently running on **Windows** side.
2. **Disk space**: 500GB available — not a constraint.
3. **Failure mode**: Silent — model stops responding mid-chat (no crash
   message). Likely a quiet OOM/resource exhaustion, not a clean error.
4. **Model confirmed**: Qwen3.6-35B-A3B (MoE, ~35B total / ~3B active params).
5. **Priorities (in order)**: chat & coding (tied top) → agentic → RAG →
   writing → speed (as long as "usable", not top priority).
6. **Time budget**: In-between — open to a few tuning iterations to land on a
   working setup, since the goal is specifically to learn to tune MoE memory
   usage.

## Working theory on the silent failure
Qwen3.6/3.5-class models ship with very large default context windows
(up to 256K tokens). If Ollama is left at a high `num_ctx`, the KV cache
alone can silently consume the remaining free RAM/VRAM after model weights
are loaded — even though the weights themselves technically fit — causing
the process to stall/hang rather than throw a clear OOM error. This is the
first thing `tuning-guide.md` addresses.

## Next deliverables (in progress)
- `research-notes.md` — tool comparison + OS recommendation + model shortlist
  (org/country included) sized for 8GB VRAM / 32GB RAM.
- `tuning-guide.md` — concrete Ollama (and llama.cpp) settings: quant level,
  `num_ctx`, `num_gpu`/GPU layers, batch size, plus a step-by-step tuning loop
  for the Qwen3.6-35B-A3B case.
