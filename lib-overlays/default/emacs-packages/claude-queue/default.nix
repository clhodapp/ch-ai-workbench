# SPDX-License-Identifier: MIT
{
  nemacsBuild,
  version,
  semantic-finder,
}:
nemacsBuild {
  pname = "claude-queue";
  inherit version;
  packageRequires = [ semantic-finder ];
  src = ./.;
}
