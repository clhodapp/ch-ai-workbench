# SPDX-License-Identifier: MIT
#
# The Claude Code side of the workbench in Emacs: the claude-queue
# bundle (sessions in ghostel terminals) and the mcp-server bundle (the
# tools a session calls back into Emacs with), plus the stdio bridge
# MCP clients register. Both bundles build on the vendor-neutral module
# beside this one: claude-queue's package depends on semantic-finder,
# and the MCP server's comment tools call collab-comments, so this
# module asserts that one is enabled rather than quietly producing an
# init that fails to byte-compile.
#
# The Claude Code CLI itself (hooks, skills, the LSP plugin) is the
# claude-code module; the hooks and skill that let a session drive this
# Emacs are emacs-integration.
{ closure-inputs, closure-lib, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.claude;

  merman = closure-inputs.merman-nix.packages.${pkgs.stdenv.hostPlatform.system}.merman-preview;

  # The bundle spec and the local packages come from this layer's
  # library, so the modules and the checks read one definition.
  workbench = closure-lib.ch-ai-workbench;

  # The editor's package scope, read from its module rather than rebuilt:
  # the bridge below is built against the same Emacs the editor
  # configures, or it loads into a different one than it compiled for.
  editorScope = config.ch-emacs-config.emacs.build.packageScope;

  # The MCP stdio bridge: a stable command MCP clients register
  # (`claude mcp add -s user emacs -- emacs-mcp-stdio`) that keeps
  # working across package updates. Defaults target the "emacs" server
  # the mcp-server bundle registers; explicit flags win, since the
  # bridge's argument parser is last-match.
  mcpStdioBridge = pkgs.writeShellApplication {
    name = "emacs-mcp-stdio";
    runtimeInputs = [
      config.programs.emacs.finalPackage
      pkgs.coreutils
    ];
    text = ''
      bridge=(${editorScope.epkgs.mcp-server-lib}/share/emacs/site-lisp/elpa/mcp-server-lib-*/emacs-mcp-stdio.sh)
      exec bash "''${bridge[0]}" \
        --init-function=ch-mcp-server-start \
        --server-id=emacs \
        "$@"
    '';
  };
in
{
  options.ch-ai-workbench.claude = {
    enable = lib.mkEnableOption "the Claude Code side of the AI workbench in Emacs";
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = config.ch-ai-workbench.emacs.enable;
        message = ''
          ch-ai-workbench.claude needs ch-ai-workbench.emacs: claude-queue
          depends on semantic-finder and the MCP server's comment tools on
          collab-comments, both of which that module provides.
        '';
      }
    ];

    ch-emacs-config.emacs.localPackageOverlays = workbench.localPackageOverlays.claude;

    # `enable` is wrapped here rather than in the spec: the spec is also
    # read as plain data by the checks, where a priority wrapper is not
    # a boolean. mkDefault so a consumer can switch a bundle off.
    ch-emacs-config.emacs.bundles =
      lib.mapAttrs (_name: bundle: bundle // { enable = lib.mkDefault bundle.enable; })
        (workbench.bundleSpec {
          inherit lib merman;
          betterleaks = pkgs.betterleaks;
        }).claude;

    home.packages = [ mcpStdioBridge ];
  };
}
