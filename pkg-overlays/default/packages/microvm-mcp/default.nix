# SPDX-License-Identifier: MIT
#
# The program `microvm-mcp`: the MCP server `microvm`, which lets a
# Claude Code session lease, start and stop the microvm guests of the
# user and use the tools of the guests that serve MCP. It builds on the
# library `ch_microvm` of the package `pkgs.ch-microvm.ch-microvm`,
# which the package overlay `ch-microvm/default` provides. The package
# overlay of this layer imports that overlay. The program reads its
# kinds from the file `MICROVM_MCP_CONFIG` names. The home-manager
# module `microvm` writes that file from its options and wraps this
# package with it.
{
  python3Packages,
  lib,
  ch-microvm,
}:
python3Packages.buildPythonApplication {
  pname = "microvm-mcp";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = [ python3Packages.setuptools ];

  dependencies = [ ch-microvm.ch-microvm ];

  checkPhase = ''
    runHook preCheck
    python -m unittest discover -s tests -v
    runHook postCheck
  '';

  meta = {
    description = "The MCP server that leases microvm guests of the user to Claude Code sessions";
    license = lib.licenses.mit;
    mainProgram = "microvm-mcp";
  };
}
