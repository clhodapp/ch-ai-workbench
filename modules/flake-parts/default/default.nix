# SPDX-License-Identifier: LGPL-3.0-or-later
{ closure-inputs, mkModule, ... }:
{ ... }:
{
  imports = [
    (mkModule ./claude-code-sandbox)
    closure-inputs.ch-flake.flakeModules.default
    closure-inputs.ch-nixpkgs.flakeModules.default
  ];
}
