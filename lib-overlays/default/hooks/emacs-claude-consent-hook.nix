# SPDX-License-Identifier: MIT
# The consent-gate PreToolUse hook as a package (script and rationale
# in emacs-claude-consent-hook.sh): built here rather than inline in
# the emacs-integration module so the flake check can drive it with
# synthetic payloads.  claude-consent is the prompt-API tool the hook
# asks through.
{ pkgs, claude-consent }:
pkgs.writeShellApplication {
  name = "emacs-claude-consent-hook";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
    claude-consent
  ];
  text = builtins.readFile ./emacs-claude-consent-hook.sh;
}
