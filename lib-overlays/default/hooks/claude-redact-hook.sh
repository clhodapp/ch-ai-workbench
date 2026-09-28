# PostToolUse hook on every tool: the CLI-side enforcement point of the
# agent-elisp isolation design (docs/development/agent-elisp-isolation.md,
# "Redaction covers every file view").  Whatever a tool returned, the
# string leaves of tool_response are run through betterleaks; on a finding
# the result the model sees is replaced (updatedToolOutput, which keeps
# the response's shape) with every occurrence of each secret turned into
# [REDACTED:<rule>], and a note naming the rules rides along as
# additionalContext so the model knows a redaction occurred.  This covers
# Read, Bash (stdout and stderr alike), Grep, the edit verbs' snippets,
# and the MCP tools, whose server already redacts and so produce no
# findings here.
#
# A clean result abstains (exit 0, no output).  A betterleaks that cannot
# run withholds the text: the response is returned with every string
# emptied and the note says why, since no text may reach the model
# without passing through betterleaks.  Anything else unexpected (no
# payload, jq failure) abstains, as the other hooks do.
#
# Read and the emacs server's two read tools (buffer-text, buffer-diff)
# have a retry path (claude-reveal-hook.sh): a redacted result is marked
# under $XDG_RUNTIME_DIR/claude-redact/redacted/ by session and a hash of
# the call, and the note tells the model to re-issue the identical call
# to ask the user.  The hash leaves out the `approval' argument, which
# the reveal hook adds after the user allows, so the marked call and the
# approved one share a key.  An MCP result was already redacted by the
# server, so this hook finds nothing in it; the server's own note marks
# it instead.  When the user has allowed, an approved marker exists for
# the key; this hook consumes it and lets that one result through
# unredacted (for an MCP read, the server skipped its own redaction for
# the same call).

payload=$(cat) || exit 0

event=$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null || true)
[ "$event" = "PostToolUse" ] || exit 0
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null || true)
response=$(jq -c '.tool_response // empty' <<<"$payload" 2>/dev/null || true)
[ -n "$response" ] || exit 0

marker=
case "$tool" in
  Read | mcp__emacs__buffer-text | mcp__emacs__buffer-diff)
    if [ -n "${XDG_RUNTIME_DIR:-}" ]; then
      session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
      key=$(jq -c '{tool_name, tool_input: ((.tool_input // {}) | del(.approval))}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-64)
      if [ -n "$session" ] && [ -n "$key" ]; then
        marker="$XDG_RUNTIME_DIR/claude-redact/redacted/${session:0:8}-$key"
        approved="$XDG_RUNTIME_DIR/claude-redact/approved/${session:0:8}-$key"
        if [ -e "$approved" ]; then
          rm -f "$approved" 2>/dev/null || true
          exit 0
        fi
      fi
    fi
    ;;
esac

text=$(jq -r '[.. | strings] | join("\n")' <<<"$response" 2>/dev/null || true)
[ -n "$text" ] || exit 0

emit() { # $1 = replacement response (JSON), $2 = note
  jq -cn --argjson out "$1" --arg note "$2" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse",
                           updatedToolOutput: $out,
                           additionalContext: $note}}' 2>/dev/null
  exit 0
}

retry_note() { # $1 = count, $2 = rules; writes the marker, prints the note tail
  if [ -n "$marker" ] \
     && mkdir -p "$(dirname "$marker")" 2>/dev/null \
     && jq -cn --arg c "$1" --arg r "$2" '{count: $c, rules: $r}' > "$marker" 2>/dev/null; then
    printf ' To ask the user for the real text, re-issue this identical call; the user answers, and the answer is final for that one call.'
  fi
}

status=0
report=$(betterleaks stdin --no-banner --log-level error --report-format json \
           --report-path - --exit-code 0 <<<"$text" 2>/dev/null) || status=$?
if [ "$status" -ne 0 ]; then
  blank=$(jq -c 'walk(if type == "string" then "" else . end)' <<<"$response" 2>/dev/null) || exit 0
  emit "$blank" "[betterleaks could not run (exit $status), so this ${tool:-tool} result was withheld: no tool result reaches the model without passing through betterleaks. Ask the user to check the betterleaks installation.]"
fi

count=$(jq -r 'length' <<<"$report" 2>/dev/null || echo 0)
case "$count" in
  '' | 0 | *[!0-9]*)
    # Nothing here, but an MCP read the server already redacted still
    # gets the retry path: mark it and tell the model how to ask.
    if [ -n "$marker" ] && [ "$tool" != "Read" ]; then
      server_note=$(grep -o '\[betterleaks redacted [^]]*\]' <<<"$text" | tail -1)
      if [ -n "$server_note" ]; then
        rules=${server_note#*: }
        rules=${rules%]}
        tail=$(retry_note some "$rules")
        if [ -n "$tail" ]; then
          jq -cn --arg note "[The emacs server redacted this ${tool#mcp__emacs__} result.$tail]" \
            '{hookSpecificOutput: {hookEventName: "PostToolUse",
                                   additionalContext: $note}}' 2>/dev/null
        fi
      fi
    fi
    exit 0
    ;;
esac

redacted="$response"
while IFS= read -r finding; do
  secret=$(jq -r '.Secret // empty' <<<"$finding")
  rule=$(jq -r '.RuleID // "secret"' <<<"$finding")
  [ -n "$secret" ] || continue
  redacted=$(jq -c --arg s "$secret" --arg r "[REDACTED:$rule]" \
    'walk(if type == "string" then (split($s) | join($r)) else . end)' \
    <<<"$redacted" 2>/dev/null) || exit 0
done < <(jq -c '.[]' <<<"$report" 2>/dev/null)

rules=$(jq -r '[.[].RuleID] | unique | join(", ")' <<<"$report" 2>/dev/null || true)
plural=s
if [ "$count" = "1" ]; then plural=; fi
retry=$(retry_note "$count" "$rules")
emit "$redacted" "[betterleaks redacted $count span$plural in this ${tool:-tool} result: $rules. A redaction is a boundary: do not reconstruct the value from its context or through another read; the user owns the real text.$retry]"
