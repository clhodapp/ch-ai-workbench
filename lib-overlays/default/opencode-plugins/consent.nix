# SPDX-License-Identifier: MIT
# The OpenCode consent plugin for an OpenCode version: the plugin file
# that hands a queued task's file writes to the consent gate
# (opencode-consent-gate.sh), which asks through claude-consent. The
# two major versions have different plugin interfaces, so `version`
# picks the file.
{
  pkgs,
  lib,
  claude-consent,
  version,
}:
let
  gate = pkgs.writeShellApplication {
    name = "opencode-consent-gate";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.jq
      claude-consent
    ];
    text = builtins.readFile ../hooks/opencode-consent-gate.sh;
  };
in
pkgs.replaceVars (if lib.versionAtLeast version "2" then ./consent-v2.js else ./consent-v1.js) {
  gate = lib.getExe gate;
}
