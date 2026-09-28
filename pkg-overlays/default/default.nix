# SPDX-License-Identifier: MIT
#
# The default package overlay: this layer's packages under
# `pkgs.ch-ai-workbench` (packages/default.nix lists them). A consumer
# that lists this flake in `projects` holds it as
# `ch-ai-workbench/default`, which its package sets apply by default;
# the modules read the packages from that scope. The scope name is bound
# here, so the packages land under `pkgs.ch-ai-workbench` in any
# consumer.
{ closure-lib, ... }:
{
  overlay = closure-lib.caisson.nixpkgs.mkPackagesOverlay ./packages "ch-ai-workbench";
}
