# SPDX-License-Identifier: MIT
#
# This layer's bundles, in the shape the editor's `bundles` option
# takes, grouped by the module that defines them: `emacs` is the
# vendor-neutral agent workbench, `gptel` the gptel side, `claude` the
# Claude Code side. A separate file because two things read it: each
# module, which defines its own group on that option, and the checks,
# which build an Emacs carrying every group. A check built from a
# second copy would pass while the real configuration broke.
{
  lib,
  readInit,
  merman,
  gitleaks,
}:
{
  emacs = {
    acp = {
      enable = true;
      init = readInit "acp.el";
      packages = epkgs: _: [ epkgs.acp ];
    };

    agent-shell = {
      enable = true;
      init = readInit "agent-shell.el";
      packages = epkgs: _: [ epkgs.agent-shell ];
    };

    # Generates commit messages through either the claude CLI or the
    # active gptel backend, chosen at runtime, so it belongs to neither
    # side.
    ai-commit = {
      enable = true;
      init = readInit "ai-commit.el";
      packages = _epkgs: local: [ local.ai-commit ];
    };

    collab-comments = {
      enable = true;
      init = readInit "collab-comments.el";
      packages = epkgs: _local: [ epkgs.collab-comments ];
    };

    # No packages: the editor's ghostel bundle supplies everything this
    # touches. It is a bundle so the registration lands in the init the
    # same way every other piece of this layer does.
    ghostel-agent-env = {
      enable = true;
      init = readInit "ghostel-agent-env.el";
      packages = _epkgs: _local: [ ];
    };

    parenting = {
      enable = true;
      init = readInit "parenting.el";
      packages = epkgs: _: [ epkgs.parenting ];
    };

    semantic-finder = {
      enable = true;
      init = readInit "semantic-finder.el";
      packages = _epkgs: local: [ local.semantic-finder ];
    };
  };

  gptel = {
    gptel = {
      enable = true;
      init = readInit "gptel.el";
      packages = epkgs: _: [ epkgs.gptel ];
    };

    gptel-agent = {
      enable = true;
      init = readInit "gptel-agent.el";
      packages = epkgs: _: [ epkgs.gptel-agent ];
    };
  };

  claude = {
    # Needs semantic-finder from the `emacs` group (the package depends
    # on it); the claude module asserts that group is enabled.
    claude-queue = {
      enable = true;
      init = readInit "claude-queue.el";
      packages = _epkgs: local: [ local.claude-queue ];
    };

    # Needs collab-comments from the `emacs` group for its comment-thread
    # tools. Carries parenting itself: the sandboxed child Emacs is
    # spawned from this init, so a configuration with only this group
    # has it too.
    mcp-server = {
      enable = true;
      # The programs the init spawns are appended to this bundle's own
      # init rather than to the configuration-wide init, so the `defvar`s
      # above them are in scope when the file compiles. The bare-name
      # defaults in the init find a program only if something else
      # installed one.
      init = readInit "mcp-server.el" + ''

        (setq ch-mcp-server-mermaid-command
              (list "${lib.getExe merman}" "mmdc"))
        (setq ch-mcp-server-gitleaks-command
              (list "${lib.getExe gitleaks}"))
      '';
      packages = epkgs: _: [
        epkgs.mcp-server-lib
        epkgs.parenting
      ];
    };
  };
}
