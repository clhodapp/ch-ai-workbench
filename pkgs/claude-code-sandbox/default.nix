# SPDX-License-Identifier: LGPL-3.0-or-later
{ callPackage, ... }:
{
  claude-code-sandbox = callPackage ./claude-code-sandbox { };
  claude-code-sandbox-plugin = callPackage ./claude-code-sandbox-plugin { };
  landlock-shim = callPackage ./landlock-shim { };
}
