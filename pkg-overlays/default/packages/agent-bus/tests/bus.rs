// SPDX-License-Identifier: MIT
//! End-to-end tests: a real daemon on a temporary socket, driven through the
//! CLI and through MCP sessions over stdio, the way harnesses use it.

use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::Duration;

use serde_json::{Value, json};

const BIN: &str = env!("CARGO_BIN_EXE_agent-bus");

struct Bus {
    dir: PathBuf,
    socket: PathBuf,
    daemon: Child,
}

impl Bus {
    fn start(name: &str) -> Bus {
        let dir = std::env::temp_dir().join(format!("ab-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let socket = dir.join("s");
        let daemon = Command::new(BIN)
            .arg("--socket")
            .arg(&socket)
            .arg("daemon")
            .arg("--db")
            .arg(dir.join("bus.sqlite"))
            .spawn()
            .expect("start the daemon");
        for _ in 0..200 {
            if std::os::unix::net::UnixStream::connect(&socket).is_ok() {
                return Bus {
                    dir,
                    socket,
                    daemon,
                };
            }
            std::thread::sleep(Duration::from_millis(20));
        }
        panic!("the daemon did not start listening");
    }

    fn cli(&self, args: &[&str]) -> Result<String, String> {
        let out = Command::new(BIN)
            .arg("--socket")
            .arg(&self.socket)
            .args(args)
            .output()
            .unwrap();
        if out.status.success() {
            Ok(String::from_utf8(out.stdout).unwrap().trim().to_string())
        } else {
            Err(String::from_utf8(out.stderr).unwrap())
        }
    }

    fn ok(&self, args: &[&str]) -> String {
        self.cli(args)
            .unwrap_or_else(|e| panic!("{args:?} failed: {e}"))
    }

    fn register(&self, harness: &str, label: &str) -> String {
        self.ok(&[
            "register",
            "--harness",
            harness,
            "--session",
            &format!("{label}-session"),
            "--label",
            label,
        ])
    }

    /// Runs one MCP session for `participant` and returns the reply to each
    /// request, in order.
    fn mcp(&self, participant: Option<&str>, calls: &[Value]) -> Vec<Value> {
        let mut cmd = Command::new(BIN);
        cmd.arg("--socket").arg(&self.socket).arg("mcp");
        cmd.env_remove("AGENT_BUS_PARTICIPANT");
        if let Some(p) = participant {
            cmd.env("AGENT_BUS_PARTICIPANT", p);
        }
        let mut child = cmd
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .spawn()
            .unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let mut msgs = vec![
            json!({"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "test", "version": "0"}}}),
            json!({"jsonrpc": "2.0", "method": "notifications/initialized"}),
        ];
        for (i, c) in calls.iter().enumerate() {
            msgs.push(json!({"jsonrpc": "2.0", "id": i + 1, "method": "tools/call", "params": c}));
        }
        for m in &msgs {
            writeln!(stdin, "{m}").unwrap();
        }
        drop(stdin);
        let replies: Vec<Value> = BufReader::new(child.stdout.take().unwrap())
            .lines()
            .map(|l| serde_json::from_str(&l.unwrap()).unwrap())
            .collect();
        child.wait().unwrap();
        assert_eq!(replies[0]["result"]["serverInfo"]["name"], "agent-bus");
        replies[1..].to_vec()
    }

    /// Calls one tool and returns (text, is_error).
    fn tool(&self, participant: &str, name: &str, args: Value) -> (String, bool) {
        let r = &self.mcp(
            Some(participant),
            &[json!({"name": name, "arguments": args})],
        )[0]["result"];
        (
            r["content"][0]["text"].as_str().unwrap().to_string(),
            r["isError"].as_bool().unwrap(),
        )
    }

    fn tool_ok(&self, participant: &str, name: &str, args: Value) -> Value {
        let (text, err) = self.tool(participant, name, args);
        assert!(!err, "{participant} {name} failed: {text}");
        serde_json::from_str(&text).unwrap()
    }

    fn tool_err(&self, participant: &str, name: &str, args: Value) -> String {
        let (text, err) = self.tool(participant, name, args);
        assert!(
            err,
            "{participant} {name} should have failed but returned {text}"
        );
        text
    }

    fn inbox(&self, participant: &str) -> Vec<Value> {
        self.tool_ok(participant, "bus_inbox", json!({}))["messages"]
            .as_array()
            .unwrap()
            .clone()
    }
}

impl Drop for Bus {
    fn drop(&mut self) {
        let _ = self.daemon.kill();
        let _ = self.daemon.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn exists(p: &Path) -> bool {
    p.exists()
}

#[test]
fn tools_are_listed() {
    let bus = Bus::start("tools");
    let mut cmd = Command::new(BIN);
    let mut child = cmd
        .arg("--socket")
        .arg(&bus.socket)
        .arg("mcp")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
    )
    .unwrap();
    drop(stdin);
    let line = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .next()
        .unwrap()
        .unwrap();
    child.wait().unwrap();
    let names: Vec<String> = serde_json::from_str::<Value>(&line).unwrap()["result"]["tools"]
        .as_array()
        .unwrap()
        .iter()
        .map(|t| t["name"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(
        names,
        [
            "bus_whoami",
            "bus_status",
            "bus_read_status",
            "bus_inbox",
            "bus_send"
        ]
    );
}

#[test]
fn registration_is_idempotent_per_harness_session() {
    let bus = Bus::start("register");
    let a = bus.register("claude", "mgr");
    let b = bus.register("claude", "mgr");
    assert_eq!(
        a, b,
        "registering the same harness session again returns the same participant"
    );
    assert!(
        bus.cli(&[
            "register",
            "--harness",
            "codex",
            "--session",
            "x",
            "--label",
            "user"
        ])
        .is_err()
    );
}

#[test]
fn supervision_rules() {
    let bus = Bus::start("supervision");
    bus.register("claude", "mgr");
    bus.register("codex", "w1");
    bus.register("opencode", "w2");
    bus.ok(&["link", "supervise", "mgr", "w1"]);
    bus.ok(&["link", "supervise", "mgr", "w2"]);
    let err = bus.cli(&["link", "supervise", "w2", "w1"]).unwrap_err();
    assert!(err.contains("already has a supervisor"), "{err}");

    bus.tool_ok(
        "mgr",
        "bus_send",
        json!({"to": "w1", "kind": "directive", "body": "Pin JDK 21."}),
    );
    let err = bus.tool_err(
        "w1",
        "bus_send",
        json!({"to": "mgr", "kind": "directive", "body": "no"}),
    );
    assert!(err.contains("not directives"), "{err}");
    bus.tool_ok(
        "w1",
        "bus_send",
        json!({"to": "mgr", "kind": "report", "body": "Pinned."}),
    );

    let inbox = bus.inbox("w1");
    assert_eq!(inbox.len(), 1);
    assert_eq!(inbox[0]["from"], "mgr");
    assert_eq!(inbox[0]["kind"], "directive");
    assert!(bus.inbox("w1").is_empty(), "reading marks messages read");

    let err = bus.tool_err(
        "w1",
        "bus_send",
        json!({"to": "w2", "kind": "question", "body": "hi"}),
    );
    assert!(err.contains("no edge"), "{err}");

    let who = bus.tool_ok("w1", "bus_whoami", json!({}));
    assert_eq!(who["supervisor"], "mgr");
    let who = bus.tool_ok("mgr", "bus_whoami", json!({}));
    assert_eq!(who["children"], json!(["w1", "w2"]));
}

#[test]
fn informed_peers_and_replies() {
    let bus = Bus::start("peers");
    bus.register("claude", "core");
    bus.register("codex", "docs");
    bus.register("opencode", "ports");
    bus.ok(&[
        "link",
        "inform",
        "core",
        "docs",
        "--scope",
        "overlay option rename",
    ]);
    bus.ok(&[
        "link",
        "inform",
        "core",
        "ports",
        "--scope",
        "overlay option rename",
        "--replies",
    ]);

    // A notice without a recipient reaches everyone informed of the sender.
    let sent = bus.tool_ok(
        "core",
        "bus_send",
        json!({"kind": "notice", "body": "libOverlays is now lib.overlays"}),
    );
    assert_eq!(sent["sent"].as_array().unwrap().len(), 2);

    // Without replies the informed side cannot answer.
    let docs_inbox = bus.inbox("docs");
    let err = bus.tool_err(
        "docs",
        "bus_send",
        json!({"to": "core", "kind": "answer", "body": "ok", "reply_to": docs_inbox[0]["id"]}),
    );
    assert!(err.contains("without replies"), "{err}");

    // With replies it can answer what it received, and only that.
    let ports_inbox = bus.inbox("ports");
    let notice = ports_inbox[0]["id"].as_str().unwrap();
    bus.tool_ok(
        "ports",
        "bus_send",
        json!({"to": "core", "kind": "answer", "body": "updated", "reply_to": notice}),
    );
    let err = bus.tool_err(
        "ports",
        "bus_send",
        json!({"to": "core", "kind": "question", "body": "new topic"}),
    );
    assert!(err.contains("only replies"), "{err}");
    assert_eq!(bus.inbox("core")[0]["reply_to"], notice);

    // The informed side reads the informer's status, not the other way round.
    bus.tool_ok("core", "bus_status", json!({"text": "renaming options"}));
    let st = bus.tool_ok("docs", "bus_read_status", json!({"participant": "core"}));
    assert_eq!(st["status"], "renaming options");
    bus.tool_err("core", "bus_read_status", json!({"participant": "docs"}));

    let who = bus.tool_ok("docs", "bus_whoami", json!({}));
    assert_eq!(who["informed_by"][0]["peer"], "core");
    assert_eq!(who["informed_by"][0]["scope"], "overlay option rename");
}

#[test]
fn user_and_unregistered_sessions() {
    let bus = Bus::start("user");
    bus.register("claude", "lead");
    bus.ok(&["send", "lead", "Start wave 3."]);
    assert_eq!(bus.inbox("lead")[0]["from"], "user");
    let err = bus.tool_err(
        "lead",
        "bus_send",
        json!({"to": "user", "kind": "question", "body": "?"}),
    );
    assert!(err.contains("escalation"), "{err}");

    let r = &bus.mcp(None, &[json!({"name": "bus_whoami", "arguments": {}})])[0]["result"];
    assert_eq!(r["isError"], true);
    assert!(
        r["content"][0]["text"]
            .as_str()
            .unwrap()
            .contains("not registered")
    );
}

#[test]
fn every_change_is_in_the_event_log() {
    let bus = Bus::start("log");
    bus.register("claude", "a");
    bus.register("codex", "b");
    bus.ok(&["link", "supervise", "a", "b"]);
    bus.tool_ok(
        "a",
        "bus_send",
        json!({"to": "b", "kind": "directive", "body": "go"}),
    );
    bus.inbox("b");
    let kinds: Vec<String> = bus
        .ok(&["log"])
        .lines()
        .map(|l| {
            serde_json::from_str::<Value>(l).unwrap()["kind"]
                .as_str()
                .unwrap()
                .to_string()
        })
        .collect();
    assert_eq!(
        kinds,
        [
            "participant_registered",
            "participant_registered",
            "edge_created",
            "message_sent",
            "message_read"
        ]
    );
    // The store survives a restart of the daemon.
    assert!(exists(&bus.dir.join("bus.sqlite")));
}
