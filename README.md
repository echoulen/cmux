# cmux

Minimal pty wrapper for Claude Code sessions. Forwards bytes verbatim (colors,
modifier keys, mouse, clipboard all unchanged) and exposes a unix socket so
other processes can inject input — one Claude can poke another with one shell
command.

## Install

Two pieces, install in order. Plugin alone is useless without the CLI.

**1. CLI** — required. Python 3.9+ stdlib only:

```bash
curl -sSL https://raw.githubusercontent.com/echoulen/cmux/main/install.sh | bash
```

Once installed, wrap a Claude session:

```bash
cmux run -- claude --permission-mode bypassPermissions   # opens claude-1
```

Re-run the curl command above to update.

**2. Claude Code plugin** — optional. Adds a `cmux` skill so agents inside
`cmux run -- claude ...` auto-discover peers and know how to handle incoming
`[<name> via cmux]` lines:

```bash
/plugin marketplace add echoulen/cmux
/plugin install cmux@cmux
```

## Usage

```bash
cmux run [<name>] [-- cmd args...]   # wrap cmd in pty (default $SHELL)
cmux send <name> <message>           # inject <message>+Enter into <name>
cmux send -r <name> <message>        # same, but declare a reply is expected
cmux list                            # list active sessions
```

Default name is `<basename(cmd)>-N` (`claude-1`, `claude-2`, ...). Each
wrapped child gets `CMUX_SESSION=<name>` in its env; `cmux send` from inside
a wrapped session auto-prefixes the message with `[<name> via cmux] ` so the
receiver knows the source. Add `-r` / `--reply` to append a `⇄` symbol —
`[<name> via cmux ⇄] ` — which the receiver's skill treats as a contract to
echo an answer back via `cmux send <name>`.

```bash
cmux send claude-1 "take a look at /tmp/foo.txt"
cmux list
```

## Two sessions talking

Spin up two wrapped Claude sessions in two terminals:

```bash
# terminal A
cmux run -- claude   # opens claude-1

# terminal B
cmux run -- claude   # opens claude-2
```

Now claude-1 and claude-2 can poke each other directly. From inside
claude-1, the agent runs:

```bash
cmux send claude-2 "starting auth refactor in src/auth/ — please draft tests for login"
```

In terminal B, claude-2's input prompt receives:

```
[claude-1 via cmux] starting auth refactor in src/auth/ — please draft tests for login
```

claude-2 acknowledges the source, writes the tests, then relays back:

```bash
cmux send claude-1 "tests live in tests/auth/login.test.ts — 6 cases, all passing"
```

…which lands in terminal A as:

```
[claude-2 via cmux] tests live in tests/auth/login.test.ts — 6 cases, all passing
```

### Asking with `-r`

When claude-1 actually needs an answer back (not just a notification), it
should use `-r`:

```bash
cmux send -r claude-2 "what's the absolute path of your working dir?"
```

claude-2's input prompt receives:

```
[claude-1 via cmux ⇄] what's the absolute path of your working dir?
```

The cmux skill in claude-2's session treats the `⇄` symbol as a contract.
After answering its user, claude-2 runs:

```bash
cmux send claude-1 "/Users/alice/work/project"
```

…which lands in claude-1's prompt as a normal `[claude-2 via cmux] /Users/alice/work/project` line.

The plugin (step 2 of Install) is what teaches each agent to (a) recognize
those prefixed lines as cmux relays and (b) reach for `cmux send` when
they want to hand work off.

## How it works

```
[host terminal] ──stdin/stdout passthrough──> [cmux] ──pty──> [child]
                                                ▲
                                                │ unix socket (~/.cmux/<name>.sock)
                                                │
                                        [cmux send <name> "..."]
```

Host terminal stays in raw mode. A session lives only as long as its
wrapper; closing the owning terminal kills the child.

## License

MIT — see [LICENSE](LICENSE).
