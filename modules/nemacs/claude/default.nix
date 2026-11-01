# SPDX-License-Identifier: MIT
#
# The Claude Code side of the workbench, as a nemacs module: the task
# queue, Claude's review of a pull request, and the MCP server agents
# reach the editor through. It builds on the nemacs module `emacs`,
# whose packages it needs (claude-queue depends on semantic-finder, and
# the MCP server's comment tools on collab-comments).
{ closure-lib, ... }:
{ lib, pkgs, ... }:
let
  readInit = name: builtins.readFile closure-lib.ch-ai-workbench.initFiles.${name};

  merman =
    closure-lib.caisson.dependencies.merman-nix.packages.${pkgs.stdenv.hostPlatform.system}.merman-preview;
in
{
  bundles = lib.mapAttrs (_name: bundle: bundle // { enable = lib.mkDefault true; }) {
    claude-queue = {
      init = readInit "claude-queue.el";
      packages = epkgs: [ epkgs.claude-queue ];
    };

    # Claude's review of a pull request in the editor's gh-review:
    # needs the editor's gh-review bundle and claude-queue above.
    gh-review-claude = {
      init = readInit "gh-review-claude.el";
      packages = epkgs: [ epkgs.gh-review-claude ];
    };

    # Carries parenting itself: the sandboxed child Emacs is spawned
    # from this init, so a configuration with only this module has it
    # too.
    mcp-server = {
      # The programs the init spawns are appended to this bundle's own
      # init rather than to the configuration-wide init, so the `defvar`s
      # above them are in scope when the file compiles. The bare-name
      # defaults in the init find a program only if something else
      # installed one.
      init = readInit "mcp-server.el" + ''

        (setq ch-mcp-server-mermaid-command
              (list "${lib.getExe merman}" "mmdc"))
        (setq ch-mcp-server-betterleaks-command
              (list "${lib.getExe pkgs.betterleaks}"))
      '';
      packages = epkgs: [
        epkgs.mcp-server-lib
        epkgs.parenting
      ];
    };
  };
}
