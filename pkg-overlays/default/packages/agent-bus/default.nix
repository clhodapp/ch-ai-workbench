# SPDX-License-Identifier: MIT
# The agent bus: the per-user daemon, the MCP server each session's harness
# starts, and the operator's CLI, as one binary. Built with the dependencies
# that `cargo-purifier lock` recorded; `passthru.tests` runs the end-to-end
# tests in tests/bus.rs, which drive a real daemon over a unix socket. The
# design is in ch-nix-workspace's docs/development/agent-bus.md.
{
  cargo-purifier,
  lib,
  pkg-config,
  sqlite,
}:
let
  # nixpkgs' cargoSetupHook sets LIBSQLITE3_SYS_USE_PKG_CONFIG=1, so
  # libsqlite3-sys links the SQLite of nixpkgs, found through pkg-config,
  # in place of the copy rusqlite's `bundled` feature builds.
  withSqlite =
    drv:
    drv.overrideAttrs (old: {
      nativeBuildInputs = (old.nativeBuildInputs or [ ]) ++ [ pkg-config ];
      buildInputs = (old.buildInputs or [ ]) ++ [ sqlite ];
    });

  project = cargo-purifier.buildCargoProject {
    src = lib.fileset.toSource {
      root = ./.;
      fileset = lib.fileset.unions [
        ./Cargo.toml
        ./Cargo.lock
        ./cargo-purifier.lock.json
        ./src
        ./tests
      ];
    };
    # Evaluation reads both lockfiles. Read from `src`, they would come from
    # the filtered copy, which `nix flake check --no-build` names without
    # writing it to the store; these paths are in the flake's source.
    cargoLock = ./Cargo.lock;
    lockFile = ./cargo-purifier.lock.json;
  };
in
(withSqlite project.packages.agent-bus).overrideAttrs (old: {
  passthru = (old.passthru or { }) // {
    tests = withSqlite project.tests;
  };
  meta = (old.meta or { }) // {
    description = "Coordination bus for agent sessions across harnesses: daemon, MCP server and CLI";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "agent-bus";
  };
})
