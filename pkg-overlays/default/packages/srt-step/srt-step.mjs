// SPDX-License-Identifier: MIT
//
// The srt step of agent-sandbox's bash chain. An agent with no sandbox
// for its shell commands (OpenCode) runs this as `bash`, through SHELL,
// with the arguments it would give bash. In a checkout enrolled with
// agent-sandbox modules it starts sandbox-runtime (srt) through srt's
// library, with the rules agent-sandbox wrote at enroll time to
// .agent-sandbox/shell-<agent>.json, and runs the rules' shell inside the
// sandbox with the same arguments. Outside an enrolled checkout it runs
// the real bash unchanged, as `agent-sandbox run` does there.
//
// It fails rather than run a command unsandboxed when srt cannot start,
// including inside another sandbox that refuses nested bubblewrap.
//
// srt's settings file has no pattern for every host. When the checkout
// grants `*`, the rules say `allowAll`, and the ask callback, which srt
// asks about each host its lists do not decide, admits a hostname. srt
// checks the addresses a hostname resolves to and refuses loopback,
// link-local and metadata addresses. It dials an IP literal as given, so
// the callback refuses every IP literal and the loopback names
// (`localhost`, `*.localhost`): an address is reachable only when a
// module lists it.
//
// Usage: srt-step AGENT REAL_BASH -- BASH_ARGS...

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync } from "node:fs";
import { isIP } from "node:net";
import { dirname, join } from "node:path";
import { SandboxManager, SandboxRuntimeConfigSchema } from "@srtIndex@";

const SIGNALS = ["SIGINT", "SIGTERM", "SIGHUP"];

const [agent, realBash, separator, ...args] = process.argv.slice(2);
if (!agent || !realBash || separator !== "--") {
  console.error("usage: srt-step AGENT REAL_BASH -- BASH_ARGS...");
  process.exit(2);
}

// The checkout whose rules apply: the nearest directory, from the working
// directory up, holding an enrollment binding. That is the root
// `agent-sandbox enroll` wrote, not the innermost git repository, so a
// submodule of an enrolled checkout gets the checkout's rules.
function enrolledRoot(start) {
  let dir = start;
  for (;;) {
    if (existsSync(join(dir, ".agent-sandbox", "binding.json"))) return dir;
    const parent = dirname(dir);
    if (parent === dir) return null;
    dir = parent;
  }
}

// The answer to srt's ask callback for a host no list decides.
function admits(allowAll, host) {
  const name = host.toLowerCase().replace(/^\[(.*)\]$/, "$1").replace(/\.$/, "");
  if (!allowAll) return false;
  if (isIP(name) !== 0) return { allow: false, reason: `agent-sandbox: an IP address is reachable only when a module lists it` };
  if (name === "localhost" || name.endsWith(".localhost")) return { allow: false, reason: `agent-sandbox: localhost is reachable only when a module lists it` };
  return true;
}

function quote(word) {
  return `'${word.replaceAll("'", `'\\''`)}'`;
}

// Exit as the command did: with its status, or killed by its signal.
function exitLike(code, signal) {
  if (signal) {
    for (const s of SIGNALS) process.removeAllListeners(s);
    process.kill(process.pid, signal);
    return;
  }
  process.exit(code ?? 1);
}

function run(file, argv, options) {
  const child = spawn(file, argv, { stdio: "inherit", ...options });
  for (const signal of SIGNALS) {
    process.on(signal, () => child.kill(signal));
  }
  return child;
}

const root = enrolledRoot(process.cwd());
const rulesFile = root && join(root, ".agent-sandbox", `shell-${agent}.json`);
if (!rulesFile || !existsSync(rulesFile)) {
  // An abandoned checkout keeps its binding with no modules, and gets no
  // rules file.
  const child = run(realBash, args, {});
  child.on("exit", exitLike);
} else {
  let rules;
  try {
    rules = JSON.parse(readFileSync(rulesFile, "utf8"));
  } catch (err) {
    console.error(`agent-sandbox: cannot read ${rulesFile}: ${err.message}; refusing to run`);
    process.exit(1);
  }
  Object.assign(process.env, rules.env);
  mkdirSync(rules.scratch, { recursive: true, mode: 0o700 });

  // `bash -c SCRIPT` hands srt the script, and srt runs it with the
  // rules' shell as `SHELL -c SCRIPT`. Any other invocation (a script
  // file, `-l -c`, positional parameters after the script) runs the
  // rules' shell with the same arguments.
  const command = args.length === 2 && args[0] === "-c" ? args[1] : [rules.shell, ...args].map(quote).join(" ");

  try {
    const config = SandboxRuntimeConfigSchema.parse(rules.settings);
    // srt can grant only a path that exists, and inside the sandbox the
    // parent of a missing directory is read-only.
    for (const granted of config.filesystem.allowWrite) {
      try {
        mkdirSync(granted, { recursive: true });
      } catch {
        // A path this user cannot create stays ungranted, as srt leaves it.
      }
    }
    await SandboxManager.initialize(config, async ({ host }) => admits(rules.allowAll === true, host));
    const wrapped = await SandboxManager.wrapWithSandbox(command, rules.shell);
    const child = run(wrapped, [], { shell: true });
    child.on("exit", (code, signal) => {
      SandboxManager.cleanupAfterCommand();
      SandboxManager.reset().finally(() => exitLike(code, signal));
    });
    child.on("error", (err) => {
      console.error(`agent-sandbox: cannot run the sandboxed command: ${err.message}`);
      process.exit(1);
    });
  } catch (err) {
    console.error(`agent-sandbox: srt cannot start (${err instanceof Error ? err.message : String(err)}); refusing to run the command without its sandbox`);
    process.exit(1);
  }
}
