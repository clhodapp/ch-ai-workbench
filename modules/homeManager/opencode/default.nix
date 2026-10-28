# SPDX-License-Identifier: MIT
#
# OpenCode against hosted providers (Baseten and Fireworks by default):
# the consumer's opencode package, installed through Home Manager's
# programs.opencode, with each provider's key delivered from a file,
# a Baseten model as the default, and its user configuration declared
# here.
#
# OpenCode reads a configuration file named by OPENCODE_CONFIG on top of
# the global opencode.json, merging the two (objects key by key, lists
# concatenated) and letting a project's configuration override both. The
# declared settings and MCP servers are rendered into that file, which
# the opencode command names, so opencode.json stays a file OpenCode and
# its users write. programs.opencode.settings is left empty, because
# Home Manager links a non-empty one from the store as opencode.json.
#
# The instructions file and the skills are plain links, through
# programs.opencode.context and programs.opencode.skills.
{ closure-lib, ... }:
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

  mcp = lib.mapAttrs (_name: server: {
    type = "local";
    command = [ server.command ] ++ server.args;
    enabled = true;
    environment = server.env;
  }) cfg.mcpServers;

  # The declared layer, named by OPENCODE_CONFIG.
  layer = pkgs.writeText "opencode-workbench.json" (
    builtins.toJSON (
      {
        "$schema" = "https://opencode.ai/config.json";
      }
      // cfg.settings
      // lib.optionalAttrs (mcp != { }) { inherit mcp; }
    )
  );

  # The name keeps the version and passthru stays, because Home
  # Manager's module reads both from the package (the version to pick a
  # configuration shape, passthru.jsonschema to validate the file).
  # A launch that sets OPENCODE_CONFIG itself names its own file, and
  # gets none of the declared settings.
  wrapped = pkgs.symlinkJoin {
    name = "${lib.getName cfg.package}-workbench-${lib.getVersion cfg.package}";
    paths = [ cfg.package ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/${cfg.package.meta.mainProgram} \
        --set-default OPENCODE_CONFIG ${layer} \
        ${lib.optionalString (!cfg.claudeCodeCompat) "--set OPENCODE_DISABLE_CLAUDE_CODE 1"} \
        ${lib.concatMapStringsSep " " (provider: "--run ${lib.escapeShellArg (readKey provider)}") (
          lib.attrValues keyed
        )}
    '';
    inherit (cfg.package) meta;
    passthru = (cfg.package.passthru or { }) // {
      workbenchLayer = layer;
    };
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

    settings = lib.mkOption {
      type = (pkgs.formats.json { }).type;
      default = { };
      example = lib.literalExpression ''
        {
          model = "fireworks-ai/accounts/fireworks/models/kimi-k3";
          permission.bash."git push*" = "ask";
          share = "disabled";
        }
      '';
      description = ''
        OpenCode settings, in the shape of opencode.json, rendered into
        the file the opencode command names in OPENCODE_CONFIG. OpenCode
        merges it over the global opencode.json, so a key set here wins
        over the same key there, and a project's configuration wins over
        both. The module sets `model` to a model of Baseten's Model APIs
        by default, as `<provider>/<model>`. `mcp` comes from the
        `mcpServers` option.
      '';
    };

    mcpServers = lib.mkOption {
      type = lib.types.attrsOf (closure-lib.ch-ai-workbench.mcpServerType lib);
      default = { };
      example = lib.literalExpression ''
        {
          emacs.command = "''${config.home.profileDirectory}/bin/emacs-mcp-stdio";
        }
      '';
      description = ''
        Stdio MCP servers, keyed by name, rendered into `mcp` of the
        declared settings as local servers. Servers in opencode.json stay
        beside them. Merged across all modules that set it.
      '';
    };

    instructions = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = ''
        $XDG_CONFIG_HOME/opencode/AGENTS.md, the instructions OpenCode
        loads into every session, through programs.opencode.context.
        Null leaves the file alone.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression "{ deploy-runbook = ./skills/deploy-runbook; }";
      description = ''
        Skill directories (SKILL.md inside) installed as
        $XDG_CONFIG_HOME/opencode/skills/<name>, through
        programs.opencode.skills.
      '';
    };

    claudeCodeCompat = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Whether OpenCode also reads Claude Code's files: the skills
        under ~/.claude/skills and CLAUDE.md as instructions. Off by
        default, so each agent reads only what is declared for it. A
        skill written for Claude Code can name tools only Claude Code
        has, such as the tools of the agent-sandbox plugin. Off sets
        OPENCODE_DISABLE_CLAUDE_CODE in the opencode command.
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

    assertions = [
      {
        assertion = !(cfg.settings ? mcp);
        message = ''
          ch-ai-workbench.opencode.settings may not set `mcp`: declare
          servers through ch-ai-workbench.opencode.mcpServers.
        '';
      }
    ];

    ch-ai-workbench.opencode.settings.model = lib.mkDefault "baseten/zai-org/GLM-5.3";

    programs.opencode = {
      enable = true;
      package = wrapped;
      skills = lib.mkIf (cfg.skills != { }) cfg.skills;
      context = lib.mkIf (cfg.instructions != null) cfg.instructions;
    };
  };
}
