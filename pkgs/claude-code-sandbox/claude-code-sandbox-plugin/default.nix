# SPDX-License-Identifier: MIT
# The skills-dir plugin: ceremony skill + the advisory SessionStart hook
# (staleness/integrity tripwire with auto-sync). Deployed by the
# home-manager module into ~/.claude/skills/claude-code-sandbox, where it
# auto-loads as claude-code-sandbox@skills-dir.
#
# The hook is advisory only: the sandbox design stays correct without it
# (it always exits 0), and managed policies like allowManagedHooksOnly
# may suppress it entirely.
{
  claude-code-sandbox,
  lib,
  runCommand,
}:
runCommand "claude-code-sandbox-plugin"
  {
    ccsTool = claude-code-sandbox;
    meta = {
      description = "Claude Code skills-dir plugin for claude-code-sandbox";
      license = lib.licenses.mit;
    };
  }
  ''
    mkdir -p "$out/.claude-plugin" "$out/hooks"
    cp ${./plugin.json} "$out/.claude-plugin/plugin.json"
    cp -r ${./skills} "$out/skills"
    substitute ${./hooks/hooks.json.in} "$out/hooks/hooks.json" \
      --subst-var ccsTool
  ''
