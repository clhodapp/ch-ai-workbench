# PreToolUse hook on Read: the resubmit-to-approve half of the redaction
# (docs/development/agent-elisp-isolation.md, "Redact and tell; resubmit
# to approve").  The redact hook marks a Read whose result it redacted
# under $XDG_RUNTIME_DIR/claude-redact/redacted/, keyed by session and a
# hash of {tool_name, tool_input}, the tic-check edit hook's key.  When
# the identical Read comes again, this hook asks the user through
# `claude-consent ask` whether the model may see the real text.  Allow
# writes an approved marker and abstains: the native engine runs the
# Read, and the redact hook, finding the marker, consumes it and lets
# that one result through unredacted.  Deny, a timeout, a pending
# question, and no attached answerer are each a deny whose reason tells
# the model the redacted view stands.  A Read with no marker abstains,
# and so does every unexpected condition (no runtime dir, no session, a
# failed ask), which leaves the native permission flow to decide.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

[ "$(field '.hook_event_name')" = "PreToolUse" ] || exit 0
[ "$(field '.tool_name')" = "Read" ] || exit 0
session=$(field '.session_id')
[ -n "$session" ] || exit 0
runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || exit 0
key=$(jq -c '{tool_name, tool_input}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-64)
[ -n "$key" ] || exit 0

approved="$runtime/claude-redact/approved/${session:0:8}-$key"
redacted="$runtime/claude-redact/redacted/${session:0:8}-$key"
if [ -e "$approved" ]; then exit 0; fi
if [ ! -e "$redacted" ]; then exit 0; fi

emit() { # $1 = permissionDecision, $2 = reason; always a clean exit
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                           permissionDecision: $d,
                           permissionDecisionReason: $r}}' 2>/dev/null
  exit 0
}

file=$(field '.tool_input.file_path')
count=$(jq -r '.count // "some"' "$redacted" 2>/dev/null || echo some)
rules=$(jq -r '.rules // empty' "$redacted" 2>/dev/null || true)

result=$(claude-consent ask --payload-stdin \
  --title "Reveal redacted text to the model" \
  --detail "Read: $file
The model read this before and betterleaks redacted $count span(s)${rules:+ ($rules)}.
It has asked for the same read again. Allow shows it the real text, once." \
  --option 'allow=Reveal the real text once' \
  --option 'deny=Keep it redacted' \
  --option-text 'deny=Reason (returned to the model)' \
  --key "$key" --deadline 300 --fallback deny <<<"$payload" 2>/dev/null) || exit 0

status=$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)
case "$status" in
  answered)
    value=$(jq -r '.value // empty' <<<"$result" 2>/dev/null || true)
    text=$(jq -r '.text // empty' <<<"$result" 2>/dev/null || true)
    case "$value" in
      allow)
        if mkdir -p "$(dirname "$approved")" 2>/dev/null && : > "$approved" 2>/dev/null; then
          exit 0
        fi
        emit deny "the user allowed the reveal but the approval could not be recorded; the redacted view stands"
        ;;
      deny) emit deny "the user kept the text redacted${text:+: $text}. The redacted view stands." ;;
      *) emit deny "malformed consent answer; the redacted view stands" ;;
    esac
    ;;
  fallback)
    emit deny "no answerer is attached to the consent spool, so the redacted view of $file stands; the user can attach one (Emacs, or claude-consent watch) and you can re-issue the identical Read"
    ;;
  timeout)
    emit deny "the question timed out after 300s with no answer, so the redacted view of $file stands; re-issue the identical Read to ask again"
    ;;
  pending)
    emit deny "$(jq -r '.instructions // "a consent question is pending; the redacted view stands"' <<<"$result" 2>/dev/null)"
    ;;
esac
exit 0
