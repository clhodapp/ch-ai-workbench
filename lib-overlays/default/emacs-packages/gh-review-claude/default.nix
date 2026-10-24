# SPDX-License-Identifier: MIT
{
  mkLocalBuild,
  version,
  gh-review,
  claude-queue,
  semantic-finder,
}:
mkLocalBuild {
  pname = "gh-review-claude";
  inherit version;
  packageRequires = [
    gh-review
    claude-queue
    semantic-finder
  ];
  src = ./.;
}
