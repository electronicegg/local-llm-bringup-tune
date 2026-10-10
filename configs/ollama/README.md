# Ollama host configuration

Use a shared config plus an optional host profile. Each host profile is a
single `.env` file consumed by both the manual loader and its systemd
drop-in, keeping values in one place:

```text
configs/ollama/
├── README.md
├── common.env
├── dev-server.env.sh
└── hosts/
    ├── legion5/
    │   ├── ollama.env
    │   └── ollama.service.d-override.conf.sample
    └── y520/
        ├── ollama.env
        └── ollama.service.d-override.conf.sample
```

`common.env` contains settings currently shared by both hosts. A host's
`ollama.env` overrides or adds to those values. Add a new host by creating a
directory under `hosts/`, placing its `ollama.env` and systemd drop-in
there, and adding its name to `dev-server.env.sh`'s profile selection and
profile-cleanup cases.

## Manual development server

From the repository root, source the common config and the chosen host
profile, then start Ollama in the same shell:

```sh
OLLAMA_HOST_PROFILE=y520
source configs/ollama/dev-server.env.sh
ollama serve
```

Set `OLLAMA_HOST_PROFILE=legion5` for Legion-specific settings. Omitting or
unsetting it loads only the common settings:

```sh
unset OLLAMA_HOST_PROFILE
source configs/ollama/dev-server.env.sh
ollama serve
```

Stop the systemd service first if it is already running:

```sh
sudo systemctl stop ollama
```

The Legion 5 Pro's NTFS model store can reject `chtimes` when accessed by the
systemd `ollama` account; running Ollama manually as the interactive user
avoids that issue. The Y520 uses its default model store on ext4.

## Systemd deployment

Install the shared and host-specific environment files, then install that
host's drop-in. Do not install both host profiles on the same Ollama service.
For the Y520:

```sh
sudo install -D -m 0644 configs/ollama/common.env /etc/ollama/common.env
sudo install -D -m 0644 configs/ollama/hosts/y520/ollama.env \
    /etc/ollama/hosts/y520/ollama.env
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo cp configs/ollama/hosts/y520/ollama.service.d-override.conf.sample \
    /etc/systemd/system/ollama.service.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart ollama
sudo systemctl enable ollama
```

For the Legion, substitute `legion5` for `y520` in the install paths and
copy `hosts/legion5/ollama.service.d-override.conf.sample`. Its systemd
profile still depends on resolving the NTFS ownership/`chtimes` issue; the
manual server workflow is the known working method.

The Y520 profile binds Ollama on all interfaces for LAN access. Ollama has
no built-in authentication, so restrict reachability using network/VLAN
ACLs and do not forward port 11434 from the internet.

Build the Y520 model aliases after pulling their base models:

```sh
./modelfiles/build-model.sh modelfiles/y520
```

Launch the Y520-tuned OpenCode setup with `bin/opencode-agentic-y520`. It
defaults to the local Ollama server; set `OLLAMA_BASE_URL` to use this
server from another machine:

```sh
OLLAMA_BASE_URL=http://y520-hostname:11434/v1 \
    bin/opencode-agentic-y520
```

The Legion's `OLLAMA_KV_CACHE_TYPE=q8_0` setting reduced host memory use in
prior testing. It is not enabled on the Y520 until its impact is measured
there. GPU-offload settings in the Legion profile are also host-specific;
the Y520 should use Ollama's automatic offload selection initially.
