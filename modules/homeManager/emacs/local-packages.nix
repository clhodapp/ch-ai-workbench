# SPDX-License-Identifier: MIT
#
# The in-tree Emacs packages this layer adds, as overlays over the
# editor's package scope, grouped by the module that adds them (the
# same groups as bundles-spec.nix). Lists rather than attrsets because
# that is what both consumers take: each module feeds its group to
# `localPackageOverlays`, and the checks feed every group to the same
# argument on `package-scope.nix`. Keeping one definition is the point;
# a check built against a different package set than the modules
# produce would pass while the real configuration broke.
#
# The overlays share one fixed point, so claude-queue reaches
# semantic-finder through `final` whichever group defined it.
{
  emacs = [
    (final: _prev: {
      semantic-finder = final.epkgs.callPackage ./packages/semantic-finder {
        inherit (final) mkLocalBuild;
        version = final.epkgs.emacs.version or "0";
      };
      ai-commit = final.epkgs.callPackage ./packages/ai-commit {
        inherit (final) mkLocalBuild;
        version = final.epkgs.emacs.version or "0";
      };
    })
  ];

  claude = [
    (final: _prev: {
      claude-queue = final.epkgs.callPackage ./packages/claude-queue {
        inherit (final) mkLocalBuild semantic-finder;
        version = final.epkgs.emacs.version or "0";
      };
    })
  ];
}
