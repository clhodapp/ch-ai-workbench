# SPDX-License-Identifier: MIT
#
# The guest kind `probe`: the NixOS configuration each slot of the kind
# takes. microvm.nix's guest module, which caisson's `microvm-guest`
# NixOS module imports, gives the guest its boot and file systems.
{ ... }:
{ ... }:
{
  system.stateVersion = "25.05";
}
