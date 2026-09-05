# SPDX-License-Identifier: MIT
{

  description = "An AI workbench in Emacs: agent sessions, Claude Code, and the editor wiring that joins them";

  inputs = {
    caisson.url = "github:nix-caisson/caisson";

    # The editor this is a workbench in. Not an optional integration:
    # the bundles here are Emacs bundles and the hooks talk to a live
    # Emacs, so the dependency is what the thing is.
    # Pinned to the branch until the four-repo shape lands on main.
    ch-emacs-config.url = "github:clhodapp/ch-emacs-config/feature/four-repo-shape";

    # Emacs packages consumed as plain sources.
    collab-comments.url = "github:clhodapp/collab-comments";
    collab-comments.flake = false;
    parenting.url = "github:clhodapp/parenting";
    parenting.flake = false;

    # The shell this layer adds one function to.
    ch-zsh-config.url = "github:clhodapp/ch-zsh-config/feature/drop-workbench-half";

    # The mermaid renderer behind the message-display hook.
    merman.url = "github:clhodapp/merman";

    nixpkgs.follows = "ch-emacs-config/nixpkgs";
  };

  outputs =
    inputs@{ caisson, ... }:
    let
      lib = caisson.lib.caisson-core.mkLib {
        inherit inputs;

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
    lib.caisson.mkFlake {
      name = "ch-ai-workbench";
      configModule = lib.caisson.mkFlakeModule ./configs/flake-parts/default;
    };

}
