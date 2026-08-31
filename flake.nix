{
  description = "hermes-agent — Nous Research AI agent framework (CLI, TUI, web dashboard, desktop, ACP)";

  inputs = {
    # Only used for `chromium` (browser automation target) and devShell
    # tooling. hermes-agent-src brings its own nixpkgs-unstable pin for
    # everything it actually builds (uv2nix venv, npm workspaces) — kept
    # separate on purpose, same rationale as packages/goose's own pin.
    nixpkgs.url = "github:nixos/nixpkgs/nixos-25.11";

    # Upstream already ships a complete flake (flake-parts + uv2nix +
    # npm workspaces + NixOS/Home Manager modules) — see nix/*.nix in the
    # checkout. Re-implementing that packaging by hand (uv.lock alone is
    # ~700KB, plus native node-gyp modules and an Electron app) would just
    # be a worse, unmaintained copy of what upstream already tests. Pinned
    # to a tagged release, not a floating branch.
    hermes-agent-src = {
      url = "github:NousResearch/hermes-agent/v2026.8.27";
      # Deliberately not `follows`-ed to nixpkgs above: upstream's uv2nix
      # dependency resolution is pinned against its own nixpkgs-unstable
      # revision (see its flake.lock) and forcing our nixpkgs-25.11 onto it
      # would invalidate that resolution.
    };
  };

  outputs =
    { nixpkgs, hermes-agent-src, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" ];

      forAllSystems = f: nixpkgs.lib.genAttrs systems (system:
        f {
          pkgs = import nixpkgs { inherit system; config.allowUnfree = true; };
          # Same exact nixpkgs revision hermes-agent-src's own uv2nix venv
          # is built against (see its flake.lock) — required so `piper-tts`
          # (a buildPythonApplication with native extensions) shares the
          # sealed venv's python3.12 ABI. Building it from OUR nixpkgs-25.11
          # pin instead risks a mismatched interpreter/glibc ABI once it
          # lands on hermes-agent's PYTHONPATH via extraPythonPackages.
          pkgsHermesRev = import hermes-agent-src.inputs.nixpkgs { inherit system; };
          hermes = hermes-agent-src.packages.${system};
        });
    in
    {
      packages = forAllSystems ({ pkgs, pkgsHermesRev, hermes }: rec {
        hermes-agent = pkgs.callPackage ./default.nix { inherit hermes pkgsHermesRev pkgs; };
        default = hermes-agent;

        # Points at OUR wrapped hermes-agent (chromium + piper), not
        # upstream's raw hermesDesktop — see default.nix's `self` tie-back.
        desktop = hermes-agent.hermesDesktop;

        # Passed through unwrapped, for anyone who wants to build just one
        # piece without the chromium/piper additions.
        inherit (hermes) minimal tui web;
      });

      nixosModules.default = hermes-agent-src.nixosModules.default;
      homeManagerModules.default = hermes-agent-src.homeManagerModules.default;

      devShells = forAllSystems ({ pkgs, ... }: {
        default = pkgs.mkShell {
          packages = [ pkgs.go-task pkgs.jq ];
          shellHook = ''
            echo "hermes-agent devShell -- task check / task build / task run / task check-update / task update"
          '';
        };
      });
    };
}
