# SPDX-License-Identifier: MIT
#
# Home-manager half of claude-code-sandbox: declares named sandbox
# *modules* (what one kind of tooling needs inside Claude Code's native
# sandbox), compiles each into a part, emits the parts plus a registry
# under $XDG_CONFIG_HOME/claude-code-sandbox/, and deploys the CLI and
# the skills-dir plugin. A checkout chooses the set of modules its work
# needs; the CLI composes the chosen parts into one settings fragment at
# enroll time, because no evaluation here knows which combinations
# checkouts will choose. HM never touches checkouts: freshness converges
# at point of use (the SessionStart hook heals staleness in the session
# it fires in; an unhealed checkout runs its consistent old closure). No
# enumeration of enrollments exists anywhere, so nothing breaks when
# folders move.
#
# Upstream references; check these when a Claude Code update changes
# sandbox behavior or before emitting new keys:
#
#   https://code.claude.com/docs/en/settings-reference   (canonical key
#     names, nesting, and scopes; every key this module emits was
#     audited against it 2026-08-22, all exact)
#   https://code.claude.com/docs/en/sandboxing           (behavior,
#     platform setup, security notes)
#   https://code.claude.com/docs/en/env-vars             (env-in-settings
#     semantics the fragments lean on: launch-independent, live-applied
#     on save, removals only at next launch, no $VAR expansion)
#
# Design facts this module encodes (spike-verified 2026-08-22):
#
# - The store mask is mount-level: `denyRead ["/nix/store"]` plus exact
#   per-path `allowRead` from the composed closure makes everything else
#   in the store nonexistent inside sandboxed Bash.
# - `failIfUnavailable = true` is mandatory: without it, sandbox *init*
#   failure silently disables sandboxing for the whole session
#   (fail-open); `allowUnsandboxedCommands = false` does not cover init
#   failure. The CLI's composer emits both for every enrollment.
# - Rules are passed through the exec environment: fragments have a hard
#   size ceiling (~128KB single-string). The composer refuses a
#   composition past a conservative 100KB, and each part's build fails
#   if the part alone is past it.
# - The Bash tool follows $SHELL (documented: tools-reference sources
#   rc files "depending on your shell", snapshot at session start), and
#   a login shell resolves through profile-farm store paths whose
#   closure is everything installed, so every enrollment pins env.SHELL
#   to the base part's bash via the documented env mechanism.
# - The sandbox helper re-enters the claude-code package inside the
#   sandbox; masked enrollments therefore need that package's closure
#   readable (`claudePackage`, in the base part).
# - env.PATH must carry the bubblewrap and socat directories or the
#   sandbox runtime cannot construct sandboxes at all.
#
# Trusted executables run outside the sandbox as socket-activated
# systemd user services; a granting module puts a stub on PATH and the
# socket in the allowlist (docs/development/claude-code-sandbox.md,
# "Trusted executables").
#
# This layer's packages (the CLI, its plugin, the Landlock shim, the
# trusted-exec stub and service) reach
# the module through its package overlay, which puts them under
# `pkgs.ch-ai-workbench` in the evaluation: a caisson consumer that
# lists this flake in `projects` applies it by default
# (`ch-ai-workbench/default`), and any other applies `overlays.default`
# to the package set its home evaluates with.
{ ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.claude-code-sandbox;

  # One of this layer's packages, from the evaluation's package set.
  workbenchPackage =
    name:
    pkgs.ch-ai-workbench.${name} or (throw ''
      ch-ai-workbench.claude-code-sandbox needs pkgs.ch-ai-workbench.${name}:
      apply ch-ai-workbench's package overlay (`overlays.default`; a
      caisson consumer lists the flake in `projects`) to the package set
      this home evaluates with.
    '');

  # An `ssh` that redirects config to the checkout's owned creds copy.
  # Inside the sandbox, ssh rejects the store-symlinked ~/.ssh/config
  # ("Bad owner or permissions": the userns maps its root owner to
  # nobody). The session-start hook writes an owned copy at the
  # ENROLLED-CHECKOUT root: <root>/.claude/claude-code-sandbox/creds/
  # ssh_config, beside the sidecar (.claude/claude-code-sandbox.json).
  # This wrapper points ssh at it with -F, then passes through every
  # argument the sandbox's injected GIT_SSH_COMMAND supplies (the CONNECT
  # ProxyCommand included): git invokes `ssh` by bare name and PATH
  # resolves it here.
  #
  # Finding the enrolled root: prefer CLAUDE_CODE_SANDBOX_ROOT, which the
  # CLI writes into the checkout's settings env, the only channel that
  # reaches a Bash command cwd-independently (hooks can't inject env;
  # CLAUDE_PROJECT_DIR is hook-only). This is authoritative: it names the
  # checkout the session is enrolled in, regardless of where the
  # command's cwd has wandered. Fallback (an un-applied checkout, or a
  # stale session predating this key): walk up from $PWD to the sidecar.
  # That is correct whenever cwd is inside the checkout, and it is NOT
  # `git rev-parse --show-toplevel`, which gives the SUBMODULE root in the
  # multi-repo case, while the creds live at the OUTER enrolled root
  # beside the sidecar. Outside the sandbox, or with no root or copy, it
  # falls through to real ssh unchanged, so it is inert there.
  sshWrapper = pkgs.writeShellScriptBin "ssh" ''
    real=${cfg.runtime.opensshPackage}/bin/ssh
    if [ -n "''${SANDBOX_RUNTIME:-}" ]; then
      root=''${CLAUDE_CODE_SANDBOX_ROOT:-}
      if [ -z "$root" ]; then
        d=$PWD
        while [ "$d" != / ]; do
          if [ -f "$d/.claude/claude-code-sandbox.json" ]; then
            root=$d
            break
          fi
          d=$(dirname "$d")
        done
      fi
      cfgfile="$root/.claude/claude-code-sandbox/creds/ssh_config"
      if [ -n "$root" ] && [ -f "$cfgfile" ]; then
        exec "$real" -F "$cfgfile" "$@"
      fi
    fi
    exec "$real" "$@"
  '';

  runtimeShell = "${cfg.runtime.shellPackage}${cfg.runtime.shellPackage.shellPath}";

  landlockShim = workbenchPackage "landlock-shim";

  # The env variable that carries a composed unix-socket allowlist to the
  # socket shell; the CLI's composer writes it (SOCKETS_ENV_VAR there).
  socketsEnvVar = "CLAUDE_CODE_SANDBOX_UNIX_SOCKETS";

  # The SHELL of every enrollment whose chosen modules declare unix
  # sockets. It narrows connect() back to the composed allowlist with
  # Landlock before exec'ing the base bash: upstream's Linux seccomp
  # filter is all-or-nothing, so the fragment opens it
  # (allowAllUnixSockets) and this layer re-narrows. That is a real reach
  # barrier (it bounds which host services sandboxed code can talk to).
  # Strictly narrowing, upstream enforcement untouched, ABI-gated so
  # older kernels degrade to upstream's enforcement instead of breaking.
  # Retirable if upstream adds path-scoped Linux support
  # (anthropics/claude-code#44180).
  #
  # The allowlist arrives one path per line in the settings env, because
  # the set of modules (and so the list) is chosen per checkout after
  # this script is built. The settings files are write-guarded at the
  # sandbox and permission layers, and a Landlock domain only narrows
  # once applied, so a command cannot widen the list for itself or its
  # children. The shim treats an empty list as "no socket narrowing", so
  # an empty variable here refuses to run rather than opening every
  # socket.
  #
  # The narrowing applies only in sandbox context, detected by the
  # SANDBOX_RUNTIME marker the sandbox sets for every sandboxed command:
  # the same SHELL also reaches unsandboxed and excludedCommands runs,
  # which must keep escaping. Misdetection therefore fails open into
  # exactly the state the fragment already declares upstream, and never
  # into breaking an escape hatch.
  socketShell = pkgs.writeShellScript "ccs-socket-shell" ''
    if [ -n "''${SANDBOX_RUNTIME:-}" ]; then
      if [ -z "''${${socketsEnvVar}:-}" ]; then
        echo "claude-code-sandbox: ${socketsEnvVar} is empty, so the unix-socket allowlist cannot be enforced; refusing to run" >&2
        exit 2
      fi
      allow=()
      while IFS= read -r socket; do
        if [ -n "$socket" ]; then
          allow+=(--allow "$socket")
        fi
      done <<<"''$${socketsEnvVar}"
      exec ${landlockShim}/bin/landlock-shim "''${allow[@]}" \
        --socket-fallback ${cfg.runtime.landlock.socketFallback} \
        -- ${runtimeShell} "$@"
    fi
    exec ${runtimeShell} "$@"
  '';

  # The floor of every enrollment: the base farm (basic tools and the CLI
  # itself, so a sandboxed agent can run `claude-code-sandbox status`),
  # the ssh wrapper, the shells, and what the sandbox runtime needs.
  #
  # Parts reference farms by exact store path: every enrolled checkout
  # runs one consistent closure generation (the new one after a sync,
  # the previous one until then, kept alive by the prior HM generation).
  # Stable-path indirection here would desynchronize rules and farms in
  # live sessions at switch.
  baseFarm = pkgs.buildEnv {
    name = "ccs-base";
    paths = cfg.runtime.basePackages ++ [ cfg.package ];
  };

  basePart =
    pkgs.runCommand "ccs-part-base.json"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        closureFile = pkgs.writeClosure (
          [
            baseFarm
            sshWrapper
            socketShell
            cfg.runtime.claudePackage
            cfg.runtime.shellPackage
          ]
          ++ cfg.runtime.sandboxTools
        );
        passAsFile = [ "spec" ];
        spec = builtins.toJSON {
          # The ssh wrapper's bin goes first so its `ssh` is found ahead of
          # any farm's openssh: an ordinary PATH precedence, not a buildEnv
          # override; a user who fronts their own ssh knows what they are
          # doing.
          pathFirst = [ "${sshWrapper}/bin" ];
          pathLast = [ "${baseFarm}/bin" ] ++ map (p: "${p}/bin") cfg.runtime.sandboxTools;
          shell = runtimeShell;
          socketShell = "${socketShell}";
        };
      }
      ''
        python3 - "$specPath" "$closureFile" > "$out" <<'EOF'
        import json, sys

        part = json.load(open(sys.argv[1]))
        part["closure"] = sorted(
            line for line in open(sys.argv[2]).read().splitlines() if line
        )
        print(json.dumps(part, indent=2))
        EOF
      '';

  modulePart =
    name: module:
    let
      # A granted trusted executable puts its stub on PATH and its socket
      # in the allowlist. The socket is what the grant consists of: any
      # program inside the sandbox that can connect to it can speak the
      # protocol, with or without the stub.
      trusted = lib.genAttrs module.trustedExecutables (te: cfg.trustedExecutables.${te});
      stubs = lib.mapAttrsToList trustedStub trusted;
      farm = pkgs.buildEnv {
        name = "ccs-module-${name}";
        paths = module.toolset ++ stubs;
      };
      hasFarm = module.toolset != [ ] || stubs != [ ];
      # allowNix grants the daemon socket and the client-side fetcher
      # cache: nix (the client, inside the sandbox) writes
      # $XDG_CACHE_HOME/nix even though the daemon builds outside it, and
      # without the cache a sandboxed `nix build` or flake fetch fails
      # opening fetcher-cache-v*.sqlite. These promotions are the one
      # place a null option can become non-null in the part.
      withAuto =
        value: auto:
        if value == null && auto == [ ] then null else (if value == null then [ ] else value) ++ auto;
      spec = builtins.toJSON {
        inherit name;
        inherit (module)
          description
          requires
          extraAllowRead
          allowedDomains
          deniedDomains
          excludedCommands
          allowAllUnixSockets
          ;
        masked = !module.allowNix;
        # What the module puts on PATH, for the people and agents that
        # read a module before enabling it (`claude-code-sandbox show`,
        # the agent tools); the builder adds the farm's command names.
        packages = map (p: p.name) module.toolset;
        path = lib.optional hasFarm "${farm}/bin";
        allowWrite = withAuto module.allowWrite (
          lib.optional module.allowNix "${config.xdg.cacheHome}/nix"
        );
        allowUnixSockets = withAuto module.allowUnixSockets (
          lib.optional module.allowNix "/nix/var/nix/daemon-socket/socket"
          ++ map trustedSocket module.trustedExecutables
        );
        trustedExecutables =
          if trusted == { } then
            null
          else
            lib.mapAttrsToList (te: executable: {
              name = te;
              inherit (executable)
                description
                program
                args
                workingDirectory
                passEnv
                ;
              socket = trustedSocket te;
            }) trusted;
        env = module.extraEnv;
        settings = module.extraSettings;
      };
    in
    pkgs.runCommand "ccs-part-${name}.json"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        closureFile = if hasFarm then pkgs.writeClosure [ farm ] else pkgs.writeText "empty" "";
        farmBin = if hasFarm then "${farm}/bin" else "";
        passAsFile = [ "spec" ];
        inherit spec;
      }
      ''
        python3 - "$specPath" "$closureFile" "$farmBin" > "$out" <<'EOF'
        import json, os, sys

        part = json.load(open(sys.argv[1]))
        part["closure"] = sorted(
            line for line in open(sys.argv[2]).read().splitlines() if line
        )
        # Dot entries are wrapper internals (.gh-wrapped), not commands
        # anyone types.
        farm_bin = sys.argv[3]
        part["commands"] = sorted(
            entry for entry in (os.listdir(farm_bin) if os.path.isdir(farm_bin) else [])
            if not entry.startswith(".")
        )

        # extraSettings and extraEnv transport keys the composer does NOT
        # generate. The generated keys carry the module's guarantees (the
        # fail-closed posture, the mask, the farm PATH and SHELL, the
        # checkout root, the socket allowlist) and may not be overridden
        # through the escape hatch. Wanting a different value for one of
        # these is a module-option request, not a passthrough.
        OWNED = [
            ("settings", ["sandbox", "enabled"]),
            ("settings", ["sandbox", "failIfUnavailable"]),
            ("settings", ["sandbox", "allowUnsandboxedCommands"]),
            ("settings", ["sandbox", "excludedCommands"]),
            ("settings", ["sandbox", "filesystem"]),
            ("settings", ["sandbox", "network"]),
            ("settings", ["env"]),
            ("env", ["PATH"]),
            ("env", ["SHELL"]),
            ("env", ["CLAUDE_CODE_SANDBOX_ROOT"]),
            ("env", ["${socketsEnvVar}"]),
        ]
        def present(tree, path):
            for key in path:
                if not isinstance(tree, dict) or key not in tree:
                    return False
                tree = tree[key]
            return True
        collisions = [
            f"{src}.{'.'.join(path)}"
            for src, path in OWNED
            if present(part[src], path)
        ]
        if collisions:
            sys.exit(
                f"claude-code-sandbox: module {part['name']} may not override "
                "generated keys through its escape hatches: " + ", ".join(collisions)
            )

        out = json.dumps(part, indent=2)
        limit = 100_000
        if len(out) > limit:
            sys.exit(
                f"module {part['name']} is {len(out)} bytes (> {limit}) on its "
                "own: the sandbox rules are passed through the exec environment "
                "and hit E2BIG around 128KB; trim its toolset"
            )
        print(out)
        EOF
      '';

  trustedExec = workbenchPackage "trusted-exec";

  # The socket of each trusted executable. Composition writes socket
  # paths into a checkout's settings at enroll time, so the path must be
  # known at evaluation. $XDG_RUNTIME_DIR holds the uid, which a home
  # evaluation does not know, so the sockets live under the state
  # directory instead.
  trustedSocketDir = "${config.xdg.stateHome}/claude-code-sandbox/trusted";
  trustedSocket = name: "${trustedSocketDir}/${name}.sock";
  trustedUnit = name: "ccs-trusted-${name}";

  # The stub a sandboxed command runs as `name`: a compiled wrapper, so
  # a call starts no shell, that runs `trusted-exec call` against the
  # socket with the caller's arguments.
  trustedStub =
    name: executable:
    pkgs.runCommand "ccs-trusted-stub-${name}"
      {
        nativeBuildInputs = [ pkgs.makeBinaryWrapper ];
      }
      ''
        makeWrapper ${lib.getExe trustedExec} "$out/bin/${name}" ${
          lib.escapeShellArgs (
            lib.concatMap
              (flag: [
                "--add-flag"
                flag
              ])
              (
                [
                  "call"
                  "--name"
                  name
                  "--socket"
                  (trustedSocket name)
                ]
                ++ lib.concatMap (var: [
                  "--pass-env"
                  var
                ]) executable.passEnv
                ++ [ "--" ]
              )
          )
        }
      '';

  # One word of a systemd ExecStart line. Single quotes keep the word
  # whole. systemd expands % specifiers and $ variables even inside
  # quotes, so both are doubled. An assertion below rejects words that
  # carry quotes, backslashes or newlines.
  systemdWord = word: "'${lib.replaceStrings [ "%" "$" ] [ "%%" "$$" ] word}'";
  systemdUnsafe =
    word:
    lib.any (c: lib.hasInfix c word) [
      "'"
      "\\"
      "\n"
    ];

  trustedServeCommand =
    executable:
    [
      (lib.getExe trustedExec)
      "serve"
    ]
    ++ lib.optionals (executable.workingDirectory != null) [
      "--cwd"
      executable.workingDirectory
    ]
    ++ lib.concatMap (var: [
      "--pass-env"
      var
    ]) executable.passEnv
    ++ [
      "--"
      executable.program
    ]
    ++ executable.args;

  # The service keys that connect the service to its socket and its
  # program. serviceConfig may not set them.
  trustedOwnedServiceKeys = [
    "ExecStart"
    "StandardInput"
    "StandardOutput"
    "StandardError"
  ];

  partXdgPath = name: "claude-code-sandbox/parts/${name}.json";
  partAbsPath = name: "${config.xdg.configHome}/${partXdgPath name}";
  moduleXdgName = name: "module-${name}";

  registry = pkgs.writeText "ccs-registry.json" (
    builtins.toJSON {
      base = partAbsPath "base";
      modules = lib.mapAttrs (name: _: partAbsPath (moduleXdgName name)) cfg.modules;
      inherit (cfg) baseModules;
      # source and target for the session-start hook to materialize as
      # owned copies under the checkout's creds dir. A null source makes
      # an empty 0600 drop point for a runtime provisioner.
      credentials = lib.mapAttrs (_: c: {
        inherit (c) source target;
      }) cfg.credentials;
    }
  );

  monotoneBaseline = {
    sandbox = {
      enabled = true;
      filesystem.denyWrite = [
        ".claude/settings.json"
        ".claude/settings.local.json"
        ".claude/claude-code-sandbox.json"
      ];
    };
    permissions.deny = [
      "Edit(.claude/settings.json)"
      "Edit(.claude/settings.local.json)"
      "Edit(.claude/claude-code-sandbox.json)"
    ];
  };

  trustedExecutable = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "What the executable does; `claude-code-sandbox show` shows it.";
      };
      program = lib.mkOption {
        type = lib.types.str;
        example = lib.literalExpression ''lib.getExe' pkgs.libnotify "notify-send"'';
        description = "Absolute path of the program the service runs.";
      };
      args = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Arguments every run starts with. The caller's arguments follow
          them, so `args = [ "status" ]` on git still lets a caller add
          options to `git status`.
        '';
      };
      workingDirectory = lib.mkOption {
        type = lib.types.nullOr lib.types.str;
        default = null;
        description = ''
          The directory every run starts in. null runs the program in the
          caller's working directory, which is almost always inside a
          checkout the sandboxed agent can write. A program that reads
          configuration from its working directory (git reads
          `.git/config` and runs hooks) then runs code the agent wrote,
          outside Claude Code's sandbox.
        '';
      };
      passEnv = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Variables the caller may set for the program. The service drops
          every other variable the caller sends, and the stub sends no
          others. A name in both `passEnv` and `environment` takes the
          caller's value when the caller sets it.
        '';
      };
      environment = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = ''
          Variables the service sets for every run (systemd
          `Environment=`). Every other variable comes from the
          environment of the systemd user manager.
        '';
      };
      serviceConfig = lib.mkOption {
        type = lib.types.attrsOf lib.types.anything;
        default = { };
        example = lib.literalExpression ''
          {
            PrivateUsers = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateNetwork = true;
          }
        '';
        description = ''
          What the program may not do. The service runs as the user
          under the systemd user manager, so by default the program has
          everything the user has, which includes everything Claude Code's
          sandbox allows. These systemd `[Service]` settings of the
          per-connection service take access away, merged over
          `NoNewPrivileges = true`. In a user service the settings that
          need file-system namespacing (ProtectSystem, ProtectHome,
          ReadWritePaths, PrivateTmp and the like) only take effect with
          `PrivateUsers = true`. Inside that user namespace, files owned
          by root (store-symlinked dotfiles included) appear owned by
          nobody, and tools that check config ownership, ssh for one,
          reject them. The keys that connect the service to its socket
          (ExecStart and the Standard* streams) may not be set here.
        '';
      };
    };
  };

  # Every list grant below is unioned across the modules a checkout
  # chooses, so a module states only what its own tooling needs. The
  # uniform missing-ness convention: null (the default) contributes
  # nothing; any non-null value, including [] or {}, puts the key in the
  # composed fragment and in the tool-managed merge domain.
  sandboxModule = lib.types.submodule {
    options = {
      description = lib.mkOption {
        type = lib.types.str;
        default = "";
        description = "What using this kind of tooling means; `claude-code-sandbox list` shows it.";
      };
      requires = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Other sandbox modules a checkout gets whenever it chooses this
          one. For example, a `github` module can require `git`.
        '';
      };
      toolset = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = ''
          Packages this module puts on PATH. Their closure joins the
          composed executable world. The runtime's base packages (bash,
          coreutils, cacert and the rest of runtime.basePackages) are in
          every enrollment and need no module.
        '';
      };
      allowNix = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Full-nix posture: leave the store unmasked so `nix` works. A
          checkout that chooses this module loses the closure
          restriction for all its modules, because an unmasked store
          makes every installed tool reachable. PATH still comes from
          the farms, so the module must list `nix` in its toolset.
        '';
      };
      extraAllowRead = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Additional allowRead paths.";
      };
      allowWrite = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Paths writable beyond the sandbox default (cwd + session tmp).
          Writes into PATH-bearing or shell-config directories are code
          execution in other contexts, so scope narrowly.
        '';
      };
      allowedDomains = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Network domains sandboxed commands may reach. Domains union
          across the chosen modules, so an empty list does not deny the
          domains another module allows; it only puts an (empty)
          allowlist in the fragment when no chosen module lists any.
        '';
      };
      deniedDomains = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Network domain denylist for sandboxed commands.";
      };
      excludedCommands = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Commands that run OUTSIDE the sandbox entirely. Each entry is
          a hole in every enrollment that chooses this module; prefer
          widening the toolset instead.
        '';
      };
      allowUnixSockets = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Unix socket paths reachable from sandboxed commands. A socket
          is often a capability grant (docker.sock is host access), so
          scope carefully. allowNix adds the nix daemon socket
          automatically.

          Upstream enforces this list on macOS only; on Linux its
          seccomp filter is all-or-nothing. A non-empty composed list
          therefore makes the composer open the upstream filter
          (allowAllUnixSockets) and pin SHELL to a Landlock wrapper that
          narrows connect() back to exactly the composed paths (kernel
          Landlock ABI 9+, i.e. 7.1+; runtime.landlock.socketFallback
          decides what older kernels do). Sockets a sandboxed command
          creates itself are always reachable.
        '';
      };
      trustedExecutables = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = ''
          Names from `trustedExecutables` that a checkout choosing this
          module may run. Each puts a stub of that name on PATH and the
          executable's socket in the unix-socket allowlist. The program
          runs outside Claude Code's sandbox with the access of the user,
          less what its `serviceConfig` takes away.
        '';
      };
      allowAllUnixSockets = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Plainly allow every unix socket on the host (upstream's
          boolean; no Landlock narrowing). This is a large capability
          grant; prefer allowUnixSockets. `true` in any chosen module
          wins over every module's list. `false` holds only while no
          chosen module lists sockets: a non-empty composed list opens
          the upstream filter and narrows it back with Landlock.
        '';
      };
      extraEnv = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
        default = null;
        description = ''
          Extra env vars carried by the fragment. Two chosen modules
          that set one variable to different values make enrollment
          fail.
        '';
      };
      extraSettings = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = ''
          Deep-merged into the composed fragment: freeform passthrough
          (RFC-42 style) for settings keys this module does not
          generate, e.g. autoAllowBashIfSandboxed. Claude Code's own
          loader validates the keys. Lists union across modules; two
          chosen modules that set one scalar to different values make
          enrollment fail. Generated keys (the fail-closed posture, the
          mask, env) may not be overridden here: the part's build fails
          on collision.
        '';
      };
    };
  };
in
{
  options.ch-ai-workbench.claude-code-sandbox = {
    enable = lib.mkEnableOption "nix-declared Claude Code sandbox modules";

    package = lib.mkOption {
      type = lib.types.package;
      default = workbenchPackage "claude-code-sandbox";
      defaultText = lib.literalExpression "pkgs.ch-ai-workbench.claude-code-sandbox";
      description = "The claude-code-sandbox CLI.";
    };

    pluginPackage = lib.mkOption {
      type = lib.types.package;
      default = workbenchPackage "claude-code-sandbox-plugin";
      defaultText = lib.literalExpression "pkgs.ch-ai-workbench.claude-code-sandbox-plugin";
      description = "The skills-dir plugin (ceremony skill + advisory hooks).";
    };

    # Everything an enrollment needs beyond its chosen modules lives
    # here, in one visible surface. These are not optional conveniences:
    # the spike showed each one's absence breaks sandboxed sessions
    # outright.
    runtime = {
      claudePackage = lib.mkOption {
        type = lib.types.package;
        description = ''
          The claude-code package this machine actually runs (no
          default: only the config wiring claude into the profile knows
          it). Its closure is in every masked enrollment's allowRead:
          the sandbox helper re-enters it inside the sandbox, and
          without it every sandboxed command fails closed.
        '';
      };
      sandboxTools = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [
          pkgs.bubblewrap
          pkgs.socat
        ];
        defaultText = lib.literalExpression "[ pkgs.bubblewrap pkgs.socat ]";
        description = ''
          On every enrollment's PATH (and in its closure): the sandbox
          runtime needs these to construct sandboxes at all.
        '';
      };
      basePackages = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [
          pkgs.bashNonInteractive
          pkgs.coreutils
          pkgs.cacert
          pkgs.diffutils
          pkgs.findutils
          pkgs.gnugrep
          pkgs.gnused
          pkgs.jq
          pkgs.ripgrep
        ];
        defaultText = lib.literalExpression "[ pkgs.bashNonInteractive pkgs.coreutils pkgs.cacert pkgs.diffutils pkgs.findutils pkgs.gnugrep pkgs.gnused pkgs.jq pkgs.ripgrep ]";
        description = ''
          The floor of every enrollment: shell, the GNU basics
          (coreutils, diff/cmp, find/xargs, grep, sed), TLS
          certificates, and the JSON and search tools agent sessions
          reach for whatever modules a checkout chooses. On NixOS even
          /bin/sh and /etc/ssl resolve into the store, so a farm without
          shell, coreutils and cacert is not a Unix. The module's own
          CLI is also in the base farm, so sandboxed agents can run
          `claude-code-sandbox status`.
        '';
      };
      shellPackage = lib.mkOption {
        type = lib.types.shellPackage;
        default = pkgs.bashNonInteractive;
        defaultText = lib.literalExpression "pkgs.bashNonInteractive";
        description = ''
          Pinned as env.SHELL in every enrollment: the Bash tool follows
          $SHELL, and the sandbox shell must come from the composed
          closure. Non-interactive bash keeps the session-start rc
          snapshot free of login-shell config.
        '';
      };
      opensshPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.openssh;
        defaultText = lib.literalExpression "pkgs.openssh";
        description = ''
          The real ssh the ssh wrapper execs (with -F pointing at the
          checkout's owned config copy inside the sandbox). Pinned so
          the wrapper never resolves itself.
        '';
      };
      landlock = {
        socketFallback = lib.mkOption {
          type = lib.types.enum [
            "open"
            "closed"
          ];
          default = "open";
          description = ''
            What an enrollment with a unix-socket allowlist does on a
            kernel whose Landlock cannot enforce it (ABI < 9, i.e. before
            7.1; Ubuntu 24.04 HWE kernels, for instance). "open" warns
            once per command and leaves sockets as the upstream sandbox
            left them (allow-all, which the fragment already declares);
            "closed" refuses to run sandboxed commands there.
          '';
        };
      };
    };

    modules = lib.mkOption {
      type = lib.types.attrsOf sandboxModule;
      default = { };
      example = lib.literalExpression ''
        {
          git = {
            description = "git over https and ssh to GitHub";
            toolset = [ pkgs.git pkgs.openssh ];
            allowedDomains = [ "github.com" "*.github.com" ];
          };
          github = {
            requires = [ "git" ];
            toolset = [ pkgs.gh ];
            allowedDomains = [ "*.githubusercontent.com" ];
          };
          nix = {
            allowNix = true;
            toolset = [ pkgs.nix ];
            allowedDomains = [ "*.nixos.org" ];
          };
        }
      '';
      description = ''
        Named sandbox modules, each saying what one kind of tooling needs
        inside the sandbox. A checkout opts into a set of them with
        `claude-code-sandbox enroll MODULE...`; the CLI composes the set
        (plus baseModules and everything they require) into the
        checkout's sandbox settings.
      '';
    };

    trustedExecutables = lib.mkOption {
      type = lib.types.attrsOf trustedExecutable;
      default = { };
      example = lib.literalExpression ''
        {
          notify-send = {
            description = "desktop notifications through the session bus";
            program = lib.getExe' pkgs.libnotify "notify-send";
            workingDirectory = "/";
            serviceConfig = {
              PrivateUsers = true;
              ProtectSystem = "strict";
              ProtectHome = true;
              PrivateNetwork = true;
            };
          };
        }
      '';
      description = ''
        Programs a sandboxed command can run outside Claude Code's
        sandbox. Each becomes a socket-activated systemd user service:
        a socket at
        `$XDG_STATE_HOME/claude-code-sandbox/trusted/<name>.sock`
        (mode 0600) and one service instance per connection, which runs
        the program and streams its stdin, stdout and stderr, forwarded
        signals and exit status over the connection. The program starts
        with the access of the user, a superset of what Claude Code's
        sandbox allows, and `serviceConfig` locks it down. A sandbox module grants the executable by
        listing its name in its own `trustedExecutables`. A checkout
        choosing that module then gets a stub named `<name>` on PATH
        and the socket in its unix-socket allowlist.

        The caller supplies the arguments after `args`, stdin, the
        working directory when `workingDirectory` is null, and the
        variables in `passEnv`. Everything else comes from the service.
        A trusted program must treat all of those as untrusted input. A
        program whose arguments can name commands to run (subcommands
        that execute, aliases, extensions, `--exec`-style options) gives
        the caller arbitrary code execution with the access the service
        has left.
      '';
    };

    baseModules = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        Modules every enrollment gets in addition to the modules the
        checkout chooses, for grants no checkout should go without.
        An abandoned checkout gets none.
      '';
    };

    credentials = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule (
          { name, ... }:
          {
            options = {
              source = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = ''
                  Absolute path whose *content* the session-start hook
                  copies into the checkout's credentials dir, owned by
                  the invoking user (so it survives the sandbox userns
                  mapping of root to nobody that makes store-symlinked
                  dotfiles unreadable to tools that strict-check config
                  ownership, e.g. ssh on ~/.ssh/config). null = the hook
                  creates an empty 0600 target instead, a drop point for
                  a runtime provisioner to fill with a delegated
                  credential.
                '';
              };
              target = lib.mkOption {
                type = lib.types.str;
                default = name;
                description = "Filename under the credentials dir.";
              };
            };
          }
        )
      );
      default = { };
      description = ''
        Config/credential files the session-start hook materializes as
        user-owned copies under
        <checkout>/.claude/claude-code-sandbox/creds/, so sandboxed tools
        can read them. Point tools at a copy with a module `extraEnv`
        entry or a farm wrapper; the credentials dir path is knowable at
        enroll time. Built-ins wire ssh and git below.
      '';
    };

    baseline = {
      install = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Install the monotone baseline as ~/.claude/settings.json.
          Leave false when user-scope Claude settings are managed
          elsewhere and merge `baseline.settings` there instead.
        '';
      };
      settings = lib.mkOption {
        type = lib.types.attrs;
        readOnly = true;
        default = monotoneBaseline;
        description = ''
          The monotone user-scope content (never-retracted keys only:
          sandbox on, settings write-guard at both the sandbox and
          permissions layers). Arrays merge across scopes and denies are
          irrevocable from below, so only content like this is safe at
          user scope.
        '';
      };
    };

    plugin.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Deploy the skills-dir plugin to ~/.claude/skills/claude-code-sandbox.";
    };

  };

  config = lib.mkIf cfg.enable {
    assertions =
      let
        known = lib.attrNames cfg.modules;
        unknownIn = names: lib.filter (n: !(lib.elem n known)) names;
      in
      [
        {
          assertion = unknownIn cfg.baseModules == [ ];
          message = ''
            claude-code-sandbox: baseModules names undeclared modules:
            ${lib.concatStringsSep ", " (unknownIn cfg.baseModules)}
          '';
        }
      ]
      ++ lib.mapAttrsToList (name: module: {
        assertion = unknownIn module.requires == [ ];
        message = ''
          claude-code-sandbox: module ${name} requires undeclared modules:
          ${lib.concatStringsSep ", " (unknownIn module.requires)}
        '';
      }) cfg.modules
      ++ lib.mapAttrsToList (
        name: module:
        let
          unknown = lib.filter (te: !(cfg.trustedExecutables ? ${te})) module.trustedExecutables;
        in
        {
          assertion = unknown == [ ];
          message = ''
            claude-code-sandbox: module ${name} grants undeclared trusted executables:
            ${lib.concatStringsSep ", " unknown}
          '';
        }
      ) cfg.modules
      ++ lib.concatLists (
        lib.mapAttrsToList (name: executable: [
          {
            # The name becomes a unit name, a command name and a file name.
            assertion = builtins.match "[A-Za-z0-9][A-Za-z0-9._-]*" name != null;
            message = ''
              claude-code-sandbox: trusted executable name ${builtins.toJSON name}
              must be letters, digits, dots, underscores and dashes.
            '';
          }
          {
            # sun_path holds 108 bytes, terminator included.
            assertion = lib.stringLength (trustedSocket name) < 108;
            message = ''
              claude-code-sandbox: the socket path ${trustedSocket name} of trusted
              executable ${name} is too long for a unix socket (107 bytes at most).
            '';
          }
          {
            assertion = lib.hasPrefix "/" executable.program;
            message = ''
              claude-code-sandbox: trusted executable ${name} needs an absolute
              program path, not ${builtins.toJSON executable.program}.
            '';
          }
          {
            assertion = !(lib.any systemdUnsafe (trustedServeCommand executable));
            message = ''
              claude-code-sandbox: trusted executable ${name} has a program, argument,
              directory or variable name containing a quote, a backslash or a
              newline, which its systemd ExecStart line cannot carry.
            '';
          }
          {
            assertion =
              lib.intersectLists trustedOwnedServiceKeys (lib.attrNames executable.serviceConfig) == [ ];
            message = ''
              claude-code-sandbox: trusted executable ${name} sets
              ${lib.concatStringsSep ", " (
                lib.intersectLists trustedOwnedServiceKeys (lib.attrNames executable.serviceConfig)
              )}
              in serviceConfig; those keys connect the service to its socket.
            '';
          }
        ]) cfg.trustedExecutables
      );

    # One socket per trusted executable, and a service template whose
    # instances each serve one connection (Accept=yes), with the
    # connection as stdin.
    systemd.user.sockets = lib.mapAttrs' (
      name: executable:
      lib.nameValuePair (trustedUnit name) {
        Unit.Description = "claude-code-sandbox trusted executable ${name}";
        Socket = {
          ListenStream = trustedSocket name;
          Accept = true;
          SocketMode = "0600";
          DirectoryMode = "0700";
        };
        Install.WantedBy = [ "sockets.target" ];
      }
    ) cfg.trustedExecutables;

    systemd.user.services = lib.mapAttrs' (
      name: executable:
      lib.nameValuePair "${trustedUnit name}@" {
        Unit = {
          Description = "claude-code-sandbox trusted executable ${name} (one call)";
          CollectMode = "inactive-or-failed";
        };
        Service = {
          NoNewPrivileges = true;
        }
        // executable.serviceConfig
        // {
          ExecStart = lib.concatMapStringsSep " " systemdWord (trustedServeCommand executable);
          StandardInput = "socket";
          StandardOutput = "journal";
          StandardError = "journal";
        }
        // lib.optionalAttrs (executable.environment != { }) {
          Environment = lib.mapAttrsToList (
            var: value: "\"${lib.replaceStrings [ "\\" "\"" "%" ] [ "\\\\" "\\\"" "%%" ] "${var}=${value}"}\""
          ) executable.environment;
        };
      }
    ) cfg.trustedExecutables;

    # Built-in: an owned copy of ~/.ssh/config, so sandboxed git-over-ssh
    # works (the store-symlinked original is rejected by ssh's config
    # ownership check under the sandbox userns). The ssh wrapper points
    # -F at the copy. git config is not wired: these machines have no
    # ~/.gitconfig, and the mechanism is here to extend when one appears.
    ch-ai-workbench.claude-code-sandbox.credentials.ssh-config = {
      source = lib.mkDefault "${config.home.homeDirectory}/.ssh/config";
      target = lib.mkDefault "ssh_config";
    };

    home.packages = [ cfg.package ];

    xdg.configFile = {
      "claude-code-sandbox/registry.json".source = registry;
      ${partXdgPath "base"}.source = basePart;
    }
    // lib.mapAttrs' (
      name: module:
      lib.nameValuePair (partXdgPath (moduleXdgName name)) { source = modulePart name module; }
    ) cfg.modules;

    home.file =
      lib.optionalAttrs cfg.plugin.enable {
        ".claude/skills/claude-code-sandbox".source = cfg.pluginPackage;
      }
      // lib.optionalAttrs cfg.baseline.install {
        ".claude/settings.json".source = pkgs.writeText "claude-settings-baseline.json" (
          builtins.toJSON monotoneBaseline
        );
      };

  };
}
