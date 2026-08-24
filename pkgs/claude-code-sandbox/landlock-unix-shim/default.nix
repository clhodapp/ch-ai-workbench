# SPDX-License-Identifier: LGPL-3.0-or-later
# Landlock-based pathname-unix-socket allowlist enforcer. The
# home-manager module wraps it around a profile's shell when the
# profile declares a socket allowlist; it is not meant to be invoked by
# hand. See the C source header for mechanism and failure posture.
{
  lib,
  stdenv,
}:
stdenv.mkDerivation {
  pname = "landlock-unix-shim";
  version = "0.1.0";

  src = ./.;

  buildPhase = ''
    runHook preBuild
    $CC -O2 -Wall -Wextra -o landlock-unix-shim landlock-unix-shim.c
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm555 landlock-unix-shim "$out/bin/landlock-unix-shim"
    runHook postInstall
  '';

  meta = {
    description = "Allowlist pathname unix-socket connect() via Landlock RESOLVE_UNIX, then exec";
    license = lib.licenses.lgpl3Plus;
    platforms = lib.platforms.linux;
    mainProgram = "landlock-unix-shim";
  };
}
