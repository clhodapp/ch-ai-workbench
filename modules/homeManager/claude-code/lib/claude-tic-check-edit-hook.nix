# SPDX-License-Identifier: MIT
# The edit-side tic-check PreToolUse hook as a package (script and
# rationale in claude-tic-check-edit-hook.sh, matching and judging in
# tic-check-match.sh), with the same rendered table and judge config
# as the Stop hook; built here so the flake check can drive it with
# synthetic payloads.
{
  pkgs,
  checks,
  judge,
  claude-response-judge,
}:
pkgs.writeShellApplication {
  name = "claude-tic-check-edit-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    claude-response-judge
  ];
  text = ''
    table=${pkgs.writeText "claude-tic-checks.json" (builtins.toJSON checks)}
    judge=${pkgs.writeText "claude-tic-check-judge.json" (builtins.toJSON judge)}
    ${builtins.readFile ./tic-check-match.sh}
    ${builtins.readFile ./claude-tic-check-edit-hook.sh}
  '';
}
