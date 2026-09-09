# Research Notes: Tools, OS, and Model Shortlist

## 1. Ollama vs llama.cpp

| | Ollama | llama.cpp (raw) |
|---|---|---|
| Setup | `ollama pull <model>`, one command | Build/download binary, manually fetch GGUF |
| Config | `Modelfile` + a handful of CLI/API params | Full CLI flag access (100+ flags) |
| GPU offload control | Simplified (`num_gpu`, auto-detects VRAM) | Precise (`--n-gpu-layers`, per-tensor overrides) |
| Serving | Built-in REST API + model manager | `llama-server` gives OpenAI-compatible API too |
| Community configs | Fewer tunables shown online | Most tutorials/benchmarks target llama.cpp directly |
| Under the hood | **Wraps llama.cpp** (ggml) | The engine itself |

**Recommendation: keep Ollama as your daily driver, but treat it as a thin
shell over llama.cpp.** Every llama.cpp GGUF works in Ollama. When online
configs mention llama.cpp flags, most map directly to Ollama equivalents:

| llama.cpp flag | Ollama equivalent |
|---|---|
| `--ctx-size` | `num_ctx` (API/Modelfile `PARAMETER num_ctx`) |
| `--n-gpu-layers` | `num_gpu` |
| `--batch-size` | `num_batch` |
| `--threads` | `num_thread` |
| quant in filename (Q4_K_M) | choose the matching `:q4_K_M` tag when pulling |

You don't need to abandon Ollama. Reach for raw llama.cpp only if you want:
per-tensor quant overrides, `imatrix` custom quantization, or the newest
model architecture support before Ollama updates.

## 2. OS: WSL2 vs native Ubuntu vs Windows

You confirmed GPU passthrough already works in WSL2, and you currently run
Ollama on Windows. Recommendation: **stay on Windows or WSL2 — don't dual
boot.** Reasoning:
- Dual-booting buys near-zero performance headroom: llama.cpp/Ollama CUDA
  performance in WSL2 is within a few % of native Linux (memcpy overhead is
  the only tax, negligible for inference).
- Your real bottleneck is **VRAM/RAM capacity**, not OS overhead — dual
  booting doesn't add memory.
- Dual boot costs you convenience: no more running your dev tools + local
  LLM API side by side, context-switching reboots to compare model output
  against code you're editing in WSL2.
- **Practical suggestion**: run Ollama on Windows (as you do now) — it can
  serve `localhost:11434`, reachable from WSL2 tools/scripts without any
  extra networking config. This also frees ~1-2GB of RAM WSL2 itself would
  otherwise reserve for a second Ollama instance.

## 3. Model shortlist for 8GB VRAM / 32GB RAM

Legend: **Org (Country)** · size · quant recommendation · fits fully in VRAM?

### Daily drivers (fit fully or almost fully in 8GB VRAM)
| Model | Org (Country) | Size | Best for | Quant | VRAM fit |
|---|---|---|---|---|---|
| Qwen2.5-Coder / Qwen3-Coder 7B–14B | Alibaba (China) | 7B/14B | Coding | Q4_K_M | 7B: yes / 14B: tight, mostly yes |
| Llama 3.1 8B Instruct | Meta (USA) | 8B | General chat, writing | Q4_K_M/Q5_K_M | Yes |
| Mistral Small 3.x (~22-24B) | Mistral AI (France) | ~22B | Chat, agentic (tool-calling) | Q4_K_M | Partial offload (32GB RAM covers rest) |
| Gemma 3 9B/12B | Google DeepMind (USA) | 9B/12B | Chat, writing, long context | Q4_K_M | Yes |
| Phi-4 14B | Microsoft (USA) | 14B | Reasoning, coding | Q4_K_M | Tight, mostly yes |
| DeepSeek-R1-Distill-Qwen 14B/32B | DeepSeek (China) | 14B/32B | Reasoning-heavy tasks | Q4_K_M | 14B yes, 32B needs offload |

### RAG/embeddings companion (small, run alongside chat model)
| Model | Org (Country) | Notes |
|---|---|---|
| nomic-embed-text | Nomic AI (USA) | Standard Ollama embedding model, <1GB, negligible VRAM cost |
| bge-m3 | BAAI (China) | Strong multilingual embeddings alternative |

### "Push the limits" MoE option (your Qwen3.6-35B-A3B case)
| Model | Org (Country) | Total/Active | Quant | Notes |
|---|---|---|---|---|
| Qwen3-30B-A3B / Qwen3.5-35B-A3B class | Alibaba (China) | ~35B / ~3B active | Q4_K_M (~20GB) | Won't fit 8GB VRAM alone; needs GPU+RAM split. Fast per-token (only 3B active) but **large total memory footprint** — the actual cause of your instability was almost certainly `num_ctx` left too high (see tuning-guide.md), not the weights themselves. |
| GPT-OSS 20B (if available in Ollama) | OpenAI (USA) | 20B / MoE | Q4_K_M | Smaller alternative MoE if you want to compare against Qwen |

### Agentic-focused note
Tool-calling reliability depends more on instruction-tuning quality than raw
size — Qwen3 (Coder/Instruct), Llama 3.1+, and Mistral Small all have solid
native tool-calling support in Ollama/llama.cpp templates. Prefer models
explicitly labeled "Instruct" or "Coder" with tool-use in their model card.

## 4. Practical picks given your priorities (chat & coding tied, then agentic, RAG, writing, speed "usable")
1. **Daily driver**: Qwen2.5-Coder or Qwen3-Coder 14B (Q4_K_M) — covers chat
   + coding + decent tool-use, fits mostly in VRAM, fast.
2. **Agentic/tool-use test**: Mistral Small 3.x or Llama 3.1 8B — both have
   mature function-calling templates.
3. **RAG embedding model**: nomic-embed-text (pair with any chat model above).
4. **Stretch/weekend option**: Qwen3.6-35B-A3B — keep it, but only after
   applying the tuning guide (capped `num_ctx`, explicit `num_gpu`).

## Sources checked
- ollama.com/library (model listing, tags/sizes)
- github.com/ggml-org/llama.cpp (engine capabilities)
- huggingface.co (Qwen3.5 release notes/benchmarks)
