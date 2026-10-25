# SPDX-License-Identifier: MIT
#
# What both fixture machines share: enough of a NixOS system to
# evaluate, and the account of `tester`.
{ ... }:
{ ... }:
{
  boot.loader.grub.enable = false;
  fileSystems."/" = {
    device = "none";
    fsType = "tmpfs";
  };
  system.stateVersion = "25.05";
  users.users.tester.isNormalUser = true;
}
