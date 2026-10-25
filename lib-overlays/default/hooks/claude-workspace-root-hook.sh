# PreToolUse hook on Bash: the command `cd-workspace-root` moves the
# session to the root of the workspace it is in.  A session moves its
# own working directory only through a Bash cd, and a cd into a
# submodule (cd projects/foo && gh pr list ...) keeps the session in
# that submodule for every later call.  The way back is a cd to the
# superproject, but its path depends on where the session runs (the
# primary checkout or one of its worktrees), and the worktree
# isolation guard refuses a cd whose target is computed at runtime
# (cd "$(git rev-parse ...)").  This hook resolves the path itself and
# rewrites the command to a cd with that path spelled out, so the
# model has one fixed command and the guard sees a literal target.
#
# The workspace root is the outermost superproject above the session's
# directory: git rev-parse --show-toplevel, then
# --show-superproject-working-tree repeated until git reports none.  A
# linked worktree of the workspace has no superproject, so a session
# isolated in one returns to that worktree's root rather than to the
# primary checkout.  Outside any superproject the root is the
# repository's own top level.
#
# The rewrite goes through hookSpecificOutput.updatedInput without a
# permissionDecision, so the native permission flow and the isolation
# guard still decide the rewritten call.  The command becomes
# `cd '<root>' && pwd`, so the result names the directory the session
# landed in; the model's own tool_use record keeps `cd-workspace-root`.
# When the session's directory is in no git repository the call is
# denied with a reason, because there is no root to move to.
#
# Only the exact command `cd-workspace-root` (surrounding whitespace
# allowed) is rewritten.  Everything else, and every unexpected
# failure (no cwd in the payload, jq failure), resolves to abstention
# (exit 0, no output).

payload=$(cat) || exit 0

field() { jq -r "$1 // empty" <<<"$payload" 2>/dev/null || true; }

cmd=$(field '.tool_input.command')
[[ "$cmd" =~ ^[[:space:]]*cd-workspace-root[[:space:]]*$ ]] || exit 0

cwd=$(field '.cwd')
[ -n "$cwd" ] || exit 0

deny() {
  jq -cn --arg r "workspace-root: $1" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse",
                           permissionDecision: "deny",
                           permissionDecisionReason: $r}}' 2>/dev/null
  exit 0
}

root=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) \
  || deny "$cwd is not inside a git repository, so there is no workspace root to move to."
while super=$(git -C "$root" rev-parse --show-superproject-working-tree 2>/dev/null) && [ -n "$super" ]; do
  root=$super
done

# updatedInput replaces the whole argument object, so the call's other
# arguments (description, timeout) are carried over beside the new
# command.
quoted="'${root//\'/\'\\\'\'}'"
jq -c --arg c "cd $quoted && pwd" \
  '{hookSpecificOutput: {hookEventName: "PreToolUse",
                         updatedInput: (.tool_input + {command: $c})}}' \
  <<<"$payload" 2>/dev/null
exit 0
