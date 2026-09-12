# configs/ollama/dev-server.env.sh — env vars for manually running
# `ollama serve` during testing/rebuilding on this host.
#
# DEV/TEST USE ONLY. Not a production/deployment config — for that, see
# configs/ollama/ollama.service.d-override.conf.sample + README.md in this
# directory, which apply the same values via systemd.
#
# Why manual instead of systemd here: the systemd ollama.service unit was
# disabled on this host due to a permission error touching mtimes
# (chtimes) on the NTFS-mounted model store — `ollama serve` run directly
# in a user shell doesn't hit that restriction. This file is what's
# `source`d before `nohup ollama serve &` each time the server needs a
# restart during tuning work.
#
# Usage:
#   source configs/ollama/dev-server.env.sh
#   nohup ollama serve > /tmp/ollama-serve.log 2>&1 &

export OLLAMA_MODELS=/mnt/windows11/Users/nikko/.ollama/models
export OLLAMA_KEEP_ALIVE=30m
export OLLAMA_NUM_GPU=99
export OLLAMA_MAX_VRAM=7500
export OLLAMA_FLASH_ATTENTION=1
export OLLAMA_NUM_PAR=1

# Quantize the K/V attention cache instead of full f16 precision. Verified
# on this host (see docs/tuning-results.md "memory footprint tuning"):
# frees VRAM headroom that Ollama's auto-balancer spends on offloading a
# couple more weight layers to GPU instead of CPU RAM, netting ~750MB less
# host RSS at idle with no observed VRAM increase or quality regression in
# testing so far.
export OLLAMA_KV_CACHE_TYPE=q8_0
