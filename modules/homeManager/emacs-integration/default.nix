# SPDX-License-Identifier: MIT
#
# Optional Emacs integration: registers the MCP server, the hooks and
# the agent-tools skills that let a coding agent's session talk to a
# live Emacs, and points Emacs's agent-shell at the agents this home
# installs. Enabling this alongside the agent modules is the whole
# setup; the Emacs side needs no knowledge of any agent, which is why
# this module lives here rather than there.
#
# For every enabled agent module (claude-code, codex, opencode):
#   - the MCP server `emacs`, through the emacs-mcp-stdio bridge of the
#     claude module, and the emacs-tools and ghostel-terminals skills;
#   - the agent-shell command that starts the agent over the Agent
#     Client Protocol, by store path, so a session in Emacs runs the
#     build and the declared configuration the agent's own command does.
#
# For Claude Code, which has hooks, it also wires up:
#   - a cwd hook, so a session's working directory follows into Emacs
#     (claude-queue follow-mode), on CwdChanged and on the worktree
#     tools, which chdir without emitting CwdChanged;
#   - a consent hook classifying edit territory for Emacs-dispatched
#     headless sessions, asking the user through the claude-code
#     module's claude-consent tool (Emacs answers while
#     claude-consent-mode is on; without an answerer the hook falls
#     back to the CLI's own prompt), plus the deny rule that keeps
#     sessions out of the spool it reads;
#   - the mermaid hook, which renders diagrams as Claude displays them.
#
# Every hook fails open: a dead or hung Emacs, an unparseable payload,
# or a missing emacsclient all leave the session running. That is
# deliberate (a session must never block on the editor) and it is also
# why `emacsclientPath` is asserted rather than discovered: without it
# the integration would install cleanly and quietly do nothing.
{ closure-inputs, closure-lib, ... }:
{
  config,
  options,
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
      closure-inputs.merman-nix.packages.${pkgs.stdenv.hostPlatform.system}.merman-preview
    ];
    text = builtins.readFile ./claude-mermaid-display-hook.sh;
  };

  # The MCP server the skills document, through the stdio bridge the
  # claude module installs in the profile, and the two skills, as every
  # agent module of this layer takes them.
  # Inside an agent-sandbox run the bridge relays to the socket the run
  # names; Codex passes only the variables a server lists.
  emacsServer.emacs = {
    command = "${config.home.profileDirectory}/bin/emacs-mcp-stdio";
    envVars = [
      "SANDBOX_RUNTIME"
      "AGENT_SANDBOX_EMACS_MCP"
    ];
  };
  emacsSkills = {
    emacs-tools = ./skills/emacs-tools;
    # Terminals are sensitive by default (the MCP server withholds them
    # until the user exposes one); this skill tells the agent what it
    # can read and how the user grants access, so it is gated with the
    # rest of the MCP-server documentation.
    ghostel-terminals = ./skills/ghostel-terminals;
  };

  # The agent modules of this layer that the home imports beside this
  # one, other than claude-code: each gets the server and the skills
  # when it is enabled. A home that leaves one out has no option to set.
  otherAgents = lib.filter (name: options.ch-ai-workbench ? ${name}) [
    "codex"
    "opencode"
  ];

  agentEnabled = name: options.ch-ai-workbench ? ${name} && config.ch-ai-workbench.${name}.enable;

  # The ACP command agent-shell starts each enabled agent with, as the
  # agent's module builds it: by exact store path, so a session in Emacs
  # runs the build this home installs, reads the same declared
  # configuration as the agent's own command, and runs inside a
  # checkout's sandbox the same way.
  acpCommands =
    lib.filter (entry: agentEnabled entry.agent && entry.command != null && entry.command != [ ])
      (
        map (entry: entry // { command = config.ch-ai-workbench.${entry.agent}.acpCommand or null; }) [
          {
            agent = "claude-code";
            variable = "agent-shell-anthropic-claude-acp-command";
          }
          {
            agent = "codex";
            variable = "agent-shell-openai-codex-acp-command";
          }
          {
            agent = "opencode";
            variable = "agent-shell-opencode-acp-command";
          }
        ]
      );

  # Appended to the agent-shell bundle's own init. The `defvar`s declare
  # the variables to the byte compiler, which compiles the init before
  # agent-shell's per-agent files load; `setq` before that load wins over
  # the `defcustom` defaults.
  acpInit = lib.concatMapStrings (entry: ''
    (defvar ${entry.variable})
    (setq ${entry.variable} '(${lib.concatMapStringsSep " " builtins.toJSON entry.command}))
  '') acpCommands;
in
{
  options.ch-ai-workbench.emacs-integration = {
    enable = lib.mkEnableOption "the Emacs integration for the coding agents of this layer";

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

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      # Codex and OpenCode run whole inside a checkout's sandbox, and the
      # MCP servers they start run there too; agent-sandbox serves them
      # this bridge from outside.
      (lib.optionalAttrs (options.ch-ai-workbench ? agent-sandbox) {
        ch-ai-workbench.agent-sandbox.emacsMcpCommand = lib.mkIf cfg.skill.enable [
          emacsServer.emacs.command
        ];
      })
      (lib.optionalAttrs (options.ch-ai-workbench ? emacs) {
        ch-emacs-config.emacs.bundles = lib.mkIf (config.ch-ai-workbench.emacs.enable && acpInit != "") {
          agent-shell.init = lib.mkAfter acpInit;
        };
      })
      {
        ch-ai-workbench = lib.genAttrs otherAgents (
          name:
          lib.mkIf (cfg.skill.enable && config.ch-ai-workbench.${name}.enable) {
            mcpServers = emacsServer;
            skills = emacsSkills;
          }
        );
      }
      {
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

        # The MCP server the skills document, through the stdio bridge the
        # claude module installs in the profile. It is a user-scope server,
        # merged into ~/.claude.json at activation.
        ch-ai-workbench.claude-code.mcpServers = lib.mkIf cfg.skill.enable emacsServer;

        ch-ai-workbench.claude-code.skills = lib.mkIf cfg.skill.enable (
          lib.mapAttrs (_name: source: { inherit source; }) emacsSkills
        );

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
              package = cwdHook;
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
      }
    ]
  );
}
