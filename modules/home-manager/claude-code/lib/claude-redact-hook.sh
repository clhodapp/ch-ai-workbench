# PostToolUse hook on every tool: the CLI-side enforcement point of the
# agent-elisp isolation design (docs/development/agent-elisp-isolation.md,
# "Redaction covers every file view").  Whatever a tool returned, the
# string leaves of tool_response are run through gitleaks; on a finding
# the result the model sees is replaced (updatedToolOutput, which keeps
# the response's shape) with every occurrence of each secret turned into
# [REDACTED:<rule>], and a note naming the rules rides along as
# additionalContext so the model knows a redaction occurred.  This covers
# Read, Bash (stdout and stderr alike), Grep, the edit verbs' snippets,
# and the MCP tools, whose server already redacts and so produce no
# findings here.
#
# A clean result abstains (exit 0, no output).  A gitleaks that cannot
# run withholds the text: the response is returned with every string
# emptied and the note says why, since no text may reach the model
# without passing through gitleaks.  Anything else unexpected (no
# payload, jq failure) abstains, as the other hooks do.

payload=$(cat) || exit 0

event=$(jq -r '.hook_event_name // empty' <<<"$payload" 2>/dev/null || true)
[ "$event" = "PostToolUse" ] || exit 0
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null || true)
response=$(jq -c '.tool_response // empty' <<<"$payload" 2>/dev/null || true)
[ -n "$response" ] || exit 0

text=$(jq -r '[.. | strings] | join("\n")' <<<"$response" 2>/dev/null || true)
[ -n "$text" ] || exit 0

emit() { # $1 = replacement response (JSON), $2 = note
  jq -cn --argjson out "$1" --arg note "$2" \
    '{hookSpecificOutput: {hookEventName: "PostToolUse",
                           updatedToolOutput: $out,
                           additionalContext: $note}}' 2>/dev/null
  exit 0
}

status=0
report=$(gitleaks stdin --no-banner --log-level error --report-format json \
           --report-path - --exit-code 0 <<<"$text" 2>/dev/null) || status=$?
if [ "$status" -ne 0 ]; then
  blank=$(jq -c 'walk(if type == "string" then "" else . end)' <<<"$response" 2>/dev/null) || exit 0
  emit "$blank" "[gitleaks could not run (exit $status), so this ${tool:-tool} result was withheld: no tool result reaches the model without passing through gitleaks. Ask the user to check the gitleaks installation.]"
fi

count=$(jq -r 'length' <<<"$report" 2>/dev/null || echo 0)
case "$count" in
  '' | 0 | *[!0-9]*) exit 0 ;;
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
[ "$count" = "1" ] && plural=
emit "$redacted" "[gitleaks redacted $count span$plural in this ${tool:-tool} result: $rules. A redaction is a boundary: do not reconstruct the value from its context or through another read; the user owns the real text.]"
