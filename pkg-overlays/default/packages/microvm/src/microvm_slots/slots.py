# SPDX-License-Identifier: MIT
"""The configured slots, their leases, and their units.

A kind is a pool of guests that run one NixOS configuration. Each guest
of a kind is a slot, with its own vsock CID and its own share
directories. The home-manager module writes the kinds into the
configuration file of the program.

The program leases a slot to a holder: the process that keeps the slot,
recorded as its process ID and its start time (field 22 of
/proc/<pid>/stat), since a process ID alone can be reused. A lease also
records the session ID of Claude Code when the caller knows it, for
display. A slot is free when it has no lease, or when the process of
its lease is gone.

The leases live under `<stateDir>/leases/<slot>.json`. Every change to
them happens under an exclusive lock on `<stateDir>/lock`, so two
programs that claim at once never claim one slot twice.
"""

from __future__ import annotations

import contextlib
import fcntl
import io
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Iterator, TextIO

from . import transport
from .transport import Endpoint


class Refused(Exception):
    """A request the program refuses, with the message for the caller."""


@dataclass(frozen=True)
class Caller:
    """Who calls: the process that holds what it claims, with that
    process's start time, and the session ID of Claude Code when the
    caller knows it."""

    session: str | None
    pid: int | None
    start: str | None


def start_time(proc_root: Path, pid: int) -> str | None:
    """The start time of process `pid` (field 22 of its stat file), or
    None when no such process runs."""
    try:
        text = (proc_root / str(pid) / "stat").read_text()
    except OSError:
        return None
    # The second field is the command name in parentheses, which may
    # itself hold spaces and parentheses, so the fields are counted from
    # the last closing parenthesis. The field after it is field 3.
    close = text.rfind(")")
    if close < 0:
        return None
    fields = text[close + 1 :].split()
    if len(fields) < 20:
        return None
    return fields[19]


def format_duration(seconds: float) -> str:
    seconds = max(0, int(seconds))
    hours, rest = divmod(seconds, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{hours}h{minutes:02d}m"
    if minutes:
        return f"{minutes}m{secs:02d}s"
    return f"{secs}s"


def slots_of(kinds: dict[str, dict]) -> dict[str, dict]:
    """Every slot of the configured kinds, by name, with its kind, its
    position in the kind, its CID, its hybrid vsock socket or None, the
    vsock port of its kind and its share directories."""
    slots: dict[str, dict] = {}
    for kind, info in kinds.items():
        root = info.get("shareRoot")
        for index, slot in enumerate(info["slots"], start=1):
            name = slot["name"]
            shares = []
            if root is not None:
                shares = [
                    {"name": "in", "source": f"{root}/{name}/in", "readOnly": True},
                    {"name": "out", "source": f"{root}/{name}/out", "readOnly": False},
                ]
            slots[name] = {
                "kind": kind,
                "index": index,
                "cid": slot["cid"],
                "vsockSocket": slot.get("vsockSocket"),
                "vsockPort": info.get("vsockPort"),
                "shares": shares,
            }
    return slots


class Slots:
    """The slots of the configured kinds, with the leases and units that
    go with them. With `agents_only`, only the kinds the configuration
    lets agents use."""

    def __init__(
        self,
        config: dict,
        *,
        agents_only: bool = False,
        proc_root: Path | None = None,
        run: Callable[..., subprocess.CompletedProcess] = subprocess.run,
        probe: Callable[[Endpoint, float], None] = transport.probe,
        clock: Callable[[], float] = time.time,
        sleep: Callable[[float], None] = time.sleep,
        out: TextIO | None = None,
    ) -> None:
        kinds: dict[str, dict] = config["kinds"]
        if agents_only:
            kinds = {kind: info for kind, info in kinds.items() if info.get("agents")}
        self.kind_info = kinds
        self.slots = slots_of(kinds)
        self.state_dir = Path(config["stateDir"])
        self.systemctl = config["systemctl"]
        self.up_timeout = float(config.get("upTimeout", 120))
        self.proc_root = proc_root or Path(config.get("procRoot", "/proc"))
        self.run = run
        self.probe = probe
        self.clock = clock
        self.sleep = sleep
        self.out = out
        self._captured = threading.local()
        self.kinds: dict[str, list[str]] = {}
        for name in sorted(self.slots, key=lambda n: (self.slots[n]["kind"], self.slots[n]["index"])):
            self.kinds.setdefault(self.slots[name]["kind"], []).append(name)

    def say(self, line: str = "") -> None:
        out = getattr(self._captured, "out", None) or self.out or sys.stdout
        print(line, file=out, flush=True)

    @contextlib.contextmanager
    def capture(self) -> Iterator[io.StringIO]:
        """Collect what this thread says while the context is open."""
        out = io.StringIO()
        self._captured.out = out
        try:
            yield out
        finally:
            self._captured.out = None

    # Leases.

    @property
    def lease_dir(self) -> Path:
        return self.state_dir / "leases"

    @contextlib.contextmanager
    def locked(self) -> Iterator[None]:
        self.lease_dir.mkdir(parents=True, exist_ok=True)
        with open(self.state_dir / "lock", "a+") as handle:
            fcntl.flock(handle, fcntl.LOCK_EX)
            try:
                yield
            finally:
                fcntl.flock(handle, fcntl.LOCK_UN)

    def leases(self) -> dict[str, dict]:
        """The leases of the configured slots, by slot. A file that is
        not a lease of a configured slot is ignored."""
        found: dict[str, dict] = {}
        for name in self.slots:
            path = self.lease_dir / f"{name}.json"
            try:
                lease = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if isinstance(lease, dict) and lease.get("slot") == name:
                found[name] = lease
        return found

    def write_lease(self, lease: dict) -> None:
        self.lease_dir.mkdir(parents=True, exist_ok=True)
        fd, tmp = tempfile.mkstemp(dir=self.lease_dir, prefix=".lease-", suffix=".tmp")
        try:
            with os.fdopen(fd, "w") as handle:
                json.dump(lease, handle, indent=2, sort_keys=True)
                handle.write("\n")
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(tmp, self.lease_dir / f"{lease['slot']}.json")
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp)
            raise

    def remove_lease(self, slot: str) -> None:
        with contextlib.suppress(FileNotFoundError):
            (self.lease_dir / f"{slot}.json").unlink()

    def alive(self, lease: dict) -> bool:
        """Whether the process that holds a lease still runs."""
        pid = lease.get("pid")
        if not isinstance(pid, int) or pid <= 0:
            return False
        return start_time(self.proc_root, pid) == lease.get("start")

    @staticmethod
    def holds(caller: Caller, lease: dict) -> bool:
        """Whether the caller holds a lease: the caller names the holding
        process of the lease, with its start time. The session ID of a
        lease is for display and decides nothing."""
        return (
            caller.pid is not None
            and caller.start is not None
            and lease.get("pid") == caller.pid
            and lease.get("start") == caller.start
        )

    def lease_for(self, slot: str, caller: Caller) -> dict:
        return {
            "slot": slot,
            "kind": self.slots[slot]["kind"],
            "session": caller.session,
            "pid": caller.pid,
            "start": caller.start,
            "claimed": int(self.clock()),
        }

    # Units.

    @staticmethod
    def unit(slot: str) -> str:
        return f"microvm@{slot}.service"

    def systemctl_run(self, *args: str) -> subprocess.CompletedProcess:
        return self.run(
            [self.systemctl, *args],
            capture_output=True,
            text=True,
            check=False,
        )

    def control(self, verb: str, slot: str, *, no_block: bool = False) -> None:
        args = ["--no-ask-password", *(["--no-block"] if no_block else []), verb, self.unit(slot)]
        done = self.systemctl_run(*args)
        if done.returncode != 0:
            detail = (done.stderr or done.stdout or "").strip()
            raise Refused(
                f"systemctl {verb} {self.unit(slot)} failed (exit {done.returncode})"
                + (f": {detail}" if detail else "")
            )

    def active(self, slot: str) -> str:
        done = self.systemctl_run("is-active", self.unit(slot))
        return (done.stdout or "").strip() or "unknown"

    def uptime(self, slot: str) -> float | None:
        done = self.systemctl_run(
            "show", "--timestamp=unix", "--property=ActiveEnterTimestamp", "--value", self.unit(slot)
        )
        value = (done.stdout or "").strip()
        if done.returncode != 0 or not value.startswith("@"):
            return None
        try:
            return self.clock() - float(value[1:])
        except ValueError:
            return None

    def endpoint(self, slot: str) -> Endpoint | None:
        """The vsock port of the guest in `slot`, or None when its kind
        serves on no port."""
        info = self.slots[slot]
        if info.get("vsockPort") is None:
            return None
        return Endpoint(slot=slot, cid=info["cid"], port=info["vsockPort"], vsock_socket=info.get("vsockSocket"))

    def answering(self, slot: str, timeout: float = 1.0) -> str | None:
        """Whether the guest in `slot` answers on its vsock port, as the
        words `status` shows, or None when its kind serves on no port. A
        permission error is shown, since the user can act on it."""
        endpoint = self.endpoint(slot)
        if endpoint is None:
            return None
        try:
            self.probe(endpoint, timeout)
        except PermissionError as error:
            return f"not answering: {error}"
        except OSError:
            return "not answering"
        return "answering"

    # Verbs.

    def up(self, kind: str, caller: Caller) -> str:
        """Lease a slot of `kind` to the caller, start it, and wait until
        it answers. A slot the caller already holds is used again."""
        if caller.pid is None or caller.start is None:
            raise Refused("up needs a holding process, and the calling process names none that runs")
        with self.locked():
            leases = self.leases()
            held = [slot for slot in self.kinds[kind] if slot in leases and self.holds(caller, leases[slot])]
            if held:
                slot = held[0]
                claimed = False
                if caller.session is not None and leases[slot].get("session") != caller.session:
                    self.write_lease(dict(leases[slot], session=caller.session))
            else:
                free = [
                    slot for slot in self.kinds[kind] if slot not in leases or not self.alive(leases[slot])
                ]
                if not free:
                    raise Refused(
                        f"every slot of the kind {kind} is held by another live session "
                        f"({', '.join(self.kinds[kind])})"
                    )
                slot = free[0]
                claimed = True
                self.write_lease(self.lease_for(slot, caller))

        try:
            # A newly claimed slot may still run for a holder that is
            # gone, so it is restarted: the session gets a fresh guest.
            self.control("restart" if claimed else "start", slot)
        except Refused:
            if claimed:
                with self.locked():
                    current = self.leases().get(slot)
                    if current is not None and self.holds(caller, current):
                        self.remove_lease(slot)
            raise

        self.wait_answering(slot)
        self.describe(slot)
        return slot

    def wait_answering(self, slot: str) -> None:
        """Wait until the guest in `slot` answers on its vsock port. A
        permission error ends the wait at once, since waiting does not
        change it. Every other error is tried again until `upTimeout`."""
        endpoint = self.endpoint(slot)
        if endpoint is None:
            return
        stays = f"it stays leased to this session, so stop it with down {slot}"
        deadline = self.clock() + self.up_timeout
        while True:
            try:
                self.probe(endpoint, 1.0)
                return
            except PermissionError as error:
                raise Refused(f"{slot} was started but {error}; {stays}") from None
            except OSError as error:
                last = str(error)
            if self.clock() >= deadline:
                raise Refused(
                    f"{slot} was started but its vsock port {endpoint.port} did not answer within "
                    f"{int(self.up_timeout)} seconds ({last}); {stays}"
                )
            self.sleep(0.5)

    def describe(self, slot: str) -> None:
        info = self.slots[slot]
        self.say(f"slot {slot} (kind {info['kind']})")
        port = info.get("vsockPort")
        self.say(f"vsock cid {info['cid']}" + (f" port {port}" if port is not None else ""))
        for share in info.get("shares", []):
            mode = "read-only" if share.get("readOnly") else "writable"
            self.say(f"share {share['name']} {share['source']} ({mode} in the guest)")

    def status(self, caller: Caller, everything: bool) -> None:
        leases = self.leases()
        if everything:
            shown = [slot for kind in sorted(self.kinds) for slot in self.kinds[kind]]
        else:
            shown = [
                slot
                for kind in sorted(self.kinds)
                for slot in self.kinds[kind]
                if slot in leases and self.holds(caller, leases[slot])
            ]
        if not shown:
            self.say("this session holds no slots")
        for slot in shown:
            lease = leases.get(slot)
            parts = [slot, f"kind {self.slots[slot]['kind']}"]
            if everything:
                parts.append(self.holder(caller, lease))
            state = self.active(slot)
            parts.append(state)
            if state == "active":
                answering = self.answering(slot)
                if answering is not None:
                    parts.append(answering)
                up_for = self.uptime(slot)
                if up_for is not None:
                    parts.append(f"up {format_duration(up_for)}")
            self.say("  ".join(parts))
        self.say("kinds:")
        for kind in sorted(self.kinds):
            names = self.kinds[kind]
            free = [slot for slot in names if slot not in leases or not self.alive(leases[slot])]
            self.say(f"  {kind}: {len(names)} slots, {len(free)} free")

    def holder(self, caller: Caller, lease: dict | None) -> str:
        if lease is None:
            return "free"
        if self.holds(caller, lease):
            return "held by this session"
        who = f"session {lease.get('session')}" if lease.get("session") else f"process {lease.get('pid')}"
        if self.alive(lease):
            return f"held by {who}"
        return f"free (holder {who} is gone)"

    def down(self, caller: Caller, slot: str | None, *, no_block: bool = False) -> None:
        """Stop one slot, or every slot the caller holds. With
        `no_block`, systemctl queues each stop and returns at once."""
        # Without leases there is nothing to stop and nothing to lock,
        # so the state directory is left as it is.
        if slot is None and not self.leases():
            self.say("this session holds no slots")
            return
        with self.locked():
            leases = self.leases()
            if slot is not None:
                lease = leases.get(slot)
                if lease is not None and not self.holds(caller, lease) and self.alive(lease):
                    raise Refused(f"{slot} is held by another live session; this session may not stop it")
                targets = [slot]
            else:
                targets = [name for name, lease in sorted(leases.items()) if self.holds(caller, lease)]
        if not targets:
            self.say("this session holds no slots")
            return
        failures = []
        for name in targets:
            try:
                self.control("stop", name, no_block=no_block)
            except Refused as error:
                failures.append(str(error))
                continue
            with self.locked():
                current = self.leases().get(name)
                if current is not None and (self.holds(caller, current) or not self.alive(current)):
                    self.remove_lease(name)
            self.say(f"stopped {name}")
        if failures:
            raise Refused("; ".join(failures))

    def reap(self) -> None:
        """Stop every leased slot whose holder is gone, and drop its lease."""
        if not self.leases():
            return
        with self.locked():
            dead = [name for name, lease in sorted(self.leases().items()) if not self.alive(lease)]
        failures = []
        for name in dead:
            try:
                self.control("stop", name)
            except Refused as error:
                failures.append(str(error))
                continue
            with self.locked():
                current = self.leases().get(name)
                # A session may have claimed the slot again meanwhile.
                if current is not None and not self.alive(current):
                    self.remove_lease(name)
            self.say(f"reaped {name}")
        if failures:
            raise Refused("; ".join(failures))
