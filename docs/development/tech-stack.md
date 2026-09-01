# Tech stack

Extends the workspace `tech-defaults.md`.

- **CLI**: Python, stdlib only (`json`, `argparse`, `pathlib`,
  `unittest`). The three-way merge wants real data handling and unit
  tests; no dependency tail is the point. Packaged with
  `buildPythonApplication` (pyproject/setuptools).
- **Flake**: caisson `mkLib`/`mkFlake`
  ([github:nix-caisson/caisson](https://github.com/nix-caisson/caisson)),
  caisson layout. Packages export through ch-nixpkgs overlays; checks
  and formatter live in partitions against `tests/dependencies`.
- **Home-manager module**: registered with
  `lib.caisson-core.mkModule "homeManager"` and exported via
  `caisson.modules.homeManager.exported`; options under
  `claude-code-sandbox.*`. Profile fragments are built at generation
  time (`writeClosure` → JSON via an inline python builder) and placed
  behind stable `$XDG_CONFIG_HOME` paths; per-profile bin farms are
  `buildEnv`s referenced by exact store path inside fragments, so each
  enrolled checkout runs one consistent closure-generation (stable-path
  indirection would tear live sessions at switch).
- **Plugin**: a Claude Code skills-dir plugin (skill + hooks.json) as a
  `runCommand` derivation with the CLI store path substituted in.
