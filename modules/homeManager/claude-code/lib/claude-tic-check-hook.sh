# Stop hook: a two-step double-check of the finished turn against the
# peer-programmer output style.  The turn is every message the model
# wrote since the user's last prompt: the CLI hands the hook only the
# final one, and claude-turn-text adds the messages written between
# tool calls from the transcript.  Two checkers feed it: the regex
# table (ch-ai-workbench.claude-code.ticChecks: the possessive handoff
# "X is yours", em-dashes, "click", arrows, ...) and the judge, a
# System One decision model that scores the message on each of
# judge.dimensions.  Matching and judging live in tic-check-match.sh
# (tic_verdict, tic_findings), prepended by the package wrapper
# together with $table and $judge; the edit-side twin is
# claude-tic-check-edit-hook.sh.
#
# When nothing pushes back, the verdict is kept under the runtime dir
# and claude-tic-check-context-hook hands it to the model with the
# next prompt, so the dimensions the judge found likely but not
# certain still reach the model, without a block.
#
# The CLI gives Stop hooks the finished message as
# last_assistant_message and flags a stop that follows a block with
# stop_hook_active (2.1.241; docs/development/claude-cli.md "Stop
# hooks").  The cycle is stateless because those two fields carry it,
# and every message in it is headed by a fixed token so consumers
# can recognize each step:
#
#   1. First stop (stop_hook_active false): match the message and on
#      a hit block with a reason headed "tic-check: check" -- what the
#      checker emits whenever it fires, however confident it is (a
#      regex entry or a confident judge dimension) -- listing the findings
#      and rules and asking for a VERDICT ONLY: "tic-check: clean"
#      (ends there) or "tic-check: tic".  The verdict is the
#      full-power model's, and "clean" is how it overrules the check.
#   2. Second stop (stop_hook_active true): if the message is exactly
#      the "tic" verdict, block once more with a reason headed
#      "tic-check: rewrite", asking for the last message to be posted
#      again without the flagged phrasing.
#   3. Anything else at a second stop -- the clean verdict, the
#      regenerated message, a reply that is no token -- ends the turn.
#      Two blocks per cycle at most; the CLI caps consecutive blocks
#      at 8 on top.
#
# The MessageDisplay hook (claude-tic-check-display-hook.sh) renders
# the verdict tokens as status lines; the hook's own reasons reach the
# screen as "Stop hook feedback" events, which only a consumer can
# restyle.  A hook cannot withdraw or edit a message already shown
# (its only channel back is the reason string), so the regenerated
# message is a second message the reader uses in place of the first.
# Every unexpected condition (no payload, no message field, jq
# failure) resolves to abstention: exit 0 with no output.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

message=$(field '.last_assistant_message')
[ -n "$message" ] || exit 0

emit() { # $1 = reason; always a clean exit
  jq -cn --arg r "$1" '{decision: "block", reason: $r}' 2>/dev/null
  exit 0
}

if [ "$(field '.stop_hook_active')" = "true" ]; then
  case "$(printf '%s' "$message" | tr -d '[:space:]')" in
    'tic-check:tic')
      emit "tic-check: rewrite
Post your final message (the one before your verdict) again in full, with each flagged phrasing rewritten per the rules you were given, and nothing else (no preamble, no note about the change). The earlier messages of the turn are already on screen: where a finding was in one of them, or the final message left out what the turn found, restate that point correctly in the final message when the reader needs it."
      ;;
  esac
  exit 0
fi

# The whole turn: the messages written between tool calls since the
# user's last prompt, read from the transcript, then this final message
# (claude-turn-text heads each, keeps the trailing judge.maxChars of a
# long turn, and falls back to the final message alone when the
# transcript cannot be read).
turn=$(claude-turn-text --transcript "$(field '.transcript_path')" --max-chars "$(jq -r '.maxChars' "$judge" 2>/dev/null)" <<<"$message" 2>/dev/null) || turn=
[ -n "$turn" ] || turn=$message

verdict=$(tic_verdict reply "$turn")
findings=$(tic_findings "$turn" "$verdict")

# The checks of the final message beside the session: its reading load,
# phrases the assistant coined, and references the user cannot resolve
# (tic_turn_checks from tic-check-turn-checks.sh).
checks=$(tic_turn_checks "$message" "$(field '.transcript_path')" "$verdict")
findings+=$(jq -r '.findings // ""' <<<"$checks" 2>/dev/null) || true
report=$(jq -c '.report // {}' <<<"$checks" 2>/dev/null) || report=
[ -n "$report" ] || report='{}'

store=$(tic_verdict_path "$(field '.session_id')") || store=

if [ -z "$findings" ]; then
  # No push-back: keep the verdict and the checks' report for
  # claude-tic-check-context-hook, which hands them to the model with
  # the next prompt.
  reported=$(jq -r 'if .load != null or (.coinage // []) != [] or (.references // []) != [] then "yes" else empty end' <<<"$report" 2>/dev/null) || reported=
  if [ -n "$store" ] && { [ -n "$verdict" ] || [ -n "$reported" ]; }; then
    kept=$(jq -cn --argjson v "$(tic_json_or_null "$verdict")" --argjson r "$report" '($v // {}) + {checks: $r}' 2>/dev/null) || kept=
    if [ -n "$kept" ]; then
      { mkdir -p "$(dirname "$store")" && printf '%s\n' "$kept" > "$store"; } 2>/dev/null || true
    fi
  fi
  exit 0
fi

# The check below carries the findings itself, and the message it
# leads to is a verdict or a rewrite, so an older verdict must not
# reach the next prompt.
[ -z "$store" ] || rm -f "$store" 2>/dev/null || true

judged=
if [ -n "$verdict" ]; then
  judged="
Entries marked judge carry the probability a decision model ($(jq -r '"\(.model) at \(.endpoint)"' <<<"$verdict" 2>/dev/null)) put on the problem; it scores the whole message and cannot point at lines."
fi

emit "tic-check: check
The turn you just finished (your final message and the messages you wrote between tool calls since the user's prompt) may break the output style's rules:$findings$judged
Re-read the turn against each finding's rule, then reply with exactly one of the next two lines and nothing else, no explanation:
tic-check: clean
tic-check: tic
(clean: every finding is a false alarm, such as a quotation, a real possessive, or a literal symbol in quoted output; the turn stands. tic: at least one finding is real; you will then be asked to post your final message again with it fixed.)"
