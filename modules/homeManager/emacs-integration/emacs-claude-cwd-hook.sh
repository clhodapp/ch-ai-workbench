# Claude Code session-cwd hook (CwdChanged + PostToolUse on the
# worktree tools): push the session's new working directory into the
# live Emacs (claude-queue follow-mode).  Observation hook -- every
# branch fails open so a session never blocks on the editor's state:
# a dead or hung Emacs is bounded by the timeout and swallowed, and
# unparseable stdin exits 0 quietly rather than leaking jq's error
# and exit status into the session (hook stderr on a non-zero exit
# is surfaced to the model).

payload=$(cat)
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null || true)
cwd=$(jq -r '.cwd // empty' <<<"$payload" 2>/dev/null || true)
[ -n "$session" ] && [ -n "$cwd" ] || exit 0

# Elisp string escaping: backslash and double quote are the only
# special characters in an elisp string literal.
escape() { printf '%s' "$1" | sed 's/[\\"]/\\&/g'; }

timeout 2 emacsclient \
  --socket-name="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/emacs/server" \
  --eval "(when (fboundp 'claude-queue-session-cwd-changed) (claude-queue-session-cwd-changed \"$(escape "$session")\" \"$(escape "$cwd")\"))" \
  > /dev/null 2>&1 || true
