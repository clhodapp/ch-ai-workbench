# UserPromptSubmit hook: the non-blocking half of the judge.  When the
# tic-check Stop hook (claude-tic-check-hook.sh) let a message stand,
# it kept the judge's verdict on that message at tic_verdict_path
# SESSION (from tic-check-verdict-path.sh, prepended by the package
# wrapper with $judge).  With the user's next prompt this hook reads that
# verdict once, deletes it, and returns the dimensions the judge put at
# or above judge.reportAbove as additionalContext, which the CLI adds
# to the model's context beside the prompt; nothing is shown to the
# user.  A verdict with nothing at that level, a missing file, no
# runtime dir, or a jq failure resolves to abstention (exit 0, no
# output).

payload=$(cat) || exit 0

store=$(tic_verdict_path "$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)") || exit 0
[ -f "$store" ] || exit 0
verdict=$(cat "$store" 2>/dev/null) || exit 0
rm -f "$store" 2>/dev/null || true

report=$(jq -j --slurpfile c "$judge" '
  $c[0] as $c
  | [.answers | to_entries[] | select(.value >= $c.reportAbove and $c.dimensions[.key] != null)]
  | sort_by(-.value)
  | map("\n- \(.key) \((.value * 100 | round) / 100): \($c.dimensions[.key].rule)")
  | add // empty
' <<<"$verdict" 2>/dev/null) || exit 0
[ -n "$report" ] || exit 0

scorer=$(jq -r '"\(.model) at \(.endpoint)"' <<<"$verdict" 2>/dev/null) || exit 0
context="tic-check: verdicts
A decision model ($scorer) scored your previous message against the output style. These problems scored at or above $(jq -r '.reportAbove' "$judge"), below the level at which the check pushes back; each line gives the probability the model put on it and the rule:$report
Weigh them in what you write next. Do not reply to this note."

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
exit 0
