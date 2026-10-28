# SPDX-License-Identifier: MIT
#
# Guests for Claude Code sessions. ch-microvm runs on-demand instances
# of microvm.nix guests for the user of this home, with the kinds of
# `ch-microvm.kinds`. This module imports the home-manager module of
# ch-microvm from the registry of this layer, as `ch-microvm/microvm`,
# and lets Claude Code sessions use some of those kinds. The option
# `kinds` names the kinds agents may use, and the guests among them
# that serve MCP.
#
# With kinds that agents may use, the module installs the Claude Code
# plugin `microvm`, which declares the MCP server `microvm`. A session
# leases, starts and stops instances through it. The plugin installs
# through the claude-code module of this layer, so a home that lets
# agents use a kind selects that module as well.
#
# For each kind that agents may use and that has shares, the module
# declares the agent-sandbox module `microvm-<kind>`. It grants
# Bash commands read and write access to the share directories of every
# instance of the kind in its default directory, as
# `ch-microvm.instances` lists them. A checkout that chooses it can put
# targets into the `in` share of an instance and read its `out` share.
# The module declares these sandbox modules when the home also selects
# the agent-sandbox module of this layer.
#
# docs/development/microvm-guests.md describes the whole mechanism.
{ closure-lib, ... }:
{
  config,
  lib,
  options,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.microvm;
  microvm = config.ch-microvm;

  # One of this layer's packages, from the evaluation's package set.
  workbenchPackage =
    name:
    pkgs.ch-ai-workbench.${name} or (throw ''
      ch-ai-workbench.microvm needs pkgs.ch-ai-workbench.${name}:
      apply ch-ai-workbench's package overlay (`overlays.default`; a
      caisson consumer lists the flake in `projects`) to the package set
      this home evaluates with.
    '');

  kindType = lib.types.submodule {
    options = {
      agents = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether agents may use the kind. The MCP server `microvm`
          offers only the kinds that set this. When the kind has shares
          and the home selects the agent-sandbox module of this
          layer, the sandbox module `microvm-<kind>` grants read and
          write access to the share directories that
          `ch-microvm.instances.<kind>` lists. The Bash commands of a
          checkout that chooses it reach the share directories of the
          instances in their default directories. No sandbox module
          grants a directory a caller passes to `microvm_up`.
        '';
      };
      mcp = lib.mkOption {
        type = lib.types.nullOr (
          lib.types.submodule {
            options.description = lib.mkOption {
              type = lib.types.str;
              description = ''
                What the MCP server of the guest offers, in a sentence
                the description of the tool `microvm_up` carries.
              '';
            };
          }
        );
        default = null;
        description = ''
          Whether the guest serves MCP on the `vsockPort` of its kind in
          `ch-microvm.kinds`. When `microvm_up` brings up such a guest,
          the MCP server `microvm` connects to it and offers the tools of
          the guest as tools of its own.
        '';
      };
    };
  };

  kinds = cfg.kinds;

  agentKinds = lib.filterAttrs (_: kind: kind.agents) kinds;

  undeclared = builtins.filter (name: !(microvm.kinds ? ${name})) (builtins.attrNames kinds);

  mcpWithoutPort = builtins.attrNames (
    lib.filterAttrs (
      name: kind: kind.mcp != null && microvm.kinds ? ${name} && microvm.kinds.${name}.vsockPort == null
    ) kinds
  );

  # One sandbox module per kind, so a checkout that works with one kind
  # reaches the share directories of that kind and of no other. The
  # grant names every share directory, since Claude Code ignores glob
  # patterns of `allowWrite` on Linux. It names the share directories
  # and not the directory of the instance, so a Bash command cannot
  # replace a share directory by a symbolic link.
  sandboxModules =
    lib.mapAttrs'
      (
        name: _:
        let
          paths = lib.concatMap (instance: instance.shareDirectories) microvm.instances.${name};
        in
        lib.nameValuePair "microvm-${name}" {
          description = "Read and write the share directories of the microvm instances of kind ${name} in their default directories: ${lib.concatStringsSep ", " paths}";
          extraAllowRead = paths;
          allowWrite = paths;
        }
      )
      (
        lib.filterAttrs (name: _: microvm.kinds ? ${name} && microvm.kinds.${name}.shares != [ ]) agentKinds
      );

  # What the program reads: the configuration file of ch-microvm, and
  # the kinds agents may use with the MCP server of each guest.
  programConfig = pkgs.writeText "microvm-mcp.json" (
    builtins.toJSON {
      instances = "${microvm.configFile}";
      kinds = builtins.mapAttrs (_: kind: { inherit (kind) mcp; }) agentKinds;
    }
  );

  # The program with the configuration baked in.
  command =
    pkgs.runCommand "microvm-mcp"
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        meta.mainProgram = "microvm-mcp";
      }
      ''
        makeWrapper ${lib.getExe cfg.programPackage} "$out/bin/microvm-mcp" \
          --set MICROVM_MCP_CONFIG ${programConfig}
      '';

  # The skills-directory plugin that declares the MCP server.
  plugin = pkgs.writeTextDir ".claude-plugin/plugin.json" (
    builtins.toJSON {
      name = "microvm";
      description = "Start and stop microvm guests of the user for a session, and use the tools of the guests that serve MCP";
      version = "0.4.0";
      mcpServers.microvm.command = lib.getExe command;
    }
  );
in
{
  imports = [ closure-lib.caisson.modules.homeManager."ch-microvm/microvm" ];

  options.ch-ai-workbench.microvm = {
    kinds = lib.mkOption {
      type = lib.types.attrsOf kindType;
      default = { };
      example = lib.literalExpression ''
        {
          rea = {
            agents = true;
            mcp.description = "Reverse-engineering tools for the binaries in the in share.";
          };
        }
      '';
      description = ''
        The kinds of `ch-microvm.kinds` that Claude Code sessions use,
        by name. An agent starts an instance of a kind with the tool
        `microvm_up` of the MCP server `microvm`. The instance belongs
        to the session: its holder is the Claude Code process, and it
        stops when the session ends.
      '';
    };

    programPackage = lib.mkOption {
      type = lib.types.package;
      default = workbenchPackage "microvm-mcp";
      defaultText = lib.literalExpression "pkgs.ch-ai-workbench.microvm-mcp";
      description = ''
        The program `microvm-mcp` before the module bakes the kinds of
        this home into it.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = command;
      defaultText = lib.literalMD "the program `microvm-mcp` with the kinds of this home baked in";
      description = ''
        The MCP server `microvm` of this home, with the kinds agents may
        use baked in. The plugin `microvm` runs it.
      '';
    };
  };

  config = lib.mkIf (kinds != { }) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = undeclared == [ ];
            message = "ch-ai-workbench.microvm.kinds: the kinds ${lib.concatStringsSep ", " undeclared} are not in ch-microvm.kinds.";
          }
          {
            assertion = mcpWithoutPort == [ ];
            message = "ch-ai-workbench.microvm.kinds: the kinds ${lib.concatStringsSep ", " mcpWithoutPort} set `mcp`, and their `vsockPort` in ch-microvm.kinds is null.";
          }
        ];
      }
      (lib.mkIf (agentKinds != { }) {
        assertions = [
          {
            assertion = config.ch-ai-workbench.claude-code.enable;
            message = ''
              ch-ai-workbench.microvm: agents may use the kinds
              ${lib.concatStringsSep ", " (builtins.attrNames agentKinds)}, and the plugin
              that serves them installs through the claude-code module.
              Enable ch-ai-workbench.claude-code.
            '';
          }
        ];

        ch-ai-workbench.claude-code.skills.microvm.source = plugin;
      })
      (lib.optionalAttrs (options ? ch-ai-workbench.agent-sandbox) {
        ch-ai-workbench.agent-sandbox.modules = sandboxModules;
      })
    ]
  );
}
