# SPDX-License-Identifier: MIT
{
  nemacsBuild,
  version,
  gh-review,
  claude-queue,
  semantic-finder,
}:
nemacsBuild {
  pname = "gh-review-claude";
  inherit version;
  packageRequires = [
    gh-review
    claude-queue
    semantic-finder
  ];
  src = ./.;
}
