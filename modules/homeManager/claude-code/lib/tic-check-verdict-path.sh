# Shared by the tic-check Stop hook, which writes the judge's verdict
# on a message it let stand, and the context hook, which reads it with
# the next prompt (prepended to each script by its package wrapper).
#
# tic_verdict_path SESSION prints where that verdict is kept, or fails
# when there is no runtime dir or the session id is not a plain token.

tic_verdict_path() {
  local runtime=${XDG_RUNTIME_DIR:-} session=$1
  [ -n "$runtime" ] && [[ $session =~ ^[A-Za-z0-9-]+$ ]] || return 1
  printf '%s/claude-tic-check/verdicts/%s.json' "$runtime" "$session"
}
