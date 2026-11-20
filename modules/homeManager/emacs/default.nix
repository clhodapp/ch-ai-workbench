# SPDX-License-Identifier: MIT
#
# The vendor-neutral half of the workbench in Emacs: the bundles that
# turn the editor into a place to run agent sessions without naming one
# vendor (comment threads, the semantic finder, parenting, the ACP
# agent shell, commit messages, the ghostel environment handoff), plus
# the local packages two of them need. The gptel and claude modules
# beside this one add more bundles on top. The bundles are the
# nemacs module `emacs`, which the home-manager configuration gives to
# the nemacs configurations declared inside it, so a configuration
# importing both gets one Emacs with both layers' bundles rather than
# two configurations fighting.
{ closure-lib, ... }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.ch-ai-workbench.emacs;
in
{
  options.ch-ai-workbench.emacs = {
    enable = lib.mkEnableOption "the vendor-neutral Emacs half of the AI workbench";

    configuration = lib.mkOption {
      type = lib.types.str;
      default = "editor";
      description = ''
        The name of the nemacs configuration declared inside this
        home-manager configuration that is the editor. The other modules
        of this layer read the editor from it.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    caisson.forChildren.extraDefaultModuleImports.nemacs = _lib: [
      closure-lib.caisson.libManifest.modules.nemacs.emacs
    ];
  };
}
