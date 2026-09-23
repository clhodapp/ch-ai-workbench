# SPDX-License-Identifier: MIT
# The edit-side tic-check PreToolUse hook as a package (script and
# rationale in claude-tic-check-edit-hook.sh, matching in
# tic-check-match.sh), with the same rendered table as the Stop hook;
# built here so the flake check can drive it with synthetic payloads.
{ pkgs, checks }:
pkgs.writeShellApplication {
  name = "claude-tic-check-edit-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
  ];
  text = ''
    table=${pkgs.writeText "claude-tic-checks.json" (builtins.toJSON checks)}
    ${builtins.readFile ./tic-check-match.sh}
    ${builtins.readFile ./claude-tic-check-edit-hook.sh}
  '';
}
