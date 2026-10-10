#!/usr/bin/env bash
# build-model.sh — builds an Ollama model from a Modelfile using a naming
# convention: the containing directory name maps to the Ollama model name,
# with "__" translating to ":" (Ollama only allows one colon: name:tag).
#
#   qwen3.6__35b-a3b-64k-agentic/  ->  ollama model name: qwen3.6:35b-a3b-64k-agentic
#
# Usage:
#   ./build-model.sh <dir>        # build one model dir or every model below it
#   ./build-model.sh              # build every model below cwd

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

  name="${base/__/:}"   # first "__" becomes ":"

  echo "==> Building '$name' from $modelfile"
  ollama create "$name" -f "$modelfile"
}

build_tree() {
  local root="$1"
  local -a modelfiles=()
  local modelfile

  mapfile -d '' modelfiles < <(find "$root" -type f -name Modelfile -print0 | sort -z)
  if [[ "${#modelfiles[@]}" -eq 0 ]]; then
    echo "No Modelfile found in $root or any subdirectory" >&2
    return 1
  fi

  for modelfile in "${modelfiles[@]}"; do
    build_one "$(dirname "$modelfile")"
  done
}

if [[ $# -gt 0 ]]; then
  for path in "$@"; do
    if [[ -f "$path/Modelfile" ]]; then
      build_one "$path"
    elif [[ -f "$path" && "$(basename "$path")" == "Modelfile" ]]; then
      build_one "$(dirname "$path")"
    elif [[ -d "$path" ]]; then
      build_tree "$path"
    else
      echo "Model directory or Modelfile not found: $path" >&2
      exit 1
    fi
  done
elif [[ -f "./Modelfile" ]]; then
  build_one "."
else
  build_tree "."
fi
