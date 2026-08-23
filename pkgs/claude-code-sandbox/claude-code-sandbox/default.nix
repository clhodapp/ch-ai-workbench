# SPDX-License-Identifier: LGPL-3.0-or-later
{ python3Packages, lib }:
python3Packages.buildPythonApplication {
  pname = "claude-code-sandbox";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = [ python3Packages.setuptools ];

  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';

  meta = {
    description = "Nix-authored per-project configuration for Claude Code's native sandbox";
    license = lib.licenses.lgpl3Plus;
    mainProgram = "claude-code-sandbox";
  };
}
