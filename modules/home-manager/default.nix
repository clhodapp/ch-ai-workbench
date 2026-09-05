# SPDX-License-Identifier: MIT
{ lib }:
{
  # The Emacs half: the bundles, their packages, and the MCP bridge.
  emacs = lib.caisson-core.mkModule "homeManager" ./emacs;
  # The agent half: hooks, skills, output styles, permissions, and the
  # LSP plugin manifest.
  claude-code = lib.caisson-core.mkModule "homeManager" ./claude-code;
  # What joins them: the hooks and skill that let a session drive the
  # live Emacs.
  emacs-integration = lib.caisson-core.mkModule "homeManager" ./emacs-integration;
  # The shell half: one function, the other end of an Emacs eval-cmd
  # this layer registers.
  zsh = lib.caisson-core.mkModule "homeManager" ./zsh;
}
