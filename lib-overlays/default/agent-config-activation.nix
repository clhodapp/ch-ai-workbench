# SPDX-License-Identifier: MIT
#
# The activation entry that converges declared settings into a config
# file a coding agent also writes (~/.claude/settings.json, Codex's
# config.toml, opencode.json). The file cannot be a store symlink,
# because the agent rewrites it at runtime, so `agent-config apply`
# merges the settings in: it changes only what the settings declare now
# or declared at the last activation, and keeps everything the agent or
# a person wrote. The sidecar under the XDG state directory records what
# was applied, and is the merge base of the next activation.
#
# The entry runs after `linkGeneration`, so a file Home Manager linked
# from the store in an earlier generation is already gone, or is still
# the link and is replaced by a regular file holding its content.
#
# Arguments: `lib` and `pkgs` of the home, `config` for the state
# directory, and per file a `name`
# (the sidecar's name and the label of report lines), `format` ("json"
# or "toml"), `target` (an absolute path string, which may use $HOME),
# and `settings` (an attribute set; TOML has no null).
{
  lib,
  pkgs,
  config,
  name,
  format,
  target,
  settings,
}:
let
  tool =
    pkgs.ch-ai-workbench.agent-config or (throw ''
      ${name} needs pkgs.ch-ai-workbench.agent-config: apply
      ch-ai-workbench's package overlay (`overlays.default`; a caisson
      consumer lists the flake in `projects`) to the package set this
      home evaluates with.
    '');
  fragment = pkgs.writeText "agent-config-${name}.json" (builtins.toJSON settings);
  sidecar = "${config.xdg.stateHome}/ch-ai-workbench/agent-config/${name}.json";
in
lib.hm.dag.entryAfter [ "linkGeneration" ] ''
  run ${lib.getExe tool} apply --format ${format} \
    --target "${target}" \
    --fragment ${fragment} \
    --sidecar "${sidecar}" \
    --name ${lib.escapeShellArg name}
''
