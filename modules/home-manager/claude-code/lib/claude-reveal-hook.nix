# SPDX-License-Identifier: MIT
# The PreToolUse reveal hook as a package (script and rationale in
# claude-reveal-hook.sh), asking through the claude-consent prompt API;
# built here so the flake check can drive it with synthetic payloads.
{ pkgs, claude-consent }:
pkgs.writeShellApplication {
  name = "claude-reveal-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    claude-consent
  ];
  text = builtins.readFile ./claude-reveal-hook.sh;
}
