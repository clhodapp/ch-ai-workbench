# SPDX-License-Identifier: MIT
#
# The ch-ai-workbench library namespace: the values this layer's
# modules and its flake configuration share. Every reader takes them
# from the composed library (`closure-lib.ch-ai-workbench` in a module,
# `lib.ch-ai-workbench` in the flake configuration), so each value has
# one definition and the directory layout of this repository stays
# internal. The files sit beside this overlay, which owns them: the
# bundle spec reads the init files next to it, the local-package
# overlays build the Emacs packages next to them, and the hook builders
# read their scripts next to them.
{ ... }:
{

  imports = [ ];

  overlay = _final: prev: {
    ch-ai-workbench = (prev.ch-ai-workbench or { }) // {
      # This layer's bundles in the shape the editor's `bundles` option
      # takes, grouped by the module that defines them (`emacs`,
      # `gptel`, `claude`). Each module defines its own group on that
      # option; the checks build an Emacs carrying every group.
      bundleSpec = import ./bundle-spec.nix;

      # The in-tree Emacs packages this layer adds, as overlays over the
      # editor's package scope, grouped the same way. Each module feeds
      # its group to the editor's `localPackageOverlays`; the checks
      # feed every group to the package scope.
      localPackageOverlays = import ./local-packages.nix;

      # The two Emacs packages this layer builds from plain source
      # inputs (collab-comments, parenting), as an override of the
      # editor's Emacs package set. It takes the two source trees; the
      # emacs module passes its closure's and the checks their own.
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
        semantic-finder = ./emacs-packages/semantic-finder;
      };

      # The Claude Code hooks a real configuration installs and the
      # checks drive with synthetic payloads: each takes `pkgs` (and
      # what its script calls) and returns the hook as a package.
      mkClaudePushPrCheckHook = import ./hooks/claude-push-pr-check-hook.nix;
      mkClaudeRedactHook = import ./hooks/claude-redact-hook.nix;
      mkClaudeRevealHook = import ./hooks/claude-reveal-hook.nix;
      mkClaudeWorkspaceRootHook = import ./hooks/claude-workspace-root-hook.nix;
      mkEmacsClaudeConsentHook = import ./hooks/emacs-claude-consent-hook.nix;
    };
  };

}
