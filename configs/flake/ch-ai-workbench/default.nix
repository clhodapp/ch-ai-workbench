# SPDX-License-Identifier: MIT
{ closure-lib, ... }:
{
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson.modules.homeManager.exported = modules: {
    inherit (modules)
      emacs
      gptel
      claude
      claude-code
      claude-code-sandbox
      emacs-integration
      microvm
      zsh
      ;
  };

  # This layer's packages (the sandbox CLI, its plugin, the Landlock
  # shim and the claude-consent tool) are its `default` package overlay
  # registry entry (pkg-overlays/, registered on mkLib), under
  # pkgs.ch-ai-workbench. The package set applies it by default, beside
  # `ch-emacs-config/default` from the editor project, which brings the
  # editor's Emacs bases and ELPA pins: the checks build this layer's
  # Emacs packages against the Emacs the editor configures, since they
  # load into it. `merman-nix/default` brings pkgs.merman-nix, the
  # headless mermaid renderer the Emacs and Claude integrations spawn.
  # The flake exports its own entry as `pkgOverlays` and as plain
  # `overlays`; the entries of consumed projects are applied, not
  # exported.

  # packages.* is deliberately not partitioned: consumers take these
  # packages against this flake's main lock, so dev-only inputs must
  # not taint them.
  caisson.nixpkgs.packages.export.enabled = true;

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
        perSystem.treefmt.programs.rustfmt = {
          enable = true;
          edition = "2024";
        };
      };
  };

  partitions.checks = {
    extraInputs = (lib.caisson.pins.flake-compat ../../../tests/dependencies).sources;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          let
            merman = inputs.merman-nix.packages.${system}.merman-preview;

            # An Emacs carrying both layers' bundles, built the way the
            # editor builds its own check Emacs: the ERT suites below run
            # `--batch` against the full init, so the packages must be in
            # the init package's closure rather than merely installed
            # into a profile.
            scope = closure-lib.ch-emacs-config.mkEmacsScope {
              inherit pkgs;
              lib = pkgs.lib;
              emacsPackage = pkgs.ch-emacs-config.emacs-pgtk;
              bundles = closure-lib.ch-emacs-config.bundleSpec // workbenchBundles;
              sources = {
                # Through the editor rather than a second input, so both
                # layers build these from one revision. The list mirrors
                # the editor module's own `emacsPackageSources`.
                inherit (inputs.ch-emacs-config.inputs) pr-review ghostel;
              };
              extraOverrides = [
                (workbench.mkEmacsPackageOverrides { inherit (inputs) collab-comments parenting; })
              ];
              localPackageOverlays = workbenchLocalPackages;
            };

            emacs = scope.emacs;

            # This layer's bundle spec and local packages, from its
            # library, so the checks and a real configuration read one
            # definition. Every group at once: the ERT suites below need
            # the whole layer in one Emacs.
            workbench = closure-lib.ch-ai-workbench;
            workbenchBundles = lib.foldl' (acc: group: acc // group) { } (
              lib.attrValues (
                workbench.bundleSpec {
                  inherit lib;
                  merman = inputs.merman-nix.packages.${system}.merman-preview;
                  betterleaks = pkgs.betterleaks;
                }
              )
            );
            workbenchLocalPackages = lib.concatLists (lib.attrValues workbench.localPackageOverlays);

            aiCommitSrc = workbench.emacsPackageSources.ai-commit;
            claudeQueueSrc = workbench.emacsPackageSources.claude-queue;
            semanticFinderSrc = workbench.emacsPackageSources.semantic-finder;
            # The ERT suites that exercise the full init rather than one
            # package: the MCP tools and the collab-comments integration.
            testsSrc = "${self}/tests/emacs";

            mermanMmdcShim = pkgs.writeShellScriptBin "mmdc" ''exec ${lib.getExe merman} mmdc "$@"'';

            # Sandbox modules covering each composition rule the CLI
            # applies to real parts: a closure-masked module, one that
            # requires another, a base module, a unix socket, and one
            # that unmasks the store. Any package stands in for the CLI
            # a host runs: the check composes parts, not a live sandbox.
            sandboxModules = {
              enable = true;
              runtime.claudePackage = pkgs.hello;
              modules = {
                search = {
                  description = "a searcher";
                  toolset = [ pkgs.fd ];
                };
                git = {
                  toolset = [ pkgs.git ];
                  allowedDomains = [ "github.com" ];
                };
                github = {
                  requires = [ "git" ];
                  toolset = [ pkgs.gh ];
                  allowedDomains = [ "*.githubusercontent.com" ];
                };
                agent = {
                  allowedDomains = [ "*.anthropic.com" ];
                  allowUnixSockets = [ "/run/agent.sock" ];
                };
                nix = {
                  allowNix = true;
                  toolset = [ pkgs.hello ];
                };
                forge.trustedExecutables = [ "greet" ];
                # Nodes the Nix build sandbox has: a glob, a symlink
                # (/dev/stdin resolves to /dev/null when stdin is
                # /dev/null), a match that is not a device node, and a
                # path that does not exist.
                devices.devices = [
                  "/dev/zer*"
                  "/dev/stdin"
                  "/dev/shm"
                  "/dev/ccs-absent"
                ];
              };
              baseModules = [ "agent" ];
              # A program whose ExecStart words carry a $ (systemd
              # expands it unless doubled) and a passed variable.
              trustedExecutables.greet = {
                description = "greets";
                program = "${pkgs.bash}/bin/sh";
                args = [
                  "-c"
                  ''echo "$GREETING" "$@"''
                  "sh"
                ];
                passEnv = [ "GREETING" ];
                serviceConfig.PrivateTmp = true;
              };
            };

            sandboxHomeFiles =
              (inputs.home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.modules.homeManager.claude-code-sandbox
                  {
                    home.username = "tester";
                    home.homeDirectory = "/home/tester";
                    home.stateVersion = "25.05";
                    ch-ai-workbench.claude-code-sandbox = sandboxModules;
                  }
                ];
              }).config.home-files;

            # Homes of `tester` that select the microvm module with the
            # given kinds.
            microvmHome =
              kinds:
              (inputs.home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.modules.homeManager.claude-code
                  self.modules.homeManager.claude-code-sandbox
                  self.modules.homeManager.microvm
                  {
                    home.username = "tester";
                    home.homeDirectory = "/home/tester";
                    home.stateVersion = "25.05";
                    ch-ai-workbench.claude-code.enable = true;
                    ch-ai-workbench.microvm.kinds = kinds;
                  }
                ];
              }).config;
            # Two slots of `probe`, which serves MCP and has shares, and
            # one of `quiet`, which serves no MCP and has no shares, both
            # for agents, and one of `hidden`, which has shares and which
            # agents may not use.
            microvmKinds = {
              probe = {
                slots = [
                  {
                    name = "probe-1";
                    cid = 101;
                  }
                  {
                    name = "probe-2";
                    cid = 102;
                  }
                ];
                vsockPort = 5000;
                shareRoot = "/var/lib/probe";
                agents = true;
                mcp.description = "Probes binaries.";
              };
              quiet = {
                slots = [
                  {
                    name = "quiet-1";
                    cid = 201;
                  }
                ];
                agents = true;
              };
              hidden = {
                slots = [
                  {
                    name = "hidden-1";
                    cid = 301;
                  }
                ];
                shareRoot = "/var/lib/hidden";
              };
            };
            microvmFullHome = microvmHome microvmKinds;
            microvmHiddenHome = microvmHome { inherit (microvmKinds) hidden; };
            microvmBareHome = microvmHome { };
            # Homes that fail an assertion of the module: a CID that two
            # kinds give, a slot name that two kinds give, and a kind
            # that serves MCP on no port. home-manager refuses to
            # evaluate a home whose assertions fail.
            microvmRefused =
              kind:
              !(builtins.tryEval (microvmHome ({ inherit (microvmKinds) hidden; } // kind)).home.packages)
              .success;
            microvmClash =
              slot: extra:
              microvmRefused {
                clash = {
                  slots = [ slot ];
                }
                // extra;
              };

            # A home of `tester` whose judge has one endpoint, the stub
            # System One server the tic-check check starts on a fixed
            # port of the build sandbox's own loopback. Its hooks are the
            # packages the module builds from the real tables.
            judgeHooks =
              (inputs.home-manager.lib.homeManagerConfiguration {
                inherit pkgs;
                modules = [
                  self.modules.homeManager.claude-code
                  self.modules.homeManager.claude-code-sandbox
                  {
                    home.username = "tester";
                    home.homeDirectory = "/home/tester";
                    home.stateVersion = "25.05";
                    ch-ai-workbench.claude-code.enable = true;
                    ch-ai-workbench.claude-code.judge.endpoints = {
                      local.url = "http://127.0.0.1:18731";
                      baseten.enable = false;
                    };
                  }
                ];
              }).config.ch-ai-workbench.claude-code.hooks;

            # The hook packages from this layer's library, so the checks
            # below drive the same scripts a real configuration installs.
            claudePushPrCheckHook = workbench.mkClaudePushPrCheckHook { inherit pkgs; };
            claudeRedactHook = workbench.mkClaudeRedactHook { inherit pkgs; };
            claudeRevealHook = workbench.mkClaudeRevealHook {
              inherit pkgs;
              claude-consent = claudeConsent;
            };

            # The prompt API tool (its build runs the unittest suite)
            # and the consent hook built on it, from the same library the
            # modules use.
            claudeConsent = pkgs.ch-ai-workbench.claude-consent;
            emacsClaudeConsentHook = workbench.mkEmacsClaudeConsentHook {
              inherit pkgs;
              claude-consent = claudeConsent;
            };
          in
          {
            checks = {
              # The sandbox's packages: building the CLI runs its
              # unittest suite, the plugin assembles the skills-dir
              # tree, and compiling the shim is its build-time test
              # (Landlock cannot be exercised inside the Nix build
              # sandbox).
              claude-code-sandbox = self.packages.${system}.claude-code-sandbox;
              claude-code-sandbox-plugin = self.packages.${system}.claude-code-sandbox-plugin;
              landlock-shim = self.packages.${system}.landlock-shim;
              # Building the judge client runs its unittest suite against
              # stub System One servers.
              claude-response-judge = self.packages.${system}.claude-response-judge;
              # Building runs the integration tests of call against serve.
              trusted-exec = self.packages.${system}.trusted-exec;
              # Building runs the unittest suite of the microvm program
              # against a fake systemctl, /proc and vsock probe.
              microvm = self.packages.${system}.microvm;

              # The microvm module with kinds from its options. The full
              # home gets the command with the kinds baked in, the reap
              # timer, and the plugin with the MCP server `microvm`, which
              # offers the kinds for agents and no other. The home whose
              # only kind is not for agents gets the command and the
              # timer and no plugin. The home without kinds gets none of
              # it. A CID or a slot name that two kinds give, and a kind
              # that serves MCP on no port, fail an assertion. The full
              # home gets the sandbox module `microvm-probe`, which grants
              # exactly the directories of the slots of `probe`, and no
              # sandbox module for `quiet`, which has no share root, or
              # for `hidden`, which agents may not use.
              microvm-home-module =
                let
                  probeSlotDirs = [
                    "/var/lib/probe/probe-1"
                    "/var/lib/probe/probe-2"
                  ];
                  sandboxModulesOf = home: home.ch-ai-workbench.claude-code-sandbox.modules;
                in
                assert builtins.attrNames (sandboxModulesOf microvmFullHome) == [ "microvm-probe" ];
                assert (sandboxModulesOf microvmFullHome).microvm-probe.allowWrite == probeSlotDirs;
                assert (sandboxModulesOf microvmFullHome).microvm-probe.extraAllowRead == probeSlotDirs;
                assert sandboxModulesOf microvmHiddenHome == { };
                assert sandboxModulesOf microvmBareHome == { };
                assert microvmFullHome.ch-ai-workbench.claude-code.skills ? microvm;
                assert !(microvmHiddenHome.ch-ai-workbench.claude-code.skills ? microvm);
                assert microvmHiddenHome.systemd.user.timers ? ch-ai-workbench-microvm-reap;
                assert builtins.elem microvmHiddenHome.ch-ai-workbench.microvm.package
                  microvmHiddenHome.home.packages;
                assert !(microvmBareHome.ch-ai-workbench.claude-code.skills ? microvm);
                assert !(microvmBareHome.systemd.user.timers ? ch-ai-workbench-microvm-reap);
                assert
                  !(builtins.elem microvmBareHome.ch-ai-workbench.microvm.package microvmBareHome.home.packages);
                # The control: a kind of its own name and CID evaluates.
                assert
                  !microvmClash {
                    name = "clash-1";
                    cid = 302;
                  } { };
                assert microvmClash {
                  name = "clash-1";
                  cid = 301;
                } { };
                assert microvmClash {
                  name = "hidden-1";
                  cid = 302;
                } { };
                assert microvmClash {
                  name = "clash-1";
                  cid = 302;
                } { mcp.description = "Nothing."; };
                pkgs.runCommand "microvm-home-module"
                  {
                    nativeBuildInputs = [ pkgs.jq ];
                    files = microvmFullHome.home-files;
                    command = lib.getExe microvmFullHome.ch-ai-workbench.microvm.package;
                    installed = builtins.elem microvmFullHome.ch-ai-workbench.microvm.package microvmFullHome.home.packages;
                  }
                  ''
                    test "$installed" = 1
                    units=$files/.config/systemd/user

                    # The reap timer and its service, with the access the
                    # module leaves it.
                    grep -qx 'OnCalendar=minutely' "$units/ch-ai-workbench-microvm-reap.timer"
                    service=$units/ch-ai-workbench-microvm-reap.service
                    grep -qx "ExecStart=$command reap" "$service"
                    for line in PrivateUsers=true ProtectSystem=strict ProtectHome=read-only \
                      "ReadWritePaths=/home/tester/.local/state/ch-ai-workbench/microvm" \
                      "RestrictAddressFamilies=AF_UNIX" NoNewPrivileges=true; do
                      grep -qx "$line" "$service"
                    done

                    # The plugin declares the MCP server `microvm` and no
                    # other.
                    manifest=$files/.claude/skills/microvm/.claude-plugin/plugin.json
                    jq -e '.name == "microvm"' "$manifest"
                    jq -e --arg c "$command" '.mcpServers == {microvm: {command: $c, args: ["mcp"]}}' "$manifest"

                    # The command has every kind baked in. No systemd runs
                    # here, so the unit state is unknown.
                    "$command" status --all > status.txt
                    grep -qx 'probe-1  kind probe  free  unknown' status.txt
                    grep -qx 'probe-2  kind probe  free  unknown' status.txt
                    grep -qx 'hidden-1  kind hidden  free  unknown' status.txt
                    grep -qx '  probe: 2 slots, 2 free' status.txt
                    rc=0
                    "$command" up nope 2> err.txt || rc=$?
                    test "$rc" = 2
                    grep -q "^microvm: unknown kind 'nope'" err.txt

                    # The MCP server over stdio offers the kinds for agents
                    # and refuses `hidden`. Its input stays open until the
                    # four answers are out, since it stops at the end of
                    # its input.
                    touch mcp.jsonl
                    {
                      echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
                      echo '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
                      echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"microvm_up","arguments":{"kind":"hidden"}}}'
                      echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"microvm_status","arguments":{"all":true}}}'
                      for _ in $(seq 600); do
                        [ "$(wc -l < mcp.jsonl)" -ge 4 ] && break
                        sleep 0.1
                      done
                    } | "$command" mcp > mcp.jsonl 2> mcp.err
                    jq -s -e 'map(.id) | sort == [1, 2, 3, 4]' mcp.jsonl
                    jq -s -e 'map(select(.id == 1))[0].result.serverInfo.name == "microvm"' mcp.jsonl
                    jq -s -e 'map(select(.id == 2))[0].result.tools | map(.name) == ["microvm_up", "microvm_down", "microvm_status"]' mcp.jsonl
                    jq -s -e 'map(select(.id == 2))[0].result.tools[0].inputSchema.properties.kind.enum == ["probe", "quiet"]' mcp.jsonl
                    jq -s -e 'map(select(.id == 2))[0].result.tools[1].inputSchema.properties.slot.enum == ["probe-1", "probe-2", "quiet-1"]' mcp.jsonl
                    jq -s -e 'map(select(.id == 3))[0].result | .isError and (.content[0].text | test("unknown kind .hidden."))' mcp.jsonl
                    jq -s -e 'map(select(.id == 4))[0].result.content[0].text | test("probe-1  kind probe  free") and (test("hidden") | not)' mcp.jsonl
                    grep -qx 'this session holds no slots' mcp.err
                    touch $out
                  '';

              # The CLI composing the parts the home-manager module
              # builds, end to end: the registry and parts come from a
              # real home's files, with the registry's home paths pointed
              # at that tree.
              claude-code-sandbox-compose =
                pkgs.runCommand "claude-code-sandbox-compose"
                  {
                    nativeBuildInputs = [
                      self.packages.${system}.claude-code-sandbox
                      self.packages.${system}.trusted-exec
                      pkgs.git
                      pkgs.jq
                      pkgs.python3
                    ];
                  }
                  ''
                    export HOME="$TMPDIR"
                    export CLAUDE_CODE_SANDBOX_CONFIG="$TMPDIR/config"
                    mkdir "$CLAUDE_CODE_SANDBOX_CONFIG"
                    sed 's|/home/tester/.config|${sandboxHomeFiles}/.config|g' \
                      ${sandboxHomeFiles}/.config/claude-code-sandbox/registry.json \
                      > "$CLAUDE_CODE_SANDBOX_CONFIG/registry.json"

                    claude-code-sandbox list | tee list.txt
                    grep -qx 'agent (in every enrollment)' list.txt
                    grep -qx 'github (requires git)' list.txt
                    grep -qx 'nix (unmasks the store)' list.txt
                    grep -qx 'search: a searcher' list.txt

                    git init -q repo
                    claude-code-sandbox enroll search github -C repo
                    settings=repo/.claude/settings.local.json
                    jq -e '.sandbox.failIfUnavailable and (.sandbox.allowUnsandboxedCommands | not)' "$settings"
                    jq -e '.sandbox.filesystem.denyRead == ["/nix/store"]' "$settings"
                    for pkg in ${pkgs.fd} ${pkgs.gh} ${pkgs.git} ${pkgs.hello}; do
                      jq -e --arg p "$pkg" '.sandbox.filesystem.allowRead | index($p)' "$settings"
                    done
                    jq -e '.sandbox.network.allowedDomains | sort == ["*.anthropic.com", "*.githubusercontent.com", "github.com"]' "$settings"
                    jq -e '.sandbox.network.allowUnixSockets == ["/run/agent.sock"] and .sandbox.network.allowAllUnixSockets' "$settings"
                    jq -e '.env.CLAUDE_CODE_SANDBOX_UNIX_SOCKETS == "/run/agent.sock"' "$settings"
                    jq -e '.env.CLAUDE_CODE_SANDBOX_DEVICES == ""' "$settings"
                    shell=$(jq -r .env.SHELL "$settings")
                    case "$shell" in *ccs-socket-shell) ;; *) echo "SHELL is $shell"; exit 1 ;; esac
                    for cmd in fd gh git ssh claude-code-sandbox bwrap; do
                      PATH=$(jq -r .env.PATH "$settings") command -v "$cmd"
                    done
                    claude-code-sandbox status -C repo

                    # The socket shell refuses an empty allowlist inside a
                    # sandbox and runs commands plainly outside one.
                    if SANDBOX_RUNTIME=1 ${pkgs.coreutils}/bin/env -u CLAUDE_CODE_SANDBOX_UNIX_SOCKETS "$shell" -c true; then
                      echo "the socket shell ran without an allowlist"; exit 1
                    fi
                    test "$("$shell" -c 'echo outside')" = outside

                    claude-code-sandbox add nix -C repo
                    jq -e '.sandbox.filesystem | has("denyRead") | not' "$settings"
                    jq -e '.sandbox.filesystem.allowWrite == ["/home/tester/.cache/nix"]' "$settings"
                    jq -e '.sandbox.network.allowUnixSockets | sort == ["/nix/var/nix/daemon-socket/socket", "/run/agent.sock"]' "$settings"

                    claude-code-sandbox drop nix github -C repo
                    jq -e '.sandbox.network.allowedDomains == ["*.anthropic.com"]' "$settings"
                    claude-code-sandbox status -C repo

                    # What a module allows, read from the parts the
                    # module builds, and a recorded refusal.
                    claude-code-sandbox show github -C repo | tee show.txt
                    grep -qx 'Commands put on PATH: gh' show.txt
                    grep -qx 'From packages: ${pkgs.gh.name}' show.txt
                    grep -qx 'Enabling it also enables: git' show.txt
                    claude-code-sandbox decline nix --reason 'no store here' -C repo
                    claude-code-sandbox status -C repo | grep -q 'declined \[nix\]'

                    # A device list, and the bwrap wrapper applying it. A
                    # bwrap that prints its arguments stands in for the
                    # real one after the wrapper on PATH.
                    git init -q repo3
                    claude-code-sandbox enroll devices -C repo3
                    settings3=repo3/.claude/settings.local.json
                    devices=$(jq -r .env.CLAUDE_CODE_SANDBOX_DEVICES "$settings3")
                    test "$devices" = "$(printf '%s\n' '/dev/zer*' /dev/stdin /dev/shm /dev/ccs-absent)"
                    claude-code-sandbox show devices -C repo3 \
                      | grep -qx 'Device nodes openable: /dev/zer\*, /dev/stdin, /dev/shm, /dev/ccs-absent'
                    wrapper=$(PATH=$(jq -r .env.PATH "$settings3") command -v bwrap)
                    case "$wrapper" in *-bubblewrap-*) echo "PATH finds $wrapper first"; exit 1 ;; esac
                    mkdir recorder
                    printf '#!${pkgs.bash}/bin/sh\nprintf "%%s\\n" "$@"\n' > recorder/bwrap
                    chmod +x recorder/bwrap
                    wrap() {
                      CLAUDE_CODE_SANDBOX_DEVICES=$1 PATH="''${wrapper%/*}:$PWD/recorder" "$wrapper" "''${@:2}" < /dev/null
                    }
                    wrap "$devices" --ro-bind / / --dev /dev --unshare-pid -- sh -c 'echo --dev /dev' \
                      > argv.txt 2> wrapper.err
                    printf '%s\n' --ro-bind / / --dev /dev \
                      --dev-bind-try /dev/zero /dev/zero --dev-bind-try /dev/null /dev/null \
                      --unshare-pid -- sh -c 'echo --dev /dev' > want.txt
                    diff want.txt argv.txt
                    grep -q '/dev/shm .*is not a device node' wrapper.err
                    if grep -q ccs-absent wrapper.err; then
                      echo "the wrapper warned about a path that does not exist"; exit 1
                    fi
                    test "$(wrap "$devices" --version)" = --version
                    test "$(wrap "" --dev /dev true)" = "$(printf '%s\n' --dev /dev true)"
                    if wrap /etc/passwd --dev /dev true; then
                      echo "the wrapper bound a path outside /dev"; exit 1
                    fi

                    # The agent tools over stdio against the same registry.
                    # The declined module is reported without a prompt.
                    {
                      echo '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{}}}'
                      echo '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"list-modules","arguments":{}}}'
                      echo '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"request-module","arguments":{"module":"nix","reason":"build"}}}'
                      echo '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"describe-module","arguments":{"module":"search"}}}'
                    } | CLAUDE_PROJECT_DIR="$PWD/repo" claude-code-sandbox mcp > mcp.jsonl
                    jq -s -e 'map(.id) == [1, 2, 3, 4]' mcp.jsonl
                    jq -s -e '.[1].result.content[0].text | fromjson | .modules | map({(.name): .status}) | add
                      == {agent: "enabled (base)", devices: "available", forge: "available", git: "available", github: "available", nix: "declined", search: "enabled"}' mcp.jsonl
                    jq -s -e '.[2].result.content[0].text | test("declined nix .*no store here")' mcp.jsonl
                    jq -s -e '.[3].result.content[0].text | fromjson | .commands == ["fd"]' mcp.jsonl

                    # The plugin starts that server with both tools pinned.
                    manifest=${self.packages.${system}.claude-code-sandbox-plugin}/.claude-plugin/plugin.json
                    test -x "$(jq -r .mcpServers.sandbox.command "$manifest")"
                    test -x "$(jq -r .mcpServers.sandbox.env.CLAUDE_CODE_SANDBOX_CONSENT "$manifest")"

                    # A trusted executable: its socket and per-connection
                    # service, the grant composed into a checkout, the
                    # stub dialling the declared socket, and the service
                    # command of the unit serving a call.
                    sock=/home/tester/.local/state/claude-code-sandbox/trusted/greet.sock
                    units=${sandboxHomeFiles}/.config/systemd/user
                    grep -qx "ListenStream=$sock" "$units/ccs-trusted-greet.socket"
                    grep -qx 'Accept=true' "$units/ccs-trusted-greet.socket"
                    grep -qx 'SocketMode=0600' "$units/ccs-trusted-greet.socket"
                    grep -qx 'StandardInput=socket' "$units/ccs-trusted-greet@.service"
                    grep -qx 'NoNewPrivileges=true' "$units/ccs-trusted-greet@.service"
                    grep -qx 'PrivateTmp=true' "$units/ccs-trusted-greet@.service"
                    exec_start=$(sed -n 's/^ExecStart=//p' "$units/ccs-trusted-greet@.service")

                    git init -q repo2
                    claude-code-sandbox enroll forge -C repo2
                    settings2=repo2/.claude/settings.local.json
                    jq -e --arg s "$sock" '.sandbox.network.allowUnixSockets | index($s)' "$settings2"
                    jq -e --arg s "$sock" '.env.CLAUDE_CODE_SANDBOX_UNIX_SOCKETS | split("\n") | index($s)' "$settings2"
                    stub=$(PATH=$(jq -r .env.PATH "$settings2") command -v greet)
                    rc=0
                    "$stub" 2> stub.err || rc=$?
                    test "$rc" = 255
                    grep -qF "$sock" stub.err
                    claude-code-sandbox show forge -C repo2 | grep -q '^Trusted executable greet: runs ${pkgs.bash}/bin/sh '

                    python3 - "$TMPDIR/greet.sock" "$exec_start" <<'EOF' &
                    import shlex, socket, subprocess, sys
                    argv = [w.replace("$$", "$").replace("%%", "%") for w in shlex.split(sys.argv[2])]
                    s = socket.socket(socket.AF_UNIX)
                    s.bind(sys.argv[1])
                    s.listen()
                    c, _ = s.accept()
                    subprocess.run(argv, stdin=c.fileno())
                    EOF
                    while [ ! -S "$TMPDIR/greet.sock" ]; do sleep 0.1; done
                    greeting=$(GREETING=hello trusted-exec call --name greet --socket "$TMPDIR/greet.sock" --pass-env GREETING -- world)
                    test "$greeting" = "hello world"
                    wait
                    touch $out
                  '';

              # Evaluating the two modules together is itself the check
              # that this layer composes with the editor: the bundles
              # merge into one init, the packages build against one Emacs
              # package set, and the whole activation resolves.
              home-manager-module =
                (inputs.home-manager.lib.homeManagerConfiguration {
                  inherit pkgs;
                  modules = [
                    inputs.ch-emacs-config.modules.homeManager.emacs
                    self.modules.homeManager.emacs
                    self.modules.homeManager.gptel
                    self.modules.homeManager.claude
                    self.modules.homeManager.claude-code
                    self.modules.homeManager.claude-code-sandbox
                    self.modules.homeManager.emacs-integration
                    # Without kinds, the microvm module adds nothing.
                    self.modules.homeManager.microvm
                    {
                      home.username = "tester";
                      home.homeDirectory = "/home/tester";
                      home.stateVersion = "25.05";
                      programs.emacs.enable = true;
                      # The claude-code module contributes global git
                      # excludes; with git enabled the check evaluates
                      # that file too.
                      programs.git.enable = true;
                      ch-emacs-config.emacs.enable = true;
                      ch-ai-workbench.emacs.enable = true;
                      # Forces the gptel option types and the init append
                      # through evaluation and the byte compiler.
                      ch-ai-workbench.gptel = {
                        enable = true;
                        backend = "fireworks";
                        model = "accounts/fireworks/models/deepseek-v4-flash";
                      };
                      ch-ai-workbench.claude.enable = true;
                      ch-ai-workbench.claude-code.enable = true;
                      ch-ai-workbench.claude-code-sandbox = sandboxModules;
                      ch-ai-workbench.emacs-integration.enable = true;
                    }
                  ];
                }).activationPackage;

              ai-commit-ert = pkgs.runCommand "ai-commit-ert" { } ''
                export HOME="$TMPDIR"
                ${emacs}/bin/emacs --batch \
                  -L ${aiCommitSrc} \
                  -l ${aiCommitSrc}/tests/ai-commit-ert.el \
                  -f ert-run-tests-batch-and-exit
                touch $out
              '';

              # The semantic finder's server-free surface: slicing,
              # staleness, response parsing, ranking, and the stale-OK
              # on-demand indexing policy (requests mocked).
              semantic-finder-ert = pkgs.runCommand "semantic-finder-ert" { } ''
                export HOME="$TMPDIR"
                ${emacs}/bin/emacs --batch \
                  -L ${semanticFinderSrc} \
                  -l ${semanticFinderSrc}/tests/semantic-finder-ert.el \
                  -f ert-run-tests-batch-and-exit
                touch $out
              '';

              # claude-queue requires semantic-finder: the agent finder
              # ranks transcripts through its embedding client.
              claude-queue-ert = pkgs.runCommand "claude-queue-ert" { } ''
                export HOME="$TMPDIR"
                ${emacs}/bin/emacs --batch \
                  -L ${claudeQueueSrc} \
                  -L ${semanticFinderSrc} \
                  -l ${claudeQueueSrc}/tests/claude-queue-ert.el \
                  -f ert-run-tests-batch-and-exit
                touch $out
              '';

              claude-consent-ert = pkgs.runCommand "claude-consent-ert" { } ''
                export HOME="$TMPDIR"
                ${emacs}/bin/emacs --batch \
                  -L ${claudeQueueSrc} \
                  -l ${claudeQueueSrc}/tests/claude-consent-ert.el \
                  -f ert-run-tests-batch-and-exit
                touch $out
              '';

              # MCP agent tools against the full init: registration
              # (which validates the tool docstring schemas), the non-LSP
              # tools end to end, and clean tool errors from the
              # LSP-backed ones.
              mcp-tools-ert =
                pkgs.runCommand "mcp-tools-ert"
                  {
                    # The mermaid tests skip without an mmdc on PATH; the
                    # shim makes them exercise the real renderer.
                    nativeBuildInputs = [ mermanMmdcShim ];
                  }
                  ''
                    export HOME="$TMPDIR"
                    ${emacs}/bin/emacs --batch \
                      -l ${testsSrc}/mcp-tools-ert.el \
                      -f ert-run-tests-batch-and-exit
                    touch $out
                  '';

              # The collab-comments integration: the add-comment and
              # list-comments MCP tools with their edit-contract anchor
              # matching, and threads surviving present and transcript
              # re-renders. The package's own suite runs in its
              # repository (github:clhodapp/collab-comments).
              collab-comments-ert = pkgs.runCommand "collab-comments-ert" { } ''
                export HOME="$TMPDIR"
                ${emacs}/bin/emacs --batch \
                  -l ${testsSrc}/collab-comments-ert.el \
                  -f ert-run-tests-batch-and-exit
                touch $out
              '';

              # The git-push PR-state reminder: a deny headed
              # "push-pr-check: verify" on a push (bare, through -C,
              # after &&, with global and push options), pass-through
              # on the identical re-issue and a fresh deny on the one
              # after it (the marker is consumed), silence on git
              # commands that are not a push, on non-git commands,
              # without a runtime dir, and on non-JSON stdin.
              claude-push-pr-check-hook =
                pkgs.runCommand "claude-push-pr-check-hook"
                  {
                    nativeBuildInputs = [ pkgs.jq ];
                  }
                  ''
                    hook=${lib.getExe claudePushPrCheckHook}
                    export XDG_RUNTIME_DIR="$TMPDIR/run"
                    mkdir -p -m 700 "$XDG_RUNTIME_DIR"
                    call() { jq -cn --arg c "$1" '{session_id: "0123456789abcdef", tool_name: "Bash", tool_input: {command: $c}}'; }
                    deny() {
                      res=$(call "$1" | "$hook")
                      [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$res")" = deny ]
                      jq -r .hookSpecificOutput.permissionDecisionReason <<<"$res" | grep -q '^push-pr-check: verify'
                    }
                    quiet() { [ -z "$(call "$1" | "$hook")" ]; }
                    deny 'git push origin feat/topic'
                    quiet 'git push origin feat/topic'
                    deny 'git push origin feat/topic'
                    deny 'git -C projects/foo push origin main'
                    deny 'cd /tmp/x && git push --force-with-lease'
                    deny 'git -c core.sshCommand=ssh push -u origin topic'
                    deny 'git commit -m "x" && git push'
                    quiet 'git commit -m "push later"'
                    quiet 'git log --oneline | grep push'
                    quiet 'git pushx'
                    quiet 'ls'
                    [ -z "$(call 'git push' | env -u XDG_RUNTIME_DIR "$hook")" ]
                    [ -z "$(echo 'not json' | "$hook")" ]
                    touch $out
                  '';

              # The tic-check hooks with the judge, against a stub System
              # One server: with the judge down the regex table decides
              # alone; the judge pushes back on a dimension at or above
              # pushBackAbove that no regex catches; a regex hit fires
              # whatever the judge says; a verdict below
              # pushBackAbove (and a report-only dimension above it) does
              # not block and reaches the next prompt once as context,
              # beside every score, highest first;
              # the rewrite step is unchanged; the edit hook asks a code
              # write only the dimensions that target code, sends an
              # Edit's replaced text beside the new text, asks a prose
              # write the prose dimensions, and still lets an identical
              # re-issue through.
              claude-tic-check-judge =
                pkgs.runCommand "claude-tic-check-judge"
                  {
                    nativeBuildInputs = [
                      pkgs.jq
                      pkgs.python3
                    ];
                  }
                  ''
                    hook=${lib.getExe judgeHooks.tic-check.package}
                    context=${lib.getExe judgeHooks.tic-check-context.package}
                    edit=${lib.getExe judgeHooks.tic-check-edit.package}
                    export XDG_RUNTIME_DIR="$TMPDIR/run"
                    mkdir -p -m 700 "$XDG_RUNTIME_DIR"
                    session=0123456789abcdef-0000-4000-8000-000000000000
                    stored="$XDG_RUNTIME_DIR/claude-tic-check/verdicts/$session.json"
                    stop() { jq -cn --arg m "$1" --arg s "$session" '{session_id: $s, stop_hook_active: false, last_assistant_message: $m}' | "$hook"; }
                    prompt() { jq -cn --arg s "$session" '{session_id: $s, prompt: "next"}' | "$context"; }
                    write() { jq -cn --arg f "$1" --arg c "$2" --arg s "$session" '{session_id: $s, tool_name: "Write", tool_input: {file_path: $f, content: $c}}' | "$edit"; }
                    reason() { jq -r .reason; }
                    lacks() { ! grep -q -- "$1"; }
                    answers() { printf '%s' "$1" > answers.json; }

                    # The judge is down: the regex table alone.
                    res=$(stop 'The merge step is yours.')
                    reason <<<"$res" | grep -q '^tic-check: check'
                    reason <<<"$res" | grep -q -- '- elliptical-possessive (1): '
                    reason <<<"$res" | lacks judge
                    [ -z "$(stop 'The build passed and the branch is pushed.')" ]
                    [ ! -e "$stored" ]

                    answers '{}'
                    python3 ${self}/tests/tic-check/stub-systemone.py 18731 answers.json requests.log &
                    for _ in $(seq 100); do
                      (: <>/dev/tcp/127.0.0.1/18731) 2>/dev/null && break
                      sleep 0.1
                    done

                    # A clean message; the verdict waits for the next
                    # prompt, which reports the readability scores and no
                    # problems. The word bans are the regex table, not
                    # judge questions.
                    [ -z "$(stop 'The build passed and the branch is pushed.')" ]
                    jq -e '.endpoint == "local" and .model == "elephant-1"' "$stored"
                    tail -n 1 requests.log | jq -e '.model == "elephant-1" and (.questions | has("fragments") and has("count-obsession") and has("undefined-terms") and (has("arguing-with-ghosts") | not) and (has("elliptical-possessive") | not))'
                    tail -n 1 requests.log | jq -e '.questions["assumed-context"].type == "score" and (.questions["assumed-context"].criteria | length) == 4 and (.questions | has("generic-concept-words") and has("unexplained-references"))'
                    tail -n 1 requests.log | jq -e '.questions["information-density"].criteria[1] | startswith("even")'
                    ctx=$(prompt | jq -r .hookSpecificOutput.additionalContext)
                    grep -q -- '- assumed-context 0 of 3, most likely nothing beyond the subject' <<<"$ctx"
                    lacks 'These problems' <<<"$ctx"
                    [ -z "$(prompt)" ]
                    [ ! -e "$stored" ]

                    # A confident dimension the regex cannot see.
                    answers '{"fragments": 0.95}'
                    res=$(stop 'Build green, pushed, PR open.')
                    reason <<<"$res" | grep -q '^tic-check: check'
                    reason <<<"$res" | grep -q -- '- fragments (judge 0.95): '
                    reason <<<"$res" | grep -q 'elephant-1 at local'
                    [ ! -e "$stored" ]

                    # A regex hit stands whatever the judge says.
                    answers '{}'
                    reason <<<"$(stop 'The merge step is yours.')" | grep -q -- '- elliptical-possessive (1): '
                    reason <<<"$(stop 'One — two.')" | grep -q -- '- em-dash (1): '

                    # Below pushBackAbove, and report-only: context, once.
                    # A score never blocks and is reported highest first.
                    answers '{"fragments": 0.6, "undefined-terms": 0.99, "information-density": [0, 0.2, 0.6, 0.2]}'
                    [ -z "$(stop 'The build passed.')" ]
                    ctx=$(prompt | jq -r .hookSpecificOutput.additionalContext)
                    grep -q '^tic-check: verdicts' <<<"$ctx"
                    grep -q -- '- undefined-terms 0.99: ' <<<"$ctx"
                    grep -q -- '- fragments 0.6: ' <<<"$ctx"
                    grep -q -- '- information-density 2 of 3, most likely dense: several facts per sentence (0.6); aim: ' <<<"$ctx"
                    [ "$(grep -n -- '- information-density ' <<<"$ctx" | cut -d: -f1)" -lt "$(grep -n -- '- assumed-context ' <<<"$ctx" | cut -d: -f1)" ]
                    [ -z "$(prompt)" ]

                    # The rewrite step.
                    res=$(jq -cn '{session_id: "s", stop_hook_active: true, last_assistant_message: "tic-check: tic"}' | "$hook")
                    reason <<<"$res" | grep -q '^tic-check: rewrite'

                    # The edit side: code is asked only the dimensions
                    # that target code.
                    answers '{"fragments": 0.95}'
                    [ -z "$(write src/main.nix 'Build green, pushed.')" ]
                    tail -n 1 requests.log | jq -e '(.state.kind | contains("source file")) and (.questions | keys) == ["arguing-with-ghosts"]'

                    # A comment explaining a deleted line after a
                    # correction, judged with the replaced text and the
                    # user's latest message beside it.
                    answers '{"arguing-with-ghosts": 0.95}'
                    jq -cn '{type: "user", message: {role: "user", content: "drop nix.package from the homes"}}' > transcript.jsonl
                    res=$(jq -cn --arg s "$session" --arg t "$PWD/transcript.jsonl" '{session_id: $s, transcript_path: $t, tool_name: "Edit", tool_input: {file_path: "home.nix", old_string: "nix.package = pkgs.nix;", new_string: "# nix.package is not set here."}}' | "$edit")
                    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$res")" = deny ]
                    jq -r .hookSpecificOutput.permissionDecisionReason <<<"$res" | grep -q -- '- arguing-with-ghosts (judge 0.95): '
                    tail -n 1 requests.log | jq -e '.state["replaced text"] == "nix.package = pkgs.nix;"'
                    tail -n 1 requests.log | jq -e '[.state | to_entries[] | select(.key | contains("latest messages")) | .value] == [["drop nix.package from the homes"]]'

                    # A prose file is asked the prose dimensions.
                    answers '{"fragments": 0.95}'
                    res=$(write docs/notes.md 'Build green, pushed.')
                    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$res")" = deny ]
                    jq -r .hookSpecificOutput.permissionDecisionReason <<<"$res" | grep -q -- '- fragments (judge 0.95): '
                    tail -n 1 requests.log | jq -e '.state.kind | contains("prose file")'
                    [ -z "$(write docs/notes.md 'Build green, pushed.')" ]

                    # The whole turn: a finding in a message written
                    # between tool calls, and a final message that leaves
                    # out what the turn found.
                    {
                      jq -cn '{type: "user", message: {role: "user", content: "fix it"}}'
                      jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "One — two."}, {type: "tool_use", id: "t", name: "Bash", input: {}}]}}'
                      jq -cn '{type: "user", message: {content: [{type: "tool_result", tool_use_id: "t", content: "ok"}]}}'
                    } > turn.jsonl
                    answers '{"final-message-recap": 0.95}'
                    res=$(jq -cn --arg s "$session" --arg t "$PWD/turn.jsonl" '{session_id: $s, transcript_path: $t, stop_hook_active: false, last_assistant_message: "All fixed."}' | "$hook")
                    reason <<<"$res" | grep -q '^The turn you just finished'
                    reason <<<"$res" | grep -q -- '- em-dash (1): '
                    reason <<<"$res" | grep -q -- '- final-message-recap (judge 0.95): '
                    tail -n 1 requests.log | jq -e '.state.text | contains("[earlier message of this turn]\nOne — two.") and contains("[final message]\nAll fixed.")'

                    # Mid-turn: a labeled note after a tool call, for the
                    # messages not judged yet, and nothing for the next
                    # call until a new message is written.
                    turnhook=${lib.getExe judgeHooks.tic-check-turn.package}
                    {
                      jq -cn '{type: "user", message: {role: "user", content: "ship it"}}'
                      jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "Build green, pushed."}, {type: "tool_use", id: "t", name: "Bash", input: {}}]}}'
                    } > progress.jsonl
                    post() { jq -cn --arg s "$session" --arg t "$PWD/progress.jsonl" '{session_id: $s, transcript_path: $t, tool_name: "Bash", tool_input: {command: "ls"}, tool_response: {}}' | "$turnhook"; }
                    answers '{"fragments": 0.6, "assumed-context": [0, 0, 1, 0]}'
                    ctx=$(post | jq -r .hookSpecificOutput.additionalContext)
                    grep -q '^tic-check: mid-turn verdicts' <<<"$ctx"
                    grep -q 'not from the Bash call: it is not part of the tool' <<<"$ctx"
                    grep -q -- '- fragments 0.6: ' <<<"$ctx"
                    grep -q -- '- assumed-context 2 of 3, most likely a lot: many names' <<<"$ctx"
                    lacks 'information-density' <<<"$ctx"
                    tail -n 1 requests.log | jq -e '(.state.kind | contains("between tool calls")) and (.questions | has("fragments") and (has("final-message-recap") | not) and (has("arguing-with-ghosts") | not))'
                    before=$(wc -l < requests.log)
                    [ -z "$(post)" ]
                    [ "$(wc -l < requests.log)" = "$before" ]
                    jq -cn '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: "Now the docs."}, {type: "tool_use", id: "u", name: "Edit", input: {}}]}}' >> progress.jsonl
                    post | jq -r .hookSpecificOutput.additionalContext | grep -q '^tic-check: mid-turn verdicts'
                    tail -n 1 requests.log | jq -e '.state.text | contains("Now the docs.") and (contains("Build green") | not)'

                    # Below the push-back level a write goes through, and
                    # its verdict reaches the model after the call, once.
                    answers '{"arguing-with-ghosts": 0.6}'
                    call='{tool_name: "Edit", tool_input: {file_path: "home.nix", old_string: "a = 1;", new_string: "# a is not set here anymore."}}'
                    [ -z "$(jq -cn --arg s "$session" "$call + {session_id: \$s}" | "$edit")" ]
                    after() { jq -cn --arg s "$session" --arg t "$PWD/progress.jsonl" "$call + {session_id: \$s, transcript_path: \$t, tool_response: {}}" | "$turnhook"; }
                    ctx=$(after | jq -r .hookSpecificOutput.additionalContext)
                    grep -q 'not from the Edit call' <<<"$ctx"
                    grep -q 'The text this Edit call wrote, judged as code before it ran' <<<"$ctx"
                    grep -q -- '- arguing-with-ghosts 0.6: ' <<<"$ctx"
                    [ -z "$(after)" ]

                    # Commit messages, pull request texts, and reviews
                    # written through Bash.
                    msg=${lib.getExe judgeHooks.tic-check-message.package}
                    run() { jq -cn --arg c "$1" --arg s "$session" --arg t "$PWD/transcript.jsonl" --arg d "$PWD" '{session_id: $s, transcript_path: $t, cwd: $d, tool_name: "Bash", tool_input: {command: $c}}' | "$msg"; }
                    answers '{"fragments": 0.95}'
                    before=$(wc -l < requests.log)
                    [ -z "$(run 'ls -la && git log --oneline -3')" ]
                    [ "$(wc -l < requests.log)" = "$before" ]
                    res=$(run "git add -A && git commit -m 'Build green, pushed.'")
                    [ "$(jq -r .hookSpecificOutput.permissionDecision <<<"$res")" = deny ]
                    jq -r .hookSpecificOutput.permissionDecisionReason <<<"$res" | grep -q -- '- fragments (judge 0.95): '
                    tail -n 1 requests.log | jq -e '(.state.kind | contains("commit message")) and (.state.text | rtrimstr("\n")) == "Build green, pushed." and (.questions | has("arguing-with-ghosts") and (has("assumed-context") | not))'
                    [ -z "$(run "git add -A && git commit -m 'Build green, pushed.'")" ]
                    answers '{"arguing-with-ghosts": 0.95}'
                    res=$(run "gh pr review 59 --comment --body 'Nothing publishes into packages anymore.'")
                    jq -r .hookSpecificOutput.permissionDecisionReason <<<"$res" | grep -q -- '- arguing-with-ghosts (judge 0.95): '

                    kill %1
                    touch $out
                  '';

              # The redaction hook: a token in a Read result is replaced
              # in place with the shape kept and a note naming the rule,
              # and the Read is marked for the retry path; an approved
              # marker lets the identical Read through once and is
              # consumed; a Read without a session is redacted but not
              # marked; a token in Bash's stderr is replaced the same
              # way; a clean result, a PreToolUse payload, and non-JSON
              # stdin are silence. The token is drawn at build time and
              # checked against betterleaks first, since betterleaks drops
              # placeholder-looking strings and a token-shaped string
              # does not belong in the tree.
              claude-redact-hook =
                pkgs.runCommand "claude-redact-hook"
                  {
                    nativeBuildInputs = [
                      pkgs.betterleaks
                      pkgs.jq
                    ];
                  }
                  ''
                    hook=${lib.getExe claudeRedactHook}
                    export XDG_RUNTIME_DIR="$TMPDIR/run"
                    mkdir -p -m 700 "$XDG_RUNTIME_DIR"
                    session=0123456789abcdef-0000-4000-8000-000000000000
                    flagged=0
                    for _ in 1 2 3 4 5 6 7 8; do
                      tok="ghp_$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-36)"
                      n=$(printf 'token = %s\n' "$tok" | betterleaks stdin --no-banner --log-level error --report-format json --report-path - --exit-code 0 | jq 'length')
                      if [ "$n" = 1 ]; then flagged=1; break; fi
                    done
                    [ "$flagged" = 1 ]
                    read_payload=$(jq -cn --arg t "$tok" --arg s "$session" '{hook_event_name: "PostToolUse", tool_name: "Read", session_id: $s,
                      tool_input: {file_path: "/x"},
                      tool_response: {type: "text", file: {content: ("token = " + $t + "\nplain\n"), filePath: "/x", numLines: 2, startLine: 1, totalLines: 2}}}')
                    res=$("$hook" <<<"$read_payload")
                    jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$res"
                    jq -e '.hookSpecificOutput.updatedToolOutput.file.content == "token = [REDACTED:github-pat]\nplain\n"' <<<"$res"
                    jq -e '.hookSpecificOutput.updatedToolOutput.file.numLines == 2' <<<"$res"
                    jq -e '.hookSpecificOutput.additionalContext | test("redacted 1 span in this Read result: github-pat")' <<<"$res"
                    jq -e '.hookSpecificOutput.additionalContext | test("re-issue this identical call")' <<<"$res"
                    key=$(jq -c '{tool_name, tool_input}' <<<"$read_payload" | sha256sum | cut -c1-64)
                    marker="$XDG_RUNTIME_DIR/claude-redact/redacted/01234567-$key"
                    jq -e '.count == "1" and .rules == "github-pat"' "$marker"
                    # The user allowed: the approved marker lets the identical Read through once.
                    approved="$XDG_RUNTIME_DIR/claude-redact/approved/01234567-$key"
                    mkdir -p "$(dirname "$approved")"
                    : > "$approved"
                    [ -z "$("$hook" <<<"$read_payload")" ]
                    [ ! -e "$approved" ]
                    [ -n "$("$hook" <<<"$read_payload")" ]
                    # No session: redacted, but no retry path is offered.
                    res=$("$hook" <<<"$(jq -c 'del(.session_id)' <<<"$read_payload")")
                    jq -e '.hookSpecificOutput.additionalContext | test("re-issue") | not' <<<"$res"
                    # An MCP read the server already redacted: nothing to
                    # replace here, but the call is marked and the model is
                    # told how to ask; the key leaves out `approval`.
                    mcp_payload=$(jq -cn --arg s "$session" '{hook_event_name: "PostToolUse", tool_name: "mcp__emacs__buffer-text", session_id: $s,
                      tool_input: {name: "notes"},
                      tool_response: [{type: "text", text: "token = [REDACTED:github-pat]\n\n[betterleaks redacted 1 span: github-pat]"}]}')
                    res=$("$hook" <<<"$mcp_payload")
                    jq -e '.hookSpecificOutput.updatedToolOutput == null' <<<"$res"
                    jq -e '.hookSpecificOutput.additionalContext | test("re-issue this identical call")' <<<"$res"
                    mkey=$(jq -c '{tool_name, tool_input}' <<<"$mcp_payload" | sha256sum | cut -c1-64)
                    jq -e '.rules == "github-pat"' "$XDG_RUNTIME_DIR/claude-redact/redacted/01234567-$mkey"
                    # The approved call carries `approval`; it shares the key,
                    # passes through once, and consumes the marker.
                    : > "$XDG_RUNTIME_DIR/claude-redact/approved/01234567-$mkey"
                    approved_payload=$(jq -c --arg t "$tok" '.tool_input.approval = "x" | .tool_response = [{type: "text", text: ("token = " + $t)}]' <<<"$mcp_payload")
                    [ -z "$("$hook" <<<"$approved_payload")" ]
                    [ ! -e "$XDG_RUNTIME_DIR/claude-redact/approved/01234567-$mkey" ]
                    # A clean MCP result stays silent.
                    [ -z "$("$hook" <<<"$(jq -c '.tool_response = [{type: "text", text: "plain"}]' <<<"$mcp_payload")")" ]
                    bash_payload=$(jq -cn --arg t "$tok" '{hook_event_name: "PostToolUse", tool_name: "Bash",
                      tool_response: {stdout: "ok\n", stderr: ("leak " + $t + " here\n"), interrupted: false}}')
                    res=$("$hook" <<<"$bash_payload")
                    jq -e '.hookSpecificOutput.updatedToolOutput.stderr == "leak [REDACTED:github-pat] here\n"' <<<"$res"
                    jq -e '.hookSpecificOutput.updatedToolOutput.stdout == "ok\n"' <<<"$res"
                    [ -z "$("$hook" <<<'{"hook_event_name":"PostToolUse","tool_name":"Bash","tool_response":{"stdout":"hello\n","stderr":""}}')" ]
                    [ -z "$("$hook" <<<'{"hook_event_name":"PreToolUse","tool_name":"Read","tool_input":{"file_path":"/x"}}')" ]
                    [ -z "$(echo 'not json' | "$hook")" ]
                    touch $out
                  '';

              # The reveal hook: a Read with no marker is none of its
              # business; a marked Read with no answerer attached is a
              # deny naming the spool; with an answerer, allow writes the
              # approved marker and abstains, an approved Read is left
              # alone, and deny with a reason reaches the model; non-JSON
              # stdin is silence.
              claude-reveal-hook =
                pkgs.runCommand "claude-reveal-hook"
                  {
                    nativeBuildInputs = [ pkgs.jq ];
                  }
                  ''
                    hook=${lib.getExe claudeRevealHook}
                    export XDG_RUNTIME_DIR="$TMPDIR/run"
                    spool="$XDG_RUNTIME_DIR/claude-consent"
                    mkdir -p -m 700 "$XDG_RUNTIME_DIR"
                    mkdir -p "$spool/handlers" "$spool/pending" "$spool/answers"
                    mkdir -p "$XDG_RUNTIME_DIR/claude-redact/redacted" "$XDG_RUNTIME_DIR/claude-redact/approved"
                    session=0123456789abcdef-0000-4000-8000-000000000000
                    payload=$(jq -cn --arg s "$session" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Read", tool_input: {file_path: "/x"}, cwd: "/proj"}')
                    key=$(jq -c '{tool_name, tool_input}' <<<"$payload" | sha256sum | cut -c1-64)
                    redacted="$XDG_RUNTIME_DIR/claude-redact/redacted/01234567-$key"
                    approved="$XDG_RUNTIME_DIR/claude-redact/approved/01234567-$key"
                    decision() { jq -r .hookSpecificOutput.permissionDecision <<<"$1"; }
                    reason() { jq -r .hookSpecificOutput.permissionDecisionReason <<<"$1"; }
                    # Never redacted: silence.
                    [ -z "$("$hook" <<<"$payload")" ]
                    # Redacted before, nobody to ask: the redacted view stands.
                    jq -cn '{count: 1, rules: "github-pat"}' > "$redacted"
                    res=$("$hook" <<<"$payload")
                    [ "$(decision "$res")" = deny ]
                    reason "$res" | grep -q 'no answerer'
                    [ ! -e "$approved" ]
                    # An answerer is attached.
                    sleep 120 & sleeper=$!
                    jq -cn --argjson p "$sleeper" '{name: "test", pid: $p}' > "$spool/handlers/test.json"
                    answer() { # $1 = value, $2 = text; answers the first pending prompt
                      for _ in $(seq 1 100); do
                        f=$(find "$spool/pending" -name '*.json' | head -1)
                        if [ -n "$f" ]; then
                          [ "$(jq -r .prompt.title "$f")" = "Reveal redacted text to the model" ]
                          [ "$(jq -r '.hook.tool_input.file_path // .hook.tool_input.name' "$f")" = "$target" ]
                          id=$(jq -r .id "$f")
                          jq -cn --arg id "$id" --arg v "$1" --arg t "$2" '{id: $id, value: $v} + (if $t == "" then {} else {text: $t} end)' > "$spool/answers/$id.json.tmp"
                          mv "$spool/answers/$id.json.tmp" "$spool/answers/$id.json"
                          exit 0
                        fi
                        sleep 0.1
                      done
                      exit 1
                    }
                    target=/x
                    # Allow: the approval is recorded and the hook abstains.
                    (answer allow "") & answerer=$!
                    [ -z "$("$hook" <<<"$payload")" ]
                    wait $answerer
                    [ -e "$approved" ]
                    # An approved Read still pending consumption is left alone.
                    [ -z "$("$hook" <<<"$payload")" ]
                    rm "$approved"
                    # Deny with a reason: the reason reaches the model.
                    (answer deny "not now") & answerer=$!
                    res=$("$hook" <<<"$payload")
                    wait $answerer
                    [ "$(decision "$res")" = deny ]
                    reason "$res" | grep -q 'kept the text redacted: not now'
                    [ ! -e "$approved" ]
                    # An MCP read: allow also writes a token file and adds the
                    # token to the call as `approval`, with no decision.
                    target=notes
                    mcp=$(jq -cn --arg s "$session" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "mcp__emacs__buffer-text", tool_input: {name: "notes"}, cwd: "/proj"}')
                    mkey=$(jq -c '{tool_name, tool_input}' <<<"$mcp" | sha256sum | cut -c1-64)
                    jq -cn '{count: "some", rules: "github-pat"}' > "$XDG_RUNTIME_DIR/claude-redact/redacted/01234567-$mkey"
                    (answer allow "") & answerer=$!
                    res=$("$hook" <<<"$mcp")
                    wait $answerer
                    jq -e '.hookSpecificOutput.permissionDecision == null' <<<"$res"
                    jq -e '.hookSpecificOutput.updatedInput.name == "notes"' <<<"$res"
                    token=$(jq -r .hookSpecificOutput.updatedInput.approval <<<"$res")
                    [ "''${#token}" -ge 32 ]
                    [ -e "$XDG_RUNTIME_DIR/claude-redact/mcp-approved/$token" ]
                    [ -e "$XDG_RUNTIME_DIR/claude-redact/approved/01234567-$mkey" ]
                    # A tool outside the three is none of its business.
                    [ -z "$("$hook" <<<"$(jq -c '.tool_name = "mcp__emacs__context"' <<<"$mcp")")" ]
                    kill $sleeper
                    # Garbage in: nothing out.
                    [ -z "$(echo 'not json' | "$hook")" ]
                    touch $out
                  '';

              # The prompt API: building the package runs its unittest
              # suite (the four ask outcomes, stored answers consumed by
              # key, the async re-entry waiter, handler liveness).
              claude-consent = claudeConsent;

              # The consent hook end to end against the tool: abstention
              # without a territory record and inside the territory, a
              # deny on the spool itself, `ask` when no answerer is
              # attached, the user's allow and deny (with reason)
              # couriered back while an answerer is registered, the
              # self-answered deny at the deadline, and silence on
              # non-JSON stdin.
              emacs-claude-consent-hook =
                pkgs.runCommand "emacs-claude-consent-hook"
                  {
                    nativeBuildInputs = [ pkgs.jq ];
                  }
                  ''
                    hook=${lib.getExe emacsClaudeConsentHook}
                    export XDG_RUNTIME_DIR="$TMPDIR/run"
                    spool="$XDG_RUNTIME_DIR/claude-consent"
                    mkdir -p -m 700 "$XDG_RUNTIME_DIR"
                    mkdir -p "$spool/territory" "$spool/handlers" "$spool/pending" "$spool/answers"
                    session=0123456789abcdef-0000-4000-8000-000000000000
                    call() { jq -cn --arg s "$session" --arg f "$1" '{session_id: $s, hook_event_name: "PreToolUse", tool_name: "Write", tool_input: {file_path: $f, content: "x"}, cwd: "/proj"}'; }
                    decision() { jq -r .hookSpecificOutput.permissionDecision <<<"$1"; }
                    reason() { jq -r .hookSpecificOutput.permissionDecisionReason <<<"$1"; }
                    record() { jq -cn --argjson d "$1" '{agent_id: "01234567", roots: ["/proj"], deadline: $d, name: "fix the frob"}' > "$spool/territory/01234567.json"; }
                    # No territory record: stock behavior.
                    [ -z "$(call /elsewhere/x | "$hook")" ]
                    record 5
                    # In territory: the sandbox accepts it, the hook says nothing.
                    [ -z "$(call /proj/sub/x | "$hook")" ]
                    [ -z "$(call sub/x | "$hook")" ]
                    # The spool is never territory.
                    res=$(call "$spool/pending/y.json" | "$hook")
                    [ "$(decision "$res")" = deny ]
                    # No answerer attached: a plain allow/deny falls back to the CLI's prompt.
                    res=$(call /elsewhere/x | "$hook")
                    [ "$(decision "$res")" = ask ]
                    reason "$res" | grep -q 'outside this session'
                    [ -z "$(ls "$spool/pending")" ]
                    # An answerer is attached: the answer is couriered back.
                    sleep 120 & sleeper=$!
                    jq -cn --argjson p "$sleeper" '{name: "test", pid: $p}' > "$spool/handlers/test.json"
                    answer() { # $1 = value, $2 = text; answers the first pending prompt
                      for _ in $(seq 1 100); do
                        f=$(find "$spool/pending" -name '*.json' | head -1)
                        if [ -n "$f" ]; then
                          [ "$(jq -r .prompt.title "$f")" = "Write outside territory" ]
                          [ "$(jq -r .mode "$f")" = blocking ]
                          [ "$(jq -r .territory.name "$f")" = "fix the frob" ]
                          [ "$(jq -r .hook.tool_input.file_path "$f")" = /elsewhere/x ]
                          id=$(jq -r .id "$f")
                          jq -cn --arg id "$id" --arg v "$1" --arg t "$2" '{id: $id, value: $v} + (if $t == "" then {} else {text: $t} end)' > "$spool/answers/$id.json.tmp"
                          mv "$spool/answers/$id.json.tmp" "$spool/answers/$id.json"
                          exit 0
                        fi
                        sleep 0.1
                      done
                      exit 1
                    }
                    (answer deny "wrong repo") & answerer=$!
                    res=$(call /elsewhere/x | "$hook")
                    wait $answerer
                    [ "$(decision "$res")" = deny ]
                    [ "$(reason "$res")" = "denied by the user: wrong repo" ]
                    (answer allow "") & answerer=$!
                    res=$(call /elsewhere/x | "$hook")
                    wait $answerer
                    [ "$(decision "$res")" = allow ]
                    [ "$(reason "$res")" = "approved by the user" ]
                    [ -z "$(ls "$spool/pending")" ]
                    [ -z "$(ls "$spool/answers")" ]
                    # Nobody answers: the hook self-denies at the record's deadline.
                    record 1
                    res=$(call /elsewhere/x | "$hook")
                    [ "$(decision "$res")" = deny ]
                    reason "$res" | grep -q 'timed out after 1s'
                    kill $sleeper
                    # Garbage in: nothing out.
                    [ -z "$(echo 'not json' | "$hook")" ]
                    [ -z "$(call /elsewhere/x | env -u XDG_RUNTIME_DIR "$hook")" ]
                    touch $out
                  '';
            };
            treefmt.programs.nixfmt.enable = true;
            treefmt.programs.rustfmt = {
              enable = true;
              edition = "2024";
            };
          };
      };
  };

}
