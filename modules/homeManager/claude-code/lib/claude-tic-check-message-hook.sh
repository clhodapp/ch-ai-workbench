# PreToolUse hook on Bash: the tic-check for commit messages, pull
# request texts, and code reviews, which the model writes through a
# shell command rather than an edit.  claude-vcs-message (from the
# claude-response-judge package) reads the command and prints the text
# it writes: the messages of a `git ... commit` (-m, --message, -F from
# a here-document or a file), the title, body, comment, or review of a
# `gh pr create|edit|comment|review`, and the review and comment bodies
# a `gh api` call posts to a pull request.  A command that writes none
# abstains.  The text
# is matched against the regex table and scored by the judge as a
# message, beside the user's latest messages from the session
# transcript (tic_verdict and tic_findings from tic-check-match.sh,
# prepended by the package wrapper with $table and $judge).  On a
# finding the command is denied once with the findings, and the reason
# comes back to the model as the tool result.
#
# One denial per identical command, keyed and stored as in
# claude-tic-check-edit-hook.sh, so a command re-issued unchanged runs.
# Everything unexpected resolves to abstention (exit 0, no output),
# which lets the native permission flow decide.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

command=$(field '.tool_input.command')
[ -n "$command" ] || exit 0

text=$(claude-vcs-message --cwd "$(field '.cwd')" <<<"$command" 2>/dev/null) || exit 0
[ -n "$text" ] || exit 0

runtime="${XDG_RUNTIME_DIR:-}"
[ -n "$runtime" ] || exit 0
session=$(field '.session_id')
[ -n "$session" ] || exit 0
key=$(jq -c '{tool_name, tool_input}' <<<"$payload" 2>/dev/null | sha256sum | cut -c1-64)
[ -n "$key" ] || exit 0
seen="$runtime/claude-tic-check/seen/${session:0:8}-$key"
[ -e "$seen" ] && exit 0

verdict=$(tic_verdict message "$text" "" "$(field '.transcript_path')")

findings=$(tic_findings "$text" "$verdict" message)

# A commit message or pull request text is where a coined phrase
# leaves the session, so it gets the coinage check (tic_write_coinage
# from tic-check-turn-checks.sh), which counts this write as a use.
wchecks=$(tic_write_coinage "$text" "$(field '.transcript_path')")
findings+=$(jq -r '.findings // ""' <<<"$wchecks" 2>/dev/null) || true
coined=$(jq -c '.report.coinage // []' <<<"$wchecks" 2>/dev/null) || coined=
[ -n "$coined" ] || coined='[]'

# What the message leans on that only the conversation showed
# (tic_write_familiarity); a reviewer reads it cold.
fchecks=$(tic_write_familiarity message "$text" "" "$(field '.transcript_path')")
findings+=$(jq -r '.findings // ""' <<<"$fchecks" 2>/dev/null) || true
familiar=$(jq -c '.report // []' <<<"$fchecks" 2>/dev/null) || familiar=
[ -n "$familiar" ] || familiar='[]'

if [ -z "$findings" ]; then
  # The command runs: keep the verdict for claude-tic-check-turn-hook,
  # which reports what it found below the push-back level after the call.
  if { [ -n "$verdict" ] || [ "$coined" != '[]' ] || [ "$familiar" != '[]' ]; } && written=$(tic_write_path "$session" "$payload"); then
    { mkdir -p "$(dirname "$written")" &&
      jq -cn --argjson v "$(tic_json_or_null "$verdict")" --argjson c "$coined" --argjson f "$familiar" \
        '{kind: "message", verdict: ($v // {}), coinage: $c, familiarity: $f}' > "$written"; } 2>/dev/null || true
  fi
  exit 0
fi

mkdir -p "$(dirname "$seen")" 2>/dev/null && : > "$seen" 2>/dev/null || exit 0

reason="tic-check: check
The commit message, pull request text, or review this command writes may break the output style's rules:$findings
Re-read the text against each finding's rule. If any finding is real, re-issue the command with that text rewritten. If every finding is a false alarm (quoted text, a real possessive, a literal symbol in code or quoted output), re-issue the same command unchanged; an identical re-issue is not checked again."

jq -cn --arg r "$reason" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse",
                         permissionDecision: "deny",
                         permissionDecisionReason: $r}}' 2>/dev/null
exit 0
