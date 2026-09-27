# SPDX-License-Identifier: MIT
#
# The agent half of the workbench: the hooks, skills, output styles and
# permissions a Claude Code session runs under, and the LSP plugin
# manifest it reads.
{ closure-inputs, closure-lib, ... }:
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
    merman = closure-inputs.merman-nix.packages.${pkgs.stdenv.hostPlatform.system}.merman-preview;
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

  claudeTicCheckHook = import ./lib/claude-tic-check-hook.nix {
    inherit pkgs;
    checks = ticCheckTable;
  };

  # Edit-side twin (PreToolUse on the disk and buffer writers): the
  # text a call writes is matched against the same table and the
  # call is denied once with the findings; an identical re-issue
  # passes (script: lib/claude-tic-check-edit-hook.sh).
  claudeTicCheckEditHook = import ./lib/claude-tic-check-edit-hook.nix {
    inherit pkgs;
    checks = ticCheckTable;
  };

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

  # PreToolUse on Read, the retry half: an identical Read after a
  # redaction asks the user through the consent spool whether the model
  # may see the real text; allow lets that one result through
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
  hooksManifest = pkgs.writeText "claude-hooks-manifest.json" (
    builtins.toJSON {
      hooks = map (hook: {
        inherit (hook)
          event
          matcher
          command
          timeout
          ;
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
                Command line registered for the hook, and the key a
                re-registration replaces. A bare name resolved on PATH
                (see package) keeps the settings entry stable across
                generations; a store path would go stale in the file
                on every rebuild.
              '';
            };

            package = lib.mkOption {
              type = lib.types.nullOr lib.types.package;
              default = null;
              description = "Package installed into the profile so that command resolves on PATH.";
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
        tic-check, the Stop hook driven by ticChecks, and
        tic-check-display, the MessageDisplay hook that renders that
        check's verdict lines ("tic-check: clean" / "tic-check: tic")
        as status lines on screen, tic-check-edit, the PreToolUse
        hook that applies the same table to the text written by Edit,
        Write, NotebookEdit, and the emacs server's edit verbs, and
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
        an identical re-issue through. Merged across all
        modules that set it. This module seeds the peer-programmer
        style's regex-catchable bans (lib/tic-checks.nix):
        elliptical-possessive, em-dash, click, arrow,
        relationship-words, performed-enthusiasm.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = unknownServerNames == [ ];
        message = "ch-ai-workbench.lspServers names not in the language-server table: ${lib.concatStringsSep ", " unknownServerNames}";
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

    ch-ai-workbench.claude-code.hooks = {
      tic-check = {
        event = "Stop";
        command = "claude-tic-check-hook";
        package = claudeTicCheckHook;
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
        matcher = "Read";
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
