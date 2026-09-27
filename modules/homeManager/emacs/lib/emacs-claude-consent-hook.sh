# Consent-gate PreToolUse hook on Edit|Write: the territory classifier
# of the workspace consent-gate design (ch-nix-workspace
# docs/development/consent-gate.md), built on the CLI facts recorded in
# docs/development/claude-cli.md "Hooks as the headless permission
# surface".  Registered user-level global, so the discipline is
# abstain-by-default: exit 0 with no output unless this session is one
# Emacs dispatched (a territory record exists for it) AND the edit
# leaves its territory.  Unknown sessions -- the user's own TUI
# included -- always get stock behavior, and every unexpected condition
# (no runtime dir, unreadable record, jq failure, a failed ask)
# resolves to abstention, never to a decision.
#
# Territory is sandbox-shaped at dispatch (probe-verified: --add-dir
# extends acceptEdits and the workdir sandbox headlessly), so
# in-territory edits need nothing from us -- abstaining lets the native
# engine accept them.  Out-of-territory edits become a question for the
# user, raised through `claude-consent ask` (the prompt API over the
# pending-consent spool): whichever answerer is attached -- Emacs, or a
# terminal running `claude-consent watch` -- renders the allow/deny
# menu, and this blocked hook process couriers the verdict back as the
# permissionDecision.  With no answerer attached the question is a
# plain allow/deny, so the hook falls back to `ask`: the CLI's own
# permission prompt takes it (the TUI prompt when attended; a headless
# session parks in `blocked`, answerable from `claude attach`).  The
# deadline lives in the ask (self-answered, actionable deny) because a
# framework-timed-out hook yields no decision at all -- fail-open
# wherever native rules allow; the declared hook timeout is only a
# liveness backstop and must stay above the longest deadline a record
# can carry.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

session=$(field '.session_id')
target=$(field '.tool_input.file_path')
[ -n "$session" ] && [ -n "$target" ] || exit 0

runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || exit 0
spool="$runtime/claude-consent"

# Ownership scoping: the dispatcher records territory keyed by the
# CLI's agent id -- the leading 8 hex digits of the session UUID.
record="$spool/territory/${session:0:8}.json"
[ -f "$record" ] || exit 0

emit() { # $1 = permissionDecision, $2 = reason; always a clean exit
  jq -cn --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                           permissionDecision: $d,
                           permissionDecisionReason: $r}}' 2>/dev/null
  exit 0
}

# Canonicalize the target (it may not exist yet; relative paths resolve
# against the session's live cwd from the payload).
cwd=$(field '.cwd')
case "$target" in
  /*) : ;;
  *) target="${cwd:-$PWD}/$target" ;;
esac
canon=$(realpath -m -- "$target" 2>/dev/null) || canon="$target"

# The spool itself is never editable territory, whatever the record
# says (the nix-rendered permissions.deny rules are the primary guard;
# this keeps the hook honest about its own state).
case "$canon" in
  "$spool" | "$spool"/*)
    emit deny "the consent spool ($spool) is not editable territory"
    ;;
esac

# In-territory -> abstain: the sandbox was shaped to the territory at
# dispatch, so the native engine accepts this edit on its own.
in_territory=0
while IFS= read -r root; do
  [ -n "$root" ] || continue
  rcanon=$(realpath -m -- "$root" 2>/dev/null) || rcanon="$root"
  case "$canon" in
    "$rcanon" | "$rcanon"/*)
      in_territory=1
      break
      ;;
  esac
done < <(jq -r '.roots[]?' "$record" 2>/dev/null || true)
[ "$in_territory" -eq 0 ] || exit 0

# Out-of-territory -> ask the user.
deadline_secs=$(jq -r '.deadline // empty' "$record" 2>/dev/null || true)
case "$deadline_secs" in
  '' | *[!0-9]*) deadline_secs=300 ;;
esac
# Stay under the declared framework timeout (3600s): a cancelled hook
# contributes no decision, which would be fail-open.
[ "$deadline_secs" -le 3500 ] || deadline_secs=3500

tool=$(field '.tool_name')
roots_list=$(jq -r '[.roots[]?] | join(", ")' "$record" 2>/dev/null || true)
# The question's identity for a stored answer: this exact call.
key=$(jq -c '{tool_name, tool_input}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-32)
territory=$(jq -c '{territory: .}' "$record" 2>/dev/null) || exit 0

# The pending record carries the full hook payload (diffs are built by
# the answerer) and the territory record, so a real prompt can be
# rendered anywhere.
result=$(claude-consent ask --payload-stdin \
  --title "$tool outside territory" \
  --detail "Target:    $canon
Territory: ${roots_list:-unknown}" \
  --option 'allow=Allow this call' \
  --option 'deny=Deny' \
  --option-text 'deny=Deny reason (returned to the model)' \
  --key "$key" --deadline "$deadline_secs" --fallback ask \
  --extra "$territory" <<<"$payload" 2>/dev/null) || exit 0

status=$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)
case "$status" in
  answered)
    value=$(jq -r '.value // empty' <<<"$result" 2>/dev/null || true)
    text=$(jq -r '.text // empty' <<<"$result" 2>/dev/null || true)
    case "$value" in
      allow) emit allow "approved by the user${text:+: $text}" ;;
      deny) emit deny "denied by the user${text:+: $text}" ;;
      *) emit deny "malformed consent answer; treating as denied" ;;
    esac
    ;;
  fallback)
    emit ask "$tool targets $canon, outside this session's territory (${roots_list:-unknown}), and no answerer is attached to the consent spool"
    ;;
  timeout)
    emit deny "consent request timed out after ${deadline_secs}s with no answer: $tool targets $canon, outside this session's territory (${roots_list:-unknown}). Keep edits inside the territory, or re-issue the operation to request consent again."
    ;;
  pending)
    emit deny "$(jq -r '.instructions // "a consent question is pending"' <<<"$result" 2>/dev/null)"
    ;;
esac
exit 0
