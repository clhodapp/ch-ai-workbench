# SPDX-License-Identifier: MIT
#
# Guests for Claude Code sessions: the microvm guest slots of the
# machine this home is declared inside, which a session leases, starts
# and stops through the `microvm` program. The module reads the slots
# from the tree, so nothing about them is declared here. It knows
# caisson-microvm guests and nothing of what runs in them.
#
# The slots are the guests that the `slots.<kind>` pools of the
# machine's caisson-microvm configurations declare. The module reads
# the machine as `lib.caisson.evalManifest.nearest.nixos`, its
# childless evaluation. That evaluation leaves out what the
# configurations declared inside the machine evaluate to, so the module
# finalizes each caisson-microvm configuration of the machine again
# from its declaration, with the machine as its parent, as the machine
# finalizes it. It reads the slots that configuration records as
# `outputs.slots`. Of those it keeps the slots that
# `caisson.microvm-host.operators` of the machine lists for the user of
# this home: the polkit rule of caisson's `microvm-host` NixOS module
# lets that user start and stop them, and no other slots.
#
# With slots, the module declares the trusted executable `microvm` and
# the sandbox module `microvm` that grants it, a user timer that stops
# the slots of sessions that are gone, and the Claude Code plugin
# `microvm`, which carries the skill and a SessionEnd hook. Without
# slots (a home outside a NixOS configuration, a machine without
# caisson-microvm slots, or a user the machine lists as operating none)
# it declares nothing. The module sets options of the claude-code and
# claude-code-sandbox modules of this layer, so a home that selects it
# selects those two as well.
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

  # The manifest of this home, null for a home that caisson does not
  # evaluate.
  manifest = lib.caisson.evalManifest or null;

  # The machine this home is declared inside, in its childless
  # evaluation, or null when there is none.
  machine = if manifest == null then null else manifest.nearest.nixos or null;

  machineEval = machine.value;

  # The caisson-microvm configurations declared inside the machine,
  # finalized again from their declarations. The option's own value
  # refuses to be read in the childless evaluation, so the definitions
  # are merged here with the option's type, as the machine's evaluation
  # merges them, and each is finalized with the machine as its parent.
  pools =
    let
      option = machineEval.options.caisson.caisson-microvm.configurations or null;
      declared =
        if option == null then { } else option.type.merge option.loc option.definitionsWithLocations;
    in
    builtins.mapAttrs (
      name: child:
      lib.caisson-core.finalizeChild {
        inherit name;
        parent = machine;
        what = "`caisson.caisson-microvm.configurations.${name}` of the machine of this home";
      } child
    ) declared;

  # Every slot of the machine, by the name of its guest.
  machineSlots =
    if machine == null then
      { }
    else
      lib.foldl' (acc: pool: acc // pool.outputs.slots) { } (builtins.attrValues pools);

  # The guests the machine lets the user of this home start and stop.
  operated =
    if machine == null then
      [ ]
    else
      (machineEval.config.caisson.microvm-host.operators or { }).${config.home.username} or [ ];

  slots = lib.filterAttrs (name: _: builtins.elem name operated) machineSlots;

  kinds = lib.groupBy (name: slots.${name}.kind) (
    lib.sort (a: b: slots.${a}.index < slots.${b}.index) (builtins.attrNames slots)
  );

  kindNames = lib.concatStringsSep ", " (builtins.attrNames kinds);

  enabled = slots != { };

  stateDir = "${config.xdg.stateHome}/ch-ai-workbench/microvm";

  # The systemctl of the machine, which talks to the machine's systemd.
  systemctl =
    if machine == null then
      lib.getExe' pkgs.systemd "systemctl"
    else
      lib.getExe' machineEval.config.systemd.package "systemctl";

  # What the program reads: the slots, where the leases live, and the
  # programs it runs.
  programConfig = pkgs.writeText "microvm-slots.json" (
    builtins.toJSON {
      slots = builtins.mapAttrs (_: slot: {
        inherit (slot)
          kind
          index
          cid
          vsockPort
          ;
        shares = map (share: {
          inherit (share) tag source mountPoint;
          readOnly = share.readOnly or false;
        }) slot.shares;
      }) slots;
      inherit stateDir systemctl;
      socat = lib.getExe pkgs.socat;
      inherit (cfg) upTimeout;
    }
  );

  # The program with the configuration baked in. `verbs` lists the
  # verbs it accepts; null accepts every verb.
  wrapped =
    name: verbs:
    pkgs.runCommand name
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
        meta.mainProgram = "microvm";
      }
      ''
        makeWrapper ${lib.getExe cfg.programPackage} "$out/bin/microvm" \
          --set MICROVM_CONFIG ${programConfig} ${
            lib.optionalString (verbs != null) "--set MICROVM_VERBS ${lib.concatStringsSep "," verbs}"
          }
      '';

  # The command of the home: every verb, `reap` and `connect` included.
  command = wrapped "microvm" null;

  # What a sandboxed session runs through the trusted executable.
  agentCommand = wrapped "microvm-agent" [
    "up"
    "status"
    "down"
  ];

  # What the program may not do. It talks to the system bus, reads
  # /proc/<pid>/stat of the calling session, connects to vsock ports
  # and writes its state directory, and nothing more.
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
    RestrictAddressFamilies = "AF_UNIX AF_VSOCK";
    UMask = "0077";
  };

  kindLines = lib.concatMapStringsSep "\n" (
    kind:
    let
      names = kinds.${kind};
      first = slots.${builtins.head names};
    in
    "- `${kind}`: ${toString (builtins.length names)} slots (${lib.concatStringsSep ", " names})"
    + lib.optionalString (first.vsockPort != null) ", serving on vsock port ${toString first.vsockPort}"
    + lib.optionalString (first.shares != [ ]) (
      ", sharing "
      + lib.concatMapStringsSep " and " (
        share: "`${share.mountPoint}` (${if share.readOnly or false then "read-only" else "writable"})"
      ) first.shares
      + " in the guest"
    )
    + "."
  ) (builtins.attrNames kinds);

  skill = pkgs.writeTextDir "SKILL.md" ''
    ---
    description: Bring up and stop the microvm guests this machine runs for Claude Code sessions (kinds ${kindNames}). Use before using a tool that runs in a guest, when such a tool reports that its guest is not running, and at the end of the task that used a guest.
    ---

    # microvm guests

    This machine runs virtual machines, called guests, for tools that
    must not run on the host, for example because they parse untrusted
    input. A guest kind is a pool of slots: identical guests, each with
    its own vsock address and its own share directories. A session
    leases a slot, and the slot stays leased to that session until the
    session stops it or ends.

    The kinds of this machine:

    ${kindLines}

    The `microvm` command controls the slots. It is on PATH in a
    checkout that chose the `microvm` sandbox module. When `microvm` is
    not found, ask for that module with the `request-module` tool of the
    sandbox plugin, and give the reason.

    - `microvm up KIND` leases a free slot of KIND to this session,
      starts it, waits until it answers, and prints the slot, its vsock
      CID and port, and its share directories on the host. When this
      session already holds a slot of KIND, it prints that slot again.
    - `microvm status` shows the slots this session holds: whether each
      is running, whether it answers, and how long it has run. It also
      shows the kinds and how many of their slots are free.
      `microvm status --all` shows every slot and the session that
      holds it.
    - `microvm down` stops every slot this session holds.
      `microvm down SLOT` stops one. A slot that another running
      session holds is refused.

    Bring a guest up before using a tool that runs in it, and run
    `microvm down` when the task that needed it is done. A guest takes
    memory from the machine, and the pool of each kind is small. A slot
    is also stopped when the session ends, when the process of its
    session is gone (checked every minute), and when it reaches the run
    time its kind allows.

    Leases are per session. This session may not use or stop a slot
    that another session holds, even when that slot runs a tool this
    session needs. When every slot of a kind is held, wait or tell the
    user.
  '';

  sessionEndHook = pkgs.writeShellApplication {
    name = "microvm-session-end-hook";
    runtimeInputs = [ pkgs.jq ];
    text = ''
      # Claude Code passes the ID of the ending session on stdin. The
      # hook runs outside the sandbox, so it runs the program directly.
      # It never fails: the end of a session must not wait on a guest.
      session=$(jq -r '.session_id // empty' 2>/dev/null) || exit 0
      if [ -z "$session" ]; then
        exit 0
      fi
      env -u CLAUDE_PID CLAUDE_CODE_SESSION_ID="$session" ${lib.getExe command} down >&2 || true
    '';
  };

  plugin =
    pkgs.runCommand "microvm-claude-plugin"
      {
        manifest = builtins.toJSON {
          name = "microvm";
          description = "Bring up and stop the microvm guests of this machine for a session";
          version = "0.1.0";
        };
        hooks = builtins.toJSON {
          hooks.SessionEnd = [
            {
              hooks = [
                {
                  type = "command";
                  command = lib.getExe sessionEndHook;
                  timeout = 120;
                }
              ];
            }
          ];
        };
        passAsFile = [
          "manifest"
          "hooks"
        ];
      }
      ''
        mkdir -p "$out/.claude-plugin" "$out/hooks" "$out/skills"
        cp "$manifestPath" "$out/.claude-plugin/plugin.json"
        cp "$hooksPath" "$out/hooks/hooks.json"
        cp -r ${skill} "$out/skills/microvm"
      '';
in
{
  options.ch-ai-workbench.microvm = {
    programPackage = lib.mkOption {
      type = lib.types.package;
      default = workbenchPackage "microvm";
      defaultText = lib.literalExpression "pkgs.ch-ai-workbench.microvm";
      description = ''
        The `microvm` program before the module bakes the slots of this
        home into it.
      '';
    };

    upTimeout = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = ''
        The number of seconds `microvm up` waits for a started guest to
        accept a connection on the vsock port of its kind.
      '';
    };

    slots = lib.mkOption {
      type = lib.types.attrsOf lib.types.raw;
      readOnly = true;
      default = slots;
      defaultText = lib.literalMD "the slots of the machine this home is declared inside that its user operates";
      description = ''
        The slots this home controls, by the name of the guest, each as
        the caisson-microvm configuration records it: `kind`, `index`,
        `cid`, `vsockPort` and `shares`. They are the slots of the
        machine this home is declared inside that
        `caisson.microvm-host.operators` of the machine lists for the
        user of this home.
      '';
    };

    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = command;
      defaultText = lib.literalMD "the `microvm` program with the slots of this home baked in";
      description = ''
        The `microvm` command of this home, with the slots of this home
        baked in, accepting every verb. The home installs it when it has
        slots. An MCP server entry that talks to a guest runs
        `microvm connect <kind>` from it. That command leases a slot of
        the kind to the Claude Code process that started the server,
        brings the slot up as `microvm up` does, and relays its stdin
        and stdout to the vsock port of the slot.
      '';
    };
  };

  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = config.ch-ai-workbench.claude-code-sandbox.enable;
        message = ''
          ch-ai-workbench.microvm: the machine of this home has microvm slots
          (${lib.concatStringsSep ", " (builtins.attrNames slots)}), and sessions reach them
          through a trusted executable of claude-code-sandbox. Enable
          ch-ai-workbench.claude-code-sandbox.
        '';
      }
      {
        assertion = config.ch-ai-workbench.claude-code.enable;
        message = ''
          ch-ai-workbench.microvm: the skill and the SessionEnd hook of the
          microvm guests install through the claude-code module. Enable
          ch-ai-workbench.claude-code.
        '';
      }
    ];

    home.packages = [ command ];

    ch-ai-workbench.claude-code-sandbox = {
      trustedExecutables.microvm = {
        description = "start, inspect and stop the microvm guests of this session (kinds ${kindNames})";
        program = lib.getExe agentCommand;
        workingDirectory = "/";
        passEnv = [
          "CLAUDE_CODE_SESSION_ID"
          "CLAUDE_PID"
        ];
        serviceConfig = hardening;
      };
      modules.microvm = {
        description = "start and stop microvm guests of the kinds ${kindNames} for this session";
        trustedExecutables = [ "microvm" ];
      };
    };

    ch-ai-workbench.claude-code.skills.microvm.source = plugin;

    # The program writes leases here, and the services see the rest of
    # home read-only, so the directory exists before they run.
    systemd.user.tmpfiles.rules = [ "d ${stateDir}/leases 0700 - - -" ];

    systemd.user.timers.ch-ai-workbench-microvm-reap = {
      Unit.Description = "Stop the microvm slots of sessions that are gone";
      Timer = {
        OnCalendar = "minutely";
        AccuracySec = "10s";
      };
      Install.WantedBy = [ "timers.target" ];
    };

    systemd.user.services.ch-ai-workbench-microvm-reap = {
      Unit.Description = "Stop the microvm slots of sessions that are gone";
      Service = hardening // {
        Type = "oneshot";
        ExecStart = "${lib.getExe command} reap";
      };
    };
  };
}
