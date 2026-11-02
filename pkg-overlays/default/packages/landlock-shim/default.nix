# SPDX-License-Identifier: MIT
# Landlock-based unix-socket narrowing that the home-manager module's
# socket shell wraps around the sandbox shell of every enrollment with a
# socket allowlist. Not meant to be invoked by hand. See the C source header for
# mechanism, ABI gating and failure posture.
{
  lib,
  stdenv,
  python3,
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

  nativeCheckInputs = [ python3 ];
  doCheck = true;
  checkPhase = ''
    runHook preCheck
    # Nix adds a scope-only Landlock layer without REFER. A descendant
    # filesystem ruleset activates that inherited denial on some kernels.
    # Exercise renames/links independently in the landlock-shim-vm check.
    python3 test_shim.py ./landlock-shim ShimTest.test_socket_allowlist_remains_enforced -v
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm555 landlock-shim "$out/bin/landlock-shim"
    runHook postInstall
  '';

  meta = {
    description = "Narrow execve and unix-socket connect() via Landlock, then exec";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    mainProgram = "landlock-shim";
  };
}
