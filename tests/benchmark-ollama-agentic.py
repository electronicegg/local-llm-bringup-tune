#!/usr/bin/env python3
"""Measure Ollama coding generation and tool-call performance with RAM/VRAM sampling."""

import argparse
import json
import os
import subprocess
import threading
import time
import urllib.request


def memory_snapshot():
    values = {}
    with open("/proc/meminfo", encoding="utf-8") as meminfo:
        for line in meminfo:
            if line.startswith(("MemTotal:", "MemAvailable:", "SwapTotal:", "SwapFree:")):
                name, value = line.split(":", 1)
                values[name] = int(value.split()[0]) * 1024

    gpu = subprocess.run(
        [
            "nvidia-smi",
            "--query-gpu=memory.used,memory.total,utilization.gpu",
            "--format=csv,noheader,nounits",
        ],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip().splitlines()[0]
    vram_used_mib, vram_total_mib, gpu_util = (int(value.strip()) for value in gpu.split(","))
    runner_rss_bytes = 0
    runner_hwm_bytes = 0
    runner_count = 0
    for entry in os.scandir("/proc"):
        if not entry.name.isdigit():
            continue
        try:
            with open(f"{entry.path}/comm", encoding="utf-8") as comm_file:
                if comm_file.read().strip() != "llama-server":
                    continue
            status = {}
            with open(f"{entry.path}/status", encoding="utf-8") as status_file:
                for line in status_file:
                    if line.startswith(("VmRSS:", "VmHWM:")):
                        key, value = line.split(":", 1)
                        status[key] = int(value.split()[0]) * 1024
            runner_rss_bytes += status.get("VmRSS", 0)
            runner_hwm_bytes += status.get("VmHWM", 0)
            runner_count += 1
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
    return {
        "ram_used_bytes": values["MemTotal"] - values["MemAvailable"],
        "swap_used_bytes": values["SwapTotal"] - values["SwapFree"],
        "vram_used_bytes": vram_used_mib * 1024 * 1024,
        "vram_total_bytes": vram_total_mib * 1024 * 1024,
        "gpu_util_percent": gpu_util,
        "runner_rss_bytes": runner_rss_bytes,
        "runner_hwm_bytes": runner_hwm_bytes,
        "runner_count": runner_count,
    }


def request_json(url, payload, timeout):
    request = urllib.request.Request(
        url,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return json.load(response)


def metric_summary(response):
    prompt_tokens = response.get("prompt_eval_count", 0)
    prompt_ns = response.get("prompt_eval_duration", 0)
    generated_tokens = response.get("eval_count", 0)
    generation_ns = response.get("eval_duration", 0)
    return {
        "load_seconds": round(response.get("load_duration", 0) / 1e9, 3),
        "prompt_tokens": prompt_tokens,
        "prompt_eval_seconds": round(prompt_ns / 1e9, 3),
        "prompt_tokens_per_second": round(prompt_tokens / (prompt_ns / 1e9), 2) if prompt_ns else None,
        "generated_tokens": generated_tokens,
        "generation_seconds": round(generation_ns / 1e9, 3),
        "generation_tokens_per_second": round(generated_tokens / (generation_ns / 1e9), 2)
        if generation_ns
        else None,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("model")
    parser.add_argument("--context", type=int, default=8192)
    parser.add_argument("--batch", type=int, default=128)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--output", type=int, default=256)
    parser.add_argument(
        "--system-prompt",
        default=(
            "You are an efficient coding agent. Keep internal reasoning concise, "
            "use tools when needed, and always finish with a clear user-facing answer."
        ),
    )
    parser.add_argument(
        "--thinking",
        choices=("on", "off"),
        default="on",
        help="Gemma thinking mode for both the coding and tool-call requests",
    )
    parser.add_argument("--timeout", type=int, default=900)
    parser.add_argument(
        "--url",
        default=os.environ.get("OLLAMA_API_URL", "http://127.0.0.1:11434"),
    )
    args = parser.parse_args()

    samples = []
    sample_errors = []
    stop = threading.Event()

    def sample_resources():
        while not stop.is_set():
            try:
                samples.append((time.monotonic(), memory_snapshot()))
            except (OSError, subprocess.CalledProcessError, ValueError, KeyError) as error:
                sample_errors.append(str(error))
                stop.set()
            stop.wait(0.25)

    options = {
        "num_ctx": args.context,
        "num_batch": args.batch,
        "num_thread": args.threads,
        "num_predict": args.output,
    }
    think = args.thinking == "on"
    base = args.url.rstrip("/")
    runs = []
    baseline = memory_snapshot()
    sampler = threading.Thread(target=sample_resources, daemon=True)
    sampler.start()
    try:
        coding = request_json(
            f"{base}/api/chat",
            {
                "model": args.model,
                "messages": [
                    {"role": "system", "content": args.system_prompt},
                    {
                        "role": "user",
                        "content": (
                            "Write a concise Python function that groups a list of dictionaries "
                            "by a given key. Include one short pytest test. Keep the entire answer "
                            "under 180 words."
                        ),
                    }
                ],
                "think": think,
                "stream": False,
                "options": options,
            },
            args.timeout,
        )
        runs.append(
            {
                "test": "coding",
                **metric_summary(coding),
                "response_preview": coding.get("message", {}).get("content", "")[:240],
                "thinking_preview": coding.get("message", {}).get("thinking", "")[:240],
                "finish_reason": coding.get("done_reason"),
            }
        )

        tool = request_json(
            f"{base}/api/chat",
            {
                "model": args.model,
                "messages": [
                    {
                        "role": "system",
                        "content": (
                            f"{args.system_prompt} Use the provided tool exactly once "
                            "to complete the user's request."
                        ),
                    },
                    {
                        "role": "user",
                        "content": "Record the result with status ready and note gemma4-y520-benchmark.",
                    },
                ],
                "tools": [
                    {
                        "type": "function",
                        "function": {
                            "name": "record_result",
                            "description": "Record a benchmark result.",
                            "parameters": {
                                "type": "object",
                                "properties": {
                                    "status": {"type": "string"},
                                    "note": {"type": "string"},
                                },
                                "required": ["status", "note"],
                            },
                        },
                    }
                ],
                "think": think,
                "stream": False,
                "options": options,
            },
            args.timeout,
        )
        tool_calls = tool.get("message", {}).get("tool_calls", [])
        runs.append(
            {
                "test": "tool_call",
                **metric_summary(tool),
                "tool_call_count": len(tool_calls),
                "tool_calls": tool_calls,
                "response_preview": tool.get("message", {}).get("content", "")[:240],
                "thinking_preview": tool.get("message", {}).get("thinking", "")[:240],
                "finish_reason": tool.get("done_reason"),
            }
        )
    finally:
        stop.set()
        sampler.join()

    if not samples:
        detail = sample_errors[-1] if sample_errors else "sampler returned no data"
        raise RuntimeError(f"No RAM/VRAM samples were collected: {detail}")
    if sample_errors:
        raise RuntimeError(f"Resource sampling failed: {sample_errors[-1]}")

    memory = [sample for _, sample in samples]
    gib = 1024**3
    result = {
        "model": args.model,
        "context": args.context,
        "batch": args.batch,
        "threads": args.threads,
        "thinking": args.thinking,
        "configured_output_limit": args.output,
        "sample_count": len(samples),
        "pre_request_baseline": {
            "ram_used_gib": round(baseline["ram_used_bytes"] / gib, 2),
            "swap_used_gib": round(baseline["swap_used_bytes"] / gib, 2),
            "vram_used_gib": round(baseline["vram_used_bytes"] / gib, 2),
            "runner_rss_gib": round(baseline["runner_rss_bytes"] / gib, 2),
        },
        "peak": {
            "ram_used_gib": round(max(m["ram_used_bytes"] for m in memory) / gib, 2),
            "swap_used_gib": round(max(m["swap_used_bytes"] for m in memory) / gib, 2),
            "vram_used_gib": round(max(m["vram_used_bytes"] for m in memory) / gib, 2),
            "gpu_util_percent": max(m["gpu_util_percent"] for m in memory),
            "runner_rss_gib": round(max(m["runner_rss_bytes"] for m in memory) / gib, 2),
            "runner_hwm_gib": round(max(m["runner_hwm_bytes"] for m in memory) / gib, 2),
        },
        "runs": runs,
    }
    print(json.dumps(result, indent=2))
    if runs[-1]["tool_call_count"] != 1:
        raise SystemExit("Tool-call smoke test did not produce exactly one tool call")


if __name__ == "__main__":
    main()
