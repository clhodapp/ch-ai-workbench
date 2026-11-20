# SPDX-License-Identifier: MIT
{ ... }:
{
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson.modules.nemacs.exported = modules: {
    inherit (modules)
      emacs
      gptel
      claude
      ;
  };

  caisson.modules.homeManager.exported = modules: {
    inherit (modules)
      emacs
      gptel
      claude
      claude-code
      agent-sandbox
      codex
      emacs-integration
      microvm
      opencode
      zsh
      ;
  };

  # This layer's packages (the sandbox CLI, its plugin, the Landlock
  # shim and the claude-consent tool) are its `default` package overlay
  # registry entry (pkg-overlays/, registered on mkLib), under
  # pkgs.ch-ai-workbench. The package set applies it by default, beside
  # `ch-emacs-config/default` from the editor project, which brings the
  # editor's Emacs bases and ELPA pins: the checks build this layer's
  # Emacs packages against the Emacs the editor configures, since they
  # load into it. `merman-nix/default` brings pkgs.merman-nix, the
  # headless mermaid renderer the Emacs and Claude integrations spawn.
  # The flake exports the entry of this layer as `pkgOverlays` and as
  # plain `overlays`; the entries of consumed projects are applied, not
  # exported.

  # packages.* is deliberately not partitioned: consumers take these
  # packages against this flake's main lock, so dev-only inputs must
  # not taint them.
  caisson.nixpkgs.packages.export.enabled = true;

  # The checks of ch-ai-workbench, with the pins of tests/dependencies
  # that only the checks need (configs/flake/checks). The caisson top
  # gathers the checks of every configuration declared inside it into
  # its `checks` output, the checks of the packages among them. This
  # selector passes the configuration up to nothing, so a flake that
  # reads the exports of ch-ai-workbench evaluates neither the
  # configuration nor its pins.
  caisson.flake-parts.configurations.checks = lib.caisson.flake-parts.mkConfiguration {
    inherit (lib.caisson.pins.flake-compat ../../../tests/dependencies) dependencies;
  };
  caisson.flake-parts.exported = _: { };

  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).dependencies;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
        perSystem.treefmt.programs.rustfmt = {
          enable = true;
          edition = "2024";
        };
      };
  };

}
