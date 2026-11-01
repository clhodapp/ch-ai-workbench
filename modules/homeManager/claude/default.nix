# SPDX-License-Identifier: MIT
#
# The Claude Code side of the workbench in Emacs: the claude-queue
# bundle (sessions in ghostel terminals) and the mcp-server bundle (the
# tools a session calls back into Emacs with), plus the stdio bridge
# MCP clients register. Both bundles build on the vendor-neutral module
# beside this one: claude-queue's package depends on semantic-finder,
# and the MCP server's comment tools call collab-comments, so this
# module asserts that one is enabled rather than quietly producing an
# init that fails to byte-compile.
#
# The Claude Code CLI itself (hooks, skills, the LSP plugin) is the
# claude-code module; the hooks and skill that let a session drive this
# Emacs are emacs-integration.
{ closure-lib, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.claude;

  # What the editor's nemacs configuration builds. The bridge below takes
  # its script from the editor's own package set, so it matches the
  # mcp-server-lib the editor loads.
  editor = config.programs.nemacs.settings.build;

  # The MCP stdio bridge: a stable command MCP clients register through
  # the home-manager profile, ~/.nix-profile/bin/emacs-mcp-stdio (the
  # directory is home.profileDirectory). The emacs-integration module
  # registers it with each agent this home configures. The profile path keeps
  # working across package updates, and unlike a bare name it does not
  # depend on PATH: a checkout enrolled in agent-sandbox sets the
  # Claude Code process's PATH to its sandbox farms. Defaults target the "emacs" server
  # the mcp-server bundle registers; explicit flags win, since the
  # bridge's argument parser is last-match.
  #
  # Inside an agent-sandbox run (Codex or OpenCode, whose MCP servers run
  # inside the sandbox with them), the bridge cannot reach the Emacs
  # daemon socket, and must not: it relays its stdio to the socket the
  # run serves the real bridge on, from outside the sandbox.
  mcpStdioBridge = pkgs.writeShellApplication {
    name = "emacs-mcp-stdio";
    runtimeInputs = [
      editor.package
      pkgs.coreutils
      pkgs.socat
    ];
    text = ''
      if [ -n "''${SANDBOX_RUNTIME:-}" ] && [ -n "''${AGENT_SANDBOX_EMACS_MCP:-}" ]; then
        exec socat STDIO "UNIX-CONNECT:$AGENT_SANDBOX_EMACS_MCP"
      fi
      bridge=(${editor.epkgs.mcp-server-lib}/share/emacs/site-lisp/elpa/mcp-server-lib-*/emacs-mcp-stdio.sh)
      exec bash "''${bridge[0]}" \
        --init-function=ch-mcp-server-start \
        --server-id=emacs \
        "$@"
    '';
  };
in
{
  options.ch-ai-workbench.claude = {
    enable = lib.mkEnableOption "the Claude Code side of the AI workbench in Emacs";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.ch-ai-workbench.emacs.enable;
        message = ''
          ch-ai-workbench.claude needs ch-ai-workbench.emacs: claude-queue
          depends on semantic-finder and the MCP server's comment tools on
          collab-comments, both of which that module provides.
        '';
      }
    ];

    programs.nemacs.settings.imports = [ closure-lib.caisson.libManifest.modules.nemacs.claude ];

    home.packages = [ mcpStdioBridge ];
  };
}
