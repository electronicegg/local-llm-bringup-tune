# LLM Glossary

## Core concepts
- **LLM (Large Language Model)**: Neural network trained on text to predict/generate tokens.
- **Parameters**: The model's learned weights. More params ≈ more capability, more memory needed. Written as "7B" = 7 billion parameters.
- **Dense model**: All parameters are used for every token (e.g., Llama 3 8B). Simple, predictable memory/speed.
- **MoE (Mixture of Experts)**: Model has many "expert" sub-networks; only a few activate per token. Named like `35B-A3B` = 35B total params, ~3B "active" per token. Uses less compute than its total size suggests, but still needs ~all params **loaded in memory**, so RAM/VRAM footprint stays large even though it runs fast.
- **Context window / context length**: Max tokens (prompt + response) the model can consider at once. Bigger context = more RAM/VRAM for the KV cache.
- **Token**: Chunk of text (~¾ word average). Models read/write in tokens, not characters.
- **Tokens/sec (t/s)**: Generation speed. Main real-world performance metric.
- **EOS (End-Of-Sequence) token**: A special token the model emits to signal "I'm finished, stop generating." A clean/natural stop (API `done_reason: stop`), distinct from being cut off by a length limit (`done_reason: length`, from `num_predict` or `num_ctx`).

## Quantization (shrinking models to fit memory)
- **Quantization**: Reducing numeric precision of weights (e.g., 16-bit → 4-bit) to cut memory use, at some quality cost.
- **GGUF**: File format used by llama.cpp/Ollama for quantized models. Successor to GGML format.
- **Q4_K_M, Q5_K_M, Q8_0, etc.**: Quantization levels. Q4 ≈ smallest/fastest/lowest quality; Q8 ≈ near full quality, biggest size. `_K_M` variants use smarter mixed-precision per-layer.
- **bpw (bits per weight)**: Average bits used per parameter after quantization; lower = smaller file.
- **Perplexity**: A quality metric — lower is better. Used to compare how much a quantization level degrades a model.

## Runtime / performance terms
- **VRAM**: GPU memory. The hard limit for how much of a model can run at GPU speed.
- **Offloading (GPU layers)**: Splitting a model's layers between GPU (fast) and CPU/RAM (slow) when it doesn't fully fit in VRAM. `n_gpu_layers` / `num_gpu` controls how many layers go to GPU.
- **KV cache**: Memory that stores attention "keys/values" for previous tokens so the model doesn't recompute them. Grows with context length; consumes extra VRAM beyond the model weights.
- **Batch size**: How many tokens are processed together; affects throughput and memory.
- **Inference**: Running a trained model to generate output (as opposed to training it).
- **CPU/RAM offload spillover**: When VRAM is full, extra layers/KV cache run in system RAM — much slower, and if RAM also runs out, the OS pages to disk or the process is killed (likely cause of your "task didn't complete" issue).

## Model behavior/tuning terms
- **Temperature**: Randomness of output. 0 = deterministic/repetitive, higher = more creative/less predictable.
- **Top-p / Top-k**: Sampling strategies that restrict which tokens can be chosen, alternatives/complements to temperature.
- **System prompt**: Instructions given to the model before user input, shaping its behavior/persona.
- **Fine-tuning**: Further training a pretrained model on custom data to change its behavior/knowledge.
- **LoRA (Low-Rank Adaptation)**: A lightweight fine-tuning method that trains small "adapter" layers instead of the whole model — much cheaper than full fine-tuning.
- **RAG (Retrieval-Augmented Generation)**: Feeding the model relevant chunks of your own documents at query time (via a vector search) instead of retraining it — how most "chat with your files" tools work.
- **Agentic / tool use**: Model calling external tools/functions (search, code execution, file access) in a loop to complete multi-step tasks.

## Tooling terms
- **Ollama**: User-friendly wrapper around llama.cpp-style inference; handles model downloading, serving an API, and simple config via `Modelfile`.
- **llama.cpp**: The underlying high-performance C/C++ inference engine (CPU+GPU) that Ollama and many other tools build on. More manual, more configurable.
- **Modelfile**: Ollama's config file for a model (system prompt, params, template).
- **safetensors**: A safer, faster alternative file format to raw PyTorch `.bin` files for storing model weights (usually unquantized, used by Hugging Face).
- **Hugging Face**: The main hub/website where open model weights are published and downloaded from.
