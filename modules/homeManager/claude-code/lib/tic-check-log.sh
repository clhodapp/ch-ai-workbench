# Shared by all the tic-check hooks (prepended to each script by its
# package wrapper).

# tic_log EVENT [FIELDS] appends one JSON line to
# ${XDG_STATE_HOME:-~/.local/state}/claude-tic-check/events.jsonl:
# {ts, session, event} plus FIELDS, a JSON object (default {}).  The
# state dir survives a reboot, unlike the runtime dir where the hooks
# keep their verdicts, so the log answers how often the judge and the
# ticChecks patterns pushed back and what the model did next.  The session id
# is the calling hook's `session` variable.  The events:
#   judge     one judge call: kind, answered, ms, endpoint, model,
#             answers (P per dimension), scores (score per scale)
#   findings  what tic_findings reported: kind, regex (entry names),
#             judge ({dimension, p} at or above the push-back level)
#   blocked   a hook sent a "tic-check: check" or "rewrite" reason
#   answered  the reply to a check at the second stop: clean, tic, other
#   note      a hook handed the model a verdict as additionalContext
# Logging never fails and never prints.
tic_log() {
  local dir fields=${2:-}
  dir=${XDG_STATE_HOME:-${HOME:-}/.local/state}/claude-tic-check
  [ -n "${XDG_STATE_HOME:-}${HOME:-}" ] || return 0
  [ -n "$fields" ] || fields='{}'
  { mkdir -p "$dir" &&
    jq -cn --arg e "$1" --arg s "${session:-}" --argjson f "$fields" \
      '{ts: (now | floor), session: $s, event: $e} + $f' >> "$dir/events.jsonl"; } 2>/dev/null || true
}
