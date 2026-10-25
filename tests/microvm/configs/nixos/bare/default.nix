# SPDX-License-Identifier: MIT
#
# A machine without guests, and the home of `tester`, which selects the
# same modules as the home on the machine with guests.
{ ... }:
{ lib, ... }:
{
  imports = [ lib.caisson.configs.nixos.machine-base ];

  caisson.home-manager.configurations.tester = lib.caisson.home-manager.mkConfiguration {
    extraModuleImports = modules: [
      modules."ch-ai-workbench/claude-code"
      modules."ch-ai-workbench/claude-code-sandbox"
      modules."ch-ai-workbench/microvm"
    ];
  };
}
