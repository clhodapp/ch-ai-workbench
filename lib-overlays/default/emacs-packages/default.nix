# SPDX-License-Identifier: MIT
#
# The in-tree Emacs packages this layer adds, as an overlay on the
# editor's nemacs package set: each is built with the set's
# `nemacsBuild`, at the version of its Emacs, and lands in the set under
# its own name. The set is one fixed point with the editor's own
# packages, so gh-review-claude reaches the editor's gh-review through
# `final`.
final: _prev:
let
  version = final.emacs.version or "0";
in
{
  semantic-finder = final.callPackage ./semantic-finder { inherit version; };
  ai-commit = final.callPackage ./ai-commit { inherit version; };
  claude-queue = final.callPackage ./claude-queue { inherit version; };
  gh-review-claude = final.callPackage ./gh-review-claude { inherit version; };
}
