# SPDX-License-Identifier: MIT
#
# The `microvm` program: it leases the microvm guest slots of a machine
# to Claude Code sessions, starts and stops their units, and serves them
# to agents as the MCP server `microvm`. The program reads the kinds of
# guests from the file `MICROVM_CONFIG` names. The home-manager module
# `microvm` writes that file from its options and wraps this package
# with it, so this package alone controls no slots.
{
  python3Packages,
  lib,
}:
python3Packages.buildPythonApplication {
  pname = "microvm";
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
    description = "Lease, start and stop the microvm guest slots of a machine for Claude Code sessions";
    license = lib.licenses.mit;
    mainProgram = "microvm";
  };
}
