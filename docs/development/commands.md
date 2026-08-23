# Commands

From this project's directory:

```zsh
nix flake check            # build CLI (runs unittest) + plugin
nix build '.#claude-code-sandbox'
nix build '.#claude-code-sandbox-plugin'
nix fmt
```

Fast Python loop (no nix rebuild), from
`pkgs/claude-code-sandbox/claude-code-sandbox/`:

```zsh
PYTHONPATH=src python3 -m unittest discover -s tests -v
```

Run the CLI against a scratch registry by pointing
`CLAUDE_CODE_SANDBOX_CONFIG` at a directory containing a
`registry.json` (see `tests/test_cli.py` for the shape).
