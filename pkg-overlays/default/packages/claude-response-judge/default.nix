# SPDX-License-Identifier: MIT
{
  python3Packages,
  lib,
  git,
}:
python3Packages.buildPythonApplication {
  pname = "claude-response-judge";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = [ python3Packages.setuptools ];

  # The coinage and familiarity checks ask git whether the repository of
  # the session already uses a name (src/claude_response_judge/repo.py).
  makeWrapperArgs = [
    "--prefix"
    "PATH"
    ":"
    (lib.makeBinPath [ git ])
  ];
  nativeCheckInputs = [ git ];

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
