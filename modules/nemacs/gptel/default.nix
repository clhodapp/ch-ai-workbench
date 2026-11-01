# SPDX-License-Identifier: MIT
#
# The gptel side of the workbench, as a nemacs module: the gptel and
# gptel-agent bundles. It stands on the editor alone and does not need
# the nemacs module `emacs` beside it.
{ closure-lib, ... }:
{ lib, ... }:
let
  readInit = name: builtins.readFile closure-lib.ch-ai-workbench.initFiles.${name};
in
{
  bundles = lib.mapAttrs (_name: bundle: bundle // { enable = lib.mkDefault true; }) {
    gptel = {
      init = readInit "gptel.el";
      packages = epkgs: [ epkgs.gptel ];
    };

    gptel-agent = {
      init = readInit "gptel-agent.el";
      packages = epkgs: [ epkgs.gptel-agent ];
    };
  };
}
