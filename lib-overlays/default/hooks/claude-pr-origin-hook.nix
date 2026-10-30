# SPDX-License-Identifier: MIT
# The pull-request origin PostToolUse hook as a package (script and
# rationale in claude-pr-origin-hook.sh); built here rather than
# inline in the module so the flake check can drive it with synthetic
# payloads.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-pr-origin-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.jq
  ];
  text = builtins.readFile ./claude-pr-origin-hook.sh;
}
