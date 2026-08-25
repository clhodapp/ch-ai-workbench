# SPDX-License-Identifier: LGPL-3.0-or-later
# Landlock-based narrowing (exec allowlist, unix-socket allowlist) that
# the home-manager module wraps around every profile's shell inside the
# sandbox. Not meant to be invoked by hand. See the C source header for
# mechanism, ABI gating and failure posture.
{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "landlock-shim";
  version = "0.2.0";

  src = ./.;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o landlock-shim landlock-shim.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm555 landlock-shim "$out/bin/landlock-shim"
    runHook postInstall
  '';

  meta = {
    description = "Narrow execve and unix-socket connect() via Landlock, then exec";
    license = lib.licenses.lgpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "landlock-shim";
  };
}
