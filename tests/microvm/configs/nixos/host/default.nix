# SPDX-License-Identifier: MIT
#
# A machine that runs a pool of two guests of the kind `probe`, which
# its user `tester` may start and stop, and the home of `tester`.
{ ... }:
{ lib, ... }:
{
  imports = [ lib.caisson.configs.nixos.machine-base ];

  caisson.caisson-microvm.configurations.pool = lib.caisson.caisson-microvm.mkConfiguration { };

  caisson.microvm-host.operators.tester = [
    "probe-1"
    "probe-2"
  ];

  caisson.home-manager.configurations.tester = lib.caisson.home-manager.mkConfiguration {
    extraModuleImports = modules: [
      modules."ch-ai-workbench/claude-code"
      modules."ch-ai-workbench/claude-code-sandbox"
      modules."ch-ai-workbench/microvm"
    ];
  };
}
