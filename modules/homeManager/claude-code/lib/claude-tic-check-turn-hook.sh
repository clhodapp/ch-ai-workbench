# PostToolUse hook on every tool: the mid-turn half of the judge.  The
# Stop hook judges a turn once it is finished; this hook judges the
# messages the model writes between tool calls while the turn is still
# running, so the model can use the verdict for the rest of the turn.
#
# After each tool call, claude-turn-text in progress mode reads the
# transcript and prints this turn's messages that the hook has not
# judged yet, keeping their digests in tic_session_path progress
# SESSION; a call with no new message before it abstains without
# asking the judge.  A lock under the same directory makes parallel
# tool calls abstain instead of judging the same text twice.  The new
# text goes through the regex table and the judge as kind progress
# (tic_verdict and tic_findings from tic-check-match.sh, prepended by
# the package wrapper with $table and $judge), and the result comes
# back as additionalContext, which the CLI adds to the model's context
# after the tool result.  The note opens with "tic-check: mid-turn
# verdicts" and says it is not part of the tool's output.  It never
# blocks or denies.  Everything unexpected resolves to abstention.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

transcript=$(field '.transcript_path')
[ -n "$transcript" ] || exit 0
state=$(tic_session_path progress "$(field '.session_id')") || exit 0
mkdir -p "$(dirname "$state")" 2>/dev/null || exit 0

exec 9>"$state.lock" 2>/dev/null || exit 0
flock -n 9 || exit 0

text=$(claude-turn-text --transcript "$transcript" --progress-state "$state" --max-chars "$(jq -r '.maxChars' "$judge" 2>/dev/null)" 2>/dev/null) || exit 0
[ -n "$text" ] || exit 0

verdict=$(tic_verdict progress "$text")
findings=$(tic_findings "$text" "$verdict")

problems=
scores=
if [ -n "$verdict" ]; then
  # The noul problems at or above reportAbove that tic_findings did not
  # already list as confident.
  problems=$(jq -j --slurpfile c "$judge" '
    $c[0] as $c
    | [.answers // {} | to_entries[]
       | $c.dimensions[.key] as $d
       | select($d != null and .value >= $c.reportAbove and ($d.pushBack and .value >= $c.pushBackAbove | not))]
    | sort_by(-.value)
    | map("\n- \(.key) \((.value * 100 | round) / 100): \($c.dimensions[.key].rule)")
    | add // empty
  ' <<<"$verdict" 2>/dev/null) || problems=
  scores=$(jq -j --slurpfile c "$judge" '
    $c[0] as $c
    | [.scores // {} | to_entries[] | select($c.dimensions[.key] != null and .value.score >= $c.turnScoresAbove)]
    | sort_by(-.value.score)
    | map("\n- \(.key) \((.value.score * 10 | round) / 10) of \(.value.levels - 1), most likely \(.value.level) (\((.value.p * 100 | round) / 100)); aim: \($c.dimensions[.key].rule)")
    | add // empty
  ' <<<"$verdict" 2>/dev/null) || scores=
fi

[ -n "$findings$problems$scores" ] || exit 0

tool=$(field '.tool_name')
context="tic-check: mid-turn verdicts
This note comes from the tic-check PostToolUse hook, not from the ${tool:-tool} call: it is not part of the tool's output. It covers the messages you wrote to the user in this turn since the last tic-check note, checked against the output style while the turn is still running."
if [ -n "$verdict" ]; then
  context+=" The decision model was $(jq -r '"\(.model) at \(.endpoint)"' <<<"$verdict" 2>/dev/null)."
fi
if [ -n "$findings" ]; then
  context+="
Findings (regex matches, and problems the decision model is confident about):$findings"
fi
if [ -n "$problems" ]; then
  context+="
Possible problems, with the probability the decision model put on each and the rule:$problems"
fi
if [ -n "$scores" ]; then
  context+="
Scales on which these messages sit at least $(jq -r '.turnScoresAbove' "$judge") above the first level (0), with the most likely level and the style's aim:$scores"
fi
context+="
Apply this to what you write for the rest of the turn. The messages are already on screen; the turn-end check will look at the whole turn. Do not reply to this note."

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null
exit 0
