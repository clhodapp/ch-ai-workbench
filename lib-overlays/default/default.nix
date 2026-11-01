# SPDX-License-Identifier: MIT
#
# The ch-ai-workbench library namespace: the values this layer's
# modules and its flake configuration share. Every reader takes them
# from the composed library (`closure-lib.ch-ai-workbench` in a module,
# `lib.ch-ai-workbench` in the flake configuration), so each value has
# one definition and the directory layout of this repository stays
# internal. The files sit beside this overlay, which owns them: the init
# files of the bundles, the Emacs packages, and the scripts the hook
# builders read.
{ ... }:
{

  imports = [ ];

  overlay = _final: prev: {
    ch-ai-workbench = (prev.ch-ai-workbench or { }) // {
      # The init files of this layer's bundles, by file name. The nemacs
      # modules `emacs`, `gptel` and `claude` define the bundles.
      initFiles = builtins.mapAttrs (name: _: ./inits + "/${name}") (builtins.readDir ./inits);

      # The in-tree Emacs packages this layer adds, as an overlay on the
      # editor's nemacs package set (`final: prev:`), built with its
      # `nemacsBuild`. The nemacs module `emacs` applies it.
      emacsPackages = import ./emacs-packages;

      # The two Emacs packages this layer builds from plain source
      # inputs (collab-comments, parenting), as an overlay on the
      # editor's nemacs package set. It takes the two source trees,
      # which the nemacs module `emacs` takes from its closure inputs.
      mkEmacsPackageOverrides =
        { collab-comments, parenting }:
        self: _super: {
          collab-comments = self.callPackage ./emacs-packages/collab-comments/package.nix {
            src = collab-comments;
          };
          parenting = self.callPackage ./emacs-packages/parenting/package.nix {
            src = parenting;
          };
        };

      # The source trees of those packages, for the ERT suites the
      # checks run against them.
      emacsPackageSources = {
        ai-commit = ./emacs-packages/ai-commit;
        claude-queue = ./emacs-packages/claude-queue;
        gh-review-claude = ./emacs-packages/gh-review-claude;
        semantic-finder = ./emacs-packages/semantic-finder;
      };

      # The Claude Code hooks a real configuration installs and the
      # checks drive with synthetic payloads: each takes `pkgs` (and
      # what its script calls) and returns the hook as a package.
      mkClaudePrOriginHook = import ./hooks/claude-pr-origin-hook.nix;
      mkClaudePushPrCheckHook = import ./hooks/claude-push-pr-check-hook.nix;
      mkClaudeRedactHook = import ./hooks/claude-redact-hook.nix;
      mkClaudeRevealHook = import ./hooks/claude-reveal-hook.nix;
      mkEmacsClaudeConsentHook = import ./hooks/emacs-claude-consent-hook.nix;
      # The Codex hook that asks consent for a queued Codex task's call
      # that would leave its sandbox.
      mkCodexConsentHook = import ./hooks/codex-consent-hook.nix;
      # The OpenCode plugin doing the same for a queued OpenCode task's
      # file writes, for the OpenCode `version` it is given.
      mkOpencodeConsentPlugin = import ./opencode-plugins/consent.nix;

      # The home-manager activation entry that merges declared settings
      # into a config file an agent also writes, through
      # `agent-config apply`. The claude-code, codex and opencode modules
      # each call it per file.
      mkAgentConfigActivation = import ./agent-config-activation.nix;

      # The type of the `mcpServers` entries of those three modules: a
      # stdio server as `command`, `args` and `env`, which each module
      # renders into its agent's shape. Takes `lib`.
      mcpServerType = import ./mcp-server-type.nix;
    };
  };

}
