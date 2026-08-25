# SPDX-License-Identifier: LGPL-3.0-or-later
{ ... }:
{
  config,
  inputs,
  lib,
  self,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  systems = [
    "x86_64-linux"
    "aarch64-linux"
  ];

  ch-flake = {
    configInfo.configName = "claude-code-sandbox";
    libOverlays.exported = libOverlays: {
      inherit (libOverlays)
        default
        ch-home-manager
        ch-nixpkgs
        ;
    };
    modules = {
      flake.exported = modules: { inherit (modules) default; };
      homeManager.exported = modules: { inherit (modules) default; };
    };
  };

  ch-nixpkgs = {
    overlays.all = {
      packages = lib.ch-nixpkgs.mkPackagesOverlay (
        { callPackage, ... }: import ../../../pkgs/claude-code-sandbox { inherit callPackage; }
      );
    };
    overlays.export = {
      enabled = true;
    };
    overlays.exported = overlays: {
      inherit (overlays) packages;
    };
    pkgSets.pkgs = {
      pkgFunction = import inputs.nixpkgs;
      overlayImports = overlays: [
        inputs.ch-nixpkgs.overlays.default
        overlays.packages
      ];
    };
    packages.export.enabled = true;
  };

  # checks and formatter live in isolated partitions; packages deliberately
  # do not: downstream flakes consume packages.* against this flake's main
  # lock (inherited locks), so dev-only inputs must not taint them.
  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = lib.ch-flake.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = lib.ch-flake.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          {
            checks = {
              # The package build runs the unittest suite in its
              # checkPhase, so building it IS the test run.
              package = self.packages.${system}.claude-code-sandbox;
              plugin = self.packages.${system}.claude-code-sandbox-plugin;
              # Compiling the shim is its build-time test; Landlock
              # behavior cannot be exercised inside the Nix build
              # sandbox.
              landlock-shim = self.packages.${system}.landlock-shim;
            };
          };
      };
  };

}
