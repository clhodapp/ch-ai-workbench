# SPDX-License-Identifier: MIT
#
# The type of a stdio MCP server as the claude-code, codex and opencode
# modules take it in their `mcpServers` option. Each module renders it
# into its agent's own shape (`mcpServers` in ~/.claude.json,
# `mcp_servers` in Codex's config.toml, `mcp` in OpenCode's config), so
# a module that serves every agent, emacs-integration for one, declares
# a server once per agent with the same value.
lib:
lib.types.submodule {
  options = {
    command = lib.mkOption {
      type = lib.types.str;
      example = "/home/me/.nix-profile/bin/emacs-mcp-stdio";
      description = "The program that serves MCP on its stdin and stdout.";
    };

    args = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Arguments passed to `command`.";
    };

    env = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Environment variables the agent sets for the server.";
    };

    envVars = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Variables of the agent's own environment the server needs.
        Codex starts a server with a cleaned environment and passes
        these on (its `env_vars`). Claude Code and OpenCode pass their
        whole environment on, so they need no list.
      '';
    };
  };
}
