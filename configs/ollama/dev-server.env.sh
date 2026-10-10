#!/usr/bin/env bash
# Load common Ollama settings and an optional host profile into the current
# shell before starting `ollama serve`.
#
# Usage:
#   OLLAMA_HOST_PROFILE=y520
#   source configs/ollama/dev-server.env.sh
#   ollama serve
#
# With no profile, only common settings are loaded.

_ollama_config_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
_ollama_common_config="$_ollama_config_dir/common.env"
_ollama_had_allexport=0
case $- in
  *a*) _ollama_had_allexport=1 ;;
esac

case "${_OLLAMA_LOADED_PROFILE:-}" in
  legion5)
    unset OLLAMA_HOST OLLAMA_MODELS OLLAMA_NUM_GPU OLLAMA_MAX_VRAM
    unset OLLAMA_FLASH_ATTENTION OLLAMA_KV_CACHE_TYPE
    ;;
  y520) unset OLLAMA_HOST ;;
esac
unset _OLLAMA_LOADED_PROFILE

if [[ ! -f "$_ollama_common_config" ]]; then
  echo "Common Ollama config not found: $_ollama_common_config" >&2
  unset _ollama_config_dir _ollama_common_config _ollama_had_allexport
  return 1
fi

set -a
# shellcheck source=/dev/null
source "$_ollama_common_config"
[[ "$_ollama_had_allexport" -eq 1 ]] || set +a

if [[ -n "${OLLAMA_HOST_PROFILE:-}" ]]; then
  case "$OLLAMA_HOST_PROFILE" in
    legion5|y520) _ollama_host_config="$_ollama_config_dir/hosts/$OLLAMA_HOST_PROFILE/ollama.env" ;;
    *)
      echo "Unknown Ollama host profile '$OLLAMA_HOST_PROFILE' (expected legion5 or y520)" >&2
      unset _ollama_config_dir _ollama_common_config _ollama_had_allexport
      return 2
      ;;
  esac

  if [[ ! -f "$_ollama_host_config" ]]; then
    echo "Ollama host profile not found: $_ollama_host_config" >&2
    unset _ollama_config_dir _ollama_common_config _ollama_host_config _ollama_had_allexport
    return 1
  fi

  set -a
  # shellcheck source=/dev/null
  source "$_ollama_host_config"
  [[ "$_ollama_had_allexport" -eq 1 ]] || set +a
  _OLLAMA_LOADED_PROFILE="$OLLAMA_HOST_PROFILE"
fi

unset _ollama_config_dir _ollama_common_config _ollama_host_config _ollama_had_allexport
