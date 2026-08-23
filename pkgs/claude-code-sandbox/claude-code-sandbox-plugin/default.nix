# SPDX-License-Identifier: LGPL-3.0-or-later
# The skills-dir plugin: ceremony skill + advisory hooks (SessionStart
# staleness tripwire, ConfigChange co-ownership canary). Deployed by the
# home-manager module into ~/.claude/skills/claude-code-sandbox, where it
# auto-loads as claude-code-sandbox@skills-dir.
#
# The hooks are advisory only: the sandbox design stays correct without
# them (they always exit 0), and managed policies like
# allowManagedHooksOnly may suppress them entirely.
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
      license = lib.licenses.lgpl3Plus;
    };
  }
  ''
    mkdir -p "$out/.claude-plugin" "$out/hooks"
    cp ${./plugin.json} "$out/.claude-plugin/plugin.json"
    cp -r ${./skills} "$out/skills"
    substitute ${./hooks/hooks.json.in} "$out/hooks/hooks.json" \
      --subst-var ccsTool
  ''
