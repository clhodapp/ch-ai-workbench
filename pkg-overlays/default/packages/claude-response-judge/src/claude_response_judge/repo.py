# SPDX-License-Identifier: MIT
"""Names that the repository of the session already uses.

A coinage check and a familiarity check ask whether a reader could tell what a name refers to.
A name that the main branch of the repository already holds belongs to the vocabulary of the
repository, and a reader finds it there. `known` asks git whether a phrase occurs in the tree of
`origin/main` (or `origin/master`, `main`, `master`, else `HEAD`), as a whole word without regard
to case, with the submodules where they are checked out. Text that is only in the working tree or
on a topic branch does not count, so a name that a session introduced on a branch stays subject to
the checks until it lands.

The directory comes from the session transcript: the `cwd` of its last entry that names one.
Every failure (no git, no repository, a timeout) answers that the name is not known.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

from .cli import transcript_entries

TIMEOUT = 5
MIN_LENGTH = 4
REFS = ("origin/main", "origin/master", "main", "master")
QUOTES = "`\"'“”‘’"


def session_cwd(transcript: Path | None) -> Path | None:
    """The working directory in the last entry of TRANSCRIPT that names an existing one."""
    if transcript is None:
        return None
    try:
        entries = transcript_entries(transcript)
    except OSError:
        return None
    for entry in reversed(entries):
        cwd = entry.get("cwd")
        if isinstance(cwd, str) and Path(cwd).is_dir():
            return Path(cwd)
    return None


def git(cwd: Path, *args: str) -> subprocess.CompletedProcess[str] | None:
    env = dict(os.environ, GIT_TERMINAL_PROMPT="0")
    try:
        return subprocess.run(
            ["git", "-C", str(cwd), *args],
            capture_output=True,
            text=True,
            timeout=TIMEOUT,
            check=False,
            env=env,
        )
    except (OSError, subprocess.SubprocessError):
        return None


def main_ref(cwd: Path) -> str:
    """The first of the usual main branches that exists in the repository, else HEAD."""
    for ref in REFS:
        done = git(cwd, "rev-parse", "--verify", "--quiet", f"{ref}^{{tree}}")
        if done is not None and done.returncode == 0:
            return ref
    return "HEAD"


def known(phrase: str, cwd: Path | None) -> bool:
    """Whether PHRASE occurs on the main branch of the repository that contains CWD."""
    text = phrase.strip().strip(QUOTES).strip()
    if cwd is None or len(text) < MIN_LENGTH:
        return False
    ref = main_ref(cwd)
    for recurse in (["--recurse-submodules"], []):
        done = git(cwd, "grep", "-q", "-i", "-F", "-w", *recurse, "-e", text, ref)
        # Status 0 means a match and 1 means none; anything else is an error of this attempt,
        # such as a submodule that is not checked out.
        if done is not None and done.returncode in (0, 1):
            return done.returncode == 0
    return False
