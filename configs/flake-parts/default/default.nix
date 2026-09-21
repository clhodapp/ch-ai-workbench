# SPDX-License-Identifier: MIT
{ ... }:
{
  inputs,
  lib,
  ...
}:
{

  imports = [ inputs.flake-parts.flakeModules.partitions ];

  debug = false;
  caisson.configInfo.configName = "ch-ai-workbench";
  caisson.modules.homeManager.exported = modules: {
    inherit (modules)
      emacs
      gptel
      claude
      claude-code
      claude-code-sandbox
      emacs-integration
      zsh
      ;
  };

  caisson.nixpkgs.overlays.all = {
    # This flake's own packages (the sandbox CLI, its plugin, and the
    # Landlock shim), under pkgs.ch-ai-workbench.
    packages = lib.caisson.nixpkgs.mkPackagesOverlay (
      { callPackage, ... }: import ../../../pkgs/ch-ai-workbench { inherit callPackage; }
    );
    merman-nix = _name: inputs.merman-nix.overlays.packages;
    # The editor's Emacs bases and ELPA pins: the checks below build
    # this layer's packages against the same Emacs the editor
    # configures, since they load into it.
    emacs = _name: inputs.ch-emacs-config.overlays.emacs;
    emacs-packages = _name: inputs.ch-emacs-config.overlays.emacs-packages;
  };

  caisson.nixpkgs.overlays.export.enabled = true;
  caisson.nixpkgs.overlays.exported = overlays: {
    inherit (overlays) packages;
  };

  caisson.nixpkgs.pkgSets.pkgs = {
    pkgFunction = import inputs.nixpkgs;
    overlayImports = overlays: [
      overlays.emacs-packages
      overlays.emacs
      overlays.merman-nix
      overlays.packages
    ];
  };

  # packages.* is deliberately not partitioned: consumers take these
  # packages against this flake's main lock, so dev-only inputs must
  # not taint them.
  caisson.nixpkgs.packages.export.enabled = true;

  partitionedAttrs.checks = "checks";
  partitionedAttrs.formatter = "formatter";

  partitions.formatter = {
    extraInputs = lib.caisson-core.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem.treefmt.programs.nixfmt.enable = true;
      };
  };

  partitions.checks = {
    extraInputs = lib.caisson-core.partitionExtraInputs ../../../tests/dependencies;
    module =
      { inputs, self, ... }:
      {
        imports = [ inputs.treefmt-nix.flakeModule ];
        perSystem =
          { pkgs, system, ... }:
          let
            merman = inputs.merman-nix.packages.${system}.merman;

            # An Emacs carrying both layers' bundles, built the way the
            # editor builds its own check Emacs: the ERT suites below run
            # `--batch` against the full init, so the packages must be in
            # the init package's closure rather than merely installed
            # into a profile.
            scope = import "${inputs.ch-emacs-config}/modules/home-manager/emacs/lib/package-scope.nix" {
              inherit pkgs;
              lib = pkgs.lib;
              emacsPackage = pkgs.ch-emacs-config.emacs-pgtk;
              bundles =
                (import "${inputs.ch-emacs-config}/modules/home-manager/emacs/bundles/spec.nix")
                // workbenchBundles;
              sources = {
                # Through the editor rather than a second input, so both
                # layers build these from one revision. The list mirrors
                # the editor module's own `emacsPackageSources`.
                inherit (inputs.ch-emacs-config.inputs) pr-review ghostel;
              };
              extraOverrides = [
                (self: _super: {
                  collab-comments = self.callPackage ../../../pkgs/emacs/collab-comments/package.nix {
                    src = inputs.collab-comments;
                  };
                  parenting = self.callPackage ../../../pkgs/emacs/parenting/package.nix {
                    src = inputs.parenting;
                  };
                })
              ];
              localPackageOverlays = workbenchLocalPackages;
            };

            emacs = scope.emacs;

            # This layer's bundle spec and local packages, read from the
            # modules so the checks and a real configuration cannot
            # drift. Every group at once: the ERT suites below need the
            # whole layer in one Emacs.
            workbenchBundles = lib.foldl' (acc: group: acc // group) { } (
              lib.attrValues (
                import ../../../modules/home-manager/emacs/bundles-spec.nix {
                  inherit lib;
                  readInit = name: builtins.readFile ../../../modules/home-manager/emacs/inits/${name};
                  merman = inputs.merman-nix.packages.${system}.merman;
                  gitleaks = pkgs.gitleaks;
                }
              )
            );
            workbenchLocalPackages = lib.concatLists (
              lib.attrValues (import ../../../modules/home-manager/emacs/local-packages.nix)
            );

            aiCommitSrc = "${self}/modules/home-manager/emacs/packages/ai-commit";
            claudeQueueSrc = "${self}/modules/home-manager/emacs/packages/claude-queue";
            semanticFinderSrc = "${self}/modules/home-manager/emacs/packages/semantic-finder";
            testsSrc = "${self}/modules/home-manager/emacs/tests";

            mermanMmdcShim = pkgs.writeShellScriptBin "mmdc" ''exec ${lib.getExe merman} mmdc "$@"'';

            # The hook package read from the module's lib, so the check
            # below drives the same script a real configuration installs.
            claudePushPrCheckHook =
              import ../../../modules/home-manager/claude-code/lib/claude-push-pr-check-hook.nix
                {
                  inherit pkgs;
                };
            claudeRedactHook = import ../../../modules/home-manager/claude-code/lib/claude-redact-hook.nix {
              inherit pkgs;
            };

            # The prompt API tool (its build runs the unittest suite)
            # and the consent hook built on it, from the same files the
            # modules use.
            claudeConsent = pkgs.callPackage ../../../pkgs/claude-consent/claude-consent { };
            emacsClaudeConsentHook =
              import ../../../modules/home-manager/emacs/lib/emacs-claude-consent-hook.nix
                {
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
                    {
                      home.username = "tester";
                      home.homeDirectory = "/home/tester";
                      home.stateVersion = "25.05";
                      programs.emacs.enable = true;
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
                      # Any package stands in for the CLI a host runs:
                      # the check evaluates the profile fragments and
                      # their closures, not a live sandbox.
                      ch-ai-workbench.claude-code-sandbox = {
                        enable = true;
                        runtime.claudePackage = pkgs.hello;
                        profiles.default.toolset = [ pkgs.ripgrep ];
                      };
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

              # The redaction hook: a token in a Read result is replaced
              # in place with the shape kept and a note naming the rule;
              # a token in Bash's stderr the same; a clean result, a
              # PreToolUse payload, and non-JSON stdin are silence. The
              # token is drawn at build time and checked against gitleaks
              # first, since gitleaks drops placeholder-looking strings
              # and a token-shaped string does not belong in the tree.
              claude-redact-hook =
                pkgs.runCommand "claude-redact-hook"
                  {
                    nativeBuildInputs = [
                      pkgs.gitleaks
                      pkgs.jq
                    ];
                  }
                  ''
                    hook=${lib.getExe claudeRedactHook}
                    flagged=0
                    for _ in 1 2 3 4 5 6 7 8; do
                      tok="ghp_$(head -c 64 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-36)"
                      n=$(printf 'token = %s\n' "$tok" | gitleaks stdin --no-banner --log-level error --report-format json --report-path - --exit-code 0 | jq 'length')
                      if [ "$n" = 1 ]; then flagged=1; break; fi
                    done
                    [ "$flagged" = 1 ]
                    read_payload=$(jq -cn --arg t "$tok" '{hook_event_name: "PostToolUse", tool_name: "Read",
                      tool_response: {type: "text", file: {content: ("token = " + $t + "\nplain\n"), filePath: "/x", numLines: 2, startLine: 1, totalLines: 2}}}')
                    res=$("$hook" <<<"$read_payload")
                    jq -e '.hookSpecificOutput.hookEventName == "PostToolUse"' <<<"$res"
                    jq -e '.hookSpecificOutput.updatedToolOutput.file.content == "token = [REDACTED:github-pat]\nplain\n"' <<<"$res"
                    jq -e '.hookSpecificOutput.updatedToolOutput.file.numLines == 2' <<<"$res"
                    jq -e '.hookSpecificOutput.additionalContext | test("redacted 1 span in this Read result: github-pat")' <<<"$res"
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
          };
      };
  };

}
