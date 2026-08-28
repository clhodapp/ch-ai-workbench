# SPDX-License-Identifier: MIT
{ closure-inputs, mkModule, ... }:
{ ... }:
{
  imports = [
    (mkModule ./claude-code-sandbox)
    closure-inputs.ch-flake.flakeModules.default
    closure-inputs.ch-nixpkgs.flakeModules.default
  ];
}
