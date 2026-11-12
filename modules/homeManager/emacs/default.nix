# SPDX-License-Identifier: MIT
#
# The vendor-neutral half of the workbench in Emacs: the bundles that
# turn the editor into a place to run agent sessions without naming one
# vendor (comment threads, the semantic finder, parenting, the ACP
# agent shell, commit messages, the ghostel environment handoff), plus
# the local packages two of them need. The gptel and claude modules
# beside this one add more bundles on top. The bundles are the
# nemacs module `emacs`, added to the editor's nemacs configuration
# (`programs.nemacs.settings`), so a configuration importing both gets
# one Emacs with both layers' bundles rather than two configurations
# fighting.
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
  };

  config = lib.mkIf cfg.enable {
    programs.nemacs.settings.imports = [ closure-lib.caisson.libManifest.modules.nemacs.emacs ];
  };
}
