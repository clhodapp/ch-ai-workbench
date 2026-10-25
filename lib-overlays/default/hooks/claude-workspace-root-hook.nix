# SPDX-License-Identifier: MIT
# The cd-workspace-root PreToolUse hook as a package (script and
# rationale in claude-workspace-root-hook.sh); built here rather than
# inline in the module so the flake check can drive it with synthetic
# payloads.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-workspace-root-hook";
  runtimeInputs = [
    pkgs.git
    pkgs.jq
  ];
  text = builtins.readFile ./claude-workspace-root-hook.sh;
}
