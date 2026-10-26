# Shared by the tic-check hooks that hand a verdict from one hook to
# another (prepended to each script by its package wrapper): the Stop
# hook keeps its verdict on a turn it let stand for the context hook,
# and the edit and message hooks keep their verdicts on a write they
# let through for the mid-turn hook.
#
# tic_verdict_path SESSION prints where that verdict is kept, or fails
# when there is no runtime dir or the session id is not a plain token.

# The mid-turn hook includes this file for tic_session_path only.
# shellcheck disable=SC2329
tic_verdict_path() {
  tic_session_path verdicts "$1"
}

# tic_write_path SESSION PAYLOAD prints where the PreToolUse hooks keep
# the judge's verdict on a write they let through, for the PostToolUse
# hook to report after the call: one file per session and call, keyed
# by a digest of the payload's {tool_name, tool_input} with sorted keys,
# which the two events' payloads share.  Fails without a runtime dir or
# a session id.
# shellcheck disable=SC2329
tic_write_path() {
  local runtime=${XDG_RUNTIME_DIR:-} session=$1 key
  [ -n "$runtime" ] && [ -n "$session" ] || return 1
  key=$(jq -cS '{tool_name, tool_input}' <<<"$2" 2>/dev/null | sha256sum | cut -c1-64) || return 1
  printf '%s/claude-tic-check/writes/%s-%s.json' "$runtime" "${session:0:8}" "$key"
}

# tic_session_path KIND SESSION prints $XDG_RUNTIME_DIR/claude-tic-check/
# KIND/SESSION.json, the per-session state file of one hook, or fails
# like tic_verdict_path.  Each hook that includes this file calls only
# some of these helpers.
# shellcheck disable=SC2329
tic_session_path() {
  local runtime=${XDG_RUNTIME_DIR:-} session=$2
  [ -n "$runtime" ] && [[ $session =~ ^[A-Za-z0-9-]+$ ]] || return 1
  printf '%s/claude-tic-check/%s/%s.json' "$runtime" "$1" "$session"
}
