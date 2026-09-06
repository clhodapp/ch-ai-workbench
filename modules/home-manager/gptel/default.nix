# SPDX-License-Identifier: MIT
#
# The gptel side of the workbench in Emacs: the gptel and gptel-agent
# bundles, and the choice of backend and model they start on. Stands on
# the editor alone; it does not need the vendor-neutral module beside
# it.
{ closure-inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.gptel;

  merman = closure-inputs.merman.packages.${pkgs.stdenv.hostPlatform.system}.merman;
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
    ch-emacs-config.emacs.bundles = lib.mkMerge [
      # `enable` is wrapped here rather than in the spec: the spec is also
      # read as plain data by the checks, where a priority wrapper is not
      # a boolean. mkDefault so a consumer can switch a bundle off.
      (lib.mapAttrs (_name: bundle: bundle // { enable = lib.mkDefault bundle.enable; })
        (import ../emacs/bundles-spec.nix {
          inherit lib merman;
          readInit = name: builtins.readFile ../emacs/inits/${name};
        }).gptel
      )
      # The backend and model choices, set on the variables the gptel
      # init declares for them. Appended to that bundle's own init, so
      # they are in the same file as the declarations (the byte compiler
      # sees them) and run at load, before gptel's deferred config reads
      # them.
      {
        gptel.init = lib.mkAfter (
          lib.concatStringsSep "\n" (
            lib.optional (cfg.backend != null) "(setq ch-emacs-config-gptel-default-backend '${cfg.backend})"
            ++ lib.optional (cfg.model != null) "(setq ch-emacs-config-gptel-default-model '${cfg.model})"
          )
        );
      }
    ];
  };
}
