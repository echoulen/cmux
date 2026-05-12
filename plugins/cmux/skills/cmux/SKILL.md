---
name: cmux
description: Coordinate with peer Claude sessions via the `cmux` CLI. Invoke when (a) an input line begins with `[Message from <name> via cmux]` — that marker means a peer Claude session relayed the message to you, and you must name the source in your reply rather than treat it as a normal user prompt; or (b) `$CMUX_SESSION` is set and the user asks you to talk to "another session / another terminal / claude-N". Lets you list peers and inject messages into them. NOTE: this plugin only ships the skill — the `cmux` CLI binary must be installed separately (see Prerequisite below).
---

# cmux — peer session coordination

You are running inside a `cmux`-wrapped session iff `$CMUX_SESSION` is set in
your shell environment. The value is your own session name (e.g. `claude-1`).
Other peer sessions live as unix sockets under `~/.cmux/<name>.sock`.

## Prerequisite

Before any other step, verify the CLI is installed:

```bash
command -v cmux
```

If this returns nothing (i.e. `cmux: command not found` when you try to use
it), the plugin is installed but the CLI is not. Stop and tell the user:

> The `cmux` CLI is not installed. Install it with:
>
> ```
> curl -sSL https://raw.githubusercontent.com/echoulen/cmux/main/install.sh | bash
> ```
>
> Then make sure `~/.local/bin` is on your PATH and re-run the request.

Do not attempt to install it yourself, fall back to ad-hoc pty hacks, or
guess at peer-session bytes through other means.

## When to use

- An input line begins with `[Message from <name> via cmux] <body>` — peer
  session `<name>` injected it. Name the source in your reply, then answer
  the body as a peer request; do not auto-reply via `cmux send` unless the
  user asks.
- `$CMUX_SESSION` is set and the user asks you to coordinate with, hand off
  to, notify, or relay a message to another session / terminal / claude-N.

## Commands

```bash
cmux list                     # list active peer session names
cmux send <name> <message>    # inject "<message>\r" into <name>'s pty
```

`cmux send` invoked from inside a wrapped session auto-prefixes the message
with `[Message from $CMUX_SESSION via cmux] ` (bold green) — the receiver
sees the source. You don't need to add the prefix yourself.

## Workflow

1. `cmux list` to see who is alive.
2. Pick a target by name (or ask the user if ambiguous).
3. `cmux send <target> "<message>"` — keep the message short and actionable;
   the peer agent sees it as if the user had just typed it and pressed Enter.
4. If you expect a reply, tell the user to watch the other terminal — there
   is no return channel back to you besides the user.

## Examples

```bash
# Tell claude-2 you finished the build:
cmux send claude-2 "build is green; please run e2e tests next"

# Ask peer to look at a file:
cmux send claude-3 "please review /tmp/diff.patch and report blockers"

# Discover peers first when unsure:
cmux list
```

## Caveats

- One-way: `cmux send` only injects input. You will not see the peer's reply
  unless the user relays it.
- The peer treats the injected text as user input — be careful with anything
  destructive, the peer may act on it without further confirmation.
- If `$CMUX_SESSION` is unset, this skill does not apply — you are not inside
  a cmux session and should not assume peers exist.
