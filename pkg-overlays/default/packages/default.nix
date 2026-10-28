# SPDX-License-Identifier: MIT
# The `pkgs.ch-ai-workbench.*` scope: the sandbox CLI, its plugin, the
# Landlock shim, the trusted-executable stub and service, the
# claude-consent prompt tool, the claude-response-judge client the
# tic-check hooks ask a decision model through, and the MCP server that
# leases microvm guests of the user to sessions.
{ callPackage, ... }:
{
  agent-sandbox = callPackage ./agent-sandbox { };
  agent-sandbox-plugin = callPackage ./agent-sandbox-plugin { };
  claude-consent = callPackage ./claude-consent { };
  claude-response-judge = callPackage ./claude-response-judge { };
  landlock-shim = callPackage ./landlock-shim { };
  microvm-mcp = callPackage ./microvm-mcp { };
  trusted-exec = callPackage ./trusted-exec { };
}
