{
  description = "nixgent -- reproducible self-hosted LLM serving via Nix";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = {
    self,
    nixpkgs,
  }: let
    system = "x86_64-linux";
    pkgs = import nixpkgs {
      inherit system;
      config.allowUnfree = true;
    };

    mkServer = pkgs.callPackage ./lib/mkServer.nix {};

    # ── Server configuration ──
    #
    # This is the single source of truth.
    # Change it here, rebuild, and the image + serve + opencode config all update.
    server = mkServer {
      model = "cyankiwi/Qwen3.6-27B-AWQ-INT4";
      servedModelName = "qwen3.6-27b";
      maxModelLen = 32768;
      gpuMemoryUtilization = 0.85;
      toolCallParser = "qwen3_coder";
      extraArgs = [
        "--max-num-seqs" "1"
        "--reasoning-parser" "qwen3"
        "--language-model-only"
      ];
    };
  in {
    packages.${system} = {
      default = server.build; # nix build  → OCI image
      serve = server.serve; # nix run .#serve  → load + run
      opencode = server.opencode; # nix build .#opencode → provider config
    };

    lib = {inherit mkServer;};

    formatter.${system} = pkgs.alejandra;
  };
}
