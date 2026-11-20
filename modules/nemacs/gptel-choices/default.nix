# SPDX-License-Identifier: MIT
#
# The backend and model the gptel bundle starts on, as the home-manager
# module `gptel` of this layer sets them (`ch-ai-workbench.gptel.backend`
# and `ch-ai-workbench.gptel.model`) in the home-manager configuration
# the nemacs configuration is declared inside. They are set on the
# variables the gptel init declares for them, appended to the init of
# that bundle, so they are in the same file as the declarations (the
# byte compiler sees them) and run at load, before gptel's deferred
# config reads them.
#
# The module reads the home-manager configuration through the manifest
# of the nemacs configuration, so it can only be imported by a nemacs
# configuration that has a home-manager configuration above it, which
# the home-manager module `gptel` arranges.
{ ... }:
{ lib, ... }:
let
  parent =
    (lib.caisson.integrations.nearestOf [ "home-manager" ] lib.caisson.evalManifest)
    .value.config.ch-ai-workbench.gptel;
in
{
  bundles.gptel.init = lib.mkAfter (
    lib.concatStringsSep "\n" (
      lib.optional (
        parent.backend != null
      ) "(setq ch-emacs-config-gptel-default-backend '${parent.backend})"
      ++ lib.optional (parent.model != null) "(setq ch-emacs-config-gptel-default-model '${parent.model})"
    )
  );
}
