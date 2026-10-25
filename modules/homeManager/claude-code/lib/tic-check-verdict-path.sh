# Shared by the tic-check Stop hook, which writes the judge's verdict
# on a message it let stand, and the context hook, which reads it with
# the next prompt (prepended to each script by its package wrapper).
#
# tic_verdict_path SESSION prints where that verdict is kept, or fails
# when there is no runtime dir or the session id is not a plain token.

# The mid-turn hook includes this file for tic_session_path only.
# shellcheck disable=SC2329
tic_verdict_path() {
  tic_session_path verdicts "$1"
}

# tic_session_path KIND SESSION prints $XDG_RUNTIME_DIR/claude-tic-check/
# KIND/SESSION.json, the per-session state file of one hook, or fails
# like tic_verdict_path.
tic_session_path() {
  local runtime=${XDG_RUNTIME_DIR:-} session=$2
  [ -n "$runtime" ] && [[ $session =~ ^[A-Za-z0-9-]+$ ]] || return 1
  printf '%s/claude-tic-check/%s/%s.json' "$runtime" "$1" "$session"
}
