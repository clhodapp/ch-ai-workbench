# SPDX-License-Identifier: MIT
# The `pkgs.ch-ai-workbench.*` scope: the sandbox CLI, its plugin, the
# Landlock shim, and the claude-consent prompt tool.
{ callPackage, ... }:
{
  claude-code-sandbox = callPackage ./claude-code-sandbox { };
  claude-code-sandbox-plugin = callPackage ./claude-code-sandbox-plugin { };
  claude-consent = callPackage ./claude-consent { };
  landlock-shim = callPackage ./landlock-shim { };
}
