# Consent-gate PreToolUse hook on Edit|Write: the territory classifier
# of the workspace consent-gate design (ch-nix-workspace
# docs/development/consent-gate.md), standing on the substrate facts in
# docs/development/claude-cli.md "Hooks as the headless permission
# surface".  Registered user-level global, so the discipline is
# abstain-by-default: exit 0 with no output unless this session is one
# Emacs dispatched (a territory record exists for it) AND the edit
# leaves its territory.  Unknown sessions -- the user's own TUI
# included -- always get stock behavior, and every unexpected condition
# (no runtime dir, unreadable record, jq failure) resolves to
# abstention, never to a decision.
#
# Territory is sandbox-shaped at dispatch (probe-verified: --add-dir
# extends acceptEdits and the workdir sandbox headlessly), so
# in-territory edits need nothing from us -- abstaining lets the native
# engine accept them.  Out-of-territory edits escalate through the
# pending-consent spool: this blocked hook process is the approval
# channel in both directions, writing the request, polling for the
# Emacs-side answer, and couriering the human verdict back as the
# permissionDecision.  The deadline lives in here (self-answered,
# actionable deny) because a framework-timed-out hook yields no
# decision at all -- fail-open wherever native rules allow; the
# declared hook timeout is only a liveness backstop and must stay
# above the longest deadline a record can carry.

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

# Out-of-territory -> escalate through the spool and wait for a human.
deadline_secs=$(jq -r '.deadline // empty' "$record" 2>/dev/null || true)
case "$deadline_secs" in
  '' | *[!0-9]*) deadline_secs=300 ;;
esac
# Stay under the declared framework timeout (3600s): a cancelled hook
# contributes no decision, which would be fail-open.
[ "$deadline_secs" -le 3500 ] || deadline_secs=3500

now=$(date +%s)
deadline=$((now + deadline_secs))
id="${session:0:8}-$now-$$"
pending="$spool/pending/$id.json"
answer="$spool/answers/$id.json"

mkdir -p "$spool/pending" "$spool/answers" || exit 0
chmod 700 "$spool" 2>/dev/null || true
trap 'rm -f "$pending" "$pending.tmp" "$answer"' EXIT

# The pending record carries everything Emacs needs to render a real
# prompt: the full tool_input (diffs are built Emacs-side), the hook
# pid (the viewer prunes dead-pid entries on read), and the deadline.
jq -cn --arg id "$id" --argjson pid "$$" --argjson created "$now" \
  --argjson deadline "$deadline" --arg target "$canon" \
  --argjson payload "$payload" --slurpfile territory "$record" \
  '{id: $id, pid: $pid, created: $created, deadline: $deadline,
    target: $target,
    session_id: $payload.session_id, tool_name: $payload.tool_name,
    tool_input: $payload.tool_input, cwd: $payload.cwd,
    territory: $territory[0]}' > "$pending.tmp" 2>/dev/null || exit 0
mv "$pending.tmp" "$pending" || exit 0

while [ "$(date +%s)" -lt "$deadline" ]; do
  if [ -e "$answer" ]; then
    decision=$(jq -r '.decision // empty' "$answer" 2>/dev/null || true)
    reason=$(jq -r '.reason // empty' "$answer" 2>/dev/null || true)
    case "$decision" in
      allow) emit allow "approved from Emacs${reason:+: $reason}" ;;
      deny) emit deny "denied from Emacs${reason:+: $reason}" ;;
      '') ;; # partially written answer; re-poll
      *) emit deny "malformed consent answer; treating as denied" ;;
    esac
  fi
  sleep 0.5
done

roots_list=$(jq -r '[.roots[]?] | join(", ")' "$record" 2>/dev/null || true)
emit deny "consent request timed out after ${deadline_secs}s with no answer from Emacs: $(field '.tool_name') targets $canon, outside this session's territory (${roots_list:-unknown}). Keep edits inside the territory, or re-issue the operation to request consent again."
