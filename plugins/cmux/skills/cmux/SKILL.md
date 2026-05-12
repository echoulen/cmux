---
name: cmux
description: Coordinate with peer Claude sessions via the `cmux` CLI. Invoke when (a) an input line begins with `[Message from <name> via cmux]` — that marker means a peer Claude session relayed the message to you, and you must name the source in your reply rather than treat it as a normal user prompt; (b) the same line also contains `reply via: cmux send …`, which means the sender REQUIRES you to echo an answer back via that exact command; or (c) `$CMUX_SESSION` is set and the user asks you to talk to "another session / another terminal / claude-N". Lets you list peers and inject messages into them. NOTE: this plugin only ships the skill — the `cmux` CLI binary must be installed separately (see Prerequisite below).
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
  the body as a peer request. Do NOT auto-reply via `cmux send` unless either
  (a) the prefix contains `reply via: <command>` (see "Reply-expected
  messages" below), or (b) the user explicitly asks you to.
- `$CMUX_SESSION` is set and the user asks you to coordinate with, hand off
  to, notify, or relay a message to another session / terminal / claude-N.

## Commands

```bash
cmux list                          # list active peer session names
cmux send <name> <message>         # inject "<message>\r" into <name>'s pty
cmux send -r <name> <message>      # same, but declare that a reply is expected
```

`cmux send` invoked from inside a wrapped session auto-prefixes the message
with `[Message from $CMUX_SESSION via cmux] ` — the receiver sees the source.
You don't need to add the prefix yourself.

Pass `-r` (or `--reply`) when you are asking the peer for information you
need to continue your own work. The receiver is contractually obligated to
echo an answer back via `cmux send $CMUX_SESSION`. For fire-and-forget
notifications ("starting refactor", "tests passing"), omit the flag.

## Reply-expected messages

If an incoming line begins with
`[Message from <name> via cmux, reply via: <command>] <body>`,
treat it as a request that REQUIRES a reply:

1. Produce your answer to `<body>` as you normally would. Your visible
   response to the user is unchanged — they can still see it locally.
2. After answering, you MUST run `<command>`, replacing the literal
   placeholder `<your answer>` inside the command with a concise string that
   conveys your answer to the sender. The sender is waiting on that exact
   channel.

   Worked example: if the prefix you received says
   `reply via: cmux send claude-1 "<your answer>"`, and your actual answer
   is `/Users/alice/work`, run:
   ```bash
   cmux send claude-1 "/Users/alice/work"
   ```
   Do NOT send the literal placeholder text `<your answer>` — it exists
   only to mark where your real answer goes.
3. If you cannot answer (refusal, missing info, blocked), still run the
   command — send a short string explaining why no answer is forthcoming,
   so the sender isn't left waiting.

If the prefix has NO `reply via:` segment, do not run `cmux send` back to
the sender unless the user explicitly asks you to.

## Workflow

1. `cmux list` to see who is alive.
2. Pick a target by name (or ask the user if ambiguous).
3. `cmux send <target> "<message>"` — keep the message short and actionable;
   the peer agent sees it as if the user had just typed it and pressed Enter.
4. If you expect a reply, send with `cmux send -r <target> "<question>"`.
   The peer's agent is then obligated to relay an answer back via
   `cmux send $CMUX_SESSION "<answer>"` — which lands in your input prompt
   as another `[Message from <peer> via cmux] ...` line. There is no
   programmatic correlation between request and reply; the user (and you)
   simply watch for the next inbound message.

## Examples

```bash
# Tell claude-2 you finished the build:
cmux send claude-2 "build is green; please run e2e tests next"

# Ask peer to look at a file:
cmux send claude-3 "please review /tmp/diff.patch and report blockers"

# Discover peers first when unsure:
cmux list

# Ask peer for info you need to continue, expecting an answer back:
cmux send -r claude-2 "what's the current pwd in your session?"
```

## Caveats

- Fire-and-forget by default: a plain `cmux send` (no `-r`) only injects
  input. You will not see the peer's reply unless the user relays it.
- With `-r`: the peer's agent is obligated to send an answer back via
  `cmux send $CMUX_SESSION "<their answer>"`, which lands in your input
  prompt as a normal `[Message from <peer> via cmux] ...` line. There is no
  programmatic correlation; just watch for the next inbound message.
- The peer treats the injected text as user input — be careful with anything
  destructive, the peer may act on it without further confirmation.
- If `$CMUX_SESSION` is unset, this skill does not apply — you are not inside
  a cmux session and should not assume peers exist.
