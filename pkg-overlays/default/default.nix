# SPDX-License-Identifier: MIT
#
# The default package overlay: this layer's packages under
# `pkgs.ch-ai-workbench` (packages/default.nix lists them). A consumer
# that lists this flake in `projects` holds it as
# `ch-ai-workbench/default`, which its package sets apply by default;
# the modules read the packages from that scope. The scope name is bound
# here, so the packages land under `pkgs.ch-ai-workbench` in any
# consumer.
#
# The overlay imports `ch-microvm/default`, the package overlay of
# ch-microvm, so every package set that applies this overlay also has
# `pkgs.ch-microvm`. The MCP server `microvm-mcp` builds on the library
# of `pkgs.ch-microvm.ch-microvm`.
{ closure-lib, ... }:
{
  imports = [ closure-lib.caisson.libManifest.pkgOverlays."ch-microvm/default" ];
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ./packages "ch-ai-workbench";
}
