# SPDX-License-Identifier: MIT
"""claude-vcs-message: print the commit message, pull request text, or review a shell command writes.

The command arrives on stdin, as the Bash tool's `command` field. Each simple command in it
(split at `;`, `&&`, `||`, `|`, and newlines) that runs `git ... commit`, `gh pr
create|edit|comment|review`, or `gh api` on a pull request's review or comment endpoints
contributes its text:

- git commit: every `-m`/`--message` value, and the `-F`/`--file` source, which is the
  command's here-document for `-` and otherwise a file read relative to `--cwd`.
- gh pr: `--title`/`-t`, `--body`/`-b`, and `--body-file`/`-F`, read the same way.
- gh api: each `-f`/`--raw-field` and `-F`/`--field` named `body` or ending in `[body]`
  (`@FILE` read as above), and every "body" string in an `--input` JSON document, which
  holds a review's body and the bodies of its inline comments.

A here-document inside a `-m` value, the `"$(cat <<'EOF' ... EOF)"` form, gives its body as the
value. The texts are printed one after another with a blank line between them. A command that
writes none, or one the tokenizer cannot read, prints nothing; this program never fails a hook.
"""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from pathlib import Path

HEREDOC = re.compile(r"<<(-?)[ \t]*(?:'([^'\n]+)'|\"([^\"\n]+)\"|\\?([A-Za-z_][A-Za-z0-9_]*))")
PLACEHOLDER = "__CLAUDE_HEREDOC_{}__"
PLACEHOLDER_RE = re.compile(r"__CLAUDE_HEREDOC_(\d+)__")
OPERATORS = {";", "&&", "||", "|", "&", "\n", "(", ")"}
SEPARATORS = ";&|()\n"
GIT_OPTIONS_WITH_VALUE = {"-C", "-c", "--git-dir", "--work-tree", "--namespace"}
# The REST paths of a pull request review, its inline comments, a reply to one, and a
# conversation comment.
REVIEW_ENDPOINT = re.compile(r"pulls/\d+/(reviews|comments)|pulls/comments/\d+|issues/\d+/comments")


def cut_heredocs(command: str) -> tuple[str, list[str]]:
    """The command with each here-document's operator replaced by a placeholder word and its
    body removed, and the bodies in order."""
    lines = command.split("\n")
    out, bodies = [], []
    i = 0
    while i < len(lines):
        pending: list[tuple[bool, str]] = []

        def replace(m: re.Match[str], pending: list[tuple[bool, str]] = pending) -> str:
            pending.append((m.group(1) == "-", m.group(2) or m.group(3) or m.group(4)))
            return " " + PLACEHOLDER.format(len(bodies) + len(pending) - 1) + " "

        out.append(HEREDOC.sub(replace, lines[i]))
        i += 1
        for strip_tabs, delimiter in pending:
            body = []
            while i < len(lines):
                candidate = lines[i].lstrip("\t") if strip_tabs else lines[i]
                i += 1
                if candidate == delimiter:
                    break
                body.append(candidate)
            bodies.append("\n".join(body) + "\n")
    return "\n".join(out), bodies


def simple_commands(command: str) -> list[list[str]]:
    # A newline outside quotes separates commands as `;` does, so it is a punctuation
    # character rather than whitespace; inside quotes it stays part of the word.
    lexer = shlex.shlex(command, posix=True, punctuation_chars=";&|()\n")
    lexer.whitespace = " \t\r"
    lexer.whitespace_split = True
    commands, current = [], []
    for token in lexer:
        if token in OPERATORS or set(token) <= set(SEPARATORS):
            if current:
                commands.append(current)
            current = []
        else:
            current.append(token)
    if current:
        commands.append(current)
    return commands


def substitute(value: str, bodies: list[str]) -> str:
    """A value holding a here-document placeholder (the `$(cat <<'EOF' ...)` form) is that
    here-document's body."""
    m = PLACEHOLDER_RE.search(value)
    return bodies[int(m.group(1))] if m else value


def stdin_body(args: list[str], bodies: list[str]) -> str | None:
    for arg in args:
        m = PLACEHOLDER_RE.fullmatch(arg)
        if m:
            return bodies[int(m.group(1))]
    return None


def source(value: str, args: list[str], bodies: list[str], cwd: Path) -> str | None:
    if value == "-":
        return stdin_body(args, bodies)
    try:
        return (cwd / value).read_text()
    except (OSError, ValueError):
        return None


def option_values(args: list[str], short: str | None, long: str) -> list[str]:
    """Values of `long VALUE`, `long=VALUE`, `short VALUE` and `shortVALUE` in ARGS."""
    values = []
    i = 0
    while i < len(args):
        arg = args[i]
        if arg == long or (short and arg == short):
            if i + 1 < len(args):
                values.append(args[i + 1])
            i += 2
            continue
        if arg.startswith(long + "="):
            values.append(arg[len(long) + 1 :])
        elif short and arg.startswith(short) and len(arg) > len(short) and not arg.startswith("--"):
            values.append(arg[len(short) :])
        i += 1
    return values


def git_commit_args(tokens: list[str]) -> list[str] | None:
    if not tokens or Path(tokens[0]).name != "git":
        return None
    i = 1
    while i < len(tokens) and tokens[i].startswith("-"):
        i += 2 if tokens[i] in GIT_OPTIONS_WITH_VALUE else 1
    if i < len(tokens) and tokens[i] == "commit":
        return tokens[i + 1 :]
    return None


def gh_pr_args(tokens: list[str]) -> list[str] | None:
    if (
        len(tokens) >= 3
        and Path(tokens[0]).name == "gh"
        and tokens[1] == "pr"
        and tokens[2] in {"create", "edit", "comment", "review"}
    ):
        return tokens[3:]
    return None


def gh_api_review_args(tokens: list[str]) -> list[str] | None:
    """The arguments of a `gh api` call to a pull request's review or comment endpoints."""
    if (
        len(tokens) >= 3
        and Path(tokens[0]).name == "gh"
        and tokens[1] == "api"
        and any(REVIEW_ENDPOINT.search(arg) for arg in tokens[2:])
    ):
        return tokens[2:]
    return None


def bodies_in(value: object) -> list[str]:
    """Every string under a "body" key in a JSON document (a review's body and the bodies
    of its inline comments)."""
    if isinstance(value, dict):
        found = [v for k, v in value.items() if k == "body" and isinstance(v, str)]
        return found + [b for k, v in value.items() if k != "body" for b in bodies_in(v)]
    if isinstance(value, list):
        return [b for v in value for b in bodies_in(v)]
    return []


def gh_api_texts(args: list[str], bodies: list[str], cwd: Path) -> list[str]:
    found = []
    fields = option_values(args, "-f", "--raw-field") + option_values(args, "-F", "--field")
    for field in fields:
        key, sep, value = field.partition("=")
        if not sep or not (key == "body" or key.endswith("[body]")):
            continue
        if value.startswith("@"):
            value = source(value[1:], args, bodies, cwd) or ""
        found.append(substitute(value, bodies))
    for value in option_values(args, None, "--input"):
        document = source(value, args, bodies, cwd)
        try:
            found += bodies_in(json.loads(document)) if document else []
        except ValueError:
            pass
    return found


def texts(command: str, cwd: Path) -> list[str]:
    command, bodies = cut_heredocs(command)
    try:
        commands = simple_commands(command)
    except ValueError:
        return []
    found = []
    for tokens in commands:
        args = git_commit_args(tokens)
        if args is not None:
            found += [substitute(v, bodies) for v in option_values(args, "-m", "--message")]
            found += [t for v in option_values(args, "-F", "--file") if (t := source(v, args, bodies, cwd))]
            continue
        args = gh_pr_args(tokens)
        if args is not None:
            found += [substitute(v, bodies) for v in option_values(args, "-t", "--title")]
            found += [substitute(v, bodies) for v in option_values(args, "-b", "--body")]
            found += [t for v in option_values(args, "-F", "--body-file") if (t := source(v, args, bodies, cwd))]
            continue
        args = gh_api_review_args(tokens)
        if args is not None:
            found += gh_api_texts(args, bodies, cwd)
    return [t.strip() for t in found if t.strip()]


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(prog="claude-vcs-message", description=__doc__.split("\n")[0])
    p.add_argument("--cwd", type=Path, default=Path("."), help="directory a relative message file is read from")
    args = p.parse_args(argv)
    found = texts(sys.stdin.read(), args.cwd)
    if found:
        print("\n\n".join(found))
    return 0


if __name__ == "__main__":
    sys.exit(main())
