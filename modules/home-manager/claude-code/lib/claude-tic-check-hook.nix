# SPDX-License-Identifier: MIT
# The tic-check Stop hook as a package (script and rationale in
# claude-tic-check-hook.sh, matching in tic-check-match.sh), with its
# pattern table rendered into the store; built here rather than
# inline in the module so the flake check can drive it with synthetic
# payloads.  checks is a list of {name, pattern, rule} (the module
# renders it from ticChecks).
{ pkgs, checks }:
pkgs.writeShellApplication {
  name = "claude-tic-check-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
  ];
  text = ''
    table=${pkgs.writeText "claude-tic-checks.json" (builtins.toJSON checks)}
    ${builtins.readFile ./tic-check-match.sh}
    ${builtins.readFile ./claude-tic-check-hook.sh}
  '';
}
