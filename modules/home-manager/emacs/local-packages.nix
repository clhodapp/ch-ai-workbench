# SPDX-License-Identifier: MIT
#
# The in-tree Emacs packages this layer adds, as overlays over the
# editor's package scope. A list rather than an attrset because that is
# what both consumers take: the module feeds it to
# `localPackageOverlays`, and the checks feed it to the same argument on
# `package-scope.nix`. Keeping one definition is the point; a check
# built against a different package set than the module produces would
# pass while the real configuration broke.
[
  (final: _prev: {
    semantic-finder = final.epkgs.callPackage ./packages/semantic-finder {
      inherit (final) mkLocalBuild;
      version = final.epkgs.emacs.version or "0";
    };
    ai-commit = final.epkgs.callPackage ./packages/ai-commit {
      inherit (final) mkLocalBuild;
      version = final.epkgs.emacs.version or "0";
    };
    claude-queue = final.epkgs.callPackage ./packages/claude-queue {
      inherit (final) mkLocalBuild semantic-finder;
      version = final.epkgs.emacs.version or "0";
    };
  })
]
