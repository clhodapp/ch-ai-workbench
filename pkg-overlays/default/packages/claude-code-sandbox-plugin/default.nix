# SPDX-License-Identifier: MIT
# The skills-dir plugin: ceremony skill, the advisory SessionStart hook
# (staleness/integrity tripwire with auto-sync), and the agent tools (the
# CLI's MCP server, which prompts through claude-consent). Deployed by the
# home-manager module into ~/.claude/skills/claude-code-sandbox, where it
# auto-loads as claude-code-sandbox@skills-dir.
#
# The hook is advisory only: the sandbox design stays correct without it
# (it always exits 0), and managed policies like allowManagedHooksOnly
# may suppress it entirely.
{
  claude-code-sandbox,
  claude-consent,
  lib,
  runCommand,
}:
runCommand "claude-code-sandbox-plugin"
  {
    ccsTool = claude-code-sandbox;
    consentTool = claude-consent;
    meta = {
      description = "Claude Code skills-dir plugin for claude-code-sandbox";
      license = lib.licenses.mit;
    };
  }
  ''
    mkdir -p "$out/.claude-plugin" "$out/hooks"
    substitute ${./plugin.json} "$out/.claude-plugin/plugin.json" \
      --subst-var ccsTool --subst-var consentTool
    cp -r ${./skills} "$out/skills"
    substitute ${./hooks/hooks.json.in} "$out/hooks/hooks.json" \
      --subst-var ccsTool
  ''
