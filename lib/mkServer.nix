# mkServer -- declare a model server, get everything from one config.
#
# Usage:
#   server = mkServer {
#     model = "Qwen/Qwen2.5-Coder-32B-Instruct-AWQ";
#     quantization = "awq";
#     maxModelLen = 32768;
#   };
#
# Returns:
#   server.build    -- OCI image derivation (nix build)
#   server.serve    -- load + run the image (nix run)
#   server.opencode -- generated opencode.json provider config
#   server.config   -- the resolved config for introspection
{pkgs}: {
  # ── Model ──
  model,
  servedModelName ? null,
  quantization ? null,
  maxModelLen ? null,
  maxOutputLen ? 8192,
  dtype ? null,

  # ── Server ──
  host ? "0.0.0.0",
  port ? 8000,
  gpuMemoryUtilization ? 0.90,
  tensorParallelSize ? null,

  # ── Tool calling (required for OpenCode) ──
  toolCallParser ? "hermes",

  # ── Extra CLI flags ──
  extraArgs ? [],

  # ── Upstream image ──
  vllm ? {
    imageName = "vllm/vllm-openai";
    imageDigest = "sha256:61fc8a896b0a4fbbbdc063bc4b0dbc25ce98e02b5050c24aeb7830ac02039b14";
    sha256 = "sha256-/0ooJaTPqowcYOGzkSLeKpREOTo2+DatEQKeA+yZaR8=";
    tag = "v0.28.0";
  },
}: let
  lib = pkgs.lib;

  modelName =
    if servedModelName != null
    then servedModelName
    else model;

  # ── vllm serve command (baked into the image) ──

  vllmArgs =
    [model]
    ++ ["--host" host "--port" (toString port)]
    ++ lib.optionals (servedModelName != null) ["--served-model-name" servedModelName]
    ++ lib.optionals (quantization != null) ["--quantization" quantization]
    ++ lib.optionals (maxModelLen != null) ["--max-model-len" (toString maxModelLen)]
    ++ ["--gpu-memory-utilization" (toString gpuMemoryUtilization)]
    ++ lib.optionals (dtype != null) ["--dtype" dtype]
    ++ lib.optionals (tensorParallelSize != null) ["--tensor-parallel-size" (toString tensorParallelSize)]
    ++ lib.optionals (toolCallParser != null) ["--enable-auto-tool-choice" "--tool-call-parser" toolCallParser]
    ++ extraArgs;

  vllmCmd = "vllm serve " + lib.escapeShellArgs vllmArgs;

  # ── Entrypoint (baked-in vllm serve command) ──

  entrypoint = pkgs.writeShellApplication {
    name = "nixgent-entrypoint";
    runtimeInputs = [];
    text = "exec ${vllmCmd}";
  };

  # ── OCI image ──

  baseImage = pkgs.dockerTools.pullImage {
    inherit (vllm) imageName imageDigest sha256;
    finalImageTag = vllm.tag;
  };

  # Tag is derived from the Nix store hash of the entrypoint so every
  # config change produces a unique image tag and stale podman images
  # are never accidentally reused.
  imageTag = let
    hash = builtins.hashString "sha256" (toString entrypoint);
  in "${vllm.tag}-${builtins.substring 0 8 hash}";

  build = pkgs.dockerTools.buildLayeredImage {
    name = "nixgent";
    tag = imageTag;
    fromImage = baseImage;
    config = {
      Entrypoint = ["${entrypoint}/bin/nixgent-entrypoint"];
      Env = [
        "NVIDIA_VISIBLE_DEVICES=all"
        "NVIDIA_DRIVER_CAPABILITIES=compute,utility"
        # Disable hf_transfer (requires a separate pip package not in the base image)
        "HF_HUB_ENABLE_HF_TRANSFER=0"
      ];
      ExposedPorts."${toString port}/tcp" = {};
    };
  };

  # ── Serve (load image + podman run) ──

  imageRef = "${build.imageName}:${build.imageTag}";

  serve = pkgs.writeShellScriptBin "nixgent-serve" ''
    set -euo pipefail

    if ! podman image exists "${imageRef}" 2>/dev/null; then
      echo "Loading image (this may take a minute)..."
      podman load < "${build}"
      # Clean up old nixgent images
      podman images --format '{{.Repository}}:{{.Tag}}' \
        | grep '^localhost/nixgent:' \
        | grep -v '${imageRef}' \
        | xargs -r podman rmi 2>/dev/null || true
    fi

    echo "nixgent: ${modelName} on http://127.0.0.1:${toString port}/v1"
    echo ""

    # --ipc=host is required by PyTorch/NCCL for shared memory
    exec podman run --rm \
      --gpus all \
      --ipc=host \
      -v nixgent-models:/root/.cache/huggingface \
      -v nixgent-tmp:/tmp \
      -p "${toString port}:${toString port}" \
      ''${HF_TOKEN:+-e "HF_TOKEN=$HF_TOKEN"} \
      "$@" \
      "${imageRef}"
  '';

  # ── OpenCode provider config ──

  opencodeConfig = {
    "$schema" = "https://opencode.ai/config.json";
    plugins = ["-opencode.provider.vllm"];
    provider.vllm-local = {
      npm = "@ai-sdk/openai-compatible";
      name = "vllm-local";
      options.baseURL = "http://127.0.0.1:${toString port}/v1";
      models.${modelName} = {
        name = modelName;
        reasoning = true;
        tool_call = true;
        limit = {
          context = maxModelLen;
          output = maxOutputLen;
        };
      };
    };
  };

  opencode = pkgs.writeText "nixgent-opencode.json"
    (builtins.toJSON opencodeConfig);
in {
  inherit build serve opencode;

  config = {
    inherit model modelName port quantization maxModelLen maxOutputLen
      gpuMemoryUtilization toolCallParser;
  };
}
