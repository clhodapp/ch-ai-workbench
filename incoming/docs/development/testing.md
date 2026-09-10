# Testing

- **Unit + CLI tests**: `unittest` under
  `pkgs/claude-code-sandbox/claude-code-sandbox/tests/`, executed in
  the package's `checkPhase` — building the package IS the test run,
  and `checks.<system>.package` exposes it to `nix flake check`.
- Fast local loop, from the package directory:

  ```zsh
  PYTHONPATH=src python3 -m unittest discover -s tests -v
  ```

- The merge engine is the correctness core: any change to
  `merge.py` needs a test for the affected rule (domain invariant,
  ad-hoc persistence, removal asymmetry, scalar authority, pruning,
  idempotence).
- Behavior against the real Claude Code sandbox (mask semantics, size
  ceiling, env delivery, permission-save co-ownership) was established
  empirically on 2026-08-22 and is documented in the module's header
  comment; re-verify against the live binary when Claude Code's
  sandboxing or settings machinery changes visibly.
