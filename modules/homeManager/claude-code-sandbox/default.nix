# SPDX-License-Identifier: MIT
#
# Home-manager half of claude-code-sandbox: declares named sandbox
# *profiles* (toolsets compiled to Claude Code native-sandbox rules),
# emits them as fragments plus a registry under
# $XDG_CONFIG_HOME/claude-code-sandbox/, and deploys the CLI and the
# skills-dir plugin. HM never touches checkouts: freshness converges at
# point of use (the SessionStart hook heals staleness in the session it
# fires in; an unhealed checkout runs its consistent old closure) — no
# enumeration of enrollments exists anywhere, so nothing breaks when
# folders move.
#
# Upstream references — check these when a Claude Code update changes
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
#   per-path `allowRead` from the profile closure makes everything else
#   in the store nonexistent inside sandboxed Bash.
# - `failIfUnavailable = true` is mandatory: without it, sandbox *init*
#   failure silently disables sandboxing for the whole session
#   (fail-open); `allowUnsandboxedCommands = false` does not cover init
#   failure.
# - Rules ride the exec environment: fragments have a hard size ceiling
#   (~128KB single-string). The fragment builder fails the build past a
#   conservative 100KB.
# - The Bash tool follows $SHELL (documented: tools-reference sources
#   rc files "depending on your shell", snapshot at session start), and
#   a login shell resolves through profile-farm store paths whose
#   closure is everything installed — so every masked profile pins
#   env.SHELL to its own bash via the documented env mechanism.
# - The sandbox helper re-enters the claude-code package inside the
#   sandbox; masked profiles therefore need that package's closure
#   readable (`claudePackage`).
# - env.PATH must carry the bubblewrap and socat directories or the
#   sandbox runtime cannot construct sandboxes at all.
#
# This layer's packages (the CLI, its plugin, the Landlock shim) reach
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

  # Everything a fragment needs beyond the declared toolset flows from
  # cfg.runtime.
  #
  # Fragments reference the farm by exact store path: every enrolled
  # checkout runs one consistent closure-generation — the new one after
  # a sync, the previous one until then (kept alive by the prior HM
  # generation). Guard: stable-path indirection here desynchronizes
  # rules and farm in live sessions at switch.
  # The module's own CLI rides every farm: a sandboxed agent can then
  # run `claude-code-sandbox status` to verify its own enrollment (in
  # masked profiles the registry/fragments are unreadable, so status
  # reports freshness as unknown there and stays truthful).
  # An `ssh` that redirects config to the checkout's owned creds copy.
  # Inside the sandbox, ssh rejects the store-symlinked ~/.ssh/config
  # ("Bad owner or permissions": the userns maps its root owner to
  # nobody). The session-start hook writes an owned copy at the
  # ENROLLED-CHECKOUT root: <root>/.claude/claude-code-sandbox/creds/
  # ssh_config, beside the sidecar (.claude/claude-code-sandbox.json).
  # This wrapper points ssh at it with -F, then passes through every
  # argument the sandbox's injected GIT_SSH_COMMAND supplies (the CONNECT
  # ProxyCommand included) — git invokes `ssh` by bare name and PATH
  # resolves it here.
  #
  # Finding the enrolled root: prefer CLAUDE_CODE_SANDBOX_ROOT, which the
  # session-start apply writes into the checkout's settings env — the
  # only channel that reaches a Bash command cwd-independently (hooks
  # can't inject env; CLAUDE_PROJECT_DIR is hook-only). This is
  # authoritative: it names the checkout the session is enrolled in,
  # regardless of where the command's cwd has wandered. Fallback (an
  # un-applied checkout, or a stale session predating this key): walk up
  # from $PWD to the sidecar — correct whenever cwd is inside the
  # checkout, which is NOT `git rev-parse --show-toplevel` (that gives
  # the SUBMODULE root in the multi-repo case, but the creds live at the
  # OUTER enrolled root beside the sidecar). Outside the sandbox, or with
  # no root/copy, it falls through to real ssh unchanged — inert there.
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

  profileFarm =
    name: profile:
    pkgs.buildEnv {
      name = "ccs-profile-${name}";
      paths = profile.toolset ++ cfg.runtime.basePackages ++ [ cfg.package ];
    };

  runtimeShell = "${cfg.runtime.shellPackage}${cfg.runtime.shellPackage.shellPath}";

  landlockShim = workbenchPackage "landlock-shim";

  # A profile with a socket allowlist gets its SHELL pinned to this
  # wrapper, which narrows connect() back to the declared sockets with
  # Landlock before exec'ing the profile bash: upstream's Linux seccomp
  # filter is all-or-nothing, so the fragment opens it
  # (allowAllUnixSockets) and this layer re-narrows. That is a real
  # reach barrier (it bounds which host services sandboxed code can
  # talk to). Strictly narrowing, upstream enforcement untouched, ABI-
  # gated so older kernels degrade to upstream's enforcement instead of
  # breaking. Retirable if upstream grows path-scoped Linux support
  # (anthropics/claude-code#44180).
  #
  # The narrowing applies only in sandbox context, detected by the
  # SANDBOX_RUNTIME marker the sandbox sets for every sandboxed command:
  # the same SHELL also reaches unsandboxed and excludedCommands runs,
  # which must keep escaping. Misdetection therefore fails open into
  # exactly the state the fragment already declares upstream — never
  # into breaking an escape hatch.
  #
  # Execve confinement was tried and removed: it could not be a real
  # boundary while the checkout and scratch dirs are both writable and
  # executable (an agent copies a readable file in and runs it), and
  # no_new_privs already neutralizes setuid. The barriers that hold are
  # network isolation, read-confinement, and write-confinement.
  shimShell =
    name: sockets:
    pkgs.writeShellScript "ccs-shell-${name}" ''
      if [ -n "''${SANDBOX_RUNTIME:-}" ]; then
        exec ${landlockShim}/bin/landlock-shim ${
          lib.concatMapStringsSep " " (s: "--allow ${lib.escapeShellArg s}") sockets
        } \
          --socket-fallback ${cfg.runtime.landlock.socketFallback} \
          -- ${runtimeShell} "$@"
      fi
      exec ${runtimeShell} "$@"
    '';

  fragmentDrv =
    name: profile:
    let
      farm = profileFarm name profile;
      # allowNix auto-grants the daemon socket; that promotion is the
      # one place a null option can become non-null in the fragment.
      effectiveUnixSockets =
        let
          auto = lib.optional profile.allowNix "/nix/var/nix/daemon-socket/socket";
        in
        if profile.allowUnixSockets == null && auto == [ ] then
          null
        else
          (if profile.allowUnixSockets == null then [ ] else profile.allowUnixSockets) ++ auto;
      # allowNix also needs the client-side fetcher cache writable: nix
      # (the client, inside the sandbox) writes $XDG_CACHE_HOME/nix even
      # though the daemon builds outside it. Without this a sandboxed
      # `nix build`/flake fetch fails opening fetcher-cache-v*.sqlite.
      effectiveAllowWrite =
        let
          auto = lib.optional profile.allowNix "${config.xdg.cacheHome}/nix";
        in
        if profile.allowWrite == null && auto == [ ] then
          null
        else
          (if profile.allowWrite == null then [ ] else profile.allowWrite) ++ auto;
      # A non-empty allowlist (without an explicit allow-all) is what
      # the shim narrows sockets to, and what makes the fragment open
      # upstream's filter; an explicit allowAllUnixSockets is carried
      # verbatim, wins, and gets no socket narrowing.
      narrowsSockets =
        profile.allowAllUnixSockets != true && effectiveUnixSockets != null && effectiveUnixSockets != [ ];
      effectiveAllowAll = if narrowsSockets then true else profile.allowAllUnixSockets;
      # Only a socket-narrowing profile needs the shim wrapper; others
      # run the profile bash directly.
      profileShell = if narrowsSockets then "${shimShell name effectiveUnixSockets}" else runtimeShell;
      closureFile = pkgs.writeClosure (
        [
          farm
          sshWrapper
          cfg.runtime.claudePackage
          cfg.runtime.shellPackage
        ]
        ++ lib.optional narrowsSockets (shimShell name effectiveUnixSockets)
        ++ cfg.runtime.sandboxTools
      );
      spec = builtins.toJSON {
        masked = !profile.allowNix;
        extraAllowRead = profile.extraAllowRead;
        allowWrite = effectiveAllowWrite;
        allowedDomains = profile.allowedDomains;
        deniedDomains = profile.deniedDomains;
        excludedCommands = profile.excludedCommands;
        allowUnixSockets = effectiveUnixSockets;
        allowAllUnixSockets = effectiveAllowAll;
        # The ssh wrapper's bin goes first so its `ssh` is found ahead of
        # the farm's openssh — an ordinary PATH precedence, not a
        # buildEnv override; a user who fronts their own ssh knows what
        # they are doing.
        path = lib.concatStringsSep ":" (
          [
            "${sshWrapper}/bin"
            "${farm}/bin"
          ]
          ++ map (p: "${p}/bin") cfg.runtime.sandboxTools
        );
        shell = "${profileShell}";
        extraEnv = profile.extraEnv;
        extraSettings = profile.extraSettings;
      };
    in
    pkgs.runCommand "ccs-fragment-${name}.json"
      {
        nativeBuildInputs = [ pkgs.python3 ];
        inherit closureFile;
        passAsFile = [ "spec" ];
        inherit spec;
      }
      ''
        python3 - "$specPath" "$closureFile" > "$out" <<'EOF'
        import json, sys

        spec = json.load(open(sys.argv[1]))
        closure = sorted(
            line for line in open(sys.argv[2]).read().splitlines() if line
        )

        # extraSettings/extraEnv transport keys this module does NOT
        # generate; the generated keys carry the module's guarantees
        # (fail-closed posture, the mask, the farm PATH/SHELL) and may
        # not be silently overridden through the escape hatch. Wanting a
        # different value for one of these is a profile-option request,
        # not a passthrough.
        OWNED = [
            ("extraSettings", ["sandbox", "enabled"]),
            ("extraSettings", ["sandbox", "failIfUnavailable"]),
            ("extraSettings", ["sandbox", "allowUnsandboxedCommands"]),
            ("extraSettings", ["sandbox", "excludedCommands"]),
            ("extraSettings", ["sandbox", "filesystem"]),
            ("extraSettings", ["sandbox", "network"]),
            ("extraSettings", ["env"]),
            ("extraEnv", ["PATH"]),
            ("extraEnv", ["SHELL"]),
        ]
        def present(tree, path):
            for part in path:
                if not isinstance(tree, dict) or part not in tree:
                    return False
                tree = tree[part]
            return True
        collisions = [
            f"{src}.{'.'.join(path)}"
            for src, path in OWNED
            if present(spec[src], path)
        ]
        if collisions:
            sys.exit(
                "claude-code-sandbox: profile escape hatches may not override "
                "generator-owned keys: " + ", ".join(collisions)
            )

        def deep_update(dst, src):
            for k, v in src.items():
                if isinstance(v, dict) and isinstance(dst.get(k), dict):
                    deep_update(dst[k], v)
                else:
                    dst[k] = v

        # Uniform decode: spec fields are null when the option was not
        # set; null = omit from the fragment, anything else (including
        # empty) is carried verbatim.
        fragment = {
            "sandbox": {
                "enabled": True,
                "failIfUnavailable": True,
                "allowUnsandboxedCommands": False,
            },
            "env": {
                "PATH": spec["path"],
                "SHELL": spec["shell"],
                **(spec["extraEnv"] or {}),
            },
        }
        fs = {}
        if spec["masked"]:
            fs["denyRead"] = ["/nix/store"]
            fs["allowRead"] = closure + (spec["extraAllowRead"] or [])
        elif spec["extraAllowRead"] is not None:
            fs["allowRead"] = spec["extraAllowRead"]
        if spec["allowWrite"] is not None:
            fs["allowWrite"] = spec["allowWrite"]
        if fs:
            fragment["sandbox"]["filesystem"] = fs

        net = {}
        for key in ("allowedDomains", "deniedDomains", "allowUnixSockets",
                    "allowAllUnixSockets"):
            if spec[key] is not None:
                net[key] = spec[key]
        if net:
            fragment["sandbox"]["network"] = net

        if spec["excludedCommands"] is not None:
            fragment["sandbox"]["excludedCommands"] = spec["excludedCommands"]

        deep_update(fragment, spec["extraSettings"] or {})

        out = json.dumps(fragment, indent=2)
        limit = 100_000
        if len(out) > limit:
            sys.exit(
                f"fragment is {len(out)} bytes (> {limit}): the sandbox rules "
                "ride the exec environment and hit E2BIG around 128KB — trim "
                "the profile toolset"
            )
        print(out)
        EOF
      '';

  noneFragment = pkgs.writeText "ccs-fragment-none.json" ''
    {}
  '';

  fragmentXdgPath = name: "claude-code-sandbox/profiles/${name}.json";
  fragmentAbsPath = name: "${config.xdg.configHome}/${fragmentXdgPath name}";

  allFragments = lib.mapAttrs fragmentDrv cfg.profiles // {
    none = noneFragment;
  };

  registry = pkgs.writeText "ccs-registry.json" (
    builtins.toJSON {
      profiles = lib.mapAttrs (name: _: fragmentAbsPath name) allFragments;
      # source→target for the session-start hook to materialize as owned
      # copies under the checkout's creds dir. source null = create an
      # empty 0600 drop point for a runtime provisioner.
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

  profileModule = lib.types.submodule {
    options = {
      toolset = lib.mkOption {
        type = lib.types.listOf lib.types.package;
        default = [ ];
        description = ''
          Packages whose closure is the profile's executable world. The
          implicit basics (bash, coreutils, cacert) are always included.
        '';
      };
      allowNix = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = ''
          Full-nix posture: leave the store unmasked so `nix` works.
          Mutually exclusive with the closure restriction by nature —
          an unmasked store makes every installed tool reachable.
        '';
      };
      # Uniform missing-ness convention for every optional field below:
      # null (the default) = absent from the fragment entirely; any
      # non-null value, including [] or {}, = the fragment carries
      # exactly what you set, and the key joins the tool-managed merge
      # domain.
      extraAllowRead = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = "Additional allowRead paths merged into the fragment.";
      };
      allowWrite = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Paths writable beyond the sandbox default (cwd + session tmp).
          Writes into PATH-bearing or shell-config directories are code
          execution in other contexts — scope narrowly.
        '';
      };
      allowedDomains = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Network domain allowlist for sandboxed commands. [] is a real
          policy (deny all domains); null leaves network rules to lower
          settings scopes.
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
          a hole in the profile; prefer widening the profile instead.
        '';
      };
      allowUnixSockets = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Unix socket paths reachable from sandboxed commands. A socket
          is often a capability grant (docker.sock is host access) —
          scope carefully. allowNix adds the nix daemon socket
          automatically.

          Upstream enforces this list on macOS only; on Linux its
          seccomp filter is all-or-nothing. A non-empty list therefore
          makes the generator open the upstream filter
          (allowAllUnixSockets) and pin the profile's SHELL to a
          Landlock wrapper that narrows connect() back to exactly these
          paths (kernel Landlock ABI 9+, i.e. 7.1+; older kernels fail
          closed). Sockets a sandboxed command creates itself are
          always reachable.
        '';
      };
      allowAllUnixSockets = lib.mkOption {
        type = lib.types.nullOr lib.types.bool;
        default = null;
        description = ''
          Plainly allow every unix socket on the host (upstream's
          boolean; no Landlock narrowing). This is a large capability
          grant — prefer allowUnixSockets. Takes precedence over the
          list when both are set.
        '';
      };
      extraEnv = lib.mkOption {
        type = lib.types.nullOr (lib.types.attrsOf lib.types.str);
        default = null;
        description = "Extra env vars carried by the fragment.";
      };
      extraSettings = lib.mkOption {
        type = lib.types.nullOr lib.types.attrs;
        default = null;
        description = ''
          Deep-merged into the generated fragment: freeform passthrough
          (RFC-42 style) for settings keys this module does not
          generate, e.g. autoAllowBashIfSandboxed. Claude Code's own
          loader validates the keys. Generator-owned keys (the
          fail-closed posture, the mask, env.PATH/SHELL) may not be
          overridden here — the fragment build fails on collision.
        '';
      };
    };
  };
in
{
  options.ch-ai-workbench.claude-code-sandbox = {
    enable = lib.mkEnableOption "nix-declared Claude Code sandbox profiles";

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

    # Everything a profile needs beyond its declared toolset lives here,
    # in one visible surface. These are not optional conveniences: the
    # spike showed each one's absence breaks sandboxed sessions outright.
    runtime = {
      claudePackage = lib.mkOption {
        type = lib.types.package;
        description = ''
          The claude-code package this machine actually runs (no
          default: only the config wiring claude into the profile knows
          it). Its closure is in every masked profile's allowRead — the
          sandbox helper re-enters it inside the sandbox, and without it
          every sandboxed command fails closed.
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
          On every profile's PATH (and in its closure): the sandbox
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
          The floor added to every profile farm: shell, the GNU basics
          (coreutils, diff/cmp, find/xargs, grep, sed), TLS
          certificates, and the JSON/search tools agent sessions reach
          for regardless of profile. On NixOS even /bin/sh and /etc/ssl
          resolve into the store, so a farm without shell, coreutils
          and cacert is not a Unix. The module's own CLI also rides
          every farm, so sandboxed agents can run
          `claude-code-sandbox status`.
        '';
      };
      shellPackage = lib.mkOption {
        type = lib.types.shellPackage;
        default = pkgs.bashNonInteractive;
        defaultText = lib.literalExpression "pkgs.bashNonInteractive";
        description = ''
          Pinned as env.SHELL in every fragment: the Bash tool follows
          $SHELL, and the sandbox shell must come from the profile's
          own closure. Non-interactive bash keeps the session-start rc
          snapshot free of login-shell config.
        '';
      };
      opensshPackage = lib.mkOption {
        type = lib.types.package;
        default = pkgs.openssh;
        defaultText = lib.literalExpression "pkgs.openssh";
        description = ''
          The real ssh the farm's ssh wrapper execs (with -F pointing at
          the checkout's owned config copy inside the sandbox). Pinned so
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
            What a profile with a unix-socket allowlist does on a kernel
            whose Landlock cannot enforce it (ABI < 9, i.e. before
            7.1 — Ubuntu 24.04 HWE kernels, for instance). "open" warns
            once per command and leaves sockets as the upstream sandbox
            left them (allow-all, which the fragment already declares);
            "closed" refuses to run sandboxed commands there.
          '';
        };
      };
    };

    profiles = lib.mkOption {
      type = lib.types.attrsOf profileModule;
      default = { };
      description = ''
        Named sandbox profiles. `default` always exists (empty until
        augmented — enrolled checkouts bound to it track whatever it
        becomes). `none` is reserved: deliberately empty forever, the
        target of `abandon`.
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
                  root→nobody mapping that makes store-symlinked dotfiles
                  unreadable to tools that strict-check config ownership,
                  e.g. ssh on ~/.ssh/config). null = the hook creates an
                  empty 0600 target instead, a drop point for a runtime
                  provisioner to fill with a delegated credential.
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
        can read them. Point tools at a copy with a profile `extraEnv`
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
    assertions = [
      {
        assertion = !(cfg.profiles ? none);
        message = ''
          claude-code-sandbox: the profile name `none` is reserved (the
          deliberately-empty target of `abandon`); it cannot be defined.
        '';
      }
    ];

    ch-ai-workbench.claude-code-sandbox.profiles.default = { };

    # Built-in: an owned copy of ~/.ssh/config, so sandboxed git-over-ssh
    # works (the store-symlinked original is rejected by ssh's config
    # ownership check under the sandbox userns). The farm's ssh wrapper
    # points -F at the copy. git config is not wired: this fleet has no
    # ~/.gitconfig, and the mechanism is here to extend when one appears.
    ch-ai-workbench.claude-code-sandbox.credentials.ssh-config = {
      source = lib.mkDefault "${config.home.homeDirectory}/.ssh/config";
      target = lib.mkDefault "ssh_config";
    };

    home.packages = [ cfg.package ];

    xdg.configFile = {
      "claude-code-sandbox/registry.json".source = registry;
    }
    // lib.mapAttrs' (
      name: drv: lib.nameValuePair (fragmentXdgPath name) { source = drv; }
    ) allFragments;

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
