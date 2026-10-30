# Consent gate for OpenCode tasks that Emacs queued (claude-queue),
# run by the workbench's OpenCode plugin before every file-writing
# tool call.  Stdin is a JSON object: {sessionID, tool, paths}, the
# paths the call writes.  Stdout is the decision, a JSON object:
# {"behavior": "allow"} or {"behavior": "deny", "message": ...}; the
# plugin fails the call with the message on a deny.
#
# A queued task carries CLAUDE_QUEUE_TASK, the id its territory record
# is filed under; a session without it is not a queued task and is
# allowed, so OpenCode's own permissions decide as they would without
# the plugin.  A queued task's writes inside its territory are allowed
# at once.  A write outside becomes a question to the user through
# `claude-consent ask'.  For a queued task every failure is a deny:
# claude-queue opens OpenCode's external_directory permission for its
# tasks, so this gate is what stands between them and the rest of the
# disk.

payload=$(cat) || payload='{}'

emit() { # $1 = allow or deny, $2 = message; always a clean exit
  jq -cn --arg b "$1" --arg m "$2" \
    '{behavior: $b} + (if $b == "deny" then {message: $m} else {} end)'
  exit 0
}

task="${CLAUDE_QUEUE_TASK:-}"
[ -n "$task" ] || emit allow ""

runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || emit deny "no XDG_RUNTIME_DIR, so the consent spool cannot be reached; keep writes inside the task root"
spool="$runtime/claude-consent"
record="$spool/territory/$task.json"
[ -f "$record" ] || emit deny "no consent territory record for queued task $task; keep writes inside the task root"

outside=()
while IFS= read -r target; do
  [ -n "$target" ] || continue
  canon=$(realpath -m -- "$target" 2>/dev/null) || canon="$target"
  case "$canon" in
    "$spool" | "$spool"/*)
      emit deny "the consent spool ($spool) is not editable territory"
      ;;
  esac
  inside=0
  while IFS= read -r root; do
    [ -n "$root" ] || continue
    rcanon=$(realpath -m -- "$root" 2>/dev/null) || rcanon="$root"
    case "$canon" in
      "$rcanon" | "$rcanon"/*)
        inside=1
        break
        ;;
    esac
  done < <(jq -r '.roots[]?' "$record" 2>/dev/null || true)
  [ "$inside" -eq 1 ] || outside+=("$canon")
done < <(jq -r '.paths[]?' <<<"$payload" 2>/dev/null || true)
[ "${#outside[@]}" -gt 0 ] || emit allow ""

tool=$(jq -r '.tool // "a tool"' <<<"$payload" 2>/dev/null || echo "a tool")
roots_list=$(jq -r '[.roots[]?] | join(", ")' "$record" 2>/dev/null || true)
deadline_secs=$(jq -r '.deadline // empty' "$record" 2>/dev/null || true)
case "$deadline_secs" in
  '' | *[!0-9]*) deadline_secs=300 ;;
esac
key=$(jq -c '{tool, paths}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-32)
territory=$(jq -c '{territory: .}' "$record" 2>/dev/null) || territory='{}'

result=$(jq -c '{session_id: .sessionID, tool_name: .tool, tool_input: {paths: .paths}}' <<<"$payload" |
  claude-consent ask --payload-stdin \
    --title "OpenCode: $tool outside territory" \
    --detail "Target:    ${outside[*]}
Territory: ${roots_list:-unknown}" \
    --option 'allow=Allow this call' \
    --option 'deny=Deny' \
    --option-text 'deny=Deny reason (returned to the model)' \
    --key "$key" --deadline "$deadline_secs" \
    --extra "$territory" 2>/dev/null) ||
  emit deny "the consent question could not be raised; keep writes inside the task root"

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
    emit deny "consent request timed out after ${deadline_secs}s with no answer: $tool writes ${outside[*]}, outside this task's territory (${roots_list:-unknown}). Keep the work inside it, or re-issue the call to ask again."
    ;;
  pending)
    emit deny "$(jq -r '.instructions // "a consent question is pending"' <<<"$result" 2>/dev/null)"
    ;;
  *)
    emit deny "unexpected consent result; keep writes inside the task root"
    ;;
esac
