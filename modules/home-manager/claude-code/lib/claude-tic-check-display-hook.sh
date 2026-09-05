# MessageDisplay hook: renders the tic-check verdict tokens.  The
# tic-check Stop hook (claude-tic-check-hook.sh) asks the model for a
# verdict in a fixed line -- "tic-check: clean" or "tic-check: tic" --
# and on screen each becomes one short status line.  MessageDisplay
# fires with each batch of newly completed lines while an assistant
# message streams, and once with the whole message in a headless
# session (docs/development/claude-cli.md "MessageDisplay hooks"); it
# is display-only, so the stored message and what the model sees keep
# the token and only the rendering changes.  A delta that is a token
# and nothing else is replaced; anything else abstains (exit 0, no
# output), including a token mixed with other text, which is the
# model not following the instruction and should stay visible as is.
# The hook's own "tic-check: check" / "tic-check: rewrite" reasons
# are not assistant messages and do not pass through here.

payload=$(cat) || exit 0

delta=$(jq -r '.delta // empty' <<<"$payload" 2>/dev/null) || exit 0

render() { # $1 = status line shown in place of the token
  jq -cn --arg t "$1" '{hookSpecificOutput: {hookEventName: "MessageDisplay", displayContent: $t}}' 2>/dev/null
  exit 0
}

case "$(printf '%s' "$delta" | tr -d '[:space:]')" in
  'tic-check:clean') render '✓ tic-check: clean, the message above stands' ;;
  'tic-check:tic') render '✗ tic-check: tic, rewriting the message' ;;
esac
exit 0
