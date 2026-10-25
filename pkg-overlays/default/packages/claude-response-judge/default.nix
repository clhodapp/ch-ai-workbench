# SPDX-License-Identifier: MIT
{
  python3Packages,
  lib,
}:
python3Packages.buildPythonApplication {
  pname = "claude-response-judge";
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
    description = "Ask a System One decision model how likely each listed problem is in a text";
    license = lib.licenses.mit;
    mainProgram = "claude-response-judge";
  };
}
