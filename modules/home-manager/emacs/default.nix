# SPDX-License-Identifier: MIT
#
# The workbench's Emacs half: ten bundles that turn the editor into a
# place to run agent sessions, plus the local packages three of them
# need. Everything here is contributed to ch-emacs-config's own options,
# so a configuration importing both gets one Emacs with both layers'
# bundles rather than two configurations fighting.
{ closure-inputs, ... }:
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.ch-ai-workbench.emacs;

  merman = closure-inputs.merman.packages.${pkgs.stdenv.hostPlatform.system}.merman;

  # The editor's package scope, read from its module rather than rebuilt:
  # the bridge below is built against the same Emacs the editor
  # configures, or it loads into a different one than it compiled for.
  editorScope = config.ch-emacs-config.emacs.build.packageScope;

  # The MCP stdio bridge: a stable command MCP clients register
  # (`claude mcp add -s user emacs -- emacs-mcp-stdio`) that keeps
  # working across package updates. Defaults target the "emacs" server
  # the mcp-server bundle registers; explicit flags win, since the
  # bridge's argument parser is last-match.
  mcpStdioBridge = pkgs.writeShellApplication {
    name = "emacs-mcp-stdio";
    runtimeInputs = [
      config.programs.emacs.finalPackage
      pkgs.coreutils
    ];
    text = ''
      bridge=(${editorScope.epkgs.mcp-server-lib}/share/emacs/site-lisp/elpa/mcp-server-lib-*/emacs-mcp-stdio.sh)
      exec bash "''${bridge[0]}" \
        --init-function=ch-emacs-config-mcp-server-start \
        --server-id=emacs \
        "$@"
    '';
  };
in
{
  options.ch-ai-workbench.emacs = {
    enable = lib.mkEnableOption "the Emacs half of the AI workbench";
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

    ch-emacs-config.emacs.localPackageOverlays = import ./local-packages.nix;

    # `enable` is wrapped here rather than in the spec: the spec is also
    # read as plain data by the checks, where a priority wrapper is not
    # a boolean. mkDefault so a consumer can switch a bundle off.
    ch-emacs-config.emacs.bundles =
      lib.mapAttrs (_name: bundle: bundle // { enable = lib.mkDefault bundle.enable; })
        (
          import ./bundles-spec.nix {
            inherit lib merman;
            readInit = name: builtins.readFile ./inits/${name};
          }
        );

    home.packages = [ mcpStdioBridge ];
  };
}
