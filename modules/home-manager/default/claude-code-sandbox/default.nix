# SPDX-License-Identifier: LGPL-3.0-or-later
#
# Home-manager half of claude-code-sandbox: declares named sandbox
# *profiles* (toolsets compiled to Claude Code native-sandbox rules),
# emits them as fragments plus a registry under
# $XDG_CONFIG_HOME/claude-code-sandbox/, deploys the CLI and the
# skills-dir plugin, and re-syncs enrolled checkouts at every switch.
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
# - Sandboxed commands exec $SHELL, and the login shell resolves through
#   the profile-farm store path (whose closure is everything installed),
#   so every masked profile pins env.SHELL to its own bash instead.
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

  farmStateSubpath = name: ".local/state/claude-code-sandbox/profiles/${name}";
  farmAbsPath = name: "${config.home.homeDirectory}/${farmStateSubpath name}";

  # Every beyond-toolset need flows from cfg.runtime through here — one
  # system, inspectable in the option docs, no hidden splices.
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
      spec = builtins.toJSON {
        masked = !profile.allowNix;
        extraAllowRead = profile.extraAllowRead;
        allowedDomains = profile.allowedDomains;
        path = lib.concatStringsSep ":" (
          [ "${farmAbsPath name}/bin" ] ++ map (p: "${p}/bin") cfg.runtime.sandboxTools
        );
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

        def deep_update(dst, src):
            for k, v in src.items():
                if isinstance(v, dict) and isinstance(dst.get(k), dict):
                    deep_update(dst[k], v)
                else:
                    dst[k] = v

        fragment = {
            "sandbox": {
                "enabled": True,
                "failIfUnavailable": True,
                "allowUnsandboxedCommands": False,
            },
            "env": {"PATH": spec["path"], "SHELL": spec["shell"], **spec["extraEnv"]},
        }
        if spec["masked"]:
            fragment["sandbox"]["filesystem"] = {
                "denyRead": ["/nix/store"],
                "allowRead": closure + spec["extraAllowRead"],
            }
        elif spec["extraAllowRead"]:
            fragment["sandbox"]["filesystem"] = {
                "allowRead": spec["extraAllowRead"]
            }
        if spec["allowedDomains"] is not None:
            fragment["sandbox"]["network"] = {
                "allowedDomains": spec["allowedDomains"]
            }
        deep_update(fragment, spec["extraSettings"])

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
      scanRoots = cfg.scanRoots;
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
      extraAllowRead = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        description = "Additional allowRead paths merged into the fragment.";
      };
      allowedDomains = lib.mkOption {
        type = lib.types.nullOr (lib.types.listOf lib.types.str);
        default = null;
        description = ''
          Network domain allowlist for sandboxed commands; null leaves
          network rules to lower settings scopes.
        '';
      };
      extraEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        description = "Extra env vars carried by the fragment.";
      };
      extraSettings = lib.mkOption {
        type = lib.types.attrs;
        default = { };
        description = ''
          Deep-merged into the generated fragment last; escape hatch for
          sandbox keys this module has no option for (e.g.
          autoAllowBashIfSandboxed).
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
          pkgs.bashInteractive
          pkgs.coreutils
          pkgs.cacert
        ];
        defaultText = lib.literalExpression "[ pkgs.bashInteractive pkgs.coreutils pkgs.cacert ]";
        description = ''
          The floor added to every profile farm: shell, core utilities,
          TLS certificates. On NixOS even /bin/sh and /etc/ssl resolve
          into the store, so a farm without these is not a Unix.
        '';
      };
      shellPackage = lib.mkOption {
        type = lib.types.shellPackage;
        default = pkgs.bashInteractive;
        defaultText = lib.literalExpression "pkgs.bashInteractive";
        description = ''
          Pinned as env.SHELL in every fragment. The Bash tool execs
          $SHELL, and the login shell resolves through the profile-farm
          store path (whose closure is everything installed), so the
          sandbox shell must be profile-owned instead.
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

    scanRoots = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "~/Projects" ];
      description = "Directories `scan`/`sync --all` walk for enrolled checkouts.";
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

    syncOnSwitch = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Re-apply profiles to enrolled checkouts under the scan roots at
        every switch (converging derived state; advisory, never fails
        the switch).
      '';
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
      lib.mapAttrs' (
        name: profile: lib.nameValuePair (farmStateSubpath name) { source = profileFarm name profile; }
      ) cfg.profiles
      // lib.optionalAttrs cfg.plugin.enable {
        ".claude/skills/claude-code-sandbox".source = cfg.pluginPackage;
      }
      // lib.optionalAttrs cfg.baseline.install {
        ".claude/settings.json".source = pkgs.writeText "claude-settings-baseline.json" (
          builtins.toJSON monotoneBaseline
        );
      };

    home.activation.claudeCodeSandboxSync = lib.mkIf cfg.syncOnSwitch (
      config.lib.dag.entryAfter [ "writeBoundary" ] ''
        ${cfg.package}/bin/claude-code-sandbox sync --all --quiet \
          || verboseEcho "claude-code-sandbox sync --all reported issues (advisory)"
      ''
    );
  };
}
