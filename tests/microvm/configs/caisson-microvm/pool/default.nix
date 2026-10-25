# SPDX-License-Identifier: MIT
#
# The guests of the machine `host`: two slots of the kind `probe`,
# started only on demand, each with its share directories and the vsock
# port the kind serves on.
{ ... }:
{ ... }:
{
  hypervisor = "cloud-hypervisor";
  mem = 512;
  autostart = false;
  restartIfChanged = true;
  runtimeMaxSec = 3600;
  slots.probe = {
    count = 2;
    cidBase = 100;
    shareRoot = "/var/lib/probe";
    vsockPort = 5000;
  };
}
