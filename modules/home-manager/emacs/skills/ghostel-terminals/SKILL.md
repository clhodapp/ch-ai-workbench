---
name: ghostel-terminals
description: The user's terminals run in ghostel, a terminal emulator inside the live Emacs, so each is an Emacs buffer. But terminals are sensitive by default and withheld from the agent until the user exposes a given one, because a terminal shows whatever ran in it. Read this before trying to see a terminal or asking the user to paste its output, so you know what you can and cannot read and how the user grants access.
---

# Ghostel terminals are Emacs buffers, hidden by default

The user runs their terminals inside **ghostel**, a terminal emulator that
lives in their Emacs session, so every active terminal is an Emacs buffer
that the `emacs` MCP server could in principle read. It does not read them
by default: a terminal shows whatever ran in it (an echoed password, a
token on a command line, the output of `env`), so terminals are treated as
sensitive and withheld until the user exposes the specific one.

This reverses the usual buffer rule. Ordinary buffers are readable unless
the user marks them sensitive; terminals are the one kind that starts
hidden and becomes readable only when the user says so.

## What you can and cannot see

- A terminal you have **not** been granted is not returned by the buffer
  read tools and does not appear in `list-buffers`. Treat it as present
  but unreadable, not as absent: do not conclude the terminal is closed
  or that ghostel is not in use.
- A terminal the user has **exposed** reads like any other buffer: its
  text is the rendered on-screen content, available through
  `mcp__emacs__buffer-text`.

## Getting access

- The user exposes a terminal they judge safe with
  `ch-mcp-server-toggle-terminal-visible`, run in that terminal; running
  it again re-hides it. Exposure is per-terminal and per-buffer: one
  terminal being visible says nothing about another.
- If you need to see a terminal that is withheld, **ask the user to
  expose it** (naming what you need to check), rather than trying to
  resolve it by mode or working around the read tools. There is no agent
  path around the default; the grant is the user's.

## Writing to them needs explicit say-so

Even an exposed terminal is read-only to you. Sending input to a ghostel
terminal (simulated keystrokes, `ghostel--send-encoded`) types into the
user's **live** session; that is stateful and needs the user's explicit
say-so first, per the `live-emacs-safety` skill. Being able to see a
terminal never implies permission to drive it, and exposing a terminal
for reading is not permission to write to it.

## When this comes up

- The user mentions a command they ran, something "in my terminal", a
  long-running build or test, or another agent session they have open. If
  the relevant terminal has been exposed, read it; if not, ask them to
  expose it rather than asking them to paste, and rather than assuming you
  cannot help.
