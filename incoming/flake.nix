# SPDX-License-Identifier: MIT
{

  description = "Nix-authored per-project configuration for Claude Code's native sandbox";

  inputs = {
    caisson.url = "github:nix-caisson/caisson";
    ch-nixpkgs.url = "github:clhodapp/ch-nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    inputs@{ caisson, ch-nixpkgs, ... }:
    let
      lib = caisson.lib.caisson-core.mkLib {
        inherit inputs;

        projects = {
          inherit caisson ch-nixpkgs;
        };

        modules = lib: {
          flake = {
            default = lib.caisson.mkFlakeModule ./modules/flake-parts/default;
          };
          homeManager = {
            default = lib.caisson-core.mkModule "homeManager" ./modules/home-manager/default/claude-code-sandbox;
          };
        };

        libOverlays = mkLibOverlay: {
          default = mkLibOverlay ./lib-overlays/default;
        };
      };
    in
    lib.caisson.mkFlake {
      name = "claude-code-sandbox";
      configModule = lib.caisson.mkFlakeModule ./configs/flake-parts/default;
    };

}
