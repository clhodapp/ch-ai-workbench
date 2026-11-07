# SPDX-License-Identifier: MIT
#
# The vendor-neutral half of the workbench, as a nemacs module: the
# bundles that turn the editor into a place to run agent sessions
# without naming one vendor (comment threads, the semantic finder,
# parenting, the ACP agent shell, commit messages, the ghostel
# environment handoff), and the Emacs packages this layer builds. The
# nemacs modules `gptel` and `claude` add their own bundles on top. Every
# bundle is on by default, so a plain `enable = false` elsewhere turns
# one off.
{ closure-lib, ... }:
{ lib, ... }:
let
  workbench = closure-lib.ch-ai-workbench;
  readInit = name: builtins.readFile workbench.initFiles.${name};
in
{
  overrides = [
    (workbench.mkEmacsPackageOverrides {
      inherit (closure-lib.caisson.dependencies) collab-comments parenting;
    })
    workbench.emacsPackages
  ];

  bundles = lib.mapAttrs (_name: bundle: bundle // { enable = lib.mkDefault true; }) {
    acp = {
      init = readInit "acp.el";
      packages = epkgs: [ epkgs.acp ];
    };

    agent-shell = {
      init = readInit "agent-shell.el";
      packages = epkgs: [ epkgs.agent-shell ];
    };

    # Generates commit messages through either the claude CLI or the
    # active gptel backend, chosen at runtime, so it belongs to neither
    # side.
    ai-commit = {
      init = readInit "ai-commit.el";
      packages = epkgs: [ epkgs.ai-commit ];
    };

    collab-comments = {
      init = readInit "collab-comments.el";
      packages = epkgs: [ epkgs.collab-comments ];
    };

    # No packages: the editor's ghostel bundle supplies everything this
    # touches. It is a bundle so the registration lands in the init the
    # same way every other piece of this layer does.
    ghostel-agent-env = {
      init = readInit "ghostel-agent-env.el";
    };

    parenting = {
      init = readInit "parenting.el";
      packages = epkgs: [ epkgs.parenting ];
    };

    semantic-finder = {
      init = readInit "semantic-finder.el";
      packages = epkgs: [ epkgs.semantic-finder ];
    };
  };
}
