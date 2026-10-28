# SPDX-License-Identifier: MIT
# The skills-dir plugin: ceremony skill, the advisory SessionStart hook
# (staleness/integrity tripwire with auto-sync), and the agent tools (the
# CLI's MCP server, which prompts through claude-consent). Deployed by the
# home-manager module into ~/.claude/skills/agent-sandbox, where it
# auto-loads as agent-sandbox@skills-dir.
#
# The hook is advisory only: the sandbox design stays correct without it
# (it always exits 0), and managed policies like allowManagedHooksOnly
# may suppress it entirely.
{
  agent-sandbox,
  claude-consent,
  lib,
  runCommand,
}:
runCommand "agent-sandbox-plugin"
  {
    agentSandboxTool = agent-sandbox;
    consentTool = claude-consent;
    meta = {
      description = "Claude Code skills-dir plugin for agent-sandbox";
      license = lib.licenses.mit;
    };
  }
  ''
    mkdir -p "$out/.claude-plugin" "$out/hooks"
    substitute ${./plugin.json} "$out/.claude-plugin/plugin.json" \
      --subst-var agentSandboxTool --subst-var consentTool
    cp -r ${./skills} "$out/skills"
    substitute ${./hooks/hooks.json.in} "$out/hooks/hooks.json" \
      --subst-var agentSandboxTool
  ''
