# SPDX-License-Identifier: MIT
# The verdict-hiding MessageDisplay hook as a package (script and
# rationale in claude-tic-check-display-hook.sh); built here rather
# than inline in the module so the flake check can drive it.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-tic-check-display-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
  ];
  text = builtins.readFile ./claude-tic-check-display-hook.sh;
}
