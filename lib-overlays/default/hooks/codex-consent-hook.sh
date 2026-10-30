# Consent hook for Codex tasks that Emacs queued (claude-queue), on
# Codex's PermissionRequest event.  Codex raises that event when a
# call would leave its workspace-write sandbox: a patch outside the
# task root, or a command that asks for escalated permissions.  The
# sandbox has already classified the call, so this hook only asks the
# user, through `claude-consent ask', and couriers the answer back as
# the decision.
#
# claude-queue starts each Codex task with CLAUDE_QUEUE_TASK set to
# the task id and writes the task's territory record under that id
# before the process starts.  A session without the variable is not a
# queued task, and the hook prints nothing, so Codex decides as it
# would without the hook.  For a queued task the hook always decides:
# with no decision Codex would hand the question to its automatic
# reviewer, a model, so every failure here is a deny.

payload=$(cat) || payload='{}'

emit() { # $1 = allow or deny, $2 = message; always a clean exit
  jq -cn --arg b "$1" --arg m "$2" \
    '{hookSpecificOutput: {hookEventName: "PermissionRequest",
                           decision: ({behavior: $b}
                                      + (if $b == "deny" then {message: $m} else {} end))}}'
  exit 0
}

task="${CLAUDE_QUEUE_TASK:-}"
[ -n "$task" ] || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || emit deny "no XDG_RUNTIME_DIR, so the consent spool cannot be reached; the call stays inside the sandbox"
record="$runtime/claude-consent/territory/$task.json"
[ -f "$record" ] || emit deny "no consent territory record for queued task $task; the call stays inside the sandbox"

tool=$(field '.tool_name')
command=$(field '.tool_input.command')
case "$tool" in
  apply_patch)
    targets=$(sed -n 's/^\*\*\* \(Add\|Update\|Delete\) File: //p; s/^\*\*\* Move to: //p' <<<"$command")
    detail="Files:     $(tr '\n' ' ' <<<"$targets")"
    ;;
  *)
    detail="Command:   $command"
    ;;
esac
roots_list=$(jq -r '[.roots[]?] | join(", ")' "$record" 2>/dev/null || true)

deadline_secs=$(jq -r '.deadline // empty' "$record" 2>/dev/null || true)
case "$deadline_secs" in
  '' | *[!0-9]*) deadline_secs=300 ;;
esac
# Stay under the hook timeout the Codex module declares (3600s).
[ "$deadline_secs" -le 3500 ] || deadline_secs=3500

key=$(jq -c '{tool_name, tool_input}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-32)
territory=$(jq -c '{territory: .}' "$record" 2>/dev/null) || territory='{}'

result=$(claude-consent ask --payload-stdin \
  --title "Codex: $tool outside its sandbox" \
  --detail "$detail
Territory: ${roots_list:-unknown}" \
  --option 'allow=Allow this call' \
  --option 'deny=Deny' \
  --option-text 'deny=Deny reason (returned to the model)' \
  --key "$key" --deadline "$deadline_secs" \
  --extra "$territory" <<<"$payload" 2>/dev/null) ||
  emit deny "the consent question could not be raised; the call stays inside the sandbox"

status=$(jq -r '.status // empty' <<<"$result" 2>/dev/null || true)
case "$status" in
  answered)
    value=$(jq -r '.value // empty' <<<"$result" 2>/dev/null || true)
    text=$(jq -r '.text // empty' <<<"$result" 2>/dev/null || true)
    case "$value" in
      allow) emit allow "" ;;
      *) emit deny "denied by the user${text:+: $text}" ;;
    esac
    ;;
  timeout)
    emit deny "consent request timed out after ${deadline_secs}s with no answer: $tool leaves this task's territory (${roots_list:-unknown}). Keep the work inside it, or re-issue the call to ask again."
    ;;
  pending)
    emit deny "$(jq -r '.instructions // "a consent question is pending"' <<<"$result" 2>/dev/null)"
    ;;
  *)
    emit deny "unexpected consent result; the call stays inside the sandbox"
    ;;
esac
