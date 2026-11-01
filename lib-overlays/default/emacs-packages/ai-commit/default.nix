# SPDX-License-Identifier: MIT
{ nemacsBuild, version }:
nemacsBuild {
  pname = "ai-commit";
  inherit version;
  packageRequires = [ ];
  src = ./.;
}
