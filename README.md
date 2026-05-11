# cmux

Minimal pty wrapper for Claude Code sessions. Forwards bytes verbatim (colors,
modifier keys, mouse, clipboard all unchanged) and exposes a unix socket so
other processes can inject input — one Claude can poke another with one shell
command.

## Install

```bash
git clone git@github.com:echoulen/cmux.git
ln -s "$(pwd)/cmux/cmux" ~/.local/bin/cmux
```

Python 3.9+ stdlib only.

## Commands

```bash
cmux run [<name>] [-- cmd args...]   # wrap cmd in pty (default $SHELL)
cmux send <name> <message>           # inject <message>+Enter into <name>
cmux list                            # list active sessions
```

If `<name>` is omitted, defaults to `<basename(cmd)>-N`, picking the lowest
free `N` (`claude-1`, `claude-2`, ...).

## Examples

```bash
cmux run -- claude --permission-mode bypassPermissions
cmux send claude-1 "take a look at /tmp/foo.txt"
cmux list
```

## CMUX_SESSION

Each wrapped child gets `CMUX_SESSION=<name>` in its env. When `cmux send` runs
inside a wrapped session, it auto-prefixes the message with `[from <name>] `
so the receiver knows the source.

## How it works

```
[host terminal] ──stdin/stdout passthrough──> [cmux] ──pty──> [child]
                                                ▲
                                                │ unix socket (~/.cmux/<name>.sock)
                                                │
                                        [cmux send <name> "..."]
```

Host terminal in raw mode → escape sequences and modifier keys pass through.
A session lives only as long as its wrapper; closing the owning terminal
kills the child (cmux has no detach/attach).

## License

MIT — see [LICENSE](LICENSE).
