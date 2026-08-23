# SPDX-License-Identifier: LGPL-3.0-or-later
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
{ closure-inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.claude-code-sandbox;
  system = pkgs.stdenv.hostPlatform.system;

  # Everything a fragment needs beyond the declared toolset flows from
  # cfg.runtime.
  #
  # Fragments reference the farm by exact store path: every enrolled
  # checkout runs one consistent closure-generation — the new one after
  # a sync, the previous one until then (kept alive by the prior HM
  # generation). Guard: stable-path indirection here desynchronizes
  # rules and farm in live sessions at switch.
  profileFarm =
    name: profile:
    pkgs.buildEnv {
      name = "ccs-profile-${name}";
      paths = profile.toolset ++ cfg.runtime.basePackages;
    };

  runtimeShell = "${cfg.runtime.shellPackage}${cfg.runtime.shellPackage.shellPath}";

  fragmentDrv =
    name: profile:
    let
      farm = profileFarm name profile;
      closureFile = pkgs.writeClosure (
        [
          farm
          cfg.runtime.claudePackage
          cfg.runtime.shellPackage
        ]
        ++ cfg.runtime.sandboxTools
      );
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
      spec = builtins.toJSON {
        masked = !profile.allowNix;
        extraAllowRead = profile.extraAllowRead;
        allowWrite = profile.allowWrite;
        allowedDomains = profile.allowedDomains;
        deniedDomains = profile.deniedDomains;
        excludedCommands = profile.excludedCommands;
        allowUnixSockets = effectiveUnixSockets;
        path = lib.concatStringsSep ":" ([ "${farm}/bin" ] ++ map (p: "${p}/bin") cfg.runtime.sandboxTools);
        shell = runtimeShell;
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
        for key in ("allowedDomains", "deniedDomains", "allowUnixSockets"):
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
      projects = lib.mapAttrs (_: p: {
        inherit (p) url path;
        profile = p.profile;
      }) cfg.projects;
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
  options.claude-code-sandbox = {
    enable = lib.mkEnableOption "nix-declared Claude Code sandbox profiles";

    package = lib.mkOption {
      type = lib.types.package;
      default = closure-inputs.self.packages.${system}.claude-code-sandbox;
      defaultText = lib.literalExpression "claude-code-sandbox.packages.<system>.claude-code-sandbox";
      description = "The claude-code-sandbox CLI.";
    };

    pluginPackage = lib.mkOption {
      type = lib.types.package;
      default = closure-inputs.self.packages.${system}.claude-code-sandbox-plugin;
      defaultText = lib.literalExpression "claude-code-sandbox.packages.<system>.claude-code-sandbox-plugin";
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
        ];
        defaultText = lib.literalExpression "[ pkgs.bashNonInteractive pkgs.coreutils pkgs.cacert ]";
        description = ''
          The floor added to every profile farm: shell, core utilities,
          TLS certificates. On NixOS even /bin/sh and /etc/ssl resolve
          into the store, so a farm without these is not a Unix.
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

    projects = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            url = lib.mkOption { type = lib.types.str; };
            path = lib.mkOption { type = lib.types.str; };
            profile = lib.mkOption {
              type = lib.types.str;
              default = "default";
            };
          };
        }
      );
      default = { };
      description = "Projects `materialize` may clone + enroll (never at switch).";
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

    claude-code-sandbox.profiles.default = { };

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
