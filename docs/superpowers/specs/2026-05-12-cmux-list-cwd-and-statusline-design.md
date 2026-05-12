# cmux: surface session cwd in `list`, expose session name as a statusline widget

Date: 2026-05-12
Status: Draft (awaiting user approval)

## Goal

Make a running cmux session's "where it lives" visible in two places:

1. **`cmux list -l`** — a long-form table showing each session's start cwd and live cwd, so the user can tell at a glance which repo / project a session belongs to and where its wrapped process currently is.
2. **`cmux statusline-widget`** — a tiny stdout helper that prints `§ cmux:<name>` (or empty) so the user can wire the current session name into their Claude Code statusline.

Default `cmux list` output and the existing socket / wire protocol stay unchanged. No new dependencies. Single-file Python, macOS + Linux.

## Non-goals

- Replacing or competing with `ccstatusline` and other full statusline tools. cmux only ships the per-session widget; composing it into a final statusline is the user's job.
- Tracking the cwd of grandchildren. The "live cwd" is the cwd of the directly wrapped process (the shell or `claude`), not the cwd of whatever the shell is currently running.
- Decorating the auto-name banner. The banner is a session-startup signal, not a query surface.

## Design

### 1. Per-session metadata sidecar

Each session writes a sidecar JSON file alongside its socket:

```
~/.cmux/<name>.sock    (existing)
~/.cmux/<name>.json    (new)
```

The JSON file holds:

```json
{ "pid": 12345, "cwd": "/Users/carlos/work/cmux", "started_at": 1715500000 }
```

- `pid` — the wrapped child's pid (the value already in `pid` after `pty.fork()`).
- `cwd` — `os.getcwd()` captured by the parent before `pty.fork()` (this is the cwd at the moment the user ran `cmux run`, i.e. the start cwd).
- `started_at` — `int(time.time())`. Future-proofing; not displayed in v1.

**Write timing.** `cmd_run()` writes the sidecar immediately after a successful `srv.bind(path)` and `os.chmod(path, 0o600)`. Writing after bind keeps the invariant "if `<name>.json` exists, `<name>.sock` was bound at least once" and avoids a partially-initialised window.

**File mode.** `0o600`, same as the socket.

**Atomicity.** Write to `~/.cmux/<name>.json.tmp` then `os.replace()` to the final name. Single-file write, no concurrent writers expected, but `os.replace` keeps readers from ever seeing a half-written file.

**Cleanup.** `cleanup()` in `cmd_run` adds a best-effort `os.unlink(metadata_path)` next to the existing socket unlink. `cmd_list`'s stale-socket sweep also unlinks the matching `<name>.json` when it removes a dead socket. A `<name>.json` without a matching live socket is treated as stale on the next `list`.

### 2. Live cwd helper: `_live_cwd(pid)`

```
def _live_cwd(pid: int) -> str | None:
    # Linux fast path
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except (FileNotFoundError, PermissionError, OSError):
        pass
    # macOS fallback via lsof
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

Notes:

- `subprocess` and `time` are already permitted (the file already imports `time`); `subprocess` is a stdlib import — no new dependency.
- Two-second timeout caps the worst case if `lsof` hangs (it shouldn't, but `cmux list` should never block forever).
- Returning `None` is the explicit "unknown" state; the caller renders `?`.

### 3. `cmux list` flag and output

**Default (unchanged):**

```
NAME
claude-1
shell-1
```

Header `NAME` plus one name per line — exactly what consumers parse today.

**Long form (`-l` / `--long`):**

```
NAME       START               CWD
claude-1   ~/work/cmux         (same)
shell-1    ~/proj              ~/proj/src
shell-2    ?                   ?
```

Rules:

- `$HOME` prefix is replaced with `~` for both columns. No other path massaging.
- If `live_cwd == start_cwd`, the CWD column shows `(same)` instead of repeating the path.
- `?` is shown when the value is unknown — e.g. session was started by an older cmux without the sidecar, the sidecar was deleted, or `_live_cwd` returned `None`.
- Column widths are computed from the rendered values (after `~` substitution and `(same)`/`?` substitution), with two spaces between columns. Header counts toward width.
- No-session and stderr fallback messages are unchanged in wording.
- Sort order is unchanged (alphabetical by name, the existing behaviour from `sorted(os.listdir(SOCK_DIR))`).

**Argument parsing.** `cmux list -l` and `cmux list --long` both accepted. Anything else after `list` is an error: `cmux: unknown argument '<x>'` to stderr, returns 2. Implementation can stay flag-by-hand; no need to pull in `argparse` for one flag.

### 4. `cmux send` fallback: always long form

When `cmd_send` cannot find a session, it currently prints `available sessions:` followed by indented names on stderr. That branch becomes the long-form table on stderr (still indented two spaces, header included), regardless of whether the user passed any flag — `send` has no flags. Rationale: this is a diagnostic context where the cwd is exactly the disambiguator the user needs ("did I send to the wrong claude-1?").

The table is produced by a single internal helper (`_render_long_table` in the architecture summary). `cmux list -l` and the `cmd_send` fallback both call it — so the format never drifts between the two surfaces. The helper takes the destination stream and an optional indent prefix as parameters; everything else (column widths, `~` substitution, `(same)` / `?` rendering) lives inside it.

### 5. `cmux statusline-widget`

New subcommand. Behaviour:

```
$ CMUX_SESSION=claude-2 cmux statusline-widget
§ cmux:claude-2
$ cmux statusline-widget          # not in a session
                                  # (empty stdout, exit 0)
```

- Reads `os.environ.get("CMUX_SESSION")`. If unset or empty, prints nothing and exits 0.
- If set, prints `§ cmux:<name>` followed by a single newline, then exits 0.
- The `§` glyph is fixed (matches the visual weight of common statusline separators in `ccstatusline` and friends; gives users a clear "this is the cmux marker" without needing colour).
- No stdin reading. No JSON. The widget is intentionally dumb so it can be glued into any statusline pipeline.
- No colour. Statusline composers handle colour. If we ever want colour, it's a follow-up flag (`--color=auto`), not v1.
- Exit code 0 in all normal cases. Non-zero only if the binary itself is broken (e.g. import failure), which the shell composer can't meaningfully recover from anyway.

The subcommand is registered alongside `run` / `send` / `list` in `main()` and added to `HELP`.

### 6. README integration docs

Add a short section to `README.md` titled "Show the session name in your Claude Code statusline" that gives two recipes:

1. **Vanilla `statusLine.command`** — append `cmux statusline-widget` output to whatever the user already has, e.g. a one-liner shell wrapper that calls their previous statusline command and concatenates `cmux statusline-widget`.
2. **As a `ccstatusline` custom widget** — a one-line custom-widget config pointing at `cmux statusline-widget`.

Both recipes are short shell snippets, not new code. We don't ship a settings.json — the user owns their own settings.

## Architecture summary

Three units, each with one job:

| Unit | What it does | How you use it | What it depends on |
|------|--------------|----------------|---------------------|
| `_write_metadata(name, pid, cwd)` | Persist sidecar JSON for a running session | Called once from `cmd_run` after socket bind | `os`, `json`, `time` |
| `_live_cwd(pid)` | Best-effort current cwd of pid | Called per session by the long-form table renderer | `os.readlink` / `lsof` |
| `_render_long_table(stream)` | Render the NAME / START / CWD table | Called by `cmux list -l` (stdout) and `cmd_send`'s missing-session fallback (stderr, two-space indent) | `_live_cwd`, sidecar JSON |
| `cmd_statusline_widget()` | Print `§ cmux:<name>` or nothing | Wired by user into Claude Code statusLine | `os.environ` |

`cmd_list` and the `cmd_send` fallback are the only consumers of the metadata + `_live_cwd`. The widget never reads metadata — it only reads the env var.

## Error handling

- `_write_metadata` swallows `OSError` and logs nothing. Failing to write metadata never aborts a session — losing the sidecar only degrades `list -l` (shows `?`), it doesn't break the session.
- `_live_cwd` returns `None` on any failure path. Caller renders `?`. Never raises.
- Missing / malformed sidecar JSON in `cmd_list -l`: caught, treated as "no metadata", both columns show `?`. Stale JSON is unlinked.
- `lsof` not installed (uncommon on macOS, possible on minimal Linux containers without `/proc`): `_live_cwd` returns `None`, CWD column shows `?`. No noisy error.

## Testing

cmux currently has no test harness. We add a small `tests/test_cmux.sh` (bash) that:

1. Starts a session in the background with `cmux run shell-test -- bash -lc 'sleep 30'`.
2. Asserts `~/.cmux/shell-test.json` exists and has `pid`, `cwd`, `started_at`.
3. Runs `cmux list` and greps for `shell-test` (default form unchanged).
4. Runs `cmux list -l` and greps for `START` and `CWD` headers + `shell-test` row.
5. Runs `cmux send nonexistent foo` and greps stderr for the long-form table.
6. Runs `CMUX_SESSION=claude-x cmux statusline-widget` and asserts output is `§ cmux:claude-x`.
7. Runs `cmux statusline-widget` (no env) and asserts empty stdout.
8. Kills the background session and asserts `~/.cmux/shell-test.json` is gone.

Bash, not pytest, to match the existing single-file no-deps stance. Test script is not run by anything (no CI in repo), but is checked-in for manual verification and for any future CI pickup.

## Out of scope (explicit)

- Colour output in widget.
- JSON output mode for `cmux list`.
- Recording the `child_cmd` in metadata. Easy to add later; not requested.
- Deleting metadata of sessions that crashed without running `cleanup` — handled lazily by the existing stale-socket sweep, which now also sweeps stale JSON.
- Showing the current session in its own banner. The banner already shows the name.

## Open questions

None remaining; all clarifications resolved during brainstorming.
