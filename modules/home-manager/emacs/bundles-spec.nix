# SPDX-License-Identifier: MIT
#
# This layer's bundles, in the shape the editor's `bundles` option
# takes. A separate file because two things read it: the module, which
# defines them on that option, and the checks, which build an Emacs
# carrying both layers' bundles. A check built from a second copy would
# pass while the real configuration broke.
{
  lib,
  readInit,
  merman,
}:
{
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

  ai-commit = {
    enable = true;
    init = readInit "ai-commit.el";
    packages = _epkgs: local: [ local.ai-commit ];
  };

  claude-queue = {
    enable = true;
    init = readInit "claude-queue.el";
    packages = _epkgs: local: [ local.claude-queue ];
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

  gptel = {
    enable = true;
    init = readInit "gptel.el";
    packages = epkgs: _: [ epkgs.gptel ];
  };

  gptel-agent = {
    enable = true;
    init = readInit "gptel-agent.el";
    packages = epkgs: _: [ epkgs.gptel ];
  };

  mcp-server = {
    enable = true;
    # The renderer is appended to this bundle's own init rather than to
    # the configuration's, so the `defvar` above it is in scope when the
    # file compiles. The init's bare-name default finds an mmdc only if
    # something else installed one.
    init = readInit "mcp-server.el" + ''

      (setq ch-emacs-config-mcp-mermaid-command
            (list "${lib.getExe merman}" "mmdc"))
    '';
    packages = epkgs: _: [ epkgs.mcp-server-lib ];
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
}
