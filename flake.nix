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
          homeManager = {
            # The Emacs half, in three modules that each define their
            # bundles on the editor's own options.
            # Vendor-neutral: comment threads, the semantic finder,
            # parenting, the ACP agent shell, commit messages, the
            # ghostel environment handoff.
            emacs = lib.caisson.home-manager.mkModule ./modules/home-manager/emacs;
            # gptel and gptel-agent, and the backend and model they
            # start on.
            gptel = lib.caisson.home-manager.mkModule ./modules/home-manager/gptel;
            # Claude Code in Emacs: claude-queue, the MCP server, and
            # its stdio bridge. Needs `emacs`.
            claude = lib.caisson.home-manager.mkModule ./modules/home-manager/claude;
            # The agent half: hooks, skills, output styles, permissions,
            # and the LSP plugin manifest.
            claude-code = lib.caisson.home-manager.mkModule ./modules/home-manager/claude-code;
            # Claude Code's native sandbox, declared: named profiles
            # (closed toolsets compiled from Nix closures into sandbox
            # rules) that a checkout opts into by enrollment.
            # Independent of the other modules.
            claude-code-sandbox = lib.caisson.home-manager.mkModule ./modules/home-manager/claude-code-sandbox;
            # What joins them: the hooks and skill that let a session
            # drive the live Emacs.
            emacs-integration = lib.caisson.home-manager.mkModule ./modules/home-manager/emacs-integration;
            # The shell half: one function, the other end of an Emacs
            # eval-cmd this layer registers.
            zsh = lib.caisson.home-manager.mkModule ./modules/home-manager/zsh;
          };
        };
      };
    in
    lib.caisson.flake-parts.mkConfiguration {
      name = "ch-ai-workbench";
      configModule = lib.caisson.flake-parts.mkModule ./configs/flake-parts/default;
    };

}
