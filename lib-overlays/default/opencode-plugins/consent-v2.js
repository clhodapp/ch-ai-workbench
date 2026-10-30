// SPDX-License-Identifier: MIT
// OpenCode 2 plugin: before a file-writing tool runs in a task Emacs
// queued (CLAUDE_QUEUE_TASK set), hand its target paths to the consent
// gate (opencode-consent-gate), which allows writes inside the task's
// territory and asks the user about the rest. A deny fails the call
// with the gate's message. The hook also sees the calls Code Mode
// (`execute`) makes.
import path from "node:path";

const GATE = "@gate@";
const WRITE_TOOLS = new Set(["write", "edit", "patch", "apply_patch"]);

function targets(input, directory) {
  const raw = [];
  if (typeof input.filePath === "string") raw.push(input.filePath);
  if (typeof input.path === "string") raw.push(input.path);
  const text = input.patchText ?? input.patch;
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

export default {
  id: "workbench-consent",
  setup(api) {
    api.tool.hook("execute.before", async (event) => {
      if (!process.env.CLAUDE_QUEUE_TASK || !WRITE_TOOLS.has(event.tool)) return;
      let directory = process.cwd();
      try {
        const session = await api.session.get({ sessionID: event.sessionID });
        directory = session?.location?.directory ?? directory;
      } catch {
        // A standalone run works in the session directory.
      }
      const paths = targets(event.input ?? {}, directory);
      if (paths.length === 0) return;
      const decision = await decide({ sessionID: event.sessionID, tool: event.tool, paths });
      if (decision.behavior !== "allow") throw new Error(decision.message ?? "denied");
    });
  },
};
