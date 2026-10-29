// SPDX-License-Identifier: MIT
// OpenCode 1 plugin: before a file-writing tool runs in a task Emacs
// queued (CLAUDE_QUEUE_TASK set), hand its target paths to the consent
// gate (opencode-consent-gate), which allows writes inside the task's
// territory and asks the user about the rest. A deny fails the call
// with the gate's message.
import path from "node:path";

const GATE = "@gate@";
const WRITE_TOOLS = new Set(["write", "edit", "multiedit", "patch", "apply_patch"]);

function targets(args, directory) {
  const raw = [];
  if (typeof args.filePath === "string") raw.push(args.filePath);
  if (typeof args.path === "string") raw.push(args.path);
  const text = args.patchText ?? args.patch;
  if (typeof text === "string")
    for (const m of text.matchAll(/^\*\*\* (?:Add|Update|Delete) File: (.+)$|^\*\*\* Move to: (.+)$/gm))
      raw.push((m[1] ?? m[2]).trim());
  return raw.map((p) => path.resolve(directory, p));
}

async function decide(request) {
  const gate = Bun.spawn([GATE], { stdin: "pipe", stdout: "pipe", stderr: "inherit" });
  gate.stdin.write(JSON.stringify(request));
  gate.stdin.end();
  const text = await new Response(gate.stdout).text();
  await gate.exited;
  try {
    return JSON.parse(text);
  } catch {
    return { behavior: "deny", message: "the consent gate gave no decision" };
  }
}

export const WorkbenchConsent = async ({ directory }) => ({
  "tool.execute.before": async (input, output) => {
    if (!process.env.CLAUDE_QUEUE_TASK || !WRITE_TOOLS.has(input.tool)) return;
    const paths = targets(output.args ?? {}, directory);
    if (paths.length === 0) return;
    const decision = await decide({ sessionID: input.sessionID, tool: input.tool, paths });
    if (decision.behavior !== "allow") throw new Error(decision.message ?? "denied");
  },
});
