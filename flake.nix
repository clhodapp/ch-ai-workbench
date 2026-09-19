# SPDX-License-Identifier: MIT
{

  description = "An AI workbench in Emacs: agent sessions, Claude Code, and the editor wiring that joins them";

  # Honored only when this flake is evaluated directly (`nix build`,
  # `nix flake check`) and the settings are accepted: answer the prompt,
  # or pass `--accept-flake-config` (a non-interactive run otherwise
  # ignores them with a warning). A consumer that takes this flake as an
  # input gets nothing from it and must declare the caches itself. The
  # two upstreams are part of the deal: the clhodapp cache skips
  # uploading paths they already hold.
  nixConfig = {
    extra-substituters = [
      "https://clhodapp.cachix.org"
      "https://nix-community.cachix.org"
      "https://numtide.cachix.org"
    ];
    extra-trusted-public-keys = [
      "clhodapp.cachix.org-1:EW/0conxH0OQyo0o4ub/grdkFspholmQMSnQyj0vrZI="
      "nix-community.cachix.org-1:mB9FSh9qf2dCimDSUo8Zy7bkq5CX+/rkCWyvRCYg3Fs="
      "numtide.cachix.org-1:2ps1kLBUWjxIneOy1Ik6cQjb41X0iXVXeHigGmycPPE="
    ];
  };

  inputs = {
    caisson.url = "github:nix-caisson/caisson";

    # The editor this is a workbench in. Not an optional integration:
    # the bundles here are Emacs bundles and the hooks talk to a live
    # Emacs, so the dependency is what the thing is.
    ch-emacs-config.url = "github:clhodapp/ch-emacs-config";

    # Emacs packages consumed as plain sources.
    collab-comments.url = "github:clhodapp/collab-comments";
    collab-comments.flake = false;
    parenting.url = "github:clhodapp/parenting";
    parenting.flake = false;

    # The shell this layer adds one function to.
    ch-zsh-config.url = "github:clhodapp/ch-zsh-config";

    # The mermaid renderer behind the message-display hook.
    merman.url = "github:clhodapp/merman";

    nixpkgs.follows = "ch-emacs-config/nixpkgs";
  };

  outputs =
    inputs@{ caisson, ... }:
    let
      lib = caisson.lib.caisson-core.mkLib {
        inherit inputs;
        systems = [ "x86_64-linux" ];
        defaultEcosystemSrc.nixpkgs = inputs.nixpkgs;

        projects = {
          inherit caisson;
          ch-emacs-config = inputs.ch-emacs-config;
          ch-zsh-config = inputs.ch-zsh-config;
        };

        modules = lib: {
          homeManager = import ./modules/home-manager {
            inherit lib;
          };
        };
      };
    in
    lib.caisson.flake-parts.mkConfiguration {
      name = "ch-ai-workbench";
      configModule = lib.caisson.flake-parts.mkModule ./configs/flake-parts/default;
    };

}
