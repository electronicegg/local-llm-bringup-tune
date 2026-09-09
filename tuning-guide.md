# Tuning Guide: Fitting Models into 8GB VRAM / 32GB RAM

## Note: OLLAMA_KEEP_ALIVE=1h is a deliberate tradeoff
This host has `OLLAMA_KEEP_ALIVE=1h` set (avoids the cold-load warm-up delay,
~45-60s, on every request) — kept intentionally, not a bug. Consequence: the
full model (~22GB for the Q4 35B-A3B build) stays resident in RAM/VRAM for a
full hour after last use, stacking on top of whatever else you run in that
window (browser, IDE, etc.). Practical guidance given this setting:
- Be mindful of what else you open on the host within an hour of a chat
  session — the model's memory isn't released until idle timeout or a
  manual unload.
- To free memory immediately without changing the global setting, unload a
  specific model on demand: `curl http://localhost:11434/api/generate -d
  '{"model":"<name>","keep_alive":0}'` (used earlier in this session to reset
  baseline before testing).
- If you hit memory pressure again, this is the first thing to check with
  `ollama ps` — a model quietly still "warm" from an hour-old session.

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
