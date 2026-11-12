# SPDX-License-Identifier: MIT
#
# The gptel side of the workbench in Emacs: the gptel and gptel-agent
# bundles, and the choice of backend and model they start on. Stands on
# the editor alone; it does not need the vendor-neutral module beside
# it.
{ closure-lib, ... }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.ch-ai-workbench.gptel;
in
{
  options.ch-ai-workbench.gptel = {
    enable = lib.mkEnableOption "the gptel side of the AI workbench";

    backend = lib.mkOption {
      type = lib.types.nullOr (
        lib.types.enum [
          "anthropic"
          "openrouter"
          "fireworks"
        ]
      );
      default = null;
      description = ''
        The backend gptel starts on, one of the three the gptel bundle
        configures. Null keeps the bundle's default (Anthropic).
      '';
    };

    model = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "[^[:space:]()'\"]+");
      default = null;
      example = "accounts/fireworks/models/deepseek-v4-flash";
      description = ''
        The model gptel starts on, as the symbol name gptel uses for it;
        it should be one the chosen backend lists. Null keeps the
        bundle's default.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.nemacs.settings = {
      imports = [ closure-lib.caisson.libManifest.modules.nemacs.gptel ];
      # The backend and model choices, set on the variables the gptel
      # init declares for them. Appended to the init of that bundle, so
      # they are in the same file as the declarations (the byte compiler
      # sees them) and run at load, before gptel's deferred config reads
      # them.
      bundles.gptel.init = lib.mkAfter (
        lib.concatStringsSep "\n" (
          lib.optional (cfg.backend != null) "(setq ch-emacs-config-gptel-default-backend '${cfg.backend})"
          ++ lib.optional (cfg.model != null) "(setq ch-emacs-config-gptel-default-model '${cfg.model})"
        )
      );
    };
  };
}
