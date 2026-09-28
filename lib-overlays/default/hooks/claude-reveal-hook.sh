# PreToolUse hook on Read and the emacs server's two read tools
# (buffer-text, buffer-diff): the resubmit-to-approve half of the
# redaction (docs/development/agent-elisp-isolation.md, "Redact and tell;
# resubmit to approve").  The redact hook marks a call whose result was
# redacted under $XDG_RUNTIME_DIR/claude-redact/redacted/, keyed by
# session and a hash of {tool_name, tool_input} without any `approval'
# argument.  When the identical call comes again, this hook asks the user
# through `claude-consent ask` whether the model may see the real text.
#
# Allow writes an approved marker, which the redact hook consumes to let
# that one result through unredacted.  For Read the hook then abstains
# and the native engine runs the Read.  For an MCP read the server
# redacts too, so the hook also writes a random token into a file under
# $XDG_RUNTIME_DIR/claude-redact/mcp-approved/ and rewrites the call to
# carry it as the `approval' argument (updatedInput, with no permission
# decision); the server consumes the file and skips its redaction for
# that call.  The model never sees the token: its record of the call
# keeps the original input.
#
# Deny, a timeout, a pending question, and no attached answerer are each
# a deny whose reason tells the model the redacted view stands.  A call
# with no marker abstains, and so does every unexpected condition (no
# runtime dir, no session, a failed ask), which leaves the native
# permission flow to decide.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

[ "$(field '.hook_event_name')" = "PreToolUse" ] || exit 0
tool=$(field '.tool_name')
case "$tool" in
  Read | mcp__emacs__buffer-text | mcp__emacs__buffer-diff) ;;
  *) exit 0 ;;
esac
session=$(field '.session_id')
[ -n "$session" ] || exit 0
runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || exit 0
key=$(jq -c '{tool_name, tool_input: ((.tool_input // {}) | del(.approval))}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-64)
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

file=$(field '.tool_input.file_path // .tool_input.name // .tool_input.file')
count=$(jq -r '.count // "some"' "$redacted" 2>/dev/null || echo some)
rules=$(jq -r '.rules // empty' "$redacted" 2>/dev/null || true)

result=$(claude-consent ask --payload-stdin \
  --title "Reveal redacted text to the model" \
  --detail "${tool#mcp__emacs__}: $file
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
        if ! { mkdir -p "$(dirname "$approved")" 2>/dev/null && : > "$approved" 2>/dev/null; }; then
          emit deny "the user allowed the reveal but the approval could not be recorded; the redacted view stands"
        fi
        [ "$tool" = "Read" ] && exit 0
        # An MCP read: the server skips its redaction only for a call
        # carrying a token whose file exists.
        token=$(head -c 48 /dev/urandom | base64 -w0 | tr -dc 'A-Za-z0-9' | cut -c1-40)
        tokens="$runtime/claude-redact/mcp-approved"
        if [ "${#token}" -lt 32 ] \
           || ! { mkdir -p "$tokens" 2>/dev/null && chmod 700 "$tokens" 2>/dev/null && : > "$tokens/$token" 2>/dev/null; }; then
          rm -f "$approved" 2>/dev/null || true
          emit deny "the user allowed the reveal but the approval could not be recorded; the redacted view stands"
        fi
        jq -c --arg t "$token" \
          '{hookSpecificOutput: {hookEventName: "PreToolUse",
                                 updatedInput: ((.tool_input // {}) + {approval: $t})}}' \
          <<<"$payload" 2>/dev/null
        exit 0
        ;;
      deny) emit deny "the user kept the text redacted${text:+: $text}. The redacted view stands." ;;
      *) emit deny "malformed consent answer; the redacted view stands" ;;
    esac
    ;;
  fallback)
    emit deny "no answerer is attached to the consent spool, so the redacted view of $file stands; the user can attach one (Emacs, or claude-consent watch) and you can re-issue the identical call"
    ;;
  timeout)
    emit deny "the question timed out after 300s with no answer, so the redacted view of $file stands; re-issue the identical call to ask again"
    ;;
  pending)
    emit deny "$(jq -r '.instructions // "a consent question is pending; the redacted view stands"' <<<"$result" 2>/dev/null)"
    ;;
esac
exit 0
