# SPDX-License-Identifier: MIT
# The tic-check PreToolUse hook on Bash for commit messages and pull
# request texts as a package (script and rationale in
# claude-tic-check-message-hook.sh, matching and judging in
# tic-check-match.sh), with the same rendered table and judge config
# as the Stop hook; built here so the flake check can drive it with
# synthetic payloads.  claude-response-judge also provides
# claude-vcs-message, which reads the message out of the command.
{
  pkgs,
  checks,
  judge,
  claude-response-judge,
}:
pkgs.writeShellApplication {
  name = "claude-tic-check-message-hook";
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
    ${builtins.readFile ./tic-check-turn-checks.sh}
    ${builtins.readFile ./tic-check-verdict-path.sh}
    ${builtins.readFile ./claude-tic-check-message-hook.sh}
  '';
}
