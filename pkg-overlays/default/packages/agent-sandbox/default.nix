# SPDX-License-Identifier: MIT
{
  python3Packages,
  lib,
  git,
  agent-config,
}:
python3Packages.buildPythonApplication {
  pname = "agent-sandbox";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = [ python3Packages.setuptools ];

  # The session-start hook locates a checkout's git dir via `git
  # rev-parse`; the tests exercise it against a real repository.
  nativeCheckInputs = [ git agent-config ];

  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';

  meta = {
    description = "Nix-authored per-project sandbox policies for coding agents";
    license = lib.licenses.mit;
    mainProgram = "agent-sandbox";
  };
}
