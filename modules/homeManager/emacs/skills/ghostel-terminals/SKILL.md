---
name: ghostel-terminals
description: The user's terminals run in ghostel, a terminal emulator inside the live Emacs, so each is an Emacs buffer. A terminal is sensitive by default and withheld from the agent until the user exposes that one, because it shows whatever ran in it. Read this before trying to see a terminal or asking the user to paste its output, so you know what you can read and how the user grants access.
---

# Ghostel terminals are Emacs buffers, hidden by default

The user runs their terminals inside **ghostel**, a terminal emulator that
lives in their Emacs session, so every active terminal is an Emacs buffer
served by the `emacs` MCP server. A terminal is sensitive by default: it
shows whatever ran in it (an echoed password, a token on a command line,
the output of `env`), so the server withholds it until the user exposes
that specific one.

The rule for every buffer: it starts sensitive when it is a terminal or
visits a file whose name marks it as holding secrets (`.authinfo`, `.gpg`
and `.age` files, `.env` and its variants), and starts readable
otherwise. The user flips any buffer either way with one toggle. A
withheld buffer is one of those two kinds, and access to it comes the
same way for both.

## What you can and cannot see

- A terminal you have **not** been granted is absent from `list-buffers`
  and refused by the buffer read tools, and it still exists: the
  terminal is open and ghostel is running, you simply have no access.
- A terminal the user has **exposed** reads like any other buffer: its
  text is the rendered on-screen content, available through
  `mcp__emacs__buffer-text`.

## Getting access

- The user exposes a terminal they judge safe with
  `ch-mcp-server-toggle-buffer-sensitive` (bound to `<leader> a t`), run
  in that terminal; running it again withholds it. The same toggle flips
  any buffer's sensitive state. Exposure is per-buffer: one terminal
  being visible says nothing about another.
- To see a withheld terminal, **ask the user to expose it**, naming what
  you need to check. The user's toggle is the only way a withheld buffer
  becomes readable.

## Writing to them needs explicit say-so

Exposure grants reading. Sending input to a ghostel terminal (simulated
keystrokes, `ghostel--send-encoded`) types into the user's **live**
session; that is stateful and needs its own explicit say-so first, per
the `live-emacs-safety` skill.

## When this comes up

- The user mentions a command they ran, something "in my terminal", a
  long-running build or test, or another agent session they have open. If
  the relevant terminal has been exposed, read it; if not, ask them to
  expose it.
