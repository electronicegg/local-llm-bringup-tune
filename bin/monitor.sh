#!/usr/bin/env bash
# monitor.sh — lightweight periodic sampler for host RAM + GPU VRAM, meant to
# run alongside a model test.
#
# NOTE: originally written for WSL2 (querying the real Windows host via
# powershell.exe, since WSL2's own `free -h` only reflects WSL's capped
# view). Now running on native Ubuntu, so RAM is read directly via `free`.
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

echo "timestamp,ram_used_mb,ram_avail_mb,ram_total_mb,ram_pressure_pct,swap_used_mb,vram_used_mb,vram_total_mb,gpu_util_pct" > "$OUT"

while true; do
  ts="$(date +%H:%M:%S)"

  # Native Ubuntu: read RAM directly from /proc via `free`. Use "available"
  # (not "used") to compute pressure — model weights are mmap'd, so Linux
  # counts them as reclaimable buff/cache rather than "used", which would
  # otherwise make usage look artificially low.
  read -r ram_total_mb ram_used_mb ram_avail_mb <<< "$(free -m | awk '/^Mem:/ {print $2, $3, $7}')"
  ram_pressure_pct=$(( (ram_total_mb - ram_avail_mb) * 100 / ram_total_mb ))
  swap_used_mb="$(free -m | awk '/^Swap:/ {print $3}')"

  # nvidia-smi works directly on this native Ubuntu host.
  gpu_line="$(nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu \
    --format=csv,noheader,nounits 2>/dev/null | head -1)"
  vram_used="$(echo "$gpu_line" | cut -d',' -f1 | tr -d ' ')"
  vram_total="$(echo "$gpu_line" | cut -d',' -f2 | tr -d ' ')"
  gpu_util="$(echo "$gpu_line" | cut -d',' -f3 | tr -d ' ')"

  echo "$ts,$ram_used_mb,$ram_avail_mb,$ram_total_mb,$ram_pressure_pct,$swap_used_mb,$vram_used,$vram_total,$gpu_util" >> "$OUT"

  sleep "$INTERVAL"
done
