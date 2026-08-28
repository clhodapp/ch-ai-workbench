# SPDX-License-Identifier: MIT
{

  description = "Nix-authored per-project configuration for Claude Code's native sandbox";

  inputs = {
    ch-flake.url = "github:clhodapp/ch-flake";
    ch-home-manager.url = "github:clhodapp/ch-home-manager";
    ch-nixpkgs.url = "github:clhodapp/ch-nixpkgs";
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

    flake-parts.follows = "ch-flake/flake-parts";
  };

  outputs =
    inputs@{
      ch-flake,
      flake-parts,
      self,
      ...
    }:
    let
      lib = ch-flake.lib.mkLib {
        inherit inputs;

        modules = lib: {
          flake = {
            default = lib.ch-flake.mkFlakeModule ./modules/flake-parts/default;
            partitions = flake-parts.flakeModules.partitions;
          };
          homeManager = {
            default = lib.ch-home-manager.mkHomeManagerModule ./modules/home-manager/default/claude-code-sandbox;
          };
        };

        libOverlays = mkLibOverlay: {
          default = mkLibOverlay ./lib-overlays/default;
          ch-home-manager = inputs.ch-home-manager.libOverlays.default;
          ch-nixpkgs = inputs.ch-nixpkgs.libOverlays.default;
        };
      };
    in
    lib.ch-flake.mkFlake {
      name = "claude-code-sandbox";
      configModule = lib.ch-flake.mkFlakeModule ./configs/flake-parts/default;
    };

}
