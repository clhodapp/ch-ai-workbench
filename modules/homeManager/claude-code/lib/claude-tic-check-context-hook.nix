# SPDX-License-Identifier: MIT
# The judge's UserPromptSubmit hook as a package (script and rationale
# in claude-tic-check-context-hook.sh), with the judge config the Stop
# hook uses; built here so the flake check can drive it with
# synthetic payloads.  It runs no regex and no judge itself.
{ pkgs, judge }:
pkgs.writeShellApplication {
  name = "claude-tic-check-context-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
  ];
  text = ''
    judge=${pkgs.writeText "claude-tic-check-judge.json" (builtins.toJSON judge)}
    ${builtins.readFile ./tic-check-verdict-path.sh}
    ${builtins.readFile ./tic-check-wake.sh}
    ${builtins.readFile ./claude-tic-check-context-hook.sh}
  '';
}
