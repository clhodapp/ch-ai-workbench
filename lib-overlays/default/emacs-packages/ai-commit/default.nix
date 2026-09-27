# SPDX-License-Identifier: MIT
{ mkLocalBuild, version }:
mkLocalBuild {
  pname = "ai-commit";
  inherit version;
  packageRequires = [ ];
  src = ./.;
}
