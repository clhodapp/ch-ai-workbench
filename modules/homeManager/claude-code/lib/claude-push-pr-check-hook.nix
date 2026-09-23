# SPDX-License-Identifier: MIT
# The git-push PR-state reminder PreToolUse hook as a package (script
# and rationale in claude-push-pr-check-hook.sh); built here rather
# than inline in the module so the flake check can drive it with
# synthetic payloads.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-push-pr-check-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.jq
  ];
  text = builtins.readFile ./claude-push-pr-check-hook.sh;
}
