# Stop hook: a two-step double-check for the phrasings the
# peer-programmer output style bans and a regex can catch (the
# possessive handoff "X is yours", em-dashes, "click", arrows, ...).
# Matching lives in tic-check-match.sh (tic_findings), prepended by
# the package wrapper together with $table, the JSON table rendered
# from ch-ai-workbench.claude-code.ticChecks; the edit-side twin is
# claude-tic-check-edit-hook.sh.
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
#      checker emits whenever it fires, however confident it is (the
#      regex today, a classifier later) -- listing the matching lines
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

findings=$(tic_findings "$message")
[ -n "$findings" ] || exit 0

emit "tic-check: check
The message you just finished contains phrasing the output style bans:$findings
Re-read each occurrence against its rule, then reply with exactly one of the next two lines and nothing else, no explanation:
tic-check: clean
tic-check: tic
(clean: every occurrence is legitimate, such as a quotation, a real possessive, or a literal symbol in quoted output; the message stands. tic: at least one occurrence is the banned phrasing; you will then be asked to post the message again without it.)"
