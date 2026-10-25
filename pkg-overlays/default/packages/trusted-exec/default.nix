# SPDX-License-Identifier: MIT
# Both sides of a claude-code-sandbox trusted executable: the stub side
# (`call`) and the service side (`serve`). The home-manager module wires
# both: a stub per granted executable on a sandboxed PATH, and a
# socket-activated systemd user service per declared executable. See
# src/main.rs for the mechanism and src/protocol.rs for the frames. The
# build runs the integration tests, which drive `call` against `serve`
# over a real unix socket.
{
  lib,
  rustPlatform,
}:
rustPlatform.buildRustPackage {
  pname = "trusted-exec";
  version = "0.1.0";

  src = lib.cleanSource ./.;

  cargoLock.lockFile = ./Cargo.lock;

  meta = {
    description = "Run a trusted executable outside Claude Code's sandbox through a unix socket, streaming its IO";
    license = lib.licenses.mit;
    platforms = [
      "x86_64-linux"
      "aarch64-linux"
    ];
    mainProgram = "trusted-exec";
  };
}
