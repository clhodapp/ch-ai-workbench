# SPDX-License-Identifier: MIT
# The judge's mid-turn PostToolUse hook as a package (script and
# rationale in claude-tic-check-turn-hook.sh, matching and judging in
# tic-check-match.sh), with the same rendered table and judge config
# as the Stop hook; built here so the flake check can drive it with
# synthetic payloads.  claude-response-judge also provides
# claude-turn-text, whose progress mode gives the hook the text it has
# not judged yet; util-linux provides flock.
{
  pkgs,
  checks,
  judge,
  claude-response-judge,
}:
pkgs.writeShellApplication {
  name = "claude-tic-check-turn-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnugrep
    pkgs.gnused
    pkgs.jq
    pkgs.util-linux
    claude-response-judge
  ];
  text = ''
    table=${pkgs.writeText "claude-tic-checks.json" (builtins.toJSON checks)}
    judge=${pkgs.writeText "claude-tic-check-judge.json" (builtins.toJSON judge)}
    ${builtins.readFile ./tic-check-match.sh}
    ${builtins.readFile ./tic-check-verdict-path.sh}
    ${builtins.readFile ./claude-tic-check-turn-hook.sh}
  '';
}
