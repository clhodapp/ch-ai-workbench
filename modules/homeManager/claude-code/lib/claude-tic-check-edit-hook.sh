# PreToolUse hook on the disk and buffer writers (Edit, Write,
# NotebookEdit, and the emacs server's edit-file / edit-buffer): the
# edit-side twin of claude-tic-check-hook.sh.  The text a call writes
# (new_string, content, new_source, or new-string) is matched against
# the same table (tic_findings from tic-check-match.sh, prepended by
# the package wrapper with $table); on a hit the call is denied once
# with the matching lines and rules, and the reason comes back to the
# model as the tool result, so it re-reads and re-issues the edit.
#
# One denial per identical call: a marker keyed by session and a
# hash of {tool_name, tool_input} is written before the deny, and a
# call whose marker exists abstains -- so a legitimate use costs one
# retry, and a re-issue with the phrasing rewritten is a different
# hash and gets checked on its own.  The marker lives under
# $XDG_RUNTIME_DIR/claude-tic-check/seen/ (per login, ephemeral).
# Everything unexpected -- no runtime dir, no session id, a failed
# marker write, jq failure -- resolves to abstention (exit 0, no
# output), which lets the native permission flow decide.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

text=$(field '.tool_input.new_string // .tool_input.content // .tool_input.new_source // .tool_input["new-string"]')
[ -n "$text" ] || exit 0

runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || exit 0
session=$(field '.session_id')
[ -n "$session" ] || exit 0
key=$(jq -c '{tool_name, tool_input}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-64)
[ -n "$key" ] || exit 0
seen="$runtime/claude-tic-check/seen/${session:0:8}-$key"
[ -e "$seen" ] && exit 0

findings=$(tic_findings "$text")
[ -n "$findings" ] || exit 0

mkdir -p "$(dirname "$seen")" 2>/dev/null && : > "$seen" 2>/dev/null || exit 0

reason="tic-check: check
The text this call writes contains phrasing the output style bans:$findings
Re-read each occurrence against its rule. If any is the tic, re-issue the call with that phrasing rewritten. If every occurrence is legitimate (quoted text, a real possessive, a literal symbol in code or quoted output), re-issue the same call unchanged; an identical re-issue is not checked again."

jq -cn --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse",
                         permissionDecision: "deny",
                         permissionDecisionReason: $r}}' 2>/dev/null
exit 0
