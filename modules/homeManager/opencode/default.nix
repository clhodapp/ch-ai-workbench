# SPDX-License-Identifier: MIT
#
# OpenCode against Baseten's Model APIs: the consumer's opencode
# package, installed through Home Manager's programs.opencode, with the
# Baseten key delivered from a file and a Baseten model as the default.
{ ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.opencode;

  # OpenCode's provider catalog (models.dev) already knows Baseten: the
  # OpenAI-compatible endpoint https://inference.baseten.co/v1 and the
  # BASETEN_API_KEY variable. The wrapper exports that variable from the
  # key file at each launch. A `{file:…}` reference in opencode.json
  # would read the same file, but OpenCode refuses to start while a
  # referenced file is missing.
  readKey = ''
    if [ -z "''${BASETEN_API_KEY:-}" ] && [ -s ${lib.escapeShellArg cfg.baseten.apiKeyFile} ]; then
      BASETEN_API_KEY=$(< ${lib.escapeShellArg cfg.baseten.apiKeyFile})
      export BASETEN_API_KEY
    fi
  '';

  # The name keeps the version and passthru stays, because Home
  # Manager's module reads both from the package (the version to pick a
  # configuration shape, passthru.jsonschema to validate the file).
  wrapped =
    if cfg.baseten.apiKeyFile == null then
      cfg.package
    else
      pkgs.symlinkJoin {
        name = "${lib.getName cfg.package}-baseten-${lib.getVersion cfg.package}";
        paths = [ cfg.package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/${cfg.package.meta.mainProgram} --run ${lib.escapeShellArg readKey}
        '';
        inherit (cfg.package) meta;
        passthru = cfg.package.passthru or { };
      };
in
{
  options.ch-ai-workbench.opencode = {
    enable = lib.mkEnableOption "OpenCode, set up against Baseten";

    package = lib.mkOption {
      type = lib.types.package;
      example = lib.literalExpression "llm-agents.packages.\${system}.opencode";
      description = ''
        The OpenCode package this machine runs, before the wrapper that
        reads the Baseten key. It has no default: only the configuration
        that installs OpenCode knows which build that machine runs.
      '';
    };

    model = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "baseten/zai-org/GLM-5.3";
      example = "baseten/moonshotai/Kimi-K3";
      description = ''
        The model OpenCode starts on, as `<provider>/<model>`. The
        default is a model of Baseten's Model APIs. Null leaves the
        choice to OpenCode.
      '';
    };

    baseten.apiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "${config.xdg.configHome}/baseten/api-key";
      defaultText = lib.literalExpression ''"''${config.xdg.configHome}/baseten/api-key"'';
      description = ''
        File holding the Baseten API key. The opencode command reads it
        at each launch and exports it as BASETEN_API_KEY, unless that
        variable is already set. While the file is missing or empty,
        OpenCode starts without a Baseten key. OpenCode 2 runs a
        background service that keeps the environment of the launch
        that started it, so with OpenCode 2 a key file written later
        takes effect once that service restarts. The default is the file
        the judge of the claude-code module reads its Baseten key from.
        A path string rather than a Nix path, so the key stays out of
        the store. Null installs the package unwrapped.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.opencode = {
      enable = true;
      package = wrapped;
      settings = lib.optionalAttrs (cfg.model != null) { inherit (cfg) model; };
    };
  };
}
