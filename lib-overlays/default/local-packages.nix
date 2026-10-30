# SPDX-License-Identifier: MIT
#
# The in-tree Emacs packages this layer adds, as overlays over the
# editor's package scope, grouped by the module that adds them (the
# same groups as bundle-spec.nix), published as
# `lib.ch-ai-workbench.localPackageOverlays`. Lists rather than attrsets
# because that is what both consumers take: each module feeds its group
# to `localPackageOverlays`, and the checks feed every group to the same
# argument on the package scope. Keeping one definition is the point;
# a check built against a different package set than the modules
# produce would pass while the real configuration broke.
#
# The overlays share one fixed point, so claude-queue reaches
# semantic-finder through `final` whichever group defined it.
{
  emacs = [
    (final: _prev: {
      semantic-finder = final.epkgs.callPackage ./emacs-packages/semantic-finder {
        inherit (final) mkLocalBuild;
        version = final.epkgs.emacs.version or "0";
      };
      ai-commit = final.epkgs.callPackage ./emacs-packages/ai-commit {
        inherit (final) mkLocalBuild;
        version = final.epkgs.emacs.version or "0";
      };
    })
  ];

  claude = [
    (final: _prev: {
      claude-queue = final.epkgs.callPackage ./emacs-packages/claude-queue {
        inherit (final) mkLocalBuild semantic-finder;
        version = final.epkgs.emacs.version or "0";
      };
      # gh-review is the editor's own package; this layer adds the
      # Claude side of a review on top of it.
      gh-review-claude = final.epkgs.callPackage ./emacs-packages/gh-review-claude {
        inherit (final)
          mkLocalBuild
          gh-review
          claude-queue
          semantic-finder
          ;
        version = final.epkgs.emacs.version or "0";
      };
    })
  ];
}
