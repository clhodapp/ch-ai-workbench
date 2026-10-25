# UserPromptSubmit hook: the non-blocking half of the judge.  When the
# tic-check Stop hook (claude-tic-check-hook.sh) let a message stand,
# it kept the judge's verdict on that message at tic_verdict_path
# SESSION (from tic-check-verdict-path.sh, prepended by the package
# wrapper with $judge).  With the user's next prompt this hook reads that
# verdict once, deletes it, and returns as additionalContext the noul
# dimensions the judge put at or above judge.reportAbove and every
# score dimension (the readability scales), which the CLI adds to the
# model's context beside the prompt; nothing is shown to the user.  A
# verdict with nothing to report, a missing file, no runtime dir, or a
# jq failure resolves to abstention (exit 0, no output).

payload=$(cat) || exit 0

store=$(tic_verdict_path "$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)") || exit 0
[ -f "$store" ] || exit 0
verdict=$(cat "$store" 2>/dev/null) || exit 0
rm -f "$store" 2>/dev/null || true

report=$(jq -j --slurpfile c "$judge" '
  $c[0] as $c
  | [.answers // {} | to_entries[] | select(.value >= $c.reportAbove and $c.dimensions[.key] != null)]
  | sort_by(-.value)
  | map("\n- \(.key) \((.value * 100 | round) / 100): \($c.dimensions[.key].rule)")
  | add // empty
' <<<"$verdict" 2>/dev/null) || exit 0

# Every score, highest effort first: the expected position on the scale
# (0 is the first level), the most likely level with its probability,
# and the style's aim for that cause.
scores=$(jq -j --slurpfile c "$judge" '
  $c[0] as $c
  | [.scores // {} | to_entries[] | select($c.dimensions[.key] != null)]
  | sort_by(-.value.score)
  | map("\n- \(.key) \((.value.score * 10 | round) / 10) of \(.value.levels - 1), most likely \(.value.level) (\((.value.p * 100 | round) / 100)); aim: \($c.dimensions[.key].rule)")
  | add // empty
' <<<"$verdict" 2>/dev/null) || exit 0

[ -n "$report$scores" ] || exit 0

scorer=$(jq -r '"\(.model) at \(.endpoint)"' <<<"$verdict" 2>/dev/null) || exit 0
context="tic-check: verdicts
A decision model ($scorer) read your previous message against the output style."
if [ -n "$report" ]; then
  context+="
These problems scored at or above $(jq -r '.reportAbove' "$judge"), below the level at which the check pushes back; each line gives the probability the model put on it and the rule:$report"
fi
if [ -n "$scores" ]; then
  context+="
These scales place the message as a whole and by each cause; each line gives the position on its scale (0 is the first level, the number after \"of\" the last), the most likely level with its probability, and the style's aim:$scores"
fi
context+="
Weigh this in what you write next. Do not reply to this note."

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
exit 0
