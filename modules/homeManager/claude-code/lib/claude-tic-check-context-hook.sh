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

# The checks of the final message that reached a report level: its
# reading load, coined phrases, and references the user cannot resolve.
checks=$(jq -j --slurpfile c "$judge" '
  $c[0] as $c
  | .checks // {}
  | (if .load then "\n- too-much-at-once: load \((.load.score * 100 | round) / 100) (\(.load.words) words, \(.load.ask_words) in the prompt that opened the turn): \($c.load.rule)" else "" end)
    + ([.coinage // [] | .[] | "\n- coined phrase \"\(.phrase)\" (judge \((.score * 100 | round) / 100)): \($c.coinage.rule)"] | add // "")
    + (if (.references // []) != [] then
         "\n- references the user may not be able to resolve: \($c.references.rule)"
         + ([.references[] | "\n    \(.reference): \(.sentence)"] | add)
       else "" end)
' <<<"$verdict" 2>/dev/null) || checks=

[ -n "$report$scores$checks" ] || exit 0

scorer=$(jq -r 'if .model then "\(.model) at \(.endpoint)" else empty end' <<<"$verdict" 2>/dev/null) || scorer=
context="tic-check: verdicts
The tic-check hooks read your previous turn (the final message and the messages before it since the user's prompt) against the output style${scorer:+, with a decision model ($scorer)}."
if [ -n "$checks" ]; then
  context+="
Checks of the final message, below the level at which they push back:$checks"
fi
if [ -n "$report" ]; then
  context+="
These problems scored at or above $(jq -r '.reportAbove' "$judge"), below the level at which the check pushes back; each line gives the probability the model put on it and the rule:$report"
fi
if [ -n "$scores" ]; then
  context+="
Scores of the turn; each line gives the position on its scale (0 is the first level, the number after \"of\" the last), the most likely level with its probability, and the style's aim:$scores"
fi
context+="
Weigh this in what you write next. Do not reply to this note."

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $c}}' 2>/dev/null
exit 0
