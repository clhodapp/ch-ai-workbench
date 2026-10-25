# SPDX-License-Identifier: MIT
#
# Guests for Claude Code sessions: microvm guests of the machine this
# home runs on, which a session leases, starts and stops. The guests
# are the units `microvm@<slot>.service` that caisson's `microvm-host`
# NixOS module runs. The option `kinds` declares them, and the module
# reads nothing else about them. It knows nothing of what runs in them.
#
# With kinds, the module installs the `microvm` command with the kinds
# baked in, and a user timer that stops the slots of holders that are
# gone. With kinds that agents may use, it also installs the Claude
# Code plugin `microvm`, which declares the MCP server `microvm`.
# Without kinds it declares nothing. The plugin installs through the
# claude-code module of this layer, so a home that lets agents use a
# kind selects that module as well.
#
# docs/development/microvm-guests.md describes the whole mechanism.
{ ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.microvm;

  # One of this layer's packages, from the evaluation's package set.
  workbenchPackage =
    name:
    pkgs.ch-ai-workbench.${name} or (throw ''
      ch-ai-workbench.microvm needs pkgs.ch-ai-workbench.${name}:
      apply ch-ai-workbench's package overlay (`overlays.default`; a
      caisson consumer lists the flake in `projects`) to the package set
      this home evaluates with.
    '');

  namePattern = "[A-Za-z0-9][A-Za-z0-9_.-]*";

  slotType = lib.types.submodule {
    options = {
      name = lib.mkOption {
        type = lib.types.strMatching namePattern;
        description = ''
          The name of the guest. Its unit is `microvm@<name>.service`.
        '';
      };
      cid = lib.mkOption {
        type = lib.types.ints.between 3 4294967294;
        description = "The vsock CID of the guest.";
      };
    };
  };

  kindType = lib.types.submodule {
    options = {
      slots = lib.mkOption {
        type = lib.types.nonEmptyListOf slotType;
        example = lib.literalExpression ''
          [
            { name = "rea-1"; cid = 101; }
            { name = "rea-2"; cid = 102; }
          ]
        '';
        description = ''
          The guests of the kind, in the order a session claims them.
        '';
      };
      vsockPort = lib.mkOption {
        type = lib.types.nullOr lib.types.port;
        default = null;
        description = ''
          The vsock port every guest of the kind serves on. `up` waits
          until a started guest accepts a connection on it. With null,
          `up` returns once the unit has started.
        '';
      };
      shareRoot = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        example = "/home/chris/rea";
        description = ''
          The directory that holds the share directories of the guests.
          The guest `<slot>` shares `<shareRoot>/<slot>/in`, read-only
          in the guest, and `<shareRoot>/<slot>/out`, writable in the
          guest. This is the layout of `shareRoot` of a caisson-microvm
          configuration. With null, the guests share no directories that
          `up` reports.
        '';
      };
      agents = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Whether agents may use the kind. The MCP server `microvm`
          offers only the kinds that set this. The `microvm` command
          controls every kind.
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
          Whether the guests of the kind serve MCP on `vsockPort`. When
          `microvm_up` brings up such a guest, the MCP server `microvm`
          connects to it and offers the tools of the guest as tools of
          its own.
        '';
      };
    };
  };

  kinds = cfg.kinds;

  agentKinds = lib.filterAttrs (_: kind: kind.agents) kinds;

  allSlots = lib.concatMap (kind: kind.slots) (builtins.attrValues kinds);

  duplicates =
    values:
    builtins.attrNames (
      lib.filterAttrs (_: n: n > 1) (
        lib.foldl' (acc: v: acc // { ${v} = (acc.${v} or 0) + 1; }) { } values
      )
    );

  duplicateSlots = duplicates (map (slot: slot.name) allSlots);

  duplicateCids = duplicates (map (slot: toString slot.cid) allSlots);

  badKindNames = builtins.filter (name: builtins.match namePattern name == null) (
    builtins.attrNames kinds
  );

  mcpWithoutPort = builtins.attrNames (
    lib.filterAttrs (_: kind: kind.mcp != null && kind.vsockPort == null) kinds
  );

  stateDir = "${config.xdg.stateHome}/ch-ai-workbench/microvm";

  # What the program reads: the kinds, where the leases live, and the
  # systemctl it runs.
  programConfig = pkgs.writeText "microvm-kinds.json" (
    builtins.toJSON {
      kinds = builtins.mapAttrs (_: kind: {
        slots = map (slot: { inherit (slot) name cid; }) kind.slots;
        inherit (kind)
          vsockPort
          shareRoot
          agents
          mcp
          ;
      }) kinds;
      inherit stateDir;
      systemctl = lib.getExe' pkgs.systemd "systemctl";
      inherit (cfg) upTimeout;
    }
  );

  # The program with the configuration baked in.
  command =
    pkgs.runCommand "microvm"
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        meta.mainProgram = "microvm";
      }
      ''
        makeWrapper ${lib.getExe cfg.programPackage} "$out/bin/microvm" \
          --set MICROVM_CONFIG ${programConfig}
      '';

  # What the reap service may not do. It talks to the system bus, reads
  # /proc/<pid>/stat of the holders and writes its state directory, and
  # nothing more.
  hardening = {
    NoNewPrivileges = true;
    PrivateUsers = true;
    ProtectSystem = "strict";
    ProtectHome = "read-only";
    ReadWritePaths = stateDir;
    PrivateTmp = true;
    PrivateDevices = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectKernelLogs = true;
    ProtectControlGroups = true;
    ProtectClock = true;
    ProtectHostname = true;
    RestrictNamespaces = true;
    RestrictRealtime = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
    SystemCallArchitectures = "native";
    RestrictAddressFamilies = "AF_UNIX";
    UMask = "0077";
  };

  # The skills-directory plugin that declares the MCP server.
  plugin = pkgs.writeTextDir ".claude-plugin/plugin.json" (
    builtins.toJSON {
      name = "microvm";
      description = "Start and stop the microvm guests of this machine for a session, and use the tools of the guests that serve MCP";
      version = "0.2.0";
      mcpServers.microvm = {
        command = lib.getExe command;
        args = [ "mcp" ];
      };
    }
  );
in
{
  options.ch-ai-workbench.microvm = {
    kinds = lib.mkOption {
      type = lib.types.attrsOf kindType;
      default = { };
      example = lib.literalExpression ''
        {
          rea = {
            slots = [
              { name = "rea-1"; cid = 101; }
              { name = "rea-2"; cid = 102; }
            ];
            vsockPort = 7000;
            shareRoot = "/home/chris/rea";
            agents = true;
            mcp.description = "Reverse-engineering tools for the binaries in the in share.";
          };
        }
      '';
      description = ''
        The guest kinds this home controls, by name. Each kind is a pool
        of guests that the machine runs as `microvm@<slot>.service` and
        that the user of this home may start and stop, which caisson's
        `microvm-host` NixOS module grants through
        `caisson.microvm-host.operators`. A machine that declares the
        slots in a caisson-microvm configuration gives the same names,
        CIDs, port and share root here. Slot names and CIDs are unique
        across the kinds.
      '';
    };

    programPackage = lib.mkOption {
      type = lib.types.package;
      default = workbenchPackage "microvm";
      defaultText = lib.literalExpression "pkgs.ch-ai-workbench.microvm";
      description = ''
        The `microvm` program before the module bakes the kinds of this
        home into it.
      '';
    };

    upTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        The number of seconds `up` waits for a started guest to accept a
        connection on the vsock port of its kind.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = command;
      defaultText = lib.literalMD "the `microvm` program with the kinds of this home baked in";
      description = ''
        The `microvm` command of this home, with the kinds of this home
        baked in. The home installs it when it has kinds.
      '';
    };
  };

  config = lib.mkIf (kinds != { }) (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = duplicateSlots == [ ];
            message = "ch-ai-workbench.microvm.kinds: the slot names ${lib.concatStringsSep ", " duplicateSlots} appear more than once.";
          }
          {
            assertion = duplicateCids == [ ];
            message = "ch-ai-workbench.microvm.kinds: the CIDs ${lib.concatStringsSep ", " duplicateCids} appear more than once.";
          }
          {
            assertion = badKindNames == [ ];
            message = "ch-ai-workbench.microvm.kinds: the kind names ${lib.concatStringsSep ", " badKindNames} are not of letters, digits, `.`, `_` and `-`.";
          }
          {
            assertion = mcpWithoutPort == [ ];
            message = "ch-ai-workbench.microvm.kinds: the kinds ${lib.concatStringsSep ", " mcpWithoutPort} set `mcp` and no `vsockPort` to serve it on.";
          }
        ];

        home.packages = [ command ];

        # The program writes leases here, and the reap service sees the
        # rest of home read-only, so the directory exists before it runs.
        systemd.user.tmpfiles.rules = [ "d ${stateDir}/leases 0700 - - -" ];

        systemd.user.timers.ch-ai-workbench-microvm-reap = {
          Unit.Description = "Stop the microvm slots of holders that are gone";
          Timer = {
            OnCalendar = "minutely";
            AccuracySec = "10s";
          };
          Install.WantedBy = [ "timers.target" ];
        };

        systemd.user.services.ch-ai-workbench-microvm-reap = {
          Unit.Description = "Stop the microvm slots of holders that are gone";
          Service = hardening // {
            Type = "oneshot";
            ExecStart = "${lib.getExe command} reap";
          };
        };
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
    ]
  );
}
