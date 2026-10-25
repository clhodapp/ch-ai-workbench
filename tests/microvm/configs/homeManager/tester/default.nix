# SPDX-License-Identifier: MIT
#
# The home of `tester` on both fixture machines: Claude Code with the
# sandbox, which the microvm module needs.
{ ... }:
{ pkgs, ... }:
{
  home.stateVersion = "25.05";
  ch-ai-workbench.claude-code.enable = true;
  ch-ai-workbench.claude-code-sandbox = {
    enable = true;
    # Any package stands in for the claude-code package a machine runs.
    runtime.claudePackage = pkgs.hello;
  };
}
