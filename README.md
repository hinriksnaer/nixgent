# nixgent

Declarative, reproducible LLM serving via Nix. Configure a model server in one
place, get an OCI image, a serve script, and an OpenCode provider config.

## Quick start

```bash
nix run .#serve
```

Requires `NVIDIA_VISIBLE_DEVICES` and GPU drivers on the host.
Model weights download to a persistent volume on first run.

## Configuration

Edit the server block in `flake.nix`:

```nix
server = mkServer {
  model = "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ";
  servedModelName = "qwen-coder-32b";
  quantization = "awq";
  maxModelLen = 32768;
  gpuMemoryUtilization = 0.90;
};
```

Rebuild. The image, serve script, and OpenCode config all update.

## Outputs

| Command | What it does |
|---------|-------------|
| `nix build` | Build the OCI container image |
| `nix run .#serve` | Load image into podman + start the server |
| `nix build .#opencode` | Generated `opencode.json` provider config |

## Using with OpenCode

```bash
# Get the provider config
nix build .#opencode && cat result

# Paste into your project's opencode.json, then:
opencode
# /models → select nixgent
```

## Requirements

- Nix with flakes enabled
- Podman
- NVIDIA GPU + drivers + nvidia-container-toolkit
