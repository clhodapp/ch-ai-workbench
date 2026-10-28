# SPDX-License-Identifier: MIT
#
# Codex, OpenAI's coding agent: the consumer's codex package, installed
# through Home Manager's programs.codex, with the Emacs MCP server of the
# claude module declared for it.
{ ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.codex;

  # The claude module builds the Emacs MCP server and its stdio bridge.
  # The bridge is registered by its home-manager profile path, the stable
  # command that module documents for MCP clients.
  mcpServers = lib.optionalAttrs (config.ch-ai-workbench.claude.enable or false) {
    emacs.command = "${config.home.profileDirectory}/bin/emacs-mcp-stdio";
  };

  # The servers reach Codex as `-c` overrides on each launch, so
  # CODEX_HOME/config.toml stays a file Codex writes: Codex records the
  # trust answer for a project, the model `/model` picks, and the
  # servers `codex mcp add` adds there. A configuration that sets
  # programs.codex.settings makes Home Manager link that file into the
  # store, where Codex cannot write it. A root-level override applies to
  # every subcommand, and `codex mcp list` shows the servers it
  # declares. The values are TOML strings, which a JSON string is.
  overrides = lib.concatLists (
    lib.mapAttrsToList (name: server: [
      "--add-flag"
      "-c"
      "--add-flag"
      "mcp_servers.${name}.command=${builtins.toJSON server.command}"
    ]) mcpServers
  );

  # The name keeps the version and passthru stays, because Home
  # Manager's module reads the version from the package to pick the
  # configuration features it writes.
  wrapped =
    if mcpServers == { } then
      cfg.package
    else
      pkgs.symlinkJoin {
        name = "${lib.getName cfg.package}-workbench-${lib.getVersion cfg.package}";
        paths = [ cfg.package ];
        nativeBuildInputs = [ pkgs.makeWrapper ];
        postBuild = ''
          wrapProgram $out/bin/${cfg.package.meta.mainProgram} ${lib.escapeShellArgs overrides}
        '';
        inherit (cfg.package) meta;
        passthru = cfg.package.passthru or { };
      };
in
{
  options.ch-ai-workbench.codex = {
    enable = lib.mkEnableOption "Codex, with the Emacs MCP server of the workbench";

    package = lib.mkOption {
      type = lib.types.package;
      example = lib.literalExpression "llm-agents.packages.\${system}.codex";
      description = ''
        The Codex package this machine runs, before the wrapper that
        declares the Emacs MCP server. It has no default: only the
        configuration that installs Codex knows which build that machine
        runs. With ch-ai-workbench.claude enabled, the codex command
        starts with the MCP server `emacs`, which runs the bridge
        `emacs-mcp-stdio` from the home-manager profile.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    programs.codex = {
      enable = true;
      package = wrapped;
    };
  };
}
