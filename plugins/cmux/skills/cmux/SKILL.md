---
name: cmux
description: Coordinate with peer Claude sessions via the `cmux` CLI. Use when $CMUX_SESSION is set in the environment (you are running inside a cmux-wrapped session), or when the user references "another session / another terminal / claude-N" and asks you to talk to it. Lets you list peer sessions and inject messages into them as if the user had typed there.
---

# cmux — peer session coordination

You are running inside a `cmux`-wrapped session iff `$CMUX_SESSION` is set in
your shell environment. The value is your own session name (e.g. `claude-1`).
Other peer sessions live as unix sockets under `~/.cmux/<name>.sock`.

## When to use

- `$CMUX_SESSION` is set and the user asks you to coordinate with, hand off
  to, notify, or relay a message to another session.
- The user mentions "the other claude / another terminal / claude-2 / my
  other session" and wants action there.
- You receive an input line starting with `[from <name>] ...` — that is a
  message a peer session injected via `cmux send`. You may reply by sending
  back to that peer.

## Commands

```bash
cmux list                     # list active peer session names
cmux send <name> <message>    # inject "<message>\r" into <name>'s pty
```

`cmux send` invoked from inside a wrapped session auto-prefixes the message
with `[from $CMUX_SESSION] ` — the receiver sees the source. You don't need
to add the prefix yourself.

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
