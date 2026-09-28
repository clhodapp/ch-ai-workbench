# SPDX-License-Identifier: MIT
{
  python3Packages,
  lib,
}:
python3Packages.buildPythonApplication {
  pname = "claude-consent";
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
    description = "Prompt API for Claude Code hooks: a question spool with pluggable answerers";
    license = lib.licenses.mit;
    mainProgram = "claude-consent";
  };
}
