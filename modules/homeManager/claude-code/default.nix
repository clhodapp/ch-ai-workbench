# SPDX-License-Identifier: MIT
#
# The agent half of the workbench: the hooks, skills, output styles and
# permissions a Claude Code session runs under, and the LSP plugin
# manifest it reads.
{ closure-sources, closure-lib, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.claude-code;

  # The shared server table (argv, extensions, settings), from the
  # editor this workbench builds on: the manifest below renders it into
  # Claude Code's lspServers shape, and the editor's eglot renders the
  # same table, so the two cannot disagree about how to spawn a server.
  languageServers = closure-lib.ch-emacs-config.languageServers pkgs {
    merman = closure-sources.merman-nix.packages.${pkgs.stdenv.hostPlatform.system}.merman-preview;
  };

  # A personal-scope skills-directory plugin: any folder under
  # ~/.claude/skills/ with a .claude-plugin/plugin.json manifest is
  # discovered in place on session start — no marketplace, no install
  # step, no copy into the plugin cache, and no entry in
  # ~/.claude/settings.json (which the CLI mutates at runtime and so
  # cannot be a store symlink; see the emacs module's cwd-hook note).
  # Keep restartOnCrash/shutdownTimeout out of the server entries:
  # claude-code < 2.1.205 silently skips a server that sets either.
  enabledServers = lib.filterAttrs (name: _: cfg.lspServers.${name}.enable or true) languageServers;

  # ext -> [ claiming enabled servers ]; routing is by extension and
  # Claude Code resolves a collision as first-registered-wins at
  # runtime (no error, losing server never starts), so surface any
  # duplicate at eval time instead.
  extensionClaims = lib.groupBy (claim: claim.ext) (
    lib.concatLists (
      lib.mapAttrsToList (
        name: server: map (ext: { inherit name ext; }) (lib.attrNames server.extensionToLanguage)
      ) enabledServers
    )
  );

  duplicateClaims = lib.filterAttrs (_ext: claims: lib.length claims > 1) extensionClaims;

  unknownServerNames = lib.subtractLists (lib.attrNames languageServers) (
    lib.attrNames cfg.lspServers
  );

  lspPluginManifest = {
    name = "ch-lsp";
    description = "Store-pinned language servers from ch-ai-workbench";
    version = "0.1.0";
    lspServers = lib.mapAttrs (
      _name: server:
      {
        command = lib.head server.cmd;
        args = lib.tail server.cmd;
        inherit (server) extensionToLanguage;
      }
      // lib.optionalAttrs (server ? settings) { inherit (server) settings; }
    ) enabledServers;
  };

  lspPlugin = pkgs.writeTextDir ".claude-plugin/plugin.json" (builtins.toJSON lspPluginManifest);

  # User-level hooks live in ~/.claude/settings.json, which the CLI
  # mutates at runtime and a person may hand-edit, so they are
  # converged in at activation by a merge (lib/claude-hooks-register.nix)
  # rather than rendered as a store symlink.  Ownership follows the
  # claude-code-sandbox model: the declaration is a store manifest,
  # a sidecar under the XDG state dir records what was last applied,
  # and only entries in one of those two are ever touched -- so a
  # hook deleted from Nix is pruned, and a hand-added hook survives.
  # The emacs module's consent-gate registration keeps its own entry.
  claudeHooksRegister = import ./lib/claude-hooks-register.nix { inherit pkgs; };

  hooksSidecar = "${config.xdg.stateHome}/claude-hooks-register/applied.json";

  # Stop hook that turns the peer-programmer style's banned phrasings
  # a regex can catch ("X is yours", em-dashes, "click", ...) into a
  # two-step double-check: when the finished message matches an
  # enabled ticChecks entry the stop is blocked with each line and
  # rule and a request for a verdict line (clean / tic); a "tic"
  # verdict is blocked once more with a request to rewrite the
  # message (script: lib/claude-tic-check-hook.sh).
  ticCheckTable = lib.mapAttrsToList (name: check: {
    inherit name;
    inherit (check) pattern rule;
  }) (lib.filterAttrs (_name: check: check.enable) cfg.ticChecks);

  # The judge: a System One decision model that scores every finished
  # message (and every write to a prose file) on judge.dimensions.
  # The config below is what claude-response-judge reads; the hooks
  # read the thresholds from the same file.
  enabledDimensions = lib.filterAttrs (_name: dimension: dimension.enable) cfg.judge.dimensions;

  judgeChecks = import ./lib/judge-checks.nix;

  malformedDimensions = lib.attrNames (
    lib.filterAttrs (
      _name: dimension:
      if dimension.type == "score" then
        lib.length dimension.levels < 2 || lib.length dimension.levels > 10
      else
        dimension.criteria.true == null || dimension.criteria.false == null
    ) enabledDimensions
  );

  enabledEndpoints = lib.sort (a: b: a.order < b.order) (
    lib.mapAttrsToList (name: endpoint: endpoint // { inherit name; }) (
      lib.filterAttrs (_name: endpoint: endpoint.enable) cfg.judge.endpoints
    )
  );

  judgeConfig = {
    endpoints = map (endpoint: {
      inherit (endpoint)
        name
        url
        model
        apiKeyFile
        timeout
        wakeUnit
        ;
    }) enabledEndpoints;
    dimensions = lib.mapAttrs (_name: dimension: {
      inherit (dimension)
        type
        instructions
        criteria
        levels
        rule
        targets
        pushBack
        ;
    }) enabledDimensions;
    inherit (cfg.judge)
      pushBackAbove
      writePushBackAbove
      reportAbove
      turnScoresAbove
      maxChars
      proseExtensions
      load
      coinage
      ghosts
      familiarity
      references
      ;
  };

  # The judge tries the endpoints one after another, so a hook that
  # asks it may wait for every endpoint's timeout in turn.
  judgeHookTimeout = 10 + lib.foldl' (sum: endpoint: sum + endpoint.timeout) 0 enabledEndpoints;

  claudeTicCheckHook = import ./lib/claude-tic-check-hook.nix {
    inherit pkgs;
    checks = ticCheckTable;
    judge = judgeConfig;
    claude-response-judge = cfg.judge.package;
  };

  # Edit-side twin (PreToolUse on the disk and buffer writers): the
  # text a call writes is matched against the same table, and judged
  # when it goes to a prose file, and the call is denied once with the
  # findings; an identical re-issue passes (script:
  # lib/claude-tic-check-edit-hook.sh).
  claudeTicCheckEditHook = import ./lib/claude-tic-check-edit-hook.nix {
    inherit pkgs;
    checks = ticCheckTable;
    judge = judgeConfig;
    claude-response-judge = cfg.judge.package;
  };

  # PreToolUse on Bash: the commit message or pull request text a
  # command writes is matched and judged the same way, and the command
  # is denied once with the findings (script:
  # lib/claude-tic-check-message-hook.sh).
  claudeTicCheckMessageHook = import ./lib/claude-tic-check-message-hook.nix {
    inherit pkgs;
    checks = ticCheckTable;
    judge = judgeConfig;
    claude-response-judge = cfg.judge.package;
  };

  # PostToolUse on every tool: the messages written since the last
  # tool call are judged while the turn runs, and the verdict comes
  # back as a labeled note after the tool result (script:
  # lib/claude-tic-check-turn-hook.sh).
  claudeTicCheckTurnHook = import ./lib/claude-tic-check-turn-hook.nix {
    inherit pkgs;
    checks = ticCheckTable;
    judge = judgeConfig;
    claude-response-judge = cfg.judge.package;
  };

  # UserPromptSubmit: the judge's verdict on a message the Stop hook
  # let stand reaches the model with the next prompt, as context
  # (script: lib/claude-tic-check-context-hook.sh).
  claudeTicCheckContextHook = import ./lib/claude-tic-check-context-hook.nix {
    inherit pkgs;
    judge = judgeConfig;
  };

  claudeResponseJudge =
    pkgs.ch-ai-workbench.claude-response-judge or (throw ''
      ch-ai-workbench.claude-code needs `pkgs.ch-ai-workbench.claude-response-judge`:
      apply this flake's package overlay (`overlays.default`; a caisson
      consumer lists the flake in `projects`) to the nixpkgs instance
      home-manager uses.
    '');

  # Companion MessageDisplay hook: the tic-check reminder asks for a
  # verdict in a fixed line ("tic-check: clean" / "tic-check: tic"),
  # and this hook renders each as a short status line on screen
  # (display-only; the transcript keeps the token).  Script:
  # lib/claude-tic-check-display-hook.sh.
  claudeTicCheckDisplayHook = import ./lib/claude-tic-check-display-hook.nix { inherit pkgs; };

  # The three hooks the flake checks also drive come from this layer's
  # library (lib-overlays/default/hooks), so the checks and this module
  # install one script each.
  workbench = closure-lib.ch-ai-workbench;

  # PostToolUse on every tool: the string leaves of the result pass
  # through betterleaks and a finding replaces what the model sees, with a
  # note naming the rules (script: claude-redact-hook.sh; design:
  # docs/development/agent-elisp-isolation.md).
  claudeRedactHook = workbench.mkClaudeRedactHook { inherit pkgs; };

  # PreToolUse on Read and the emacs server's buffer-text and
  # buffer-diff, the retry half: an identical call after a redaction
  # asks the user through the consent spool whether the model may see
  # the real text; allow lets that one result through, for an MCP read
  # by adding an approval token the server checks
  # (script: claude-reveal-hook.sh).
  claudeRevealHook = workbench.mkClaudeRevealHook {
    inherit pkgs;
    claude-consent = claudeConsent;
  };

  # PreToolUse hook on Bash: a command that appears to run git push
  # is denied once with a reminder to confirm that the branch's pull
  # request,
  # if it has one, is not already merged (GitHub keeps accepting
  # pushes to a merged PR's head branch); the identical re-issue
  # passes and consumes the marker, so every push costs one check
  # (script: claude-push-pr-check-hook.sh).
  claudePushPrCheckHook = workbench.mkClaudePushPrCheckHook { inherit pkgs; };

  enabledHooks = lib.filterAttrs (_name: hook: hook.enable) cfg.hooks;

  # The prompt API behind the consent spool (`pkgs.ch-ai-workbench.claude-consent`,
  # from this flake's package overlay): `claude-consent ask` raises a
  # question from a hook and returns the answer, `answer`, `watch`, and
  # `list` are the user's terminal side. Installed here, vendor side,
  # because the spool is Claude Code's permission surface; the Emacs
  # answerer plugs in from emacs-integration.
  claudeConsent =
    pkgs.ch-ai-workbench.claude-consent or (throw ''
      ch-ai-workbench.claude-code needs `pkgs.ch-ai-workbench.claude-consent`:
      apply this flake's package overlay (`overlays.default`; a caisson
      consumer lists the flake in `projects`) to the nixpkgs instance
      home-manager uses.
    '');

  # The declaration as a store manifest: enabled hooks and the deny
  # rules, so a switched-off or deleted entry is absent from "new" and
  # the register prunes it against the sidecar's "base".
  #
  # A hook whose package this module installs is registered through the
  # home-manager profile's bin directory rather than by bare name. The
  # path is the same string in every generation, and it does not depend
  # on PATH: a checkout enrolled in claude-code-sandbox sets the Claude
  # Code process's PATH to its sandbox farms, which hooks inherit.
  hooksManifest = pkgs.writeText "claude-hooks-manifest.json" (
    builtins.toJSON {
      hooks = map (hook: {
        inherit (hook)
          event
          matcher
          timeout
          ;
        command =
          if hook.package != null && !(lib.hasPrefix "/" hook.command) then
            "${config.home.profileDirectory}/bin/${hook.command}"
          else
            hook.command;
      }) (lib.attrValues enabledHooks);
      permissions.deny = cfg.permissions.deny;
    }
  );

  # An output style on disk is YAML frontmatter plus a markdown body.
  # The description is emitted as a JSON string, which is a valid YAML
  # double-quoted scalar, so colons and quotes in it cannot break the
  # header. One file per style: the CLI's /config picker lists every
  # file under output-styles/ by its own name, so a second file for
  # the same style is a second, duplicate picker row, not an alias
  # (found 2026-08-24 after shipping exactly that). displayName, when
  # set, becomes the frontmatter name field on the SAME file — the
  # CLI keys a style by that field when present, and by the file name
  # otherwise (claude-cli.md § Output styles), so setting it trades
  # the attribute name away as a selectable key in exchange for the
  # Initial-Caps picker label.
  renderOutputStyle =
    name: style:
    pkgs.writeText "claude-output-style-${name}.md" ''
      ---
      description: ${builtins.toJSON style.description}
      keep-coding-instructions: ${lib.boolToString style.keepCodingInstructions}
      ${lib.optionalString (style.displayName != null) "name: ${builtins.toJSON style.displayName}\n"}---

      ${lib.concatStringsSep "\n" style.parts}'';
in
{
  options.ch-ai-workbench.claude-code = {
    enable = lib.mkEnableOption "shared Claude Code configuration";

    lspServers = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options.enable = lib.mkOption {
            type = lib.types.bool;
            default = true;
            description = "Whether the ch-lsp plugin includes this server.";
          };
        }
      );
      default = { };
      example = lib.literalExpression "{ ty-ruff.enable = false; }";
      description = ''
        Per-server toggles for the ch-lsp plugin, keyed by the shared
        language-server table's entry names. Merged across all modules
        that set it, so a downstream config can switch individual
        servers off.
      '';
    };

    skills = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to install this entry.";
            };

            source = lib.mkOption {
              type = lib.types.path;
              description = ''
                Directory installed as ~/.claude/skills/<name>: a skill
                (SKILL.md inside) or a skills-directory plugin
                (.claude-plugin/plugin.json inside). Claude Code follows
                the store symlink either way.
              '';
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression "{ deploy-runbook.source = ./skills/deploy-runbook; }";
      description = ''
        Entries installed into ~/.claude/skills/ (personal scope).
        Merged across all modules that set it, so a downstream config
        can add its own entries or switch an upstream one off with
        <name>.enable = false. This module seeds ch-lsp, the plugin
        carrying the shared language-server table.
      '';
    };

    outputStyles = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to install this style.";
            };

            description = lib.mkOption {
              type = lib.types.str;
              description = "One line shown beside the style in the /output-style picker.";
            };

            displayName = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "Peer Programmer";
              description = ''
                Initial-Caps label for the /config picker, matching the
                CLI's own built-in styles (Default, Explanatory,
                Learning): rendered as the frontmatter name field of
                this style's one file. The CLI keys a style by that
                field when present, so setting displayName means
                outputStyle must be set to it, not to the attribute
                name — the picker's row name and the settings value
                are the same string either way. Leave null to select
                and display the style by its attribute name (no
                frontmatter name field, so the picker falls back to
                the file name).
              '';
            };

            keepCodingInstructions = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = ''
                Keep Claude Code's own software-engineering instructions
                in the system prompt and append the style after them.
                False drops those instructions and leaves only the style
                text (the CLI's default for a bare file) — the shape for
                a style that redefines the job, not the voice.
              '';
            };

            parts = lib.mkOption {
              type = lib.types.listOf lib.types.lines;
              default = [ ];
              description = ''
                Markdown sections concatenated, in merge order, into the
                style body. Merged across all modules that set it (list
                concatenation), so a downstream config grafts its own
                sections onto a seeded style by adding to this list; the
                seeded body carries lib.mkBefore, so plain additions land
                after it, and lib.mkOrder places a part precisely.
              '';
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          # Graft a section onto a seeded style.
          peer-programmer.parts = [ (builtins.readFile ./house-conventions.md) ];
          # Define a new one.
          terse = {
            description = "Answers only, no narration";
            parts = [ "Reply with the answer and nothing else." ];
          };
        }
      '';
      description = ''
        Output styles rendered into ~/.claude/output-styles/<name>.md
        (personal scope): YAML frontmatter from the description,
        keepCodingInstructions, and displayName fields, then the
        parts. One file per style — the /config picker lists every
        file under output-styles/, so a second file for the same
        style is a duplicate row, not an alias. The selectable name
        (and the picker's label) is displayName when set, else the
        attribute name. Merged across all modules that set it, so a
        downstream config can add styles, graft parts onto seeded
        ones, or switch one off with <name>.enable = false. This
        module seeds iso-plain-language, asd-ste100, and
        peer-programmer, each with a displayName. Installing a style
        only makes it selectable; which one is active is runtime
        state in ~/.claude/settings.json (outputStyle) and is not
        managed here.
      '';
    };

    hooks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether to register this hook; false removes a previously registered entry.";
            };

            event = lib.mkOption {
              type = lib.types.str;
              example = "Stop";
              description = "Hook event as Claude Code spells it (Stop, PreToolUse, PostToolUse, ...).";
            };

            matcher = lib.mkOption {
              type = lib.types.nullOr lib.types.str;
              default = null;
              example = "Edit|Write";
              description = "Tool-name pattern for events that take one; null registers without a matcher.";
            };

            command = lib.mkOption {
              type = lib.types.str;
              example = "claude-yours-check-hook";
              description = ''
                Command line for the hook. With `package` set, a command
                that does not start with `/` names an executable of that
                package and is registered as
                `<home.profileDirectory>/bin/<command>`: the entry in
                the settings file stays the same across generations
                (a store path would change on every rebuild), and the
                hook runs whatever PATH the Claude Code process has. The
                registered command is the key a re-registration
                replaces.
              '';
            };

            package = lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = null;
              description = "Package installed into the profile; command is registered through the profile's bin directory.";
            };

            timeout = lib.mkOption {
              type = lib.types.nullOr lib.types.int;
              default = null;
              description = "Per-hook timeout in seconds; null leaves the CLI default (60).";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          # Switch off the seeded check.
          yours-check.enable = false;
          # Add one.
          log-bash = {
            event = "PreToolUse";
            matcher = "Bash";
            command = "my-bash-logger";
            package = pkgs.my-bash-logger;
          };
        }
      '';
      description = ''
        User-level (global) Claude Code hooks, converged into
        ~/.claude/settings.json at activation (the CLI rewrites that
        file at runtime, so it cannot be a store symlink). Ownership
        follows the claude-code-sandbox model: the enabled entries are
        rendered into a store manifest, a sidecar under
        $XDG_STATE_HOME/claude-hooks-register/ records what the last
        activation applied, and the merge touches only entries found
        in one of the two, keeping hand-added hooks in place and
        reporting them. Deleting an entry here, or setting
        <name>.enable = false, removes it from the file on the next
        activation; a hand-edited copy of a module hook is replaced
        (an entry is identified by its command). The same manifest
        carries permissions.deny. Merged across all modules that set
        it. This module seeds
        tic-check, the Stop hook driven by ticChecks and the judge,
        tic-check-turn, the PostToolUse hook that judges the messages
        written between tool calls while a turn runs and hands the
        verdict to the model as a note labeled "tic-check: mid-turn
        verdicts",
        tic-check-context, the UserPromptSubmit hook that hands the
        judge's verdict on a message the Stop hook let stand to the
        model with the next prompt, and
        tic-check-display, the MessageDisplay hook that renders that
        check's verdict lines ("tic-check: clean" / "tic-check: tic")
        as status lines on screen, tic-check-edit, the PreToolUse
        hook that applies the same table to the text written by Edit,
        Write, NotebookEdit, and the emacs server's edit verbs,
        tic-check-message, the PreToolUse hook on Bash that applies it
        to the commit message or pull request text a command writes, and
        redact, the PostToolUse hook that runs every tool result
        through betterleaks and replaces a recognized secret with
        [REDACTED:<rule>] before the model sees it, and reveal, the
        PreToolUse hook on Read that turns an identical re-issue of a
        redacted Read into a question to the user through the consent
        spool. It
        also seeds push-pr-check, the PreToolUse hook on Bash that
        denies a command that appears to run git push once with a reminder to
        confirm the branch's pull request is not already merged, and
        lets the identical re-issue through.
      '';
    };

    consentPackage = lib.mkOption {
      type = lib.types.package;
      default = claudeConsent;
      defaultText = lib.literalExpression "pkgs.ch-ai-workbench.claude-consent";
      description = ''
        The claude-consent tool: the prompt API hooks use to ask the
        user a question and get the answer back. A hook runs
        `claude-consent ask` with a title, options, and the hook
        payload on stdin; the question goes into the spool under
        $XDG_RUNTIME_DIR/claude-consent, any attached answerer (the
        Emacs side registered by claude-consent-mode, or a terminal
        running `claude-consent watch`) renders it as a menu, and the
        answer comes back to the hook as JSON. With no answerer
        attached a hook may fall back to the CLI's own permission
        prompt (`--fallback ask`), or the question is stored and
        answered later in a terminal with `claude-consent answer
        TOKEN`, the token naming the session. `ask --async -- CMD`
        returns at once and re-runs CMD with the answer when it lands.
        Installed into the profile so the terminal commands are on
        PATH and the hooks find it. Override to substitute a build.
      '';
    };

    permissions.deny = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      example = lib.literalExpression ''[ "Edit(/''${XDG_RUNTIME_DIR}/claude-consent/**)" ]'';
      description = ''
        User-level permissions.deny rules, converged into
        ~/.claude/settings.json by the same manifest-plus-sidecar merge
        as hooks: a rule is identified by its text, deleting one here
        removes it on the next activation, and hand-added rules stay in
        place. The literal ''${XDG_RUNTIME_DIR} is replaced at activation
        with the runtime dir (/run/user/<uid> when unset), since that
        path is not known at evaluation and a rule must name it
        concretely. Only deny rules are offered: at user scope a deny
        cannot be retracted by a project, so it is the one kind of rule
        that is safe to declare globally. Merged across all modules that
        set it.
      '';
    };

    ticChecks = lib.mkOption {
      type = lib.types.attrsOf (
        lib.types.submodule {
          options = {
            enable = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Whether the tic-check hook looks for this entry.";
            };

            pattern = lib.mkOption {
              type = lib.types.str;
              example = "\\byours\\b";
              description = "GNU grep extended regex, matched case-insensitively against the finished message's prose.";
            };

            rule = lib.mkOption {
              type = lib.types.str;
              example = "a handoff names the next action, not the owner";
              description = "One-line reminder returned to the model beside the matching lines.";
            };
          };
        }
      );
      default = { };
      example = lib.literalExpression ''
        {
          # Switch off a seeded entry.
          em-dash.enable = false;
          # Add one.
          leverage = {
            pattern = "\\bleverage\\b";
            rule = "say use";
          };
        }
      '';
      description = ''
        Phrasings the tic-check Stop hook (hooks.tic-check) looks for
        in every finished message, with code fences and backtick
        spans removed first. On a match the hook blocks the stop with
        a reason headed "tic-check: check" (what the checker emits
        whenever it fires, however confident it is) that hands the
        model each matching line with the entry's rule and asks for a
        verdict: exactly "tic-check: clean" (the message stands) or
        "tic-check: tic". A "tic" verdict is blocked once more, headed
        "tic-check: rewrite", with a request to post the message again
        without the phrasing; hooks.tic-check-display renders the
        verdict tokens as status lines. The verdict is the model's,
        so the check is a trigger, not the last word. The original
        cannot be withdrawn, since a hook's only channel back is the
        reason string. The same table drives hooks.tic-check-edit,
        which denies an edit or write once with the findings and lets
        an identical re-issue through. The judge (judge.*) feeds the
        same cycle with the rules a pattern cannot decide. Merged
        across all modules that set it. This module seeds the
        peer-programmer style's bans on a word or a character
        (lib/tic-checks.nix): elliptical-possessive, em-dash, click,
        arrow, relationship-words, grows, performed-enthusiasm.
      '';
    };

    judge = {
      package = lib.mkOption {
        type = lib.types.package;
        default = claudeResponseJudge;
        defaultText = lib.literalExpression "pkgs.ch-ai-workbench.claude-response-judge";
        description = ''
          The claude-response-judge client the tic-check hooks run: it
          sends a text and the enabled dimensions to the System One API
          (`POST /v1/systemone`) of the first endpoint that answers and
          prints the probability the model put on each dimension.
          Override to substitute a build.
        '';
      };

      endpoints = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether the judge tries this endpoint.";
              };

              order = lib.mkOption {
                type = lib.types.int;
                default = 1000;
                description = "Endpoints are tried in ascending order; the first that answers gives the verdict.";
              };

              url = lib.mkOption {
                type = lib.types.str;
                example = "http://127.0.0.1:8000";
                description = "Base URL; the judge posts to <url>/v1/systemone.";
              };

              model = lib.mkOption {
                type = lib.types.str;
                example = "decision-models/baseten-elephant-9b-latest";
                description = "The request's model field. A local decision-server serves one model and ignores it.";
              };

              apiKeyFile = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "/run/user/1000/secrets/baseten-api-key";
                description = ''
                  File holding the API key, read at each request and sent
                  as `Authorization: Api-Key <key>` (Baseten's scheme).
                  The judge skips the endpoint while the file is missing,
                  unreadable, or empty. A path string rather than a Nix
                  path, so the key stays out of the store.
                '';
              };

              timeout = lib.mkOption {
                type = lib.types.int;
                default = 30;
                description = ''
                  Seconds the judge waits for this endpoint before trying
                  the next. A server that is not running refuses the
                  connection at once and costs no wait. The hooks that run
                  the judge are registered with a timeout of 10 seconds
                  plus the sum over the enabled endpoints.
                '';
              };

              wakeUnit = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                example = "decision-server.service";
                description = ''
                  A systemd user unit that runs the server behind this
                  endpoint and is started on demand. The prompt hook and
                  the mid-turn hook start it with `systemctl --user start
                  --no-block` and do not wait, so a server that takes a
                  while to load is usually up by the time the turn ends.
                  Starting a unit that is already running does nothing.
                '';
              };
            };
          }
        );
        default = { };
        example = lib.literalExpression ''
          {
            # A decision-server on another port.
            local.url = "http://127.0.0.1:8010";
            # The cloud's smaller model.
            baseten.model = "decision-models/baseten-elephant-9b-latest";
          }
        '';
        description = ''
          System One endpoints the judge tries, in ascending order. This
          module seeds two. local is a decision-server from ch-local-llms
          (elephant-1, 9B) on this machine's GPU at its default port
          (http://127.0.0.1:8000); while none is running the connection is
          refused and the judge moves on at once. baseten is Base Labs'
          hosted API at https://inference.baseten.co with mammoth-1 (27B),
          the larger of the two decision models; its key is read from
          $XDG_CONFIG_HOME/baseten/api-key, and while that file does not
          exist the endpoint is skipped. With no endpoint answering, the
          hooks run on the regex table alone. Merged across all modules
          that set it.
        '';
      };

      dimensions = lib.mkOption {
        type = lib.types.attrsOf (
          lib.types.submodule {
            options = {
              enable = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = "Whether the judge asks this question.";
              };

              type = lib.mkOption {
                type = lib.types.enum [
                  "noul"
                  "score"
                ];
                default = "noul";
                description = ''
                  noul: a yes/no question (criteria.true and criteria.false)
                  whose answer is the probability that the problem is
                  present; it can push back. score: an ordered scale
                  (levels) whose answer is a probability for each level; it
                  is reported to the model as context and never pushes back.
                '';
              };

              instructions = lib.mkOption {
                type = lib.types.str;
                description = "The question the decision model answers about the text.";
              };

              criteria.true = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "For a noul: what the text looks like when the answer is yes (the problem is present).";
              };

              criteria.false = lib.mkOption {
                type = lib.types.nullOr lib.types.str;
                default = null;
                description = "For a noul: what the text looks like when the answer is no.";
              };

              levels = lib.mkOption {
                type = lib.types.listOf lib.types.str;
                default = [ ];
                description = "For a score: the levels of the scale, low to high, 2 to 10 of them.";
              };

              rule = lib.mkOption {
                type = lib.types.str;
                description = ''
                  One-line reminder returned to the model with this
                  dimension: for a noul when the judge pushes back or
                  reports it, for a score as the style's aim beside the
                  level the judge found.
                '';
              };

              targets = lib.mkOption {
                type = lib.types.listOf (
                  lib.types.enum [
                    "reply"
                    "progress"
                    "prose"
                    "code"
                    "message"
                  ]
                );
                default = [
                  "reply"
                  "progress"
                  "prose"
                  "message"
                ];
                description = ''
                  What the judge asks this question about: reply (a finished
                  turn), progress (the messages written between tool calls
                  during a turn, judged by hooks.tic-check-turn), prose (a write to a file with an extension in
                  judge.proseExtensions), code (a write to any other file),
                  and message (a commit message or pull request text a Bash
                  command writes). For prose, code, and message, the user's
                  latest messages from the session transcript are sent beside
                  the text, and for an edit also the text it replaces.
                '';
              };

              pushBack = lib.mkOption {
                type = lib.types.bool;
                default = true;
                description = ''
                  Whether a probability at or above judge.pushBackAbove
                  blocks the stop (or denies the edit) through the
                  tic-check cycle. False keeps the dimension to the
                  context report, for a question the model cannot answer
                  reliably from the message alone.
                '';
              };
            };
          }
        );
        default = { };
        description = ''
          The questions the judge asks about finished messages and
          writes to files (see targets). A noul dimension is a yes/no
          question of the System One API whose answer is the probability
          that the problem is present; at or above pushBackAbove it is a
          finding of the tic-check cycle ("tic-check: check", then the
          model's clean or tic verdict). A score dimension is an ordered
          scale whose answer is a probability per level; it never pushes
          back. When nothing pushes back, the noul dimensions at or above
          reportAbove and every score reach the model with the next prompt
          as context (hooks.tic-check-context). Merged across all modules
          that set it. This module seeds lib/judge-readability.nix (the
          score information-density, asked of replies and progress
          messages), and the peer-programmer style's rules that need
          judgment (lib/judge-dimensions.nix): arguing-with-ghosts (asked
          of writes only), final-message-recap (asked of finished turns
          only), count-obsession, staccato-pronouncements,
          rhetorical-hooks, grading-the-point, self-correction-narration,
          selling, fragments, process-narration, and undefined-terms
          (report only). Reading load, coined phrases, and references the
          reader cannot resolve are separate checks: judge.load,
          judge.coinage, and judge.references.
        '';
      };

      pushBackAbove = lib.mkOption {
        type = lib.types.float;
        default = 0.9;
        description = "Probability at or above which a dimension with pushBack set is a finding of the tic-check cycle, for a reply or a progress message.";
      };

      writePushBackAbove = lib.mkOption {
        type = lib.types.float;
        default = 0.7;
        description = ''
          Probability at or above which a dimension with pushBack set
          denies a write: an edit to a prose or code file, or a commit
          message, pull request text, or review. It is lower than
          pushBackAbove because a write stays in the repository after the
          turn, while a reply is read once.
        '';
      };

      reportAbove = lib.mkOption {
        type = lib.types.float;
        default = 0.5;
        description = ''
          Probability at or above which a dimension is listed in the
          context the model gets with the next prompt, when the Stop hook
          let the message stand. Set to 0 to report every dimension.
        '';
      };

      load = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = "Whether the Stop hook scores the reading load of the final message.";
        };

        reportAbove = lib.mkOption {
          type = lib.types.float;
          default = 7.15;
          description = ''
            Load at or above which the final message is reported with the
            next prompt. The load is ln(prose words + 1) + the judge's
            information-density score - 0.25 * ln(words of the prompt that
            opened the turn + 8), computed by claude-turn-load: each density
            level multiplies the words a message may spend by e, and a
            longer request earns a longer answer. At density 2.2 and no
            request, 7.15 is about 230 words.
          '';
        };

        pushBackAbove = lib.mkOption {
          type = lib.types.float;
          default = 8.0;
          description = "Load at or above which the final message is a finding of the tic-check cycle.";
        };

        rule = lib.mkOption {
          type = lib.types.str;
          default = "say less at once: lead with what the reader needs now, cut what they do not, and leave detail for when it is asked for";
          description = "Reminder returned with a load finding or report.";
        };
      };

      coinage = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether the Stop hook and the hooks on durable writes (prose
            files, commit messages, pull request texts) look for phrases
            the assistant coined. claude-coinage-check finds "the <word>"
            phrases at their second use when the assistant used them first,
            the user has used none of their words in any session, and
            earlier sessions rarely use them; the judge then scores each
            candidate's opacity on its own state.
          '';
        };

        instructions = lib.mkOption {
          type = lib.types.str;
          description = "The score question the judge answers about one candidate phrase.";
        };

        levels = lib.mkOption {
          type = lib.types.listOf lib.types.str;
          description = "The levels of that score, from an ordinary term to an opaque coined name.";
        };

        reportAbove = lib.mkOption {
          type = lib.types.float;
          default = 1.0;
          description = "Opacity score (expected level) at or above which a candidate is reported.";
        };

        pushBackAbove = lib.mkOption {
          type = lib.types.float;
          default = 1.4;
          description = "Opacity score at or above which a candidate in the final message is a finding that blocks the stop.";
        };

        writePushBackAbove = lib.mkOption {
          type = lib.types.float;
          default = 1.2;
          description = ''
            Opacity score at or above which a candidate in a write (a prose
            file, a commit message, a pull request text, a review) denies
            the write once. A phrase the session already judged below
            pushBackAbove is denied from its kept score when it reaches this
            level.
          '';
        };

        rule = lib.mkOption {
          type = lib.types.str;
          default = "do not coin names from generic words; use the real name (the function, the file, the option) or say plainly what the thing is";
          description = "Reminder returned with a coinage finding or report.";
        };
      };

      ghosts = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether the edit hook looks for sentences of a prose write that
            argue with ghosts. claude-ghost-check takes a sentence that
            narrates a correction or the history of the text, or one that
            states an absence or a non-change about something named in the
            latest messages from the user, and asks the judge whether a
            writer who never saw the replaced text or the conversation would
            write it.
          '';
        };

        instructions = lib.mkOption {
          type = lib.types.str;
          description = "The noul question the judge answers about one candidate sentence.";
        };

        criteria = lib.mkOption {
          type = lib.types.attrsOf lib.types.str;
          description = "The `true` and `false` criteria of that question.";
        };

        reportAbove = lib.mkOption {
          type = lib.types.float;
          default = 0.4;
          description = "Probability at or above which a sentence is reported after the write.";
        };

        pushBackAbove = lib.mkOption {
          type = lib.types.float;
          default = 0.6;
          description = "Probability at or above which a sentence denies the write once.";
        };

        rule = lib.mkOption {
          type = lib.types.str;
          description = "Reminder returned with a finding or report.";
        };
      };

      familiarity = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether the edit hook (prose files) and the message hook
            (commit messages, pull request texts, reviews) look for what a
            write leans on that only the conversation or the task showed.
            claude-familiarity-check takes the phrases about the work and
            the names of the write that the replaced text does not already
            hold, and asks the judge about each one: what a reader must know
            to resolve it, and whether the text briefly says what it is.
          '';
        };

        familiarity = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          description = "The score question, from general programming to this conversation or task.";
        };

        described = lib.mkOption {
          type = lib.types.attrsOf lib.types.anything;
          description = "The noul question whether the text briefly says what the candidate is.";
        };

        pushBackAbove = lib.mkOption {
          type = lib.types.float;
          default = 0.7;
          description = "Probability of the conversation level at or above which an undescribed candidate denies the write once.";
        };

        reportAbove = lib.mkOption {
          type = lib.types.float;
          default = 0.4;
          description = "Probability of the conversation level at or above which an undescribed candidate is reported after the write.";
        };

        describedBelow = lib.mkOption {
          type = lib.types.float;
          default = 0.8;
          description = "A candidate counts as undescribed when the described question is below this probability.";
        };

        rule = lib.mkOption {
          type = lib.types.str;
          default = "write for a reader who never saw the conversation: a file may lean on the codebase, and a pull request description ideally only on the ecosystem; give what only the chat or the work showed a brief description in the sentence that uses it, or leave it out, rather than making the text longer";
          description = "Reminder returned with a finding or report.";
        };
      };

      references = {
        enable = lib.mkOption {
          type = lib.types.bool;
          default = true;
          description = ''
            Whether the Stop hook looks for references the user cannot
            resolve. claude-reference-check flags definite references to
            work the user never saw ("the recording proxy", "their notes")
            that nothing earlier in the message anchors, and names that
            appear only in tool calls and output, outside anything the user
            has typed or been shown, when the judge confirms the reader can
            neither resolve them nor is expected to know them.
          '';
        };

        resolvable = lib.mkOption {
          type = lib.types.attrs;
          description = "The noul question whether the reader can tell what a tool-only name refers to.";
        };

        presupposed = lib.mkOption {
          type = lib.types.attrs;
          description = "The noul question whether the message uses a tool-only name as if the reader already knew it.";
        };

        flagAbove = lib.mkOption {
          type = lib.types.float;
          default = 0.44;
          description = "P(not resolvable) times P(presupposed) at or above which a tool-only name is flagged.";
        };

        blockAtFlags = lib.mkOption {
          type = lib.types.int;
          default = 2;
          description = "Number of flagged references at which the final message is a finding; fewer are reported with the next prompt.";
        };

        rule = lib.mkOption {
          type = lib.types.str;
          default = "give each reference the few words a reader who did not see the work needs: what the thing is and where it came from";
          description = "Reminder returned with a reference finding or report.";
        };
      };

      turnScoresAbove = lib.mkOption {
        type = lib.types.float;
        default = 1.0;
        description = ''
          Expected position on its scale (0 is the first level) at or above
          which a score is listed in the mid-turn note of
          hooks.tic-check-turn. The note after a finished turn lists every
          score; the mid-turn note, which can come after every tool call,
          lists only the scores that are off the first level by this much.
        '';
      };

      maxChars = lib.mkOption {
        type = lib.types.int;
        default = 40000;
        description = ''
          Longest text, after code blocks are replaced by a marker, the
          judge sends; a longer text is cut. elephant-1 was trained on
          prompts of at most 16,384 tokens, and a local decision-server
          refuses a longer one (the judge then tries the next endpoint).
        '';
      };

      proseExtensions = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [
          "md"
          "markdown"
          "org"
          "txt"
          "rst"
          "adoc"
        ];
        description = ''
          File extensions whose writes the judge reads as prose and asks
          the dimensions targeting prose. A write to any other file is
          read as code and asked the dimensions targeting code.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unknownServerNames == [ ];
        message = "ch-ai-workbench.lspServers names not in the language-server table: ${lib.concatStringsSep ", " unknownServerNames}";
      }
      {
        assertion = malformedDimensions == [ ];
        message = "ch-ai-workbench.claude-code.judge.dimensions: a noul needs criteria.true and criteria.false, a score 2 to 10 levels: ${lib.concatStringsSep ", " malformedDimensions}";
      }
      {
        assertion = duplicateClaims == { };
        message = "ch-ai-workbench: file extensions claimed by more than one enabled server (Claude Code would silently keep only the first): ${
          lib.concatStringsSep "; " (
            lib.mapAttrsToList (
              ext: claims: "${ext} -> ${lib.concatStringsSep ", " (map (claim: claim.name) claims)}"
            ) duplicateClaims
          )
        }";
      }
    ];

    ch-ai-workbench.claude-code.skills.ch-lsp.source = lspPlugin;

    # Voice presets, selectable per session with /output-style. The
    # bodies are plain markdown files (no frontmatter; the module
    # renders that) seeded with mkBefore so a consumer's parts append.
    ch-ai-workbench.claude-code.outputStyles = {
      iso-plain-language = {
        description = "ISO 24495-1 plain language — relevant, findable, understandable, usable";
        displayName = "ISO Plain Language";
        parts = lib.mkBefore [ (builtins.readFile ./output-styles/iso-plain-language.md) ];
      };
      asd-ste100 = {
        description = "ASD-STE100 Simplified Technical English (Issue 9) applied to replies";
        displayName = "ASD Simplified Technical English";
        parts = lib.mkBefore [ (builtins.readFile ./output-styles/asd-ste100.md) ];
      };
      peer-programmer = {
        description = "Peer-programmer communication: a working programmer who has not seen your reasoning and does not know the whole codebase";
        displayName = "Peer Programmer";
        parts = lib.mkBefore [ (builtins.readFile ./output-styles/peer-programmer.md) ];
      };
    };

    ch-ai-workbench.claude-code.ticChecks = import ./lib/tic-checks.nix;

    ch-ai-workbench.claude-code.judge.dimensions =
      import ./lib/judge-dimensions.nix // import ./lib/judge-readability.nix;

    ch-ai-workbench.claude-code.judge.coinage = {
      instructions = lib.mkDefault judgeChecks.coinage.instructions;
      levels = lib.mkDefault judgeChecks.coinage.levels;
    };

    ch-ai-workbench.claude-code.judge.ghosts = {
      instructions = lib.mkDefault judgeChecks.ghosts.instructions;
      criteria = lib.mkDefault judgeChecks.ghosts.criteria;
      rule = lib.mkDefault (import ./lib/judge-dimensions.nix).arguing-with-ghosts.rule;
    };

    ch-ai-workbench.claude-code.judge.familiarity = {
      familiarity = lib.mkDefault judgeChecks.familiarity.familiarity;
      described = lib.mkDefault judgeChecks.familiarity.described;
    };

    ch-ai-workbench.claude-code.judge.references = {
      resolvable = lib.mkDefault judgeChecks.references.resolvable;
      presupposed = lib.mkDefault judgeChecks.references.presupposed;
    };

    # The local GPU first, the cloud when it is not running. The fields
    # are defaults so a consumer can move either endpoint (another port,
    # the cloud's elephant-1) by setting the field.
    ch-ai-workbench.claude-code.judge.endpoints = {
      local = {
        order = lib.mkDefault 100;
        url = lib.mkDefault "http://127.0.0.1:8000";
        model = lib.mkDefault "elephant-1";
      };
      baseten = {
        order = lib.mkDefault 200;
        url = lib.mkDefault "https://inference.baseten.co";
        model = lib.mkDefault "decision-models/baseten-mammoth-27b-latest";
        apiKeyFile = lib.mkDefault "${config.xdg.configHome}/baseten/api-key";
      };
    };

    ch-ai-workbench.claude-code.hooks = {
      tic-check = {
        event = "Stop";
        command = "claude-tic-check-hook";
        package = claudeTicCheckHook;
        timeout = judgeHookTimeout;
      };
      tic-check-context = {
        event = "UserPromptSubmit";
        command = "claude-tic-check-context-hook";
        package = claudeTicCheckContextHook;
      };
      tic-check-display = {
        event = "MessageDisplay";
        command = "claude-tic-check-display-hook";
        package = claudeTicCheckDisplayHook;
      };
      tic-check-edit = {
        event = "PreToolUse";
        matcher = "Edit|Write|NotebookEdit|mcp__emacs__edit-file|mcp__emacs__edit-buffer";
        command = "claude-tic-check-edit-hook";
        package = claudeTicCheckEditHook;
        timeout = judgeHookTimeout;
      };
      tic-check-turn = {
        event = "PostToolUse";
        command = "claude-tic-check-turn-hook";
        package = claudeTicCheckTurnHook;
        timeout = judgeHookTimeout;
      };
      tic-check-message = {
        event = "PreToolUse";
        matcher = "Bash";
        command = "claude-tic-check-message-hook";
        package = claudeTicCheckMessageHook;
        timeout = judgeHookTimeout;
      };
      redact = {
        event = "PostToolUse";
        command = "claude-redact-hook";
        package = claudeRedactHook;
      };
      # Waits on a human; the deadline lives in the ask (300 s), the
      # declared timeout is only the liveness backstop above it.
      reveal = {
        event = "PreToolUse";
        matcher = "Read|mcp__emacs__buffer-text|mcp__emacs__buffer-diff";
        command = "claude-reveal-hook";
        package = claudeRevealHook;
        timeout = 3600;
      };
      push-pr-check = {
        event = "PreToolUse";
        matcher = "Bash";
        command = "claude-push-pr-check-hook";
        package = claudePushPrCheckHook;
      };
    };

    home.packages = [
      cfg.consentPackage
    ]
    ++ lib.filter (package: package != null) (
      lib.mapAttrsToList (_name: hook: hook.package) enabledHooks
    );

    home.activation.claudeCodeHooksRegister = lib.hm.dag.entryAfter [ "writeBoundary" ] ''
      run ${lib.getExe claudeHooksRegister} "$HOME/.claude/settings.json" \
        ${hooksManifest} ${lib.escapeShellArg hooksSidecar}
    '';

    # Claude Code writes per-checkout state under .claude/ inside the
    # checkout (agent worktrees, checkpoints, the per-machine settings
    # overlay, scheduler state). None of it is repo content, and it
    # appears in every clone the CLI is run in, so the exclusion is
    # global rather than one .gitignore per repo. home-manager writes
    # this list to $XDG_CONFIG_HOME/git/ignore, which git reads as the
    # default global excludes file. Only takes effect where
    # programs.git is enabled; this module does not enable it.
    programs.git.ignores = [
      "**/.claude/worktrees/"
      "**/.claude/checkpoints/"
      "**/.claude/mailbox/"
      "**/.claude/routines/.state/"
      "**/.claude/scheduled_tasks.json"
      "**/.claude/scheduled_tasks.lock"
      "**/.claude/agent-registry.json"
      "**/.claude/agent-memory-local"
      "**/.claude/assistant-daemon-state.json"
      "**/.claude/first-run"
      "**/.claude/settings.local.json"
      "**/.claude/.cc-writes/"
    ];

    home.file =
      lib.mapAttrs' (
        name: entry: lib.nameValuePair ".claude/skills/${name}" { inherit (entry) enable source; }
      ) cfg.skills
      // lib.mapAttrs' (
        name: style:
        lib.nameValuePair ".claude/output-styles/${name}.md" {
          inherit (style) enable;
          source = renderOutputStyle name style;
        }
      ) cfg.outputStyles;
  };
}
