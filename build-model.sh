#!/usr/bin/env bash
# build-model.sh — builds an Ollama model from a Modelfile using a naming
# convention: the containing directory name maps to the Ollama model name,
# with "__" translating to ":" (Ollama only allows one colon: name:tag).
#
#   qwen3.6__35b-a3b-8gb-vram-tuned/  ->  ollama model name: qwen3.6:35b-a3b-8gb-vram-tuned
#
# Usage:
#   ./build-model.sh <dir>        # build one model dir
#   ./build-model.sh              # if cwd itself has a Modelfile, build using
#                                  # cwd's dirname; otherwise build every
#                                  # subdirectory of cwd that has a Modelfile

set -euo pipefail

build_one() {
  local dir="$1"
  local base modelfile name

  # Resolve to an absolute path first so basename works correctly even for
  # "." or "some/dir/" (trailing slash) — plain `basename "."` would return
  # "." instead of the actual directory name.
  dir="$(cd "$dir" && pwd)"
  base="$(basename "$dir")"
  modelfile="$dir/Modelfile"

  if [[ ! -f "$modelfile" ]]; then
    echo "skip: no Modelfile in $dir" >&2
    return 0
  fi

  name="${base/__/:}"   # first "__" becomes ":"

  echo "==> Building '$name' from $modelfile"
  ollama create "$name" -f "$modelfile"
}

if [[ $# -ge 1 ]]; then
  for d in "$@"; do
    build_one "${d%/}"
  done
elif [[ -f "./Modelfile" ]]; then
  # Called from inside a model directory itself — use the current dirname.
  build_one "."
else
  found=0
  for d in */; do
    [[ -f "${d}Modelfile" ]] || continue
    found=1
    build_one "${d%/}"
  done
  if [[ "$found" -eq 0 ]]; then
    echo "No Modelfile found in cwd or any subdirectory of $(pwd)" >&2
    exit 1
  fi
fi
