#!/usr/bin/env bash
# monitor.sh — lightweight periodic sampler for Windows host RAM + GPU VRAM,
# meant to run alongside a model test (from WSL2, querying the real Windows
# host via powershell.exe, since WSL2's own `free -h` only reflects WSL's
# capped memory, not true host usage).
#
# Usage:
#   ./monitor.sh [interval_seconds] [output_file]
#   ./monitor.sh 2 /tmp/watch.csv &
#   MONITOR_PID=$!
#   ...run test...
#   kill $MONITOR_PID

set -euo pipefail

INTERVAL="${1:-2}"
OUT="${2:-/tmp/monitor.csv}"

echo "timestamp,ram_used_mb,ram_total_mb,ram_pct,vram_used_mb,vram_total_mb,gpu_util_pct" > "$OUT"

while true; do
  ts="$(date +%H:%M:%S)"

  # Single lightweight WMI query (CIM), avoids spawning a full PowerShell
  # session per metric — one call returns both total/free KB.
  read -r total_kb free_kb <<< "$(powershell.exe -NoProfile -Command \
    "(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty TotalVisibleMemorySize),(Get-CimInstance Win32_OperatingSystem | Select-Object -ExpandProperty FreePhysicalMemory)" \
    2>/dev/null | tr -d '\r' | paste -sd' ')"

  ram_total_mb=$(( total_kb / 1024 ))
  ram_free_mb=$(( free_kb / 1024 ))
  ram_used_mb=$(( ram_total_mb - ram_free_mb ))
  ram_pct=$(( ram_used_mb * 100 / ram_total_mb ))

  # nvidia-smi is cheap/fast and works directly from WSL2 (GPU passthrough).
  gpu_line="$(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu \
    --format=csv,noheader,nounits 2>/dev/null | head -1)"
  vram_used="$(echo "$gpu_line" | cut -d',' -f1 | tr -d ' ')"
  vram_total="$(echo "$gpu_line" | cut -d',' -f2 | tr -d ' ')"
  gpu_util="$(echo "$gpu_line" | cut -d',' -f3 | tr -d ' ')"

  echo "$ts,$ram_used_mb,$ram_total_mb,$ram_pct,$vram_used,$vram_total,$gpu_util" >> "$OUT"

  sleep "$INTERVAL"
done
