# SPDX-License-Identifier: MIT
#
# Codex, OpenAI's coding agent: the consumer's codex package, installed
# through Home Manager's programs.codex, with its user configuration
# declared here.
#
# Codex writes CODEX_HOME/config.toml itself: it records the trust
# answer for a project, the model `/model` picks, and the servers
# `codex mcp add` adds. So the declared settings and MCP servers are
# merged into that file at activation by `agent-config apply`, which
# changes only what this module declares now or declared at the last
# activation, and keeps the comments and everything else in the file.
# programs.codex.settings is left empty, because Home Manager links a
# non-empty one from the store, where Codex cannot write it.
#
# The instructions file and the skills are plain links, through
# programs.codex.context and programs.codex.skills.
{ closure-lib, ... }:
{
  config,
  options,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.codex;

  # Where Home Manager's codex module puts CODEX_HOME: the XDG directory
  # when the home prefers XDG directories, ~/.codex otherwise. It exports
  # CODEX_HOME in the first case, which activation does not see, so the
  # merge names the directory itself.
  codexHome =
    if config.home.preferXdgDirectories then
      "${config.xdg.configHome}/codex"
    else
      "${config.home.homeDirectory}/.codex";

  # With agent-sandbox enabled in this home, Codex runs whole inside a
  # checkout's sandbox when the checkout is enrolled (`agent-sandbox run`),
  # and as it is elsewhere. Inside, the sandbox confines every command, so
  # Codex runs its commands without a sandbox of its own: its bubblewrap
  # sandbox would need user namespaces the outer sandbox does not grant.
  sandboxed = options.ch-ai-workbench ? agent-sandbox && config.ch-ai-workbench.agent-sandbox.enable;
  sandboxCli = lib.getExe config.ch-ai-workbench.agent-sandbox.package;
  noInnerSandbox = [
    "-c"
    ''sandbox_mode="danger-full-access"''
  ];

  # The codex that codex-acp starts inside the sandbox, through
  # CODEX_PATH: the same Codex, without a sandbox of its own.
  codexInSandbox = pkgs.writeShellScriptBin "codex-in-sandbox" ''
    exec ${lib.getExe cfg.package} ${lib.escapeShellArgs noInnerSandbox} "$@"
  '';

  # The codex command. The name keeps the version and passthru stays,
  # because Home Manager's codex module reads the version from the
  # package to pick the configuration features it writes.
  command =
    if !sandboxed then
      cfg.package
    else
      pkgs.symlinkJoin {
        name = "${lib.getName cfg.package}-sandboxed-${lib.getVersion cfg.package}";
        paths = [ cfg.package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          rm $out/bin/${cfg.package.meta.mainProgram}
          makeWrapper ${sandboxCli} $out/bin/${cfg.package.meta.mainProgram} \
            --add-flags ${lib.escapeShellArg "run codex -- ${lib.getExe cfg.package}"}
        '';
        inherit (cfg.package) meta;
        passthru = cfg.package.passthru or { };
      };

  mcpServers = lib.mapAttrs (
    _name: server:
    {
      inherit (server) command;
    }
    // lib.optionalAttrs (server.args != [ ]) { inherit (server) args; }
    // lib.optionalAttrs (server.env != { }) { inherit (server) env; }
  ) cfg.mcpServers;

  settings = cfg.settings // lib.optionalAttrs (mcpServers != { }) { mcp_servers = mcpServers; };
in
{
  options.ch-ai-workbench.codex = {
    enable = lib.mkEnableOption "Codex, with its user configuration declared";

    package = lib.mkOption {
      type = lib.types.package;
      example = lib.literalExpression "llm-agents.packages.\${system}.codex";
      description = ''
        The Codex package this machine runs. It has no default: only the
        configuration that installs Codex knows which build that machine
        runs.
      '';
    };

    acpPackage = lib.mkOption {
      type = lib.types.nullOr lib.types.package;
      default = null;
      example = lib.literalExpression "llm-agents.packages.\${system}.codex-acp";
      description = ''
        The codex-acp adapter, which serves Codex over the Agent Client
        Protocol to clients such as Emacs's agent-shell. It reads the
        same CODEX_HOME/config.toml as the codex command. With
        ch-ai-workbench.emacs-integration enabled, agent-shell starts
        Codex sessions through it. Null leaves agent-shell to find
        `codex-acp` on PATH.
      '';
    };

    acpCommand = lib.mkOption {
      type = lib.types.nullOr (lib.types.listOf lib.types.str);
      readOnly = true;
      internal = true;
      description = ''
        The command that starts `acpPackage`, through agent-sandbox when
        this home enables it. The emacs-integration module hands it to
        agent-shell.
      '';
    };

    settings = lib.mkOption {
      type = (pkgs.formats.toml { }).type;
      default = { };
      example = lib.literalExpression ''
        {
          model = "gpt-5.5";
          approval_policy = "on-request";
          tui.notifications = true;
        }
      '';
      description = ''
        Settings merged into CODEX_HOME/config.toml at activation by
        `agent-config apply`. Codex writes that file at runtime, so it
        stays a regular file. The merge changes only the keys declared
        here now or at the previous activation, and keeps every comment
        and every other key in the file. A list keeps the entries someone
        added to it by hand, after the declared ones. A declared value
        replaces a value changed by hand, and the activation reports it.
        `mcp_servers` comes from the `mcpServers` option.
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
        Stdio MCP servers, keyed by name, merged into `mcp_servers` of
        CODEX_HOME/config.toml with the settings. Servers added with
        `codex mcp add` stay beside them. Merged across all modules that
        set it.
      '';
    };

    instructions = lib.mkOption {
      type = lib.types.nullOr lib.types.lines;
      default = null;
      description = ''
        CODEX_HOME/AGENTS.md, the instructions Codex loads into every
        session, through programs.codex.context. Null leaves the file
        alone.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf lib.types.path;
      default = { };
      example = lib.literalExpression "{ deploy-runbook = ./skills/deploy-runbook; }";
      description = ''
        Skill directories (SKILL.md inside) installed as
        CODEX_HOME/skills/<name>, through programs.codex.skills.
      '';
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      (lib.optionalAttrs (options.ch-ai-workbench ? agent-sandbox) {
        # What Codex itself needs inside a checkout's sandbox: its
        # package, CODEX_HOME (its sessions, logs and config.toml), OpenAI's
        # hosts for the API and for ChatGPT sign-in, and the store, where
        # its skills and AGENTS.md are linked.
        ch-ai-workbench.agent-sandbox = lib.mkIf config.ch-ai-workbench.agent-sandbox.enable {
          modules.codex = {
            description = "Codex itself: its package, CODEX_HOME and OpenAI's hosts";
            toolset = [ cfg.package ];
            readStore = true;
            allowWrite = [ codexHome ];
            allowedDomains = [
              "api.openai.com"
              "auth.openai.com"
              "chatgpt.com"
              "*.chatgpt.com"
            ];
          };
          agents.codex = {
            modules = [ "codex" ];
            args = noInnerSandbox;
          };
          agents.codex-acp = {
            modules = [ "codex" ];
            env.CODEX_PATH = lib.getExe codexInSandbox;
          };
        };
      })
      {
        assertions = [
          {
            assertion = !(cfg.settings ? mcp_servers);
            message = ''
              ch-ai-workbench.codex.settings may not set `mcp_servers`:
              declare servers through ch-ai-workbench.codex.mcpServers.
            '';
          }
        ];

        ch-ai-workbench.codex.acpCommand =
          if cfg.acpPackage == null then
            null
          else
            lib.optionals sandboxed [
              sandboxCli
              "run"
              "codex-acp"
              "--"
            ]
            ++ [ (lib.getExe cfg.acpPackage) ];

        programs.codex = {
          enable = true;
          package = command;
          skills = lib.mkIf (cfg.skills != { }) cfg.skills;
          context = lib.mkIf (cfg.instructions != null) cfg.instructions;
        };

        home.activation.codexSettings = closure-lib.ch-ai-workbench.mkAgentConfigActivation {
          inherit
            lib
            pkgs
            config
            settings
            ;
          name = "codex-settings";
          format = "toml";
          target = "${codexHome}/config.toml";
        };
      }
    ]
  );
}
