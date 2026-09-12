# Ollama server configs

Two forms of the same host-wide tuning values, for two different scenarios:

## `dev-server.env.sh` — dev/test use (current setup)
`source` before running `ollama serve` manually in a shell. This is the
active method on this host right now, because the systemd `ollama.service`
unit fails to start: it hits a permission error trying to update file
modification times (`chtimes`) on the NTFS-mounted Windows model store
(`OLLAMA_MODELS`). Running the server manually in a user shell sidesteps
that restriction.

```sh
source configs/ollama/dev-server.env.sh
nohup ollama serve > /tmp/ollama-serve.log 2>&1 &
```

## `ollama.service.d-override.conf.sample` — systemd deployment
For a real always-on setup once the NTFS/chtimes issue above is resolved
(e.g. by moving `OLLAMA_MODELS` to an ext4/native-Linux path, or a fixed
Ollama release). Copy it into a systemd drop-in and reload:

```sh
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo cp configs/ollama/ollama.service.d-override.conf.sample \
    /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart ollama
sudo systemctl enable ollama   # if not already enabled
```

Both files carry identical values; keep them in sync if you retune
`OLLAMA_NUM_GPU` / `OLLAMA_MAX_VRAM` / `OLLAMA_KEEP_ALIVE` etc.
