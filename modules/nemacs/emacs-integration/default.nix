# SPDX-License-Identifier: MIT
#
# The init that the home-manager module `emacs-integration` of this
# layer appends to bundles of the editor: the agent-shell command of
# each agent the home-manager configuration installs, and the programs
# and switches claude-queue dispatches with. The home-manager
# configuration computes the init (`bundleInits`), and this module
# appends each part to its bundle.
#
# The module reads the home-manager configuration through the manifest
# of the nemacs configuration, so it can only be imported by a nemacs
# configuration that has a home-manager configuration above it, which
# the home-manager module `emacs-integration` arranges.
{ ... }:
{ lib, ... }:
let
  inits =
    (lib.caisson.integrations.nearestOf [ "home-manager" ] lib.caisson.evalManifest)
    .value.config.ch-ai-workbench.emacs-integration.bundleInits;
in
{
  bundles = lib.mapAttrs (_name: init: { init = lib.mkAfter init; }) inits;
}
