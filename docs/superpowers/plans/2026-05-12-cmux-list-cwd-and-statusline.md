# cmux list cwd + statusline widget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make a running cmux session's directory visible in `cmux list -l` and expose the session name as `cmux statusline-widget` for users to wire into Claude Code's statusLine.

**Architecture:** Single-file Python `cmux` script gains (a) a per-session `~/.cmux/<name>.json` sidecar holding pid + start cwd, (b) helpers `_live_cwd` (proc-or-lsof) and `_render_long_table` (shared by `list -l` and the `send` not-found fallback), and (c) a `statusline-widget` subcommand that reads `$CMUX_SESSION` and prints a single line. A new `tests/test_cmux.sh` blackbox-tests each surface end-to-end.

**Tech Stack:** Python 3.9+ stdlib only (`json`, `subprocess` newly used; `os`, `time`, `socket`, `pty`, `select`, etc. already present). Bash for the test script.

**Spec:** `docs/superpowers/specs/2026-05-12-cmux-list-cwd-and-statusline-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `cmux` | Modify | All implementation. Add helpers + new subcommand + flag handling, all alphabetised next to existing peers. |
| `tests/test_cmux.sh` | Create | Bash blackbox suite. Each surface gets a self-contained test function. Cleans up its own sessions and tmp dir on exit. |
| `README.md` | Modify | Add "Show the session name in your Claude Code statusline" section near the bottom (above License). |

No file split inside `cmux` itself — the script is ~370 lines and the spec adds ~150. Splitting into a package would change the install story (one-file curl) and is out of scope.

---

### Task 1: Test harness scaffolding + smoke test

**Files:**
- Create: `tests/test_cmux.sh`

- [ ] **Step 1: Create the test harness file**

```bash
#!/usr/bin/env bash
# tests/test_cmux.sh — manual end-to-end check for cmux.
# Run from the repo root: bash tests/test_cmux.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMUX="${CMUX_BIN:-$REPO_ROOT/cmux}"
TEST_TMP="$(mktemp -d -t cmux-test.XXXXXX)"
# Isolate ~/.cmux for tests so we never touch the user's real sessions.
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

PASS=0
FAIL=0
SESSION_PIDS=()

cleanup() {
  for pid in "${SESSION_PIDS[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  # Give cmux's cleanup() a moment to unlink sockets/sidecars.
  sleep 0.2
  rm -rf "$TEST_TMP"
}
trap cleanup EXIT

ok() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

bad() {
  echo "  FAIL: $1"
  echo "    $2"
  FAIL=$((FAIL + 1))
}

# Spawn `cmux run <name> -- <cmd...>` in the background. Records the pid.
spawn_session() {
  local name="$1"; shift
  setsid "$CMUX" run "$name" -- "$@" </dev/null >/dev/null 2>&1 &
  SESSION_PIDS+=("$!")
  # Wait up to 2s for the socket to appear.
  for _ in $(seq 1 20); do
    [[ -S "$HOME/.cmux/$name.sock" ]] && return 0
    sleep 0.1
  done
  bad "spawn_session $name" "socket never appeared"
  return 1
}

# Test: cmux help exits 0 and contains the word "Usage:".
test_help() {
  echo "test_help"
  local out
  if ! out="$("$CMUX" help 2>&1)"; then
    bad "cmux help exits 0" "non-zero exit"
    return
  fi
  if [[ "$out" == *"Usage:"* ]]; then
    ok "cmux help mentions Usage:"
  else
    bad "cmux help mentions Usage:" "got: $out"
  fi
}

test_help

echo
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x tests/test_cmux.sh`

- [ ] **Step 3: Run the smoke test**

Run: `bash tests/test_cmux.sh`
Expected: `Results: 1 passed, 0 failed`, exit 0.

- [ ] **Step 4: Commit**

```bash
git add tests/test_cmux.sh
git commit -m "test: scaffold tests/test_cmux.sh with help smoke test"
```

---

### Task 2: `cmux statusline-widget` — failing test

**Files:**
- Modify: `tests/test_cmux.sh` (append a test function and call it)

- [ ] **Step 1: Add `test_statusline_widget` to the script**

Insert immediately above the `test_help` invocation line:

```bash
test_statusline_widget() {
  echo "test_statusline_widget"
  local out
  out="$(CMUX_SESSION=claude-x "$CMUX" statusline-widget 2>&1)"
  if [[ "$out" == "§ cmux:claude-x" ]]; then
    ok "widget prints '§ cmux:<name>' when CMUX_SESSION is set"
  else
    bad "widget prints '§ cmux:<name>' when CMUX_SESSION is set" "got: $out"
  fi

  out="$(env -u CMUX_SESSION "$CMUX" statusline-widget 2>&1)"
  if [[ -z "$out" ]]; then
    ok "widget prints nothing when CMUX_SESSION is unset"
  else
    bad "widget prints nothing when CMUX_SESSION is unset" "got: $out"
  fi
}

```

And add the call right above `test_help`:

```bash
test_statusline_widget
test_help
```

- [ ] **Step 2: Run the suite to confirm it fails**

Run: `bash tests/test_cmux.sh`
Expected: at least one `FAIL:` for the widget — `cmux statusline-widget` currently prints the help text and exits 2 (unknown command), so both assertions fail.

---

### Task 3: `cmux statusline-widget` — implement

**Files:**
- Modify: `cmux` (add function near `cmd_list`, register in `main()`, mention in `HELP`)

- [ ] **Step 1: Add the subcommand function**

Add this function in `cmux` directly after `cmd_list` (around line 318, before the `HELP` string):

```python
def cmd_statusline_widget() -> int:
    """Print a one-line cmux marker if we're inside a wrapped session."""
    name = os.environ.get("CMUX_SESSION")
    if name:
        sys.stdout.write(f"§ cmux:{name}\n")
    return 0
```

- [ ] **Step 2: Register the subcommand in `main()`**

In `main()`, add this branch right before the final `print(f"cmux: unknown command '{cmd}'"` line:

```python
    if cmd == "statusline-widget":
        return cmd_statusline_widget()
```

- [ ] **Step 3: Add it to `HELP`**

Update the `HELP` string. Replace the existing usage block:

```
  cmux run [<name>] [-- cmd args...]  Start a wrapped session (default: $SHELL)
                                      Name auto-generated from cmd if omitted.
  cmux send <name> <message>          Send <message>+Enter to <name>
  cmux list                           List active sessions
  cmux help                           Show help
```

with:

```
  cmux run [<name>] [-- cmd args...]  Start a wrapped session (default: $SHELL)
                                      Name auto-generated from cmd if omitted.
  cmux send <name> <message>          Send <message>+Enter to <name>
  cmux list [-l|--long]               List active sessions (-l adds cwd columns)
  cmux statusline-widget              Print "§ cmux:<name>" if $CMUX_SESSION set
  cmux help                           Show help
```

Make the same swap inside the longer `HELP` constant near the bottom of the file (it appears twice — once as the docstring near the top of the file, once as `HELP`). Update both so they stay in sync.

- [ ] **Step 4: Run the suite**

Run: `bash tests/test_cmux.sh`
Expected: both widget assertions pass; total `Results: 3 passed, 0 failed`.

- [ ] **Step 5: Commit**

```bash
git add cmux tests/test_cmux.sh
git commit -m "feat(cmux): add statusline-widget subcommand"
```

---

### Task 4: Sidecar metadata file — failing test

**Files:**
- Modify: `tests/test_cmux.sh`

- [ ] **Step 1: Add `test_sidecar_metadata` to the script**

Insert above the `test_help` invocation:

```bash
test_sidecar_metadata() {
  echo "test_sidecar_metadata"
  spawn_session shell-meta bash -lc 'sleep 30' || return
  local meta="$HOME/.cmux/shell-meta.json"
  if [[ -f "$meta" ]]; then
    ok "sidecar JSON exists at ~/.cmux/shell-meta.json"
  else
    bad "sidecar JSON exists at ~/.cmux/shell-meta.json" "missing"
    return
  fi
  # Confirm shape: pid is a number, cwd is a string, started_at is a number.
  python3 - "$meta" <<'PY' || bad "sidecar JSON has pid/cwd/started_at" "shape mismatch"
import json, sys
m = json.load(open(sys.argv[1]))
assert isinstance(m.get("pid"), int), m
assert isinstance(m.get("cwd"), str) and m["cwd"], m
assert isinstance(m.get("started_at"), int), m
PY
  if [[ $? -eq 0 ]]; then
    ok "sidecar JSON has pid/cwd/started_at"
  fi
  # Kill the session and confirm the sidecar is unlinked.
  kill "${SESSION_PIDS[-1]}" 2>/dev/null || true
  sleep 0.3
  if [[ ! -f "$meta" ]]; then
    ok "sidecar JSON removed when session exits"
  else
    bad "sidecar JSON removed when session exits" "still present"
  fi
}

```

And call it above `test_help`:

```bash
test_statusline_widget
test_sidecar_metadata
test_help
```

- [ ] **Step 2: Run the suite to confirm the new test fails**

Run: `bash tests/test_cmux.sh`
Expected: `FAIL: sidecar JSON exists at ~/.cmux/shell-meta.json` (file is never written today).

---

### Task 5: Sidecar metadata file — implement

**Files:**
- Modify: `cmux` (add `json` import, `_meta_path`, `_write_metadata`, `_read_metadata` helpers; update `cmd_run` and its `cleanup`)

- [ ] **Step 1: Add the `json` import**

In the top-of-file imports block, insert `import json` in alphabetical order (after `import fcntl`, before `import os`):

```python
import fcntl
import json
import os
```

- [ ] **Step 2: Add the metadata helpers**

Add these three helpers right after the existing `sock_path` / `ensure_sock_dir` helpers (around line 42):

```python
def _meta_path(name: str) -> str:
    return os.path.join(SOCK_DIR, f"{name}.json")


def _write_metadata(name: str, pid: int, cwd: str) -> None:
    """Persist sidecar JSON. Best-effort — failure must not abort the session."""
    path = _meta_path(name)
    tmp = path + ".tmp"
    payload = {"pid": pid, "cwd": cwd, "started_at": int(time.time())}
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(payload, f)
        os.replace(tmp, path)
    except OSError:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def _read_metadata(name: str) -> dict | None:
    try:
        with open(_meta_path(name), "r") as f:
            return json.load(f)
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return None
```

- [ ] **Step 3: Capture cwd and write metadata in `cmd_run`**

In `cmd_run`, capture `start_cwd` before `pty.fork()` (around line 142, just above the `pid, pty_fd = pty.fork()` line):

```python
    start_cwd = os.getcwd()

    pid, pty_fd = pty.fork()
```

Then, after `os.chmod(path, 0o600)` and before `srv.listen(8)` (around line 158), add:

```python
    _write_metadata(name, pid, start_cwd)
```

- [ ] **Step 4: Unlink metadata in `cleanup`**

In the `cleanup` closure inside `cmd_run`, add a metadata unlink right after the existing `os.unlink(path)` block (around line 197):

```python
        try:
            os.unlink(_meta_path(name))
        except FileNotFoundError:
            pass
```

- [ ] **Step 5: Run the suite**

Run: `bash tests/test_cmux.sh`
Expected: `Results: 6 passed, 0 failed` (3 sidecar assertions + the 3 from earlier).

- [ ] **Step 6: Commit**

```bash
git add cmux tests/test_cmux.sh
git commit -m "feat(cmux): write per-session sidecar JSON with pid + start cwd"
```

---

### Task 6: `cmux list` default unchanged + `-l` flag — failing test

**Files:**
- Modify: `tests/test_cmux.sh`

- [ ] **Step 1: Add `test_list_default_unchanged` and `test_list_long`**

Insert above the `test_help` invocation:

```bash
test_list_default_unchanged() {
  echo "test_list_default_unchanged"
  spawn_session shell-list bash -lc 'sleep 30' || return
  local out
  out="$("$CMUX" list 2>&1)"
  # Default form: a "NAME" header line followed by names, one per line.
  if [[ "$(echo "$out" | head -n1)" == "NAME" ]]; then
    ok "default list keeps NAME header"
  else
    bad "default list keeps NAME header" "got first line: $(echo "$out" | head -n1)"
  fi
  if echo "$out" | grep -qx "shell-list"; then
    ok "default list contains the session name on its own line"
  else
    bad "default list contains the session name on its own line" "got: $out"
  fi
  # Cleanup before next test.
  kill "${SESSION_PIDS[-1]}" 2>/dev/null || true
  sleep 0.3
}

test_list_long() {
  echo "test_list_long"
  spawn_session shell-long bash -lc 'sleep 30' || return
  local out
  out="$("$CMUX" list -l 2>&1)"
  if [[ "$(echo "$out" | head -n1)" =~ ^NAME[[:space:]]+START[[:space:]]+CWD$ ]]; then
    ok "list -l prints NAME / START / CWD header"
  else
    bad "list -l prints NAME / START / CWD header" "got: $(echo "$out" | head -n1)"
  fi
  if echo "$out" | grep -q "shell-long"; then
    ok "list -l contains the session row"
  else
    bad "list -l contains the session row" "got: $out"
  fi
  # --long alias works.
  out="$("$CMUX" list --long 2>&1)"
  if [[ "$(echo "$out" | head -n1)" =~ ^NAME[[:space:]]+START[[:space:]]+CWD$ ]]; then
    ok "list --long is accepted as an alias"
  else
    bad "list --long is accepted as an alias" "got: $(echo "$out" | head -n1)"
  fi
  # Unknown flag is rejected.
  if "$CMUX" list -x 2>/dev/null; then
    bad "list -x rejects unknown flag" "exit 0 unexpected"
  else
    ok "list -x rejects unknown flag"
  fi
  kill "${SESSION_PIDS[-1]}" 2>/dev/null || true
  sleep 0.3
}

```

And call them above `test_help`:

```bash
test_statusline_widget
test_sidecar_metadata
test_list_default_unchanged
test_list_long
test_help
```

- [ ] **Step 2: Run the suite to confirm new tests fail**

Run: `bash tests/test_cmux.sh`
Expected: `test_list_default_unchanged` passes (default form already correct after Task 5); `test_list_long` fails (`-l` not implemented).

---

### Task 7: `cmux list -l` flag — implement

**Files:**
- Modify: `cmux` (add `subprocess` import, `_live_cwd`, `_tilde`, `_iter_alive_sessions`, `_render_long_table`; refactor `cmd_list`; thread argv through `main`)

- [ ] **Step 1: Add the `subprocess` import**

In the imports block, insert `import subprocess` in alphabetical order (after `import socket`, before `import sys`):

```python
import socket
import subprocess
import sys
```

- [ ] **Step 2: Add the `_live_cwd` helper**

Add directly after `_read_metadata` (introduced in Task 5):

```python
def _live_cwd(pid: int) -> str | None:
    """Best-effort current cwd of pid. Returns None on any failure."""
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except (FileNotFoundError, PermissionError, OSError):
        pass
    try:
        out = subprocess.run(
            ["lsof", "-a", "-p", str(pid), "-d", "cwd", "-Fn"],
            capture_output=True, text=True, timeout=2,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if out.returncode != 0:
        return None
    for line in out.stdout.splitlines():
        if line.startswith("n"):
            return line[1:]
    return None
```

- [ ] **Step 3: Add the `_tilde` helper**

Right after `_live_cwd`:

```python
def _tilde(path: str) -> str:
    home = os.path.expanduser("~")
    if path == home:
        return "~"
    if path.startswith(home + os.sep):
        return "~" + path[len(home):]
    return path
```

- [ ] **Step 4: Add the shared `_iter_alive_sessions` sweep helper**

Right after `_tilde`:

```python
def _iter_alive_sessions() -> list[str]:
    """Sorted list of live session names; sweeps stale sockets and sidecars."""
    if not os.path.isdir(SOCK_DIR):
        return []
    alive: list[str] = []
    for entry in sorted(os.listdir(SOCK_DIR)):
        if not entry.endswith(".sock"):
            continue
        name = entry[:-5]
        sock = os.path.join(SOCK_DIR, entry)
        if _is_socket_alive(sock):
            alive.append(name)
        else:
            try:
                os.unlink(sock)
            except FileNotFoundError:
                pass
            try:
                os.unlink(_meta_path(name))
            except FileNotFoundError:
                pass
    return alive
```

- [ ] **Step 5: Add the `_render_long_table` helper**

Right after `_iter_alive_sessions`:

```python
def _render_long_table(out, indent: str = "") -> None:
    """Render the NAME / START / CWD table to `out`, prefixed by `indent`."""
    names = _iter_alive_sessions()
    if not names:
        print(f"{indent}(no active cmux sessions)", file=out)
        return
    rows: list[tuple[str, str, str]] = []
    for name in names:
        meta = _read_metadata(name)
        if meta is None:
            rows.append((name, "?", "?"))
            continue
        start_cwd = meta.get("cwd") or ""
        pid = meta.get("pid")
        live = _live_cwd(pid) if isinstance(pid, int) else None
        start_disp = _tilde(start_cwd) if start_cwd else "?"
        if live is None:
            cwd_disp = "?"
        elif start_cwd and live == start_cwd:
            cwd_disp = "(same)"
        else:
            cwd_disp = _tilde(live)
        rows.append((name, start_disp, cwd_disp))
    headers = ("NAME", "START", "CWD")
    cols = list(zip(*([headers] + rows)))
    widths = [max(len(c) for c in col) for col in cols]
    for row in [headers] + rows:
        line = "  ".join(s.ljust(w) for s, w in zip(row, widths)).rstrip()
        print(f"{indent}{line}", file=out)
```

- [ ] **Step 6: Refactor `cmd_list` to accept argv and `-l`**

Replace the entire existing `cmd_list` function body with:

```python
def cmd_list(argv: list[str] | None = None, to_stderr: bool = False) -> int:
    out = sys.stderr if to_stderr else sys.stdout
    long_form = False
    for a in argv or []:
        if a in ("-l", "--long"):
            long_form = True
        else:
            print(f"cmux: unknown argument '{a}'", file=sys.stderr)
            return 2
    if long_form:
        _render_long_table(out)
        return 0
    names = _iter_alive_sessions()
    if not names:
        print("(no active cmux sessions)", file=sys.stderr)
        return 0
    if to_stderr:
        print("available sessions:", file=sys.stderr)
        for name in names:
            print(f"  {name}", file=sys.stderr)
    else:
        print("NAME", file=out)
        for name in names:
            print(name, file=out)
    return 0
```

- [ ] **Step 7: Pass argv through `main()`**

In `main()`, change the existing list dispatch from:

```python
    if cmd in ("list", "ls"):
        return cmd_list()
```

to:

```python
    if cmd in ("list", "ls"):
        return cmd_list(argv[2:])
```

- [ ] **Step 8: Run the suite**

Run: `bash tests/test_cmux.sh`
Expected: `Results: 11 passed, 0 failed` (4 new list assertions + 7 from before).

- [ ] **Step 9: Commit**

```bash
git add cmux tests/test_cmux.sh
git commit -m "feat(cmux): add 'cmux list -l' with NAME/START/CWD columns"
```

---

### Task 8: `cmux send` not-found fallback uses long table — failing test

**Files:**
- Modify: `tests/test_cmux.sh`

- [ ] **Step 1: Add `test_send_fallback_long`**

Insert above `test_help`:

```bash
test_send_fallback_long() {
  echo "test_send_fallback_long"
  spawn_session shell-fallback bash -lc 'sleep 30' || return
  # Sending to a nonexistent name must fail and dump the long-form table on stderr.
  local err
  err="$("$CMUX" send no-such-session hi 2>&1 >/dev/null || true)"
  if echo "$err" | grep -q "available sessions:"; then
    ok "send fallback prints 'available sessions:'"
  else
    bad "send fallback prints 'available sessions:'" "got: $err"
  fi
  if echo "$err" | grep -qE "^[[:space:]]+NAME[[:space:]]+START[[:space:]]+CWD$"; then
    ok "send fallback shows long-form header"
  else
    bad "send fallback shows long-form header" "got: $err"
  fi
  if echo "$err" | grep -q "shell-fallback"; then
    ok "send fallback lists the live session"
  else
    bad "send fallback lists the live session" "got: $err"
  fi
  kill "${SESSION_PIDS[-1]}" 2>/dev/null || true
  sleep 0.3
}

```

And call it above `test_help`:

```bash
test_statusline_widget
test_sidecar_metadata
test_list_default_unchanged
test_list_long
test_send_fallback_long
test_help
```

- [ ] **Step 2: Run the suite to confirm it fails**

Run: `bash tests/test_cmux.sh`
Expected: the long-form header / row assertions fail (current fallback prints indented names only).

---

### Task 9: `cmux send` fallback — implement

**Files:**
- Modify: `cmux` (`cmd_send`)

- [ ] **Step 1: Replace the fallback branch in `cmd_send`**

In `cmd_send`, replace the existing not-found branch:

```python
    if not os.path.exists(path):
        print(f"cmux: session '{name}' not found", file=sys.stderr)
        cmd_list(to_stderr=True)
        return 1
```

with:

```python
    if not os.path.exists(path):
        print(f"cmux: session '{name}' not found", file=sys.stderr)
        print("available sessions:", file=sys.stderr)
        _render_long_table(sys.stderr, indent="  ")
        return 1
```

- [ ] **Step 2: Run the suite**

Run: `bash tests/test_cmux.sh`
Expected: `Results: 14 passed, 0 failed`.

- [ ] **Step 3: Commit**

```bash
git add cmux tests/test_cmux.sh
git commit -m "feat(cmux): use long-form table in 'cmux send' not-found fallback"
```

---

### Task 10: README — statusline integration recipes

**Files:**
- Modify: `README.md` (add section between "How it works" and "License")

- [ ] **Step 1: Insert the new section**

Find this block in `README.md`:

```markdown
Host terminal stays in raw mode. A session lives only as long as its
wrapper; closing the owning terminal kills the child.

## License
```

and insert this section between the paragraph and the `## License` heading:

```markdown
## Show the session name in your Claude Code statusline

`cmux` exports `CMUX_SESSION` inside every wrapped session and ships a tiny
`cmux statusline-widget` helper that prints `§ cmux:<name>` (or nothing when
not in a session). Wire it into Claude Code's `statusLine` setting two ways:

**1. Vanilla `statusLine.command`.** In `~/.claude/settings.json`, replace
your statusline with a tiny wrapper that appends the cmux marker:

```json
{
  "statusLine": {
    "command": "bash -lc 'echo \"$(your-existing-statusline)\" $(cmux statusline-widget)'"
  }
}
```

**2. As a `ccstatusline` custom widget.** Add a custom widget pointing at
`cmux statusline-widget`; ccstatusline will render its stdout inline with
the rest of your widgets.

The helper is intentionally dumb: no JSON, no colour, no stdin. Composition
belongs to whatever statusline tool you already use.

```

- [ ] **Step 2: Commit**

```bash
git add README.md
git commit -m "docs(readme): document statusline-widget integration"
```

---

## Self-Review

**Spec coverage check:**

| Spec section | Implementing task |
|--------------|-------------------|
| §1 Sidecar metadata (write timing, mode, atomicity, cleanup) | Task 5 (write + cleanup), Task 7 step 4 (stale sweep) |
| §2 `_live_cwd` helper | Task 7 step 2 |
| §3 `cmux list` default + `-l` table | Task 7 steps 5–7 |
| §4 `cmux send` fallback long form | Task 9 |
| §5 `cmux statusline-widget` | Task 3 |
| §6 README integration docs | Task 10 |
| Architecture summary `_render_long_table` shared by both surfaces | Task 7 step 5 + Task 9 step 1 (both call same helper) |
| Testing checklist (1–8 in spec) | tests added across tasks 1, 2, 4, 6, 8 |

All sections covered.

**Placeholder scan:** No "TBD", "later", "handle edge cases" or other vague directives in this plan. Every code step has the actual code; every command shows expected output.

**Type consistency:**
- Sidecar fields: `pid` (int), `cwd` (str), `started_at` (int) — used identically in `_write_metadata`, `_read_metadata`, `_render_long_table`, and the test's Python shape check.
- `_render_long_table(out, indent: str = "")` signature is identical in all four call sites (Task 7 step 5 definition; Task 7 step 6 inside `cmd_list`; Task 9 step 1 inside `cmd_send`; spec architecture summary).
- `_iter_alive_sessions()` returns `list[str]` — consumed identically by `cmd_list` default branch and `_render_long_table`.
- `cmd_list(argv, to_stderr=False)` — argv is the first positional arg in both the definition (Task 7 step 6) and the call in `main()` (Task 7 step 7) and the call in `cmd_send` is removed entirely (Task 9 step 1 doesn't call `cmd_list` anymore).

No drift detected.
