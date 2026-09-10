# SPDX-License-Identifier: MIT
{ lib }:
{
  # The Emacs half, in three modules that each define their bundles on
  # the editor's own options.
  # Vendor-neutral: comment threads, the semantic finder, parenting, the
  # ACP agent shell, commit messages, the ghostel environment handoff.
  emacs = lib.caisson-core.mkModule "homeManager" ./emacs;
  # gptel and gptel-agent, and the backend and model they start on.
  gptel = lib.caisson-core.mkModule "homeManager" ./gptel;
  # Claude Code in Emacs: claude-queue, the MCP server, and its stdio
  # bridge. Needs `emacs`.
  claude = lib.caisson-core.mkModule "homeManager" ./claude;
  # The agent half: hooks, skills, output styles, permissions, and the
  # LSP plugin manifest.
  claude-code = lib.caisson-core.mkModule "homeManager" ./claude-code;
  # Claude Code's native sandbox, declared: named profiles (closed
  # toolsets compiled from Nix closures into sandbox rules) that a
  # checkout opts into by enrollment. Independent of the other modules.
  claude-code-sandbox = lib.caisson-core.mkModule "homeManager" ./claude-code-sandbox;
  # What joins them: the hooks and skill that let a session drive the
  # live Emacs.
  emacs-integration = lib.caisson-core.mkModule "homeManager" ./emacs-integration;
  # The shell half: one function, the other end of an Emacs eval-cmd
  # this layer registers.
  zsh = lib.caisson-core.mkModule "homeManager" ./zsh;
}
