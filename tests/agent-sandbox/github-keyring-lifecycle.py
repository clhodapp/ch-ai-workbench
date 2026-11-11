# SPDX-License-Identifier: MIT
"""Real Codex daemon, real gh, real Secret Service; no production credentials."""
import copy
import json
import os
import queue
import threading
import subprocess
import sys
from pathlib import Path

from agent_sandbox.run import prepare

if len(sys.argv) > 1 and sys.argv[1] == "--prepare":
    _, environment, bridge = prepare("codex", [sys.argv[3]], Path(sys.argv[2]), False)
    assert bridge is None
    print(json.dumps(environment))
    raise SystemExit(0)


def prepare_launcher(root, codex):
    # Each launcher has a separate PID and runtime, as real terminal clients do.
    result = subprocess.run([sys.executable, __file__, "--prepare", str(root), codex],
                            text=True, capture_output=True, check=True)
    return json.loads(result.stdout)

home = Path.home()
allowed = home / "clone-a"
denied = home / "clone-b"
raw_codex, raw_gh = sys.argv[1:]
cli = "agent-sandbox"
for root, modules in ((allowed, ["vm-runtime", "github"]), (denied, ["vm-runtime", "bare-gh"])):
    subprocess.run(["git", "init", "-q", str(root)], check=True)
    subprocess.run([cli, "enroll", *modules, "-C", str(root), "--quiet"], check=True)

environment_a = prepare_launcher(allowed, raw_codex)
runtime_a = Path(environment_a["AGENT_SANDBOX_CODEX_POLICY"])
policy_a = json.loads(runtime_a.read_text())
cached_a = copy.deepcopy(policy_a["config"])
current_path = cached_a["shell_environment_policy"]["set"]["PATH"]
parts = current_path.split(":")
cached_path = ":".join([parts[0], str(Path(raw_gh).parent), *parts[1:]])
cached_a["shell_environment_policy"]["set"]["PATH"] = cached_path
policy_a["config"] = copy.deepcopy(cached_a)
policy_a["path"] = str(Path(raw_gh).parent) + ":" + policy_a["path"]
policy_a.pop("command_env", None)  # Reproduce the pre-repair runtime format.
runtime_a.write_text(json.dumps(policy_a))

environment_b = prepare_launcher(denied, raw_codex)
assert environment_b["AGENT_SANDBOX_CODEX_POLICY"] != str(runtime_a)
policy_b = json.loads(Path(environment_b["AGENT_SANDBOX_CODEX_POLICY"]).read_text())
assert cached_a["default_permissions"] != policy_b["config"]["default_permissions"]

baseline = '''import subprocess,pathlib
p=subprocess.run(["gh","auth","git-credential","get"],input="protocol=https\\nhost=github.com\\n\\n",text=True,capture_output=True)
assert p.returncode != 0 and not p.stdout
pathlib.Path("baseline-observed").touch()
'''
check = '''import json,os,pathlib,subprocess,socket
p=subprocess.run(["gh","auth","git-credential","get"],input="protocol=https\\nhost=github.com\\n\\n",text=True,capture_output=True)
assert p.returncode == 0, p.stderr
fields=dict(line.split("=",1) for line in p.stdout.splitlines() if "=" in line)
assert fields.get("password")=="ghp_vm_keyring_fixture"
p=subprocess.run(["gh","api","user","--jq",".login"],text=True,capture_output=True)
assert p.returncode==0 and p.stdout.strip()=="vm-alice",p.stderr
p=subprocess.run(["gh","auth","token","--hostname","github.com"],text=True,capture_output=True,
                 env={**os.environ,"GH_TOKEN":"explicit-vm-token"})
assert p.returncode==0 and p.stdout.strip()=="explicit-vm-token"
bus=socket.socket(socket.AF_UNIX)
try:
 bus.connect(os.environ["XDG_RUNTIME_DIR"]+"/bus")
except PermissionError: pass
else: raise AssertionError("sandbox reached host session bus")
pathlib.Path("credential-route-passed").touch()
'''
registry = json.loads((home / ".config/agent-sandbox/registry.json").read_text())
github = json.loads(Path(registry["modules"]["github"]).read_text())
broker = str(Path(github["path"][0]) / "github-auth-token")
negative = f'''import pathlib,subprocess
p=subprocess.run([{broker!r}],capture_output=True)
assert p.returncode != 0 and not p.stdout
p=subprocess.run(["gh","auth","git-credential","get"],input="protocol=https\\nhost=github.com\\n\\n",text=True,capture_output=True)
assert p.returncode != 0 and not p.stdout
pathlib.Path("credential-route-denied").touch()
'''
(allowed / "baseline.py").write_text(baseline)
(allowed / "credential-check.py").write_text(check)
(denied / "credential-denied.py").write_text(negative)

log = (home / "codex-keyring-api.log").open("w")
server = subprocess.Popen([raw_codex, "app-server"], cwd=home, env=environment_a,
                          stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=log,
                          text=True, bufsize=1)
request_id = 0
notifications = []
messages = queue.Queue()

def receive():
    for line in server.stdout:
        messages.put(json.loads(line))
    messages.put(None)

threading.Thread(target=receive, daemon=True).start()

def read_message():
    value = messages.get(timeout=90)
    assert value is not None, "Codex app-server exited"
    return value

def rpc(method, params):
    global request_id
    request_id += 1
    server.stdin.write(json.dumps({"id": request_id, "method": method, "params": params}) + "\n")
    server.stdin.flush()
    while True:
        result = read_message()
        if result.get("id") == request_id:
            assert "error" not in result, result.get("error")
            return result["result"]
        notifications.append(result)

def turn(thread, script):
    notifications.clear()
    result = rpc("turn/start", {"threadId": thread, "input": [
        {"type": "text", "text": "SHELL-PROBE:" + script}]})
    turn_id = result["turn"]["id"]
    while True:
        value = notifications.pop(0) if notifications else read_message()
        if value.get("method", "").endswith("/outputDelta"):
            print("command output:", value.get("params", {}).get("delta", ""), flush=True)
        if value.get("method") == "item/completed":
            item = value.get("params", {}).get("item", {})
            if item.get("type") == "commandExecution":
                print("command completed:", item.get("exitCode"), item.get("aggregatedOutput"), flush=True)
        if value.get("method") == "turn/completed" and value["params"]["turn"]["id"] == turn_id:
            assert value["params"]["turn"]["status"] == "completed", value
            return

try:
    rpc("initialize", {"clientInfo": {"name": "keyring-vm-test", "version": "1"},
                       "capabilities": {"experimentalApi": True}})
    server.stdin.write('{"method":"initialized"}\n')
    server.stdin.flush()
    first = rpc("thread/start", {"cwd": str(allowed), "config": cached_a,
                                 "approvalPolicy": "never", "ephemeral": True})
    thread_a = first["thread"]["id"]
    turn(thread_a, "baseline.py")
    assert (allowed / "baseline-observed").exists(), "stale PATH failure was not reproduced"
    subprocess.run([cli, "sync", "-C", str(allowed), "--quiet"], check=True)
    refreshed = json.loads(runtime_a.read_text())
    assert refreshed["config"]["shell_environment_policy"]["set"]["PATH"] == cached_path
    assert refreshed["command_env"]["PATH"] != cached_path
    assert server.poll() is None
    turn(thread_a, "credential-check.py")
    assert (allowed / "credential-route-passed").exists()
    second = rpc("thread/start", {"cwd": str(denied), "config": policy_b["config"],
                                  "approvalPolicy": "never", "ephemeral": True})
    turn(second["thread"]["id"], "credential-denied.py")
    assert (denied / "credential-route-denied").exists()
    assert server.poll() is None
    for root in (allowed, denied):
        for path in (root / ".codex/config.toml", root / ".agent-sandbox/binding.json",
                     root / ".agent-sandbox/codex-config.json"):
            assert "ghp_vm_keyring_fixture" not in path.read_text(), "credential persisted in enrollment"
    print("PASS: real keyring -> scoped broker -> real gh; cached thread repaired without restart; other clone denied")
finally:
    server.terminate()
    server.wait(timeout=15)
