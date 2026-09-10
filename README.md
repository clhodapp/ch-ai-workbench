# ch-ai-workbench

An AI workbench in Emacs: the agent tooling, the Claude Code
configuration, and the wiring that joins them, as Home Manager modules
layered on
[ch-emacs-config](https://github.com/clhodapp/ch-emacs-config).

It is one repo rather than one per tool because a workbench is one
thing. Splitting it by which program each piece configures would put the
hook, the skill it documents, the shell function that calls it, and the
Emacs command it drives in four places, with an interface between every
pair.

## What it adds to the editor

**Agent sessions in Emacs.** `claude-queue` runs and tracks sessions,
following a session's working directory as it moves. `agent-shell` and
`acp` speak to agents over their own protocols. `parenting` spawns and
supervises child Emacs instances.

**An MCP server.** Emacs exposes its own tools (diagnostics, references,
buffer text, edits) to an agent over MCP, with a stable `emacs-mcp-stdio`
command that clients register once and keeps working across updates.

**Retrieval by description.** `semantic-finder` ranks buffers, windows,
and frames by an embedding of what they contain, bound to the `?` key in
each leader namespace as the semantic sibling of the `/` literal layer.

**Review threads.** `collab-comments` holds comment threads on shared
text, so a person and an agent can leave each other notes in place.

**A declarative Claude Code.** Hooks, skills, output styles, permission
rules, and an LSP plugin, built from Nix rather than edited into
`~/.claude/settings.json` by hand. The CLI writes that file at runtime,
so the module converges instead of overwriting: it renders what you
declared into a manifest, merges that into the live settings, and leaves
anything you added by hand alone.

**A sandbox for Claude Code.** Named sandbox profiles, each a closed
toolset compiled from Nix closures into the CLI's native sandbox
rules, that a checkout opts into by enrollment. Enforcement is Claude
Code's own; Nix authors its configuration. Design and boundaries in
[`docs/development/claude-code-sandbox.md`](docs/development/claude-code-sandbox.md).

**The two halves talking.** A session's working directory follows into
Emacs, an edit-consent gate answers from a spool Emacs writes, mermaid
blocks render in message display, and the `emacs-tools` skill documents
the MCP tools for the agent reading them.

## Use it

```nix
{
  inputs.ch-ai-workbench.url = "github:clhodapp/ch-ai-workbench";

  # in a Home Manager configuration, alongside the editor:
  #   ch-emacs-config.emacs.enable = true;
  #   ch-ai-workbench.emacs.enable = true;     # vendor-neutral bundles
  #   ch-ai-workbench.gptel.enable = true;     # gptel, plus .backend/.model
  #   ch-ai-workbench.claude.enable = true;    # Claude Code in Emacs; needs .emacs
  #   ch-ai-workbench.claude-code.enable = true;
  #   ch-ai-workbench.claude-code-sandbox.enable = true;  # plus .runtime.claudePackage and .profiles
  #   ch-ai-workbench.emacs-integration.enable = true;
}
```

The Emacs half contributes to the editor's own options, so both layers
produce one Emacs with one init rather than two configurations
competing.

Every hook fails open: a dead Emacs, an unparseable payload, or a
missing `emacsclient` leaves the session running, since a session must
never block on the editor. That is also why the integration asserts on
`emacsclient` rather than discovering it. Without the assertion it would
install cleanly and quietly do nothing.

## Development

`nix flake check` evaluates both layers into one Home Manager
configuration and builds the Emacs it produces, which is the check that
this layer composes with the editor rather than merely parsing. It then
runs the ERT suites for the packages defined here against that Emacs,
drives each Claude Code hook with synthetic payloads, and builds the
sandbox CLI (its unittest suite runs in the build), plugin, and shim.

`nix fmt` formats.

## Binary cache

The check builds the editor, whose compiled package set
`ch-emacs-config`'s `main` pushes to the `clhodapp` cachix cache. The
flake's `nixConfig` declares that cache and its two upstreams (the cache
skips uploading paths they already hold), so a direct `nix flake check`
at the same pins, run with `--accept-flake-config` or after answering
Nix's prompt, substitutes the editor instead of native-compiling it:

| Substituter | Public key |
|---|---|
| `https://clhodapp.cachix.org` | `clhodapp.cachix.org-1:EW/0conxH0OQyo0o4ub/grdkFspholmQMSnQyj0vrZI=` |
| `https://nix-community.cachix.org` | `nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs=` |
| `https://numtide.cachix.org` | `numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE=` |

A flake that consumes this one as an input must add them to its own
`extra-substituters` and `extra-trusted-public-keys`; Nix does not carry
an input's settings into the consumer.

## License

MIT, see [`LICENSE`](LICENSE).
