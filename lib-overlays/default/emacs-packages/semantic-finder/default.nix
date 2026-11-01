# SPDX-License-Identifier: MIT
{ nemacsBuild, version }:
nemacsBuild {
  pname = "semantic-finder";
  inherit version;
  packageRequires = [ ];
  src = ./.;
}
