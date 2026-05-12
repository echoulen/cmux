# cmux reply-expected signal — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a sender-declared `-r` / `--reply` flag to `cmux send` that embeds an explicit reply command inside the receiver's prefix, so a peer Claude session no longer has to infer whether an answer is expected.

**Architecture:** Single-file CLI change in `cmux` (Python stdlib only). Sender flag toggles a longer prefix that carries the literal reply command (`cmux send <sender> "<your answer>"`). Receiver behavior is governed by an additional SKILL.md contract that triggers on the `reply via:` segment in the prefix. No new dependencies, no socket protocol changes, no return channel.

**Tech Stack:** Python 3.9+ stdlib (`cmux` CLI), Markdown (SKILL.md, README, JSON manifests).

**Spec:** `docs/superpowers/specs/2026-05-12-cmux-reply-expected-design.md`

**No test suite in this repo.** Verification is manual (smoke tests in Task 7). Every code task ends with a syntax-check invocation before commit.

---

## File Structure

| Path | Action | Responsibility |
|------|--------|----------------|
| `cmux` | modify | Parse `-r`/`--reply`, emit reply-expected prefix, edge-case errors, updated HELP & docstring |
| `plugins/cmux/skills/cmux/SKILL.md` | modify | Frontmatter trigger, new "reply instruction" contract section, sender-side guidance, example |
| `README.md` | modify | Usage block + "Two sessions talking" example showing `-r` |
| `plugins/cmux/.claude-plugin/plugin.json` | modify | Version `0.1.1` → `0.1.2` |
| `.claude-plugin/marketplace.json` | modify | Version `0.1.1` → `0.1.2` (top-level + plugin entry) |

---

### Task 1: CLI parsing + edge-case errors + reply-expected prefix

**Files:**
- Modify: `cmux:262-285` (`cmd_send` body)
- Modify: `cmux:360-364` (`main` send dispatcher)

- [ ] **Step 1: Update `cmd_send` signature and body to accept `expect_reply`**

Replace lines 262-285 (the whole `cmd_send` function) with:

```python
def cmd_send(name: str, message: str, expect_reply: bool = False) -> int:
    path = sock_path(name)
    if not os.path.exists(path):
        print(f"cmux: session '{name}' not found", file=sys.stderr)
        cmd_list(to_stderr=True)
        return 1
    sender = os.environ.get("CMUX_SESSION")
    if expect_reply:
        if not sender:
            print(
                "cmux: -r requires running inside a wrapped session "
                "(CMUX_SESSION unset)",
                file=sys.stderr,
            )
            return 1
        if sender == name:
            print(
                "cmux: cannot use -r when sending to yourself",
                file=sys.stderr,
            )
            return 1
        if not message:
            print(
                "cmux: -r requires a non-empty message",
                file=sys.stderr,
            )
            return 1
    if sender and sender != name and message:
        if expect_reply:
            reply_cmd = f'cmux send {sender} "<your answer>"'
            message = (
                f"[Message from {sender} via cmux, reply via: {reply_cmd}] "
                f"{message}"
            )
        else:
            message = f"[Message from {sender} via cmux] {message}"
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.connect(path)
    except (ConnectionRefusedError, FileNotFoundError) as e:
        print(f"cmux: cannot connect to '{name}': {e}", file=sys.stderr)
        return 1
    # Send the message and the trailing CR in two separate writes. Ink-based
    # TUIs (Claude Code) treat a single chunk containing both as a paste, in
    # which case the embedded \r becomes a literal newline instead of submit.
    if message:
        s.sendall(message.encode("utf-8"))
        time.sleep(0.05)
    s.sendall(b"\r")
    s.close()
    return 0
```

Rationale notes (do NOT include as comments in the file):
- Edge-case checks happen **before** the existing `if sender and sender != name and message:` guard so they fire even when the prefix wouldn't otherwise be added.
- `<your answer>` is a literal placeholder shown to the receiver agent — the receiver SKILL tells it to substitute.

- [ ] **Step 2: Update `main`'s `send` dispatcher to parse `-r` / `--reply`**

Find the `if cmd == "send":` block inside `main()` (originally lines 360-364, but those will have shifted after Step 1). Replace the entire block (from `if cmd == "send":` through the `return cmd_send(...)` line) with:

```python
    if cmd == "send":
        args = argv[2:]
        expect_reply = False
        positional: list[str] = []
        for a in args:
            if a in ("-r", "--reply"):
                expect_reply = True
            else:
                positional.append(a)
        if len(positional) < 2:
            print(
                "usage: cmux send [-r|--reply] <name> <message>",
                file=sys.stderr,
            )
            return 2
        return cmd_send(
            positional[0],
            " ".join(positional[1:]),
            expect_reply=expect_reply,
        )
```

This accepts `-r` / `--reply` anywhere in the send args (before `<name>`, between, or after). Unknown long flags fall through into `positional` and would be treated as part of `<name>` / `<message>` — acceptable for this minimal CLI, since adding unknown-flag detection here is not in scope.

- [ ] **Step 3: Syntax-check the file**

Run: `python3 -m py_compile /Users/carlosli/work/cmux/cmux`
Expected: no output, exit 0.

- [ ] **Step 4: Smoke-check argument parsing (no socket needed)**

These calls should fail with the new error messages, exit code 1, before any socket I/O. They prove the new code paths are reachable.

Run: `unset CMUX_SESSION; /Users/carlosli/work/cmux/cmux send -r claude-2 "ping"`
Expected stderr: `cmux: -r requires running inside a wrapped session (CMUX_SESSION unset)`
Expected exit: 1

Run: `CMUX_SESSION=claude-1 /Users/carlosli/work/cmux/cmux send -r claude-1 "ping"`
Expected stderr: `cmux: cannot use -r when sending to yourself`
Expected exit: 1

Run: `CMUX_SESSION=claude-1 /Users/carlosli/work/cmux/cmux send -r claude-2 ""`
Expected stderr: `cmux: -r requires a non-empty message`
Expected exit: 1

Note: the empty-message case requires the socket file to NOT exist for `claude-2` — if a real session is running it will short-circuit at the earlier `session not found` check (which is fine; the edge-case error simply isn't reached). To force the path, choose a name with no live session. If that's awkward, accept the short-circuit and rely on Task 7 for full verification.

Run: `CMUX_SESSION=claude-1 /Users/carlosli/work/cmux/cmux send claude-nonexistent-xyz "msg"`
Expected stderr begins with: `cmux: session 'claude-nonexistent-xyz' not found`
Expected exit: 1 (proves the path without `-r` still works.)

- [ ] **Step 5: Commit**

```bash
cd /Users/carlosli/work/cmux
git add cmux
git commit -m "$(cat <<'EOF'
feat(cmux send): add -r/--reply flag for reply-expected messages

When set, the receiver's prefix carries a `reply via: cmux send <sender>
"<your answer>"` segment so a peer Claude session knows it must echo an
answer back. Without -r, behavior is unchanged.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Update CLI docstring and HELP text

**Files:**
- Modify: `cmux:14-17` (module docstring)
- Modify: `cmux:320-340` (HELP string)

- [ ] **Step 1: Update module docstring**

Replace lines 14-17 (currently `Each wrapped child gets ... poke came from.`) with:

```
Each wrapped child gets CMUX_SESSION=<name> in its env. When `cmux send` is
invoked from inside a wrapped session, it auto-prefixes the message with
"[Message from <CMUX_SESSION> via cmux] " so the receiver knows where the
poke came from. Adding `-r`/`--reply` further declares that the receiver is
expected to echo an answer back via `cmux send <CMUX_SESSION>`.
```

- [ ] **Step 2: Update HELP usage and trailing prose**

Replace the `Usage:` line for `send` (currently `cmux send <name> <message>          Send <message>+Enter to <name>`) with two lines:

```
  cmux send [-r] <name> <message>     Send <message>+Enter to <name>
                                      -r/--reply: request the receiver echo an answer back
```

Replace the trailing paragraph beginning `Inside a wrapped session, $CMUX_SESSION holds ...` (lines 336-337) with:

```
Inside a wrapped session, $CMUX_SESSION holds the current session name and
`cmux send` auto-prefixes messages with "[Message from $CMUX_SESSION via cmux] ".
Pass `-r`/`--reply` to additionally tell the receiver that an answer is
expected back via `cmux send $CMUX_SESSION`.
```

- [ ] **Step 3: Verify help output renders cleanly**

Run: `/Users/carlosli/work/cmux/cmux help`
Expected: output includes the new `[-r]` usage line and the new `-r/--reply` description; no Python errors.

- [ ] **Step 4: Commit**

```bash
cd /Users/carlosli/work/cmux
git add cmux
git commit -m "$(cat <<'EOF'
docs(cmux): describe -r/--reply in module docstring and HELP

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: SKILL.md — contract, frontmatter trigger, examples

**Files:**
- Modify: `plugins/cmux/skills/cmux/SKILL.md:3` (frontmatter description)
- Modify: `plugins/cmux/skills/cmux/SKILL.md:36-52` (When to use + Commands)
- Modify: `plugins/cmux/skills/cmux/SKILL.md:54-74` (Workflow + Examples)

- [ ] **Step 1: Extend frontmatter `description` to trigger on reply prefix**

Replace line 3 (the entire `description:` line) with:

```
description: Coordinate with peer Claude sessions via the `cmux` CLI. Invoke when (a) an input line begins with `[Message from <name> via cmux]` — that marker means a peer Claude session relayed the message to you, and you must name the source in your reply rather than treat it as a normal user prompt; (b) the same line also contains `reply via: cmux send …`, which means the sender REQUIRES you to echo an answer back via that exact command; or (c) `$CMUX_SESSION` is set and the user asks you to talk to "another session / another terminal / claude-N". Lets you list peers and inject messages into them. NOTE: this plugin only ships the skill — the `cmux` CLI binary must be installed separately (see Prerequisite below).
```

- [ ] **Step 2: Update the "When to use" bullet about incoming messages**

Replace lines 36-39 (the bullet starting `An input line begins with ...`) with:

```
- An input line begins with `[Message from <name> via cmux] <body>` — peer
  session `<name>` injected it. Name the source in your reply, then answer
  the body as a peer request. Do NOT auto-reply via `cmux send` unless either
  (a) the prefix contains `reply via: <command>` (see "Reply-expected
  messages" below), or (b) the user explicitly asks you to.
```

- [ ] **Step 3: Update the "Commands" block to list `-r`**

Replace lines 45-52 (the `## Commands` block plus the paragraph following it) with:

```
## Commands

​`​`​`bash
cmux list                          # list active peer session names
cmux send <name> <message>         # inject "<message>\r" into <name>'s pty
cmux send -r <name> <message>      # same, but declare that a reply is expected
​`​`​`

`cmux send` invoked from inside a wrapped session auto-prefixes the message
with `[Message from $CMUX_SESSION via cmux] ` — the receiver sees the source.
You don't need to add the prefix yourself.

Pass `-r` (or `--reply`) when you are asking the peer for information you
need to continue your own work. The receiver is contractually obligated to
echo an answer back via `cmux send $CMUX_SESSION`. For fire-and-forget
notifications ("starting refactor", "tests passing"), omit the flag.
```

(In your actual edit, use real backticks instead of the zero-width-joiner-decorated `​`​`​`` shown above. They're only escaped here to keep the plan readable.)

- [ ] **Step 4: Add the "Reply-expected messages" contract section**

Insert a new section between `## Commands` and `## Workflow`. Content:

```
## Reply-expected messages

If an incoming line begins with
`[Message from <name> via cmux, reply via: <command>] <body>`,
treat it as a request that REQUIRES a reply:

1. Produce your answer to `<body>` as you normally would. Your visible
   response to the user is unchanged — they can still see it locally.
2. After answering, you MUST run `<command>`, replacing `<your answer>`
   inside the command with a concise string that conveys your answer to the
   sender. The sender is waiting on that exact channel.
3. If you cannot answer (refusal, missing info, blocked), still run the
   command — send a short string explaining why no answer is forthcoming,
   so the sender isn't left waiting.

If the prefix has NO `reply via:` segment, do not run `cmux send` back to
the sender unless the user explicitly asks you to.
```

- [ ] **Step 5: Update the Workflow bullet about replies**

Replace the existing step 4 (line 60-61, `If you expect a reply, tell the user to watch the other terminal — there is no return channel back to you besides the user.`) with:

```
4. If you expect a reply, send with `cmux send -r <target> "<question>"`.
   The peer's agent is then obligated to relay an answer back via
   `cmux send $CMUX_SESSION "<answer>"` — which lands in your input prompt
   as another `[Message from <peer> via cmux] ...` line. There is no
   programmatic correlation between request and reply; the user (and you)
   simply watch for the next inbound message.
```

- [ ] **Step 6: Add a reply-expected example**

In the `## Examples` block, append after the existing three examples:

```
# Ask peer for info you need to continue, expecting an answer back:
cmux send -r claude-2 "what's the current pwd in your session?"
```

- [ ] **Step 7: Syntax check (skill linter not available; eyeball pass)**

Re-read the file end-to-end and confirm:
- Frontmatter still parses (single `---` block, `name:` and `description:` present).
- All triple-backtick code fences are closed.
- No duplicate section headings.

- [ ] **Step 8: Commit**

```bash
cd /Users/carlosli/work/cmux
git add plugins/cmux/skills/cmux/SKILL.md
git commit -m "$(cat <<'EOF'
feat(skill): contract for reply-expected messages

Receiver agent now has an explicit rule: when the cmux prefix contains
`reply via: <command>`, it MUST execute that command with its answer
after responding. Sender guidance and an example are added too.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: README — usage and example for `-r`

**Files:**
- Modify: `README.md:31-46` (Usage section)
- Modify: `README.md:60-87` (Two sessions talking)

- [ ] **Step 1: Add `-r` to the Usage code block**

Replace lines 31-35 (the `bash` block listing the three commands) with:

```
​`​`​`bash
cmux run [<name>] [-- cmd args...]   # wrap cmd in pty (default $SHELL)
cmux send <name> <message>           # inject <message>+Enter into <name>
cmux send -r <name> <message>        # same, but declare a reply is expected
cmux list                            # list active sessions
​`​`​`
```

(Use real backticks in the actual edit.)

- [ ] **Step 2: Mention `-r` in the prose right after that code block**

Replace lines 37-40 (the paragraph beginning `Default name is ...`) with:

```
Default name is `<basename(cmd)>-N` (`claude-1`, `claude-2`, ...). Each
wrapped child gets `CMUX_SESSION=<name>` in its env; `cmux send` from inside
a wrapped session auto-prefixes the message with `[Message from <name> via cmux] `
so the receiver knows the source. Add `-r` / `--reply` to additionally embed
a `reply via: cmux send <name> "<your answer>"` instruction in the prefix —
the receiver's skill treats that as a contract to echo an answer back.
```

- [ ] **Step 3: Extend "Two sessions talking" with a reply-expected round trip**

After the existing `claude-2 acknowledges ...` paragraph and its example (ending at line 85 with the second `[Message from ...]` code block), insert:

```
### Asking with `-r`

When claude-1 actually needs an answer back (not just a notification), it
should use `-r`:

​`​`​`bash
cmux send -r claude-2 "what's the absolute path of your working dir?"
​`​`​`

claude-2's input prompt receives:

​`​`​`
[Message from claude-1 via cmux, reply via: cmux send claude-1 "<your answer>"] what's the absolute path of your working dir?
​`​`​`

The cmux skill in claude-2's session treats `reply via:` as a contract.
After answering its user, claude-2 runs:

​`​`​`bash
cmux send claude-1 "/Users/alice/work/project"
​`​`​`

…which lands in claude-1's prompt as a normal `[Message from claude-2 via cmux] /Users/alice/work/project` line.
```

(Use real backticks in the actual edit.)

- [ ] **Step 4: Commit**

```bash
cd /Users/carlosli/work/cmux
git add README.md
git commit -m "$(cat <<'EOF'
docs(README): describe cmux send -r and example round-trip

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Version bump to 0.1.2

**Files:**
- Modify: `plugins/cmux/.claude-plugin/plugin.json:3`
- Modify: `.claude-plugin/marketplace.json:8` and `:17`

- [ ] **Step 1: Bump `plugins/cmux/.claude-plugin/plugin.json`**

Change `"version": "0.1.1"` → `"version": "0.1.2"`.

- [ ] **Step 2: Bump `.claude-plugin/marketplace.json`**

Change both occurrences of `"version": "0.1.1"` → `"version": "0.1.2"` (top-level marketplace version and the entry under `plugins[]`).

- [ ] **Step 3: Verify both files parse as JSON**

Run:
```
python3 -c 'import json,sys; json.load(open("/Users/carlosli/work/cmux/plugins/cmux/.claude-plugin/plugin.json")); json.load(open("/Users/carlosli/work/cmux/.claude-plugin/marketplace.json")); print("ok")'
```
Expected: `ok`

Run:
```
grep -H '"version"' /Users/carlosli/work/cmux/plugins/cmux/.claude-plugin/plugin.json /Users/carlosli/work/cmux/.claude-plugin/marketplace.json
```
Expected: every line shows `"version": "0.1.2"`.

- [ ] **Step 4: Commit**

```bash
cd /Users/carlosli/work/cmux
git add plugins/cmux/.claude-plugin/plugin.json .claude-plugin/marketplace.json
git commit -m "$(cat <<'EOF'
chore: bump cmux plugin to 0.1.2

Carries the reply-expected feature.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Manual smoke verification (no commit)

This task does not modify code. It exercises the end-to-end flow against two real wrapped sessions to confirm everything wires up as designed. The agent executing this plan should perform it before declaring the work complete.

- [ ] **Step 1: Reinstall the local CLI**

Run: `bash /Users/carlosli/work/cmux/install.sh`
Expected: `installed: ~/.local/bin/cmux -> ~/.local/share/cmux/cmux`. (Or, equivalently, point the existing symlink at the working tree.)

- [ ] **Step 2: Open two wrapped sessions in two terminals**

Manual: terminal A → `cmux run -- claude` (auto-named `claude-1`).
Manual: terminal B → `cmux run -- claude` (auto-named `claude-2`).

- [ ] **Step 3: Fire a fire-and-forget message, confirm unchanged behavior**

In terminal A, send via the Claude agent or shell-out: `cmux send claude-2 "fyi: smoke test"`
Expected: terminal B's input box shows `[Message from claude-1 via cmux] fyi: smoke test` (no `reply via:` segment).

- [ ] **Step 4: Fire a reply-expected message, confirm new prefix**

In terminal A: `cmux send -r claude-2 "what is your pwd?"`
Expected: terminal B's input box shows
```
[Message from claude-1 via cmux, reply via: cmux send claude-1 "<your answer>"] what is your pwd?
```

- [ ] **Step 5: Confirm receiver replies automatically**

Wait for claude-2's agent (with the updated SKILL) to answer. It should:
- Answer the question to its local user.
- Run `cmux send claude-1 "<actual pwd>"`.
- Terminal A's input box should receive `[Message from claude-2 via cmux] <actual pwd>`.

If claude-2 answers but does NOT run `cmux send` back, the SKILL contract is not landing. Re-check Task 3 step 4 in the running Claude's plugin cache.

- [ ] **Step 6: Confirm edge-case errors fire correctly under real sessions**

Inside terminal A (CMUX_SESSION=claude-1 is set):
- `cmux send -r claude-1 "x"` → stderr: `cmux: cannot use -r when sending to yourself`, exit 1.
- `cmux send -r claude-2 ""` → stderr: `cmux: -r requires a non-empty message`, exit 1.

In a bare shell (no `cmux run` wrapper, so CMUX_SESSION is unset):
- `cmux send -r claude-2 "x"` → stderr: `cmux: -r requires running inside a wrapped session (CMUX_SESSION unset)`, exit 1.

- [ ] **Step 7: Push**

If smoke tests pass:
```bash
cd /Users/carlosli/work/cmux
gh auth switch -u echoulen
git push
gh auth switch -u NextDriveBot
```

(Repo write access lives on the `echoulen` GitHub account, not `NextDriveBot`.)

---

## Spec coverage

| Spec section | Implementing task |
|--------------|-------------------|
| CLI surface (`-r`/`--reply`) | Task 1 step 2 |
| Edge cases: `$CMUX_SESSION` unset / self / empty body | Task 1 step 1 |
| Prefix format (reply-expected) | Task 1 step 1 |
| SKILL contract section | Task 3 step 4 |
| Sender-side rule in SKILL | Task 3 step 3 |
| SKILL example for `-r` | Task 3 step 6 |
| SKILL frontmatter trigger on `reply via:` | Task 3 step 1 |
| HELP and module docstring | Task 2 |
| README usage + example | Task 4 |
| Version bump `0.1.1` → `0.1.2` | Task 5 |
| Manual verification | Task 6 |
