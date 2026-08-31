{
  description = "hermes-agent — Nous Research AI agent framework (CLI, TUI, web dashboard, desktop, ACP)";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";
    hermes-agent-src = {
      url = "github:NousResearch/hermes-agent/v2026.8.27";
      # Not `follows`-ed: upstream's uv2nix is pinned to its own nixpkgs-unstable revision.
    };
  };

  outputs =
    { nixpkgs, hermes-agent-src, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f {
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
          # Match upstream's nixpkgs revision for piper ABI compatibility.
          pkgsHermesRev = import hermes-agent-src.inputs.nixpkgs { inherit system; };
          hermes = hermes-agent-src.packages.${system};
        });
    in
    {
      packages = forAllSystems ({ pkgs, pkgsHermesRev, hermes }: rec {
        hermes-agent = pkgs.callPackage ./default.nix { inherit hermes pkgsHermesRev pkgs; };
        default = hermes-agent;
        desktop = hermes-agent.hermesDesktop;
        inherit (hermes) minimal tui web;
      });

      nixosModules.default = hermes-agent-src.nixosModules.default;
      homeManagerModules.default = hermes-agent-src.homeManagerModules.default;

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          packages = [ pkgs.go-task pkgs.jq ];
        };
      });
    };
}
