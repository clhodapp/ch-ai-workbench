# PostToolUse hook on Bash: when a command creates a GitHub pull
# request, record which session created it.  A review of that pull
# request later reads the record to find the conversation the work
# came from, so follow-ups and fixes can go back to it; nothing in
# git or on GitHub may carry that link, so the record stays on this
# machine.
#
# Creating commands are gh pr create and gh-stack (in any wrapper,
# such as nix shell ... -c gh-stack): every pull request link in such
# a command's output is recorded.  Other commands print links too
# (gh pr list, gh pr view), and recording those would name a session
# that only looked at a pull request as its origin, so they are left
# out.
#
# Each record is one JSON line appended to
# ${XDG_STATE_HOME:-~/.local/state}/claude-pr-origins/origins.jsonl:
# {url, session_id, cwd, transcript_path, time}.  The newest record
# for a link wins.
#
# Everything unexpected (no command, no link, jq failure, an
# unwritable state directory) resolves to silence: the hook never
# prints anything, so it never changes what the model sees.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

cmd=$(field '.tool_input.command')
[ -n "$cmd" ] || exit 0
grep -Eq '(\bgh[[:space:]]+pr[[:space:]]+create\b|\bgh-stack\b)' <<<"$cmd" || exit 0

output=$(jq -r '[.tool_response | .. | strings] | join("\n")' <<<"$payload" 2>/dev/null) || exit 0
urls=$(grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' <<<"$output" | sort -u) || exit 0
[ -n "$urls" ] || exit 0

session=$(field '.session_id')
[ -n "$session" ] || exit 0
cwd=$(field '.cwd')
transcript=$(field '.transcript_path')

dir="${XDG_STATE_HOME:-$HOME/.local/state}/claude-pr-origins"
mkdir -p "$dir" 2>/dev/null || exit 0
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)

while IFS= read -r url; do
  jq -cn --arg url "$url" --arg session "$session" --arg cwd "$cwd" \
    --arg transcript "$transcript" --arg time "$now" \
    '{url: $url, session_id: $session, cwd: $cwd,
      transcript_path: $transcript, time: $time}' \
    >>"$dir/origins.jsonl" 2>/dev/null || true
done <<<"$urls"
exit 0
