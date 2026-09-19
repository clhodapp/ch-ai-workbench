# SPDX-License-Identifier: MIT
#
# The vendor-neutral half of the workbench in Emacs: the bundles that
# turn the editor into a place to run agent sessions without naming one
# vendor (comment threads, the semantic finder, parenting, the ACP
# agent shell, commit messages, the ghostel environment handoff), plus
# the local packages two of them need. The gptel and claude modules
# beside this one add their own bundles on top. Everything here is
# contributed to ch-emacs-config's own options, so a configuration
# importing both gets one Emacs with both layers' bundles rather than
# two configurations fighting.
{ closure-inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.emacs;

  merman = closure-inputs.merman-nix.packages.${pkgs.stdenv.hostPlatform.system}.merman;
in
{
  options.ch-ai-workbench.emacs = {
    enable = lib.mkEnableOption "the vendor-neutral Emacs half of the AI workbench";
  };

  config = lib.mkIf cfg.enable {
    # The two Emacs packages this layer takes as plain sources, added to
    # the editor's package set so the bundles can name them. The editor
    # composes this after its own overrides, so they build against the
    # same Emacs as everything else here.
    ch-emacs-config.emacs.extraOverrides = [
      (self: _super: {
        collab-comments = self.callPackage ../../../pkgs/emacs/collab-comments/package.nix {
          src = closure-inputs.collab-comments;
        };
        parenting = self.callPackage ../../../pkgs/emacs/parenting/package.nix {
          src = closure-inputs.parenting;
        };
      })
    ];

    ch-emacs-config.emacs.localPackageOverlays = (import ./local-packages.nix).emacs;

    # `enable` is wrapped here rather than in the spec: the spec is also
    # read as plain data by the checks, where a priority wrapper is not
    # a boolean. mkDefault so a consumer can switch a bundle off.
    ch-emacs-config.emacs.bundles =
      lib.mapAttrs (_name: bundle: bundle // { enable = lib.mkDefault bundle.enable; })
        (import ./bundles-spec.nix {
          inherit lib merman;
          gitleaks = pkgs.gitleaks;
          readInit = name: builtins.readFile ./inits/${name};
        }).emacs;
  };
}
