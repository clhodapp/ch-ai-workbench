# SPDX-License-Identifier: MIT
# The tic-check Stop hook as a package (script and rationale in
# claude-tic-check-hook.sh, matching and judging in
# tic-check-match.sh), with its pattern table and judge config
# rendered into the store; built here rather than inline in the
# module so the flake check can drive it with synthetic payloads.
# checks is a list of {name, pattern, rule, dimension} (the module
# renders it from ticChecks), judge the config claude-response-judge
# reads (the module renders it from judge.*).
{
  pkgs,
  checks,
  judge,
  claude-response-judge,
}:
pkgs.writeShellApplication {
  name = "claude-tic-check-hook";
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
    ${builtins.readFile ./tic-check-verdict-path.sh}
    ${builtins.readFile ./claude-tic-check-hook.sh}
  '';
}
