# SPDX-License-Identifier: MIT
{ mkLocalBuild, version }:
mkLocalBuild {
  pname = "semantic-finder";
  inherit version;
  packageRequires = [ ];
  src = ./.;
}
