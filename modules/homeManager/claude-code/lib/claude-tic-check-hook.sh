# Stop hook: a two-step double-check of the finished message against
# the peer-programmer output style.  Two checkers feed it: the regex
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
Post the message before your verdict again in full, with each flagged phrasing rewritten per the rules you were given, and nothing else (no preamble, no note about the change)."
      ;;
  esac
  exit 0
fi

verdict=$(tic_verdict reply "$message")
findings=$(tic_findings "$message" "$verdict")
store=$(tic_verdict_path "$(field '.session_id')") || store=

if [ -z "$findings" ]; then
  # No push-back: keep the verdict for claude-tic-check-context-hook,
  # which hands it to the model with the next prompt.
  if [ -n "$store" ] && [ -n "$verdict" ]; then
    { mkdir -p "$(dirname "$store")" && printf '%s\n' "$verdict" > "$store"; } 2>/dev/null || true
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
The message you just finished may break the output style's rules:$findings$judged
Re-read the message against each finding's rule, then reply with exactly one of the next two lines and nothing else, no explanation:
tic-check: clean
tic-check: tic
(clean: every finding is a false alarm, such as a quotation, a real possessive, or a literal symbol in quoted output; the message stands. tic: at least one finding is real; you will then be asked to post the message again without it.)"
