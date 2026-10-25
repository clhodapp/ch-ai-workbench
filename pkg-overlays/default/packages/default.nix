# SPDX-License-Identifier: MIT
# The `pkgs.ch-ai-workbench.*` scope: the sandbox CLI, its plugin, the
# Landlock shim, the trusted-executable stub and service, the
# claude-consent prompt tool, the claude-response-judge client the
# tic-check hooks ask a decision model through, and the program that
# leases microvm guest slots to sessions.
{ callPackage, ... }:
{
  claude-code-sandbox = callPackage ./claude-code-sandbox { };
  claude-code-sandbox-plugin = callPackage ./claude-code-sandbox-plugin { };
  claude-consent = callPackage ./claude-consent { };
  claude-response-judge = callPackage ./claude-response-judge { };
  landlock-shim = callPackage ./landlock-shim { };
  microvm = callPackage ./microvm { };
  trusted-exec = callPackage ./trusted-exec { };
}
