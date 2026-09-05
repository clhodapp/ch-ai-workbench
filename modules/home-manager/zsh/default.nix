# SPDX-License-Identifier: MIT
#
# The workbench's shell half: one function, and the reason this repo is
# organized by what it is for rather than by which program each piece
# configures. `update_emacs_env` is the shell end of an Emacs eval-cmd
# this layer registers; splitting them by tool would put the two halves
# of one mechanism in two repos with an interface between them.
{ ... }:
{
  config,
  lib,
  ...
}:
let
  cfg = config.ch-ai-workbench.zsh;
in
{
  options.ch-ai-workbench.zsh = {
    enable = lib.mkEnableOption "the shell half of the AI workbench";
  };

  config = lib.mkIf cfg.enable {
    # Pull the live Emacs environment into this shell: the terminal is a
    # ghostel buffer inside Emacs, so a long-lived shell there otherwise
    # keeps whatever environment Emacs had when it spawned. The
    # `ch/ghostel-send-buffer-env` eval-cmd is registered by this
    # layer's Emacs half.
    ch-zsh-config.zsh.extraInitContent = ''
      update_emacs_env() {
        ghostel_cmd "ch/ghostel-send-buffer-env"
        local cmd
        read -r -s cmd
        eval "$cmd"
      }
    '';
  };
}
