# SPDX-License-Identifier: MIT
{ ... }:
{

  overlay = final: prev: {
    claude-code-sandbox = prev.claude-code-sandbox or { };
  };

}
