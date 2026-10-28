# SPDX-License-Identifier: MIT
#
# OpenCode against hosted providers (Baseten and Fireworks by default):
# the consumer's opencode package, installed through Home Manager's
# programs.opencode, with each provider's key delivered from a file and
# a Baseten model as the default.
{ ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.opencode;

  # The providers whose keys come from a file.
  keyed = lib.filterAttrs (_: provider: provider.apiKeyFile != null) cfg.providers;

  # OpenCode's provider catalog (models.dev) already knows each provider
  # here: its endpoint and the variable OpenCode reads its key from. The
  # wrapper exports that variable from the key file at each launch. A
  # `{file:…}` reference in opencode.json would read the same file, but
  # OpenCode refuses to start while a referenced file is missing.
  readKey =
    provider:
    let
      file = lib.escapeShellArg provider.apiKeyFile;
    in
    ''
      if [ -z "''${${provider.keyVariable}:-}" ] && [ -r ${file} ] && [ -s ${file} ]; then
        ${provider.keyVariable}=$(< ${file})
        export ${provider.keyVariable}
      fi
    '';

  # The name keeps the version and passthru stays, because Home
  # Manager's module reads both from the package (the version to pick a
  # configuration shape, passthru.jsonschema to validate the file).
  wrapped =
    if keyed == { } then
      cfg.package
    else
      pkgs.symlinkJoin {
        name = "${lib.getName cfg.package}-keyed-${lib.getVersion cfg.package}";
        paths = [ cfg.package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/${cfg.package.meta.mainProgram} ${
            lib.concatMapStringsSep " " (provider: "--run ${lib.escapeShellArg (readKey provider)}") (
              lib.attrValues keyed
            )
          }
        '';
        inherit (cfg.package) meta;
        passthru = cfg.package.passthru or { };
      };
in
{
  options.ch-ai-workbench.opencode = {
    enable = lib.mkEnableOption "OpenCode, set up against hosted providers";

    package = lib.mkOption {
      type = lib.types.package;
      example = lib.literalExpression "llm-agents.packages.\${system}.opencode";
      description = ''
        The OpenCode package this machine runs, before the wrapper that
        reads the provider keys. It has no default: only the
        configuration that installs OpenCode knows which build that
        machine runs.
      '';
    };

    model = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "baseten/zai-org/GLM-5.3";
      example = "fireworks-ai/accounts/fireworks/models/kimi-k3";
      description = ''
        The model OpenCode starts on, as `<provider>/<model>`. The
        default is a model of Baseten's Model APIs. Null leaves the
        choice to OpenCode.
      '';
    };

    providers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            keyVariable = lib.mkOption {
              type = lib.types.strMatching "[A-Za-z_][A-Za-z0-9_]*";
              example = "BASETEN_API_KEY";
              description = ''
                The environment variable OpenCode reads this provider's
                key from, as its provider catalog names it.
              '';
            };

            apiKeyFile = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              example = "/run/user/1000/secrets/baseten-api-key";
              description = ''
                File holding the provider's API key. The opencode
                command reads it at each launch and exports it as
                `keyVariable`, unless that variable is already set.
                While the file is missing, unreadable or empty, OpenCode starts
                without this provider's key. OpenCode 2 runs a
                background service that keeps the environment of the
                launch that started it, so with OpenCode 2 a key file
                written later takes effect once that service restarts.
                A path string rather than a Nix path, so the key stays
                out of the store. Null leaves the key to the
                environment OpenCode is started from.
              '';
            };
          };
        }
      );
      example = lib.literalExpression ''
        {
          # A key managed by a secrets tool.
          baseten.apiKeyFile = "/run/user/1000/secrets/baseten-api-key";
          # A provider the module does not seed.
          openrouter = {
            keyVariable = "OPENROUTER_API_KEY";
            apiKeyFile = "''${config.xdg.configHome}/openrouter/api-key";
          };
        }
      '';
      description = ''
        The providers whose keys the opencode command reads from files,
        keyed by OpenCode's provider id. The module seeds two. baseten
        is Baseten's Model APIs; its key is read from
        $XDG_CONFIG_HOME/baseten/api-key, the file the judge of the
        claude-code module also reads. fireworks-ai is Fireworks; its
        key is read from $XDG_CONFIG_HOME/fireworks/api-key. Merged
        across all modules that set it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    ch-ai-workbench.opencode.providers = {
      baseten = {
        keyVariable = lib.mkDefault "BASETEN_API_KEY";
        apiKeyFile = lib.mkDefault "${config.xdg.configHome}/baseten/api-key";
      };
      fireworks-ai = {
        keyVariable = lib.mkDefault "FIREWORKS_API_KEY";
        apiKeyFile = lib.mkDefault "${config.xdg.configHome}/fireworks/api-key";
      };
    };

    programs.opencode = {
      enable = true;
      package = wrapped;
      settings = lib.optionalAttrs (cfg.model != null) { inherit (cfg) model; };
    };
  };
}
