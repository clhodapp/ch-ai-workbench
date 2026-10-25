# SPDX-License-Identifier: MIT
#
# The tree the microvm checks evaluate: a machine whose caisson-microvm
# configuration declares slots, and a machine without any. A home of
# the user `tester` is declared inside each.
{ ... }:
{ lib, ... }:
{
  caisson.nixos.configurations = {
    host = lib.caisson.nixos.mkConfiguration {
      extraModuleImports = modules: [ modules."caisson/microvm-host" ];
    };
    bare = lib.caisson.nixos.mkConfiguration { };
  };
}
