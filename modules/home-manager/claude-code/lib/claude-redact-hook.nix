# SPDX-License-Identifier: MIT
# The PostToolUse redaction hook as a package (script and rationale in
# claude-redact-hook.sh), carrying gitleaks from the pinned nixpkgs so
# the rule set moves with the pin; built here so the flake check can
# drive it with synthetic payloads.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-redact-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.gitleaks
    pkgs.jq
  ];
  text = builtins.readFile ./claude-redact-hook.sh;
}
