# SPDX-License-Identifier: LGPL-3.0-or-later
{ ... }:
{

  overlay = final: prev: {
    claude-code-sandbox = prev.claude-code-sandbox or { };
  };

}
