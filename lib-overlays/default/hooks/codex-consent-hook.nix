# SPDX-License-Identifier: MIT
# The consent hook for queued Codex tasks as a package (script and
# rationale in codex-consent-hook.sh), built here so the flake check
# can drive it.  claude-consent is the prompt-API tool the hook asks
# through.
{ pkgs, claude-consent }:
pkgs.writeShellApplication {
  name = "codex-consent-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gnused
    pkgs.jq
    claude-consent
  ];
  text = builtins.readFile ./codex-consent-hook.sh;
}
