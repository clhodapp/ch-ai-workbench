# SPDX-License-Identifier: MIT
#
# The agent bus for the user of this home-manager configuration: the
# `agent-bus` daemon as a socket-activated systemd user service, the
# `agent-bus` CLI on the PATH, and, when the configuration also selects
# the agent-sandbox module of this layer, the agent-sandbox module
# `agent-bus`, which lets the Bash commands of a checkout that chooses it
# reach the daemon's socket.
#
# systemd holds the listening socket, so the socket file exists before any
# session starts and keeps the same inode across daemon restarts. That
# matters because a sandbox's Landlock grant binds the socket file present
# when the sandbox starts. The socket is under $XDG_STATE_HOME rather than
# $XDG_RUNTIME_DIR because sandbox grants are absolute paths fixed at
# evaluation, and the runtime directory holds the uid, which evaluation
# does not know.
#
# Claude Code and Codex start MCP servers outside the command sandbox, so
# their `agent-bus mcp` reaches the socket without the sandbox module.
# OpenCode runs its MCP servers inside its sandbox, and every harness runs
# Bash commands inside it; both need the module.
#
# ch-nix-workspace's docs/development/agent-bus.md describes the bus.
{ ... }:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.agent-bus;
in
{
  options.ch-ai-workbench.agent-bus = {
    package = lib.mkOption {
      type = lib.types.package;
      default =
        pkgs.ch-ai-workbench.agent-bus or (throw ''
          ch-ai-workbench.agent-bus needs pkgs.ch-ai-workbench.agent-bus:
          apply ch-ai-workbench's package overlay (`overlays.default`; a
          caisson consumer lists the flake in `projects`) to the package set
          this home-manager configuration evaluates with.
        '');
      defaultText = lib.literalExpression "pkgs.ch-ai-workbench.agent-bus";
      description = "The agent-bus package: the daemon, the MCP server and the CLI.";
    };
    socket = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      default = "${config.xdg.stateHome}/agent-bus/socket";
      defaultText = lib.literalExpression ''"''${config.xdg.stateHome}/agent-bus/socket"'';
      description = ''
        The daemon's socket, which systemd listens on and which the CLI,
        the MCP server and the sandbox module name.
      '';
    };
  };

  config = lib.mkMerge [
    {
      home.packages = [ cfg.package ];
      home.sessionVariables.AGENT_BUS_SOCKET = cfg.socket;

      systemd.user.sockets.agent-bus = {
        Unit.Description = "agent-bus daemon socket";
        Socket = {
          ListenStream = cfg.socket;
          SocketMode = "0600";
          DirectoryMode = "0700";
        };
        Install.WantedBy = [ "sockets.target" ];
      };

      systemd.user.services.agent-bus = {
        Unit = {
          Description = "agent-bus daemon";
          Requires = [ "agent-bus.socket" ];
          After = [ "agent-bus.socket" ];
        };
        Service = {
          ExecStart = "${lib.getExe cfg.package} --socket ${cfg.socket} daemon";
          Environment = [ "XDG_STATE_HOME=${config.xdg.stateHome}" ];
          NoNewPrivileges = true;
          UMask = "0077";
        };
      };
    }
    (lib.optionalAttrs (options ? ch-ai-workbench.agent-sandbox) {
      ch-ai-workbench.agent-sandbox.modules.agent-bus = {
        description = "the agent bus: the agent-bus CLI and MCP server, and the daemon's socket";
        toolset = [ cfg.package ];
        allowUnixSockets = [ cfg.socket ];
        extraEnv.AGENT_BUS_SOCKET = cfg.socket;
      };
    })
  ];
}
