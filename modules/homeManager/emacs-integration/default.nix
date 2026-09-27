# SPDX-License-Identifier: MIT
#
# Optional Emacs integration: registers the hooks and the agent-tools
# skill that let a Claude Code session talk to a live Emacs. Enabling
# this alongside the claude-code module is the whole setup; the Emacs
# side needs no knowledge of Claude Code, which is why this module lives
# here rather than there.
#
# What it wires up:
#   - a cwd hook, so a session's working directory follows into Emacs
#     (claude-queue follow-mode), on CwdChanged and on the worktree
#     tools, which chdir without emitting CwdChanged;
#   - a consent hook classifying edit territory for Emacs-dispatched
#     headless sessions, asking the user through the claude-code
#     module's claude-consent tool (Emacs answers while
#     claude-consent-mode is on; without an answerer the hook falls
#     back to the CLI's own prompt), plus the deny rule that keeps
#     sessions out of the spool it reads;
#   - the emacs-tools skill, usage depth for the MCP server's agent
#     tools.
#
# Every hook fails open: a dead or hung Emacs, an unparseable payload,
# or a missing emacsclient all leave the session running. That is
# deliberate (a session must never block on the editor) and it is also
# why `emacsclientPath` is asserted rather than discovered: without it
# the integration would install cleanly and quietly do nothing.
{ closure-inputs, closure-lib, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.emacs-integration;

  # Resolved at run time from the profile, not baked to a store path: a
  # generation switch swaps a symlink without changing any mtime, so a
  # hook that captured a store path at build time would keep driving a
  # daemon that no longer exists.
  emacsclient =
    if cfg.emacsclientPath != null then
      cfg.emacsclientPath
    else
      "${config.home.profileDirectory}/bin/emacsclient";

  cwdHook = pkgs.writeShellApplication {
    name = "emacs-claude-cwd-hook";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
    ];
    text = ''
      emacsclient() { ${lib.escapeShellArg emacsclient} "$@"; }
      ${builtins.readFile ./emacs-claude-cwd-hook.sh}
    '';
  };

  # The consent hook comes from this layer's library, so the checks
  # drive the same package this module installs.
  consentHook = closure-lib.ch-ai-workbench.mkEmacsClaudeConsentHook {
    inherit pkgs;
    claude-consent = config.ch-ai-workbench.claude-code.consentPackage;
  };

  # Renders mermaid blocks as Claude displays them. merman supplies the
  # mmdc-compatible renderer on the hook's own PATH, so this works with
  # no browser and nothing installed globally.
  mermaidDisplayHook = pkgs.writeShellApplication {
    name = "claude-mermaid-display-hook";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.findutils
      pkgs.gawk
      pkgs.gnugrep
      pkgs.jq
      closure-inputs.merman-nix.packages.${pkgs.stdenv.hostPlatform.system}.merman
    ];
    text = builtins.readFile ./claude-mermaid-display-hook.sh;
  };
in
{
  options.ch-ai-workbench.emacs-integration = {
    enable = lib.mkEnableOption "the Emacs integration for Claude Code";

    emacsclientPath = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      example = "/usr/bin/emacsclient";
      description = ''
        Where the cwd hook finds `emacsclient`. `null` means the Nix
        profile, which is right whenever Emacs is in the profile, by
        `programs.emacs` or by `home.packages`. Set it when emacsclient
        comes from somewhere else.
      '';
    };

    # Each piece needs the matching Emacs feature to be enabled on the
    # other side: the skill documents the MCP server's tools, the
    # session hooks drive claude-queue, and the mermaid hook renders
    # through render-dwim's toolchain. This module cannot read that
    # flake's bundle state, so it asks instead of guessing. Registering
    # a hook whose Emacs half is absent is harmless (every hook fails
    # open) but pointless.
    skill.enable = lib.mkEnableOption "the emacs-tools skill (needs the mcp-server bundle)" // {
      default = true;
    };

    sessionHooks.enable =
      lib.mkEnableOption "the cwd and consent hooks (needs the claude-queue bundle)"
      // {
        default = true;
      };

    mermaidHook.enable =
      lib.mkEnableOption "rendering mermaid in message display (needs the render-dwim bundle)"
      // {
        default = true;
      };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.emacsclientPath != null || config.programs.emacs.enable;
        message = ''
          ch-ai-workbench.emacs-integration needs emacsclient, and
          the hooks fail open, so without it the integration installs
          and silently does nothing. Either enable programs.emacs, or
          set emacsclientPath to where emacsclient lives.
        '';
      }
      # The skill documents the MCP server's tools and the session hooks
      # drive claude-queue; both live in this flake's claude module, so
      # unlike the render-dwim bundle above this can be checked rather
      # than asked.
      {
        assertion =
          (!cfg.skill.enable && !cfg.sessionHooks.enable) || (config.ch-ai-workbench.claude.enable or false);
        message = ''
          ch-ai-workbench.emacs-integration's skill and session hooks
          need ch-ai-workbench.claude (the MCP server and claude-queue);
          enable it, or switch skill.enable and sessionHooks.enable off.
        '';
      }
    ];

    ch-ai-workbench.claude-code.skills = lib.mkIf cfg.skill.enable {
      emacs-tools.source = ./skills/emacs-tools;
      # Terminals are sensitive by default (the MCP server withholds them
      # until the user exposes one); this skill tells the agent what it
      # can read and how the user grants access, so it is gated with the
      # rest of the MCP-server documentation.
      ghostel-terminals.source = ./skills/ghostel-terminals;
    };

    ch-ai-workbench.claude-code.hooks =
      # The consent hook's timeout is a liveness backstop only, kept
      # above the longest deadline the hook manages internally (it
      # self-denies before 3500s); a framework-cancelled hook yields no
      # decision, which is fail-open wherever native rules allow the
      # call.
      lib.optionalAttrs cfg.sessionHooks.enable {
        emacs-cwd = {
          event = "CwdChanged";
          command = "emacs-claude-cwd-hook";
          package = cwdHook;
        };
        emacs-cwd-worktree = {
          event = "PostToolUse";
          matcher = "EnterWorktree|ExitWorktree";
          command = "emacs-claude-cwd-hook";
        };
        emacs-consent = {
          event = "PreToolUse";
          matcher = "Edit|Write";
          command = "emacs-claude-consent-hook";
          package = consentHook;
          timeout = 3600;
        };
      }
      // lib.optionalAttrs cfg.mermaidHook.enable {
        emacs-mermaid-display = {
          event = "MessageDisplay";
          command = "claude-mermaid-display-hook";
          package = mermaidDisplayHook;
        };
      };

    # One Edit rule only: the CLI's file permission checks match
    # Edit(path) rules against every file-editing tool (Write included)
    # and warn at startup that a Write(path) rule is never consulted
    # (2.1.241). The spool path is rendered concretely from the
    # activation environment's runtime dir by the register, not left as
    # a wildcard pattern.
    ch-ai-workbench.claude-code.permissions.deny = lib.mkIf cfg.sessionHooks.enable [
      "Edit(/\${XDG_RUNTIME_DIR}/claude-consent/**)"
    ];
  };
}
