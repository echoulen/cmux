# cmux

Minimal Claude Code session multiplexer with side-channel input. Spawns a
child program in a pty and forwards bytes **transparently** between the host
terminal and the child — so colors, modifier keys (Shift+Enter), mouse, and
copy-paste all behave as if you ran the command directly.

Each session also exposes a unix socket that other processes can write into.
Anything written there is delivered to the child as if you had typed it,
which lets one Claude session "poke" another with a single command.

## Why not tmux?

tmux re-renders the inner terminal into a virtual screen, so truecolor,
extended keys, and clipboard hand-off all have to be negotiated, and several
combinations break in the IDE-integrated terminals where Claude Code lives.

cmux does no rendering. It is a thin pty proxy that forwards bytes both ways
verbatim, plus a side-channel socket.

## Install

```bash
git clone git@github.com:echoulen/cmux.git
mkdir -p ~/.local/bin
ln -s "$(pwd)/cmux/cmux" ~/.local/bin/cmux
```

Requires Python 3.9+ (stdlib only).

## Usage

```bash
# Start a wrapped Claude session named "claude-1":
cmux run claude-1 -- claude --permission-mode bypassPermissions

# From another terminal — poke claude-1 with a message:
cmux send claude-1 "幫我看 /tmp/foo.txt"

# List active sessions:
cmux list
```

A session lives only as long as the wrapper process. Closing the terminal
that owns it kills the wrapped child (this is intentional — cmux does not
provide detach/attach).

## How it works

```
[IDE terminal] ──stdin/stdout passthrough──> [cmux] ──pty──> [child]
                                                ▲
                                                │ unix socket (~/.cmux/<name>.sock)
                                                │
                                        [cmux send <name> "..."]
```

The main loop `select()`s over stdin, the pty master fd, and the unix
socket. Bytes from any input source are forwarded to the pty master; bytes
from the pty master are forwarded to stdout. The host terminal is put into
raw mode so escape sequences and modifier keys pass through unchanged.

## IDE setup

Replace your IDE's "Claude" launch command with:

```bash
cmux run claude-$$ -- claude --permission-mode bypassPermissions
```

`$$` gives each terminal a unique session name (process ID of the parent
shell). For a deterministic name use `claude-1`, `claude-2`, etc.

## License

MIT — see [LICENSE](LICENSE).
