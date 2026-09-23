# SPDX-License-Identifier: MIT
{
  mkLocalBuild,
  version,
  semantic-finder,
}:
mkLocalBuild {
  pname = "claude-queue";
  inherit version;
  packageRequires = [ semantic-finder ];
  src = ./.;
}
