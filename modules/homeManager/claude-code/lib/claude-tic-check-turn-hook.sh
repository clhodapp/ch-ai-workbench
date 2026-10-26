# PostToolUse hook on every tool: the mid-turn half of the judge.  The
# Stop hook judges a turn once it is finished; this hook reports, while
# the turn is still running, on the two kinds of text the model has
# written since its last note, so the model can use the verdict for
# the rest of the turn.
#
# The write the call just made.  The edit hook and the message hook
# judge a write before it runs (as prose, code, or message) and stop it
# only on a confident finding.  When they let it through they keep the
# verdict at tic_write_path SESSION PAYLOAD (tic-check-verdict-path.sh),
# and this hook reads it for the same call, deletes it, and reports the
# noul problems at or above judge.reportAbove.  This is where a comment
# or a commit message that argues with ghosts below the push-back level
# shows up: those texts come into the turn through tool calls.
#
# The messages to the user.  claude-turn-text in progress mode reads
# the transcript and prints this turn's messages that the hook has not
# judged yet, keeping their digests in tic_session_path progress
# SESSION; with no new message the judge is not asked.  A lock makes
# parallel tool calls skip this part instead of judging the same text
# twice.  The text goes through the regex table and the judge as kind
# progress (tic_verdict and tic_findings from tic-check-match.sh).
#
# The report comes back as additionalContext, which the CLI adds to the
# model's context after the tool result.  The note opens with
# "tic-check: mid-turn verdicts", says it is not part of the tool's
# output, and names the source of each section.  It never blocks or
# denies.  Everything unexpected resolves to abstention.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

session=$(field '.session_id')
tool=$(field '.tool_name')
tool=${tool:-tool}
sections=
scorer=

# Noul problems at or above reportAbove in a verdict ($1) on text of
# kind $2, leaving out those tic_findings lists as confident.
problems_in() {
  local at
  at=$(tic_push_back_above "$2") || return 0
  jq -j --slurpfile c "$judge" --argjson at "$at" '
    $c[0] as $c
    | [.answers // {} | to_entries[]
       | $c.dimensions[.key] as $d
       | select($d != null and .value >= $c.reportAbove and ($d.pushBack and .value >= $at | not))]
    | sort_by(-.value)
    | map("\n- \(.key) \((.value * 100 | round) / 100): \($c.dimensions[.key].rule)")
    | add // empty
  ' <<<"$1" 2>/dev/null || true
}

if written=$(tic_write_path "$session" "$payload") && [ -f "$written" ]; then
  stored=$(cat "$written" 2>/dev/null) || stored=
  rm -f "$written" 2>/dev/null || true
  if [ -n "$stored" ]; then
    write_verdict=$(jq -c '.verdict' <<<"$stored" 2>/dev/null) || write_verdict=
    write_kind=$(jq -r '.kind' <<<"$stored" 2>/dev/null) || write_kind=
    lines=$(problems_in "$write_verdict" "$write_kind")
    # Coined phrases the write uses, which the coinage check scored
    # below the level that stops a write.
    lines+=$(jq -j --slurpfile c "$judge" '
      $c[0] as $c
      | [.coinage // [] | .[] | "\n- coined phrase \"\(.phrase)\" (judge \((.score * 100 | round) / 100)): \($c.coinage.rule)"]
      | add // empty
    ' <<<"$stored" 2>/dev/null) || true
    # Sentences that may argue with ghosts, below the level that stops
    # a write.
    lines+=$(jq -j --slurpfile c "$judge" '
      $c[0] as $c
      | [.ghosts // [] | .[] | "\n- arguing-with-ghosts sentence (judge \((.p * 100 | round) / 100)): \"\(.sentence)\"; \($c.ghosts.rule)"]
      | add // empty
    ' <<<"$stored" 2>/dev/null) || true
    if [ -n "$lines" ]; then
      sections+="
The text this $tool call wrote, judged as $write_kind before it ran and let through because no problem reached the level that stops a write; probability and rule:$lines"
      scorer=$(jq -r 'if .model then "\(.model) at \(.endpoint)" else empty end' <<<"$write_verdict" 2>/dev/null) || scorer=
    fi
  fi
fi

transcript=$(field '.transcript_path')
if [ -n "$transcript" ] && state=$(tic_session_path progress "$session") &&
  mkdir -p "$(dirname "$state")" 2>/dev/null &&
  { exec 9>"$state.lock"; } 2>/dev/null && flock -n 9; then
  text=$(claude-turn-text --transcript "$transcript" --progress-state "$state" --max-chars "$(jq -r '.maxChars' "$judge" 2>/dev/null)" 2>/dev/null) || text=
  if [ -n "$text" ]; then
    verdict=$(tic_verdict progress "$text")
    findings=$(tic_findings "$text" "$verdict")
    problems=
    scores=
    if [ -n "$verdict" ]; then
      problems=$(problems_in "$verdict" progress)
      scores=$(jq -j --slurpfile c "$judge" '
        $c[0] as $c
        | [.scores // {} | to_entries[] | select($c.dimensions[.key] != null and .value.score >= $c.turnScoresAbove)]
        | sort_by(-.value.score)
        | map("\n- \(.key) \((.value.score * 10 | round) / 10) of \(.value.levels - 1), most likely \(.value.level) (\((.value.p * 100 | round) / 100)); aim: \($c.dimensions[.key].rule)")
        | add // empty
      ' <<<"$verdict" 2>/dev/null) || scores=
      scorer=$(jq -r '"\(.model) at \(.endpoint)"' <<<"$verdict" 2>/dev/null) || scorer=
    fi
    if [ -n "$findings" ]; then
      sections+="
The messages you wrote to the user since the last note, findings (regex matches, and problems the decision model is confident about):$findings"
    fi
    if [ -n "$problems" ]; then
      sections+="
The messages you wrote to the user since the last note, possible problems; probability and rule:$problems"
    fi
    if [ -n "$scores" ]; then
      sections+="
The messages you wrote to the user since the last note, scales on which they sit at least $(jq -r '.turnScoresAbove' "$judge") above the first level (0), with the most likely level and the style's aim:$scores"
    fi
  fi
fi

[ -n "$sections" ] || exit 0

context="tic-check: mid-turn verdicts
This note comes from the tic-check PostToolUse hook, not from the $tool call: it is not part of the tool's output. It covers what you wrote in this turn since the last tic-check note, checked against the output style while the turn is still running."
[ -z "$scorer" ] || context+=" The decision model was $scorer."
context+="$sections
Apply this to what you write for the rest of the turn; the text it covers is already written, and a write can be corrected with another edit. The turn-end check will look at the whole turn. Do not reply to this note."

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse", additionalContext: $c}}' 2>/dev/null
exit 0
