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
    merman-nix.url = "github:clhodapp/merman-nix";

    # The on-demand microvm guests of the user, which the MCP server
    # `microvm` leases to sessions.
    ch-microvm.url = "github:clhodapp/ch-microvm";

    nixpkgs.follows = "ch-emacs-config/nixpkgs";

    # The library comes from the nixpkgs.lib mirror. The package sets
    # take nixpkgs.
    nixpkgs-lib.url = "github:nix-community/nixpkgs.lib";

    flake-parts.url = "github:hercules-ci/flake-parts";
    flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs-lib";
  };

  outputs =
    inputs@{ caisson, ... }:
    let
      lib = caisson.lib.caisson.mkLib {
        inherit (caisson.lib.caisson.pins.flake inputs) sources root;
        name = "ch-ai-workbench";
        systems = [ "x86_64-linux" ];

        projects = {
          inherit caisson;
          ch-emacs-config = inputs.ch-emacs-config;
          ch-zsh-config = inputs.ch-zsh-config;
          merman-nix = inputs.merman-nix;
          ch-microvm = inputs.ch-microvm;
        };

        # The three trees, read from the layout: each entry under
        # modules/<class>/ and configs/<class>/ registers under its
        # directory name, each lib-overlays/<name>/ registers as a
        # library overlay, and the default.nix of each describes what it
        # configures.
        modules = lib: lib.caisson.mkModules ./modules;
        configs = lib: lib.caisson.mkModules ./configs;
        pkgSets = lib: lib.caisson.nixpkgs.mkConfigurations { };
        libOverlays = lib: lib.caisson.mkLibOverlays ./lib-overlays;
        pkgOverlays = lib: lib.caisson.mkPkgOverlays ./pkg-overlays;
      };
    in
    lib.caisson.flake-parts.mkTopConfiguration { };

}
