# PostToolUse hook on Bash: when a command opened a GitHub pull
# request into a branch other than main, master or develop, remind
# the model that GitHub has stacked pull requests as a feature.  A
# pull request based on another pull request's branch is usually the
# upper part of a chain, and a chain made by setting --base by hand is
# not a stack: GitHub does not rebase or retarget it when the lower
# pull request merges, so the upper one can merge into a stale branch
# whose commits never reach the default branch.  The reminder tells
# the model to link the chain with gh-stack.
#
# What counts as opening one: gh pr create (or its alias gh pr new)
# with a base given as --base X, --base=X, -B X or -BX, and a pull
# request link in the output, which gh prints only once the pull
# request exists.  A command that also runs gh-stack is already
# working with a stack and is left alone.
#
# The note goes to the model as additionalContext; the command and
# its output are unchanged.  Everything unexpected (no command, no
# base, jq failure) resolves to silence.

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

cmd=$(field '.tool_input.command')
[ -n "$cmd" ] || exit 0
grep -Eq '\bgh[[:space:]]+pr[[:space:]]+(create|new)\b' <<<"$cmd" || exit 0
grep -Eq '\bgh-stack\b|\bgh[[:space:]]+stack\b' <<<"$cmd" && exit 0

flag="[[:space:]](--base(=|[[:space:]]+)|-B[[:space:]]*)[\"']?"
bases=$(grep -Eo -- "${flag}[^\"'[:space:];&|)]+" <<<"$cmd" | sed -E "s/^$flag//") || exit 0
[ -n "$bases" ] || exit 0

base=""
while IFS= read -r b; do
  case "$b" in
    main | master | develop) ;;
    *) base="$b" ;;
  esac
done <<<"$bases"
[ -n "$base" ] || exit 0

output=$(jq -r '[.tool_response | .. | strings] | join("\n")' <<<"$payload" 2>/dev/null) || exit 0
url=$(grep -Eo 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[0-9]+' <<<"$output" | tail -n 1) || exit 0
[ -n "$url" ] || exit 0

context="stack-reminder: this pull request ($url) targets the branch $base, not main, master or develop.
GitHub has stacked pull requests as a feature. Setting --base to the branch of another pull request makes a chain, not a stack: when the lower pull request merges, GitHub does not rebase or retarget the one above it, and that one can merge into a stale branch whose commits never reach the default branch.
If this pull request is meant to sit above the pull request for $base, make it an actual stack. From inside a clone of the repository, link the chain from the bottom pull request upward:
  nix shell 'nixpkgs#gh-stack' -c gh-stack link <bottom> ... <top>
The arguments are pull request numbers, and linking retargets the bottom pull request to the default branch. If $base is a long-lived branch that no other pull request is opened from, and this pull request is not part of a chain, no stack is needed."

jq -cn --arg c "$context" \
  '{hookSpecificOutput: {hookEventName: "PostToolUse",
                         additionalContext: $c}}' 2>/dev/null
exit 0
