# PreToolUse hook on Bash: a git push costs one confirmation that the
# branch's pull request, if it has one, is still open.  GitHub keeps
# accepting pushes to the head branch of a merged pull request, and
# each one lands commits on a closed PR that nobody reviews or merges;
# the push itself carries no sign of that, so the call is denied once
# with a reminder to check the PR state (gh pr list --head), and the
# reason comes back to the model as the tool result.
#
# One denial per push: a marker keyed by session and a hash of
# {tool_name, tool_input} is written before the deny, and the
# identical re-issue finds the marker, removes it, and passes.  The
# marker is consumed rather than kept (the edit-side tic check keeps
# its markers) because the same push command later in the session,
# after the PR was merged in between, is exactly the case to catch:
# every push costs one check, and the re-issue is the model's word
# that it looked.  Markers live under
# $XDG_RUNTIME_DIR/claude-push-pr-check/seen/ (per login, ephemeral).
#
# What counts as a push: the word git, any number of global options
# (-C dir, -c key=value, --no-pager, ...), then push as its own word,
# anywhere on a line of the command -- so "cd x && git push",
# "git -C projects/foo push origin topic", and "git push
# --force-with-lease" fire, while "git commit -m 'push later'" and
# "git log | grep push" do not.
#
# Everything unexpected -- no runtime dir, no session id, a failed
# marker write, jq failure -- resolves to abstention (exit 0, no
# output), which lets the native permission flow decide.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

cmd=$(field '.tool_input.command')
[ -n "$cmd" ] || exit 0
grep -Eq '\bgit\b([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]][^[:space:]]*)?)*[[:space:]]+push([[:space:]]|$)' <<<"$cmd" || exit 0

runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || exit 0
session=$(field '.session_id')
[ -n "$session" ] || exit 0
key=$(jq -c '{tool_name, tool_input}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-64)
[ -n "$key" ] || exit 0
seen="$runtime/claude-push-pr-check/seen/${session:0:8}-$key"
if [ -e "$seen" ]; then
  rm -f "$seen" 2>/dev/null || true
  exit 0
fi

mkdir -p "$(dirname "$seen")" 2>/dev/null && : > "$seen" 2>/dev/null || exit 0

reason="push-pr-check: verify
This command appears to run git push. If it does, and the branch it pushes has a pull request, confirm that the pull request is not already merged before pushing: from inside that repository run
  gh pr list --head <branch> --state all --json number,state,url
A merged pull request does not take new commits. If the state is MERGED, do not push to that branch: start a new branch from main, commit there, and open a new pull request. If the pull request is OPEN, if the branch has no pull request, or if the command does not actually push, re-issue this exact command unchanged; the identical re-issue passes."

jq -cn --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse",
                         permissionDecision: "deny",
                         permissionDecisionReason: $r}}' 2>/dev/null
exit 0
