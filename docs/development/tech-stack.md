# Tech stack

Extends the workspace `tech-defaults.md`.

- **CLI**: Python, stdlib only (`json`, `argparse`, `pathlib`,
  `unittest`). The three-way merge wants real data handling and unit
  tests; no dependency tail is the point. Packaged with
  `buildPythonApplication` (pyproject/setuptools).
- **Flake**: ch-flake `mkLib`/`mkFlake`, caisson layout. Packages
  export through ch-nixpkgs overlays; checks and formatter live in
  partitions against `tests/dependencies`.
- **Home-manager module**: exported via
  `lib.ch-home-manager.mkHomeManagerModule`; options under
  `claude-code-sandbox.*`. Profile fragments are built at generation
  time (`writeClosure` → JSON via an inline python builder) and placed
  behind stable `$XDG_CONFIG_HOME` paths; per-profile bin farms are
  `buildEnv`s behind stable `~/.local/state` paths (fixed-path
  contract, same reasoning as ch-home-manager's user-shell).
- **Plugin**: a Claude Code skills-dir plugin (skill + hooks.json) as a
  `runCommand` derivation with the CLI store path substituted in.
