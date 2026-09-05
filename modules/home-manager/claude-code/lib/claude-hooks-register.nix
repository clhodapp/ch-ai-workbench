# SPDX-License-Identifier: MIT
# Idempotent user-level registration of the module's Claude Code hooks
# and permissions.deny rules
# (usage: claude-hooks-register <settings-file> <manifest> <sidecar>).
#
# ~/.claude/settings.json is runtime-mutable state (the CLI rewrites
# it for theme/model toggles, and a person may hand-add entries), so
# it can never be a store symlink; the module's entries are converged
# in by a merge that follows the claude-code-sandbox model for
# co-owned settings files: <manifest> is the store-rendered
# declaration (the "new" fragment: {hooks: [{event, matcher|null,
# command, timeout|null}], permissions: {deny: [rule]}}), <sidecar>
# records what this tool last applied (the "base"), and only entries
# in base or new are ever touched.  Per hook event, and for the deny
# list, the next list is
#
#   new + (current - base - owned)
#
# so declared entries come first, an entry that was applied before
# but is no longer declared is removed (deleting or disabling it in
# Nix converges), and an entry someone added by hand is kept in
# place.  For hooks, "owned" additionally drops any current entry
# naming a declared command, so a hand-edited copy of a module hook
# is overridden rather than kept beside the fresh one (two entries
# with one command would fire it twice); a deny rule is identified by
# its text.  The literal ''${XDG_RUNTIME_DIR} in a deny rule is
# replaced with the activation environment's runtime dir
# (/run/user/<uid> when unset): that path is not known at evaluation,
# and a rule must name it concretely.  Preserved ad-hoc entries are
# reported on stderr.  A sidecar from before the deny fragment
# existed (applied = {event: [entries]}) is read as hooks only.
{ pkgs }:
pkgs.writeShellApplication {
  name = "claude-hooks-register";
  runtimeInputs = [
    pkgs.coreutils
    pkgs.jq
  ];
  text = ''
    settings=$1
    manifest=$2
    sidecar=$3
    runtime="''${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
    mkdir -p "$(dirname "$settings")" "$(dirname "$sidecar")"
    [ -s "$settings" ] || echo '{}' > "$settings"
    base='{"hooks":{},"deny":[]}'
    if [ -s "$sidecar" ]; then
      base=$(jq -c '
        .applied // {}
        | if has("hooks") or has("deny") then {hooks: (.hooks // {}), deny: (.deny // [])}
          else {hooks: ., deny: []} end
      ' "$sidecar" 2>/dev/null || echo '{"hooks":{},"deny":[]}')
    fi
    # The declaration rendered into the settings shape: hooks grouped
    # by event as {event: [ {matcher?, hooks: [{type, command, timeout?}]} ]},
    # deny rules with the runtime-dir placeholder resolved.
    new=$(jq -c --arg runtime "$runtime" '
      def render:
        (if .matcher != null then {matcher: .matcher} else {} end)
        + {hooks: [ {type: "command", command: .command}
                    + (if .timeout != null then {timeout: .timeout} else {} end) ]};
      { hooks: ((.hooks // []) | group_by(.event)
                | map({key: .[0].event, value: map(render)}) | from_entries),
        deny: ((.permissions.deny // []) | map(gsub("\\$\\{XDG_RUNTIME_DIR\\}"; $runtime))) }
    ' "$manifest")
    tmp=$(mktemp "$settings.XXXXXX")
    if ! jq --argjson new "$new" --argjson base "$base" '
      def commands: [.hooks[]?.command];
      reduce (($new.hooks | keys) + ($base.hooks | keys) | unique | .[]) as $ev (.;
        ($new.hooks[$ev] // []) as $n
        | ($base.hooks[$ev] // []) as $b
        | ($n | map(commands[])) as $owned
        | .hooks[$ev] =
            ($n + ((.hooks[$ev] // [])
                   | map(select(. as $e
                                | ($b | any(.[]; . == $e)) == false
                                  and ($e | commands | any(.[]; . as $c | $owned | any(.[]; . == $c))) == false))))
        | if .hooks[$ev] == [] then del(.hooks[$ev]) else . end)
      | if .hooks == {} then del(.hooks) else . end
      | ($new.deny) as $n
      | ($base.deny) as $b
      | .permissions.deny =
          ($n + ((.permissions.deny // [])
                 | map(select(. as $r | ($b | index($r)) == null and ($n | index($r)) == null))))
      | if .permissions.deny == [] then del(.permissions.deny) else . end
      | if .permissions == {} then del(.permissions) else . end
    ' "$settings" > "$tmp"; then
      rm -f "$tmp"
      echo "claude-hooks-register: $settings is not valid JSON; fix or remove it" >&2
      exit 1
    fi
    mv "$tmp" "$settings"
    jq -n --arg manifest "$manifest" --argjson applied "$new" \
      '{manifest: $manifest, applied: $applied}' > "$sidecar"
    # Ad-hoc entries kept in place: in the file, in a list the module
    # touches, but neither declared now nor applied before.
    jq -r --argjson new "$new" --argjson base "$base" '
      ([ .hooks // {} | to_entries[]
         | select(.key as $ev | ($new.hooks | has($ev)) or ($base.hooks | has($ev)))
         | .key as $ev | .value[]
         | select(. as $e | (($new.hooks[$ev] // []) + ($base.hooks[$ev] // [])) | any(.[]; . == $e) | not)
         | "claude-hooks-register: keeping ad-hoc \($ev) hook: \(.hooks | map(.command) | join(", "))" ]
       + [ (if ($new.deny + $base.deny) == [] then empty else (.permissions.deny // [])[] end)
           | select(. as $r | ($new.deny + $base.deny) | index($r) | . == null)
           | "claude-hooks-register: keeping ad-hoc deny rule: \(.)" ])
      | .[]
    ' "$settings" >&2 || true
  '';
}
