# SPDX-License-Identifier: MIT
#
# The exported flake module. Consumers also need caisson's default
# flake module (configInfo and the export options) applied, which any
# caisson composition selects from its own registry.
{ mkModule, ... }:
{ ... }:
{
  imports = [
    (mkModule ./claude-code-sandbox)
  ];
}
