# SPDX-License-Identifier: MIT
{
  python3Packages,
  lib,
}:
python3Packages.buildPythonApplication {
  pname = "agent-config";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = [ python3Packages.setuptools ];

  # tomlkit keeps the comments and layout of a TOML file through a
  # merge; the standard library only reads TOML.
  dependencies = [ python3Packages.tomlkit ];

  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';

  meta = {
    description = "Converge declared settings into the JSON and TOML config files coding agents also write";
    license = lib.licenses.mit;
    mainProgram = "agent-config";
  };
}
