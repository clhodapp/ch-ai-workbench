# SPDX-License-Identifier: MIT
# The stacked pull request reminder PostToolUse hook as a package
# (script and rationale in claude-stack-reminder-hook.sh); built here
# rather than inline in the module so the flake check can drive it
# with synthetic payloads.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-stack-reminder-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
  ];
  text = builtins.readFile ./claude-stack-reminder-hook.sh;
}
