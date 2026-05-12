# cmux: explicit "reply expected" signal

## Problem

`cmux send` delivers a message to a peer Claude session. The receiver currently
cannot tell, from the message alone, whether the sender expects an answer
relayed back. Observed failure mode: receiver answers the question to its local
user only and never calls `cmux send` back to the sender, leaving the sender
waiting. The current workaround — embedding "please reply via `cmux send …`"
inside the body — is unreliable and depends on the sender remembering to write
it every time.

## Goal

A first-class, sender-declared signal that the receiver must echo a reply.
Receiver behavior is unambiguous and visible inside the message itself; no
inference from body content required.

## Non-goals

- Synchronous / blocking ask. `cmux send -r` stays asynchronous; the sender
  continues immediately and the reply arrives whenever the receiver runs.
- Return channel inside `cmux` itself (no socket-level reply). Replies travel
  via the receiver doing its own `cmux send <original-sender> "<answer>"`.
- Timeout or retry on the sender side.
- Multi-hop conversation tracking. Each `-r` request is independent; the
  receiver who wants to ask back adds `-r` themselves.
- Auto-ack from the receiver when it cannot answer.

## CLI surface

Add `-r` / `--reply` to `cmux send`:

```
cmux send <name> <message>          # fire-and-forget (unchanged)
cmux send -r <name> <message>       # request a reply
cmux send --reply <name> <message>  # long form
```

Flag may appear before or after `<name>`; documented standard form is
`cmux send -r <name> "<message>"`. Implementation uses hand-rolled parsing,
matching the existing file style (no `argparse` dependency).

`-r` is meaningful only when the sender is itself running inside a wrapped
session — i.e. `$CMUX_SESSION` is set and target ≠ sender. When `-r` is set
without a viable sender identity, the call fails loudly:

| Condition                                | Behavior                                                                 |
|------------------------------------------|--------------------------------------------------------------------------|
| `-r` and `$CMUX_SESSION` unset           | print `cmux: -r requires running inside a wrapped session` to stderr; exit 1 |
| `-r` and target == sender                | print `cmux: cannot use -r when sending to yourself` to stderr; exit 1   |
| `-r` and empty message                   | print `cmux: -r requires a non-empty message` to stderr; exit 1          |
| no `-r`                                  | unchanged behavior; empty message still allowed (sends CR only)          |

## Prefix format

Receiver-visible prefix on the wire:

```
fire-and-forget:  [Message from claude-1 via cmux] body
reply-expected:   [Message from claude-1 via cmux, reply via: cmux send claude-1 "<your answer>"] body
```

- Primary marker `[Message from <name> via cmux]` is unchanged, so any pattern
  matchers downstream still trigger.
- The reply hint is appended inside the same bracket, before the closing `]`,
  so it is part of the prefix rather than body. Body content is not modified.
- `<your answer>` is a literal placeholder shown to the receiver agent. The
  SKILL contract (below) tells the agent to substitute its own answer string.
- Reply target is always the sender's own `$CMUX_SESSION` value.

## SKILL.md contract

Add an explicit rule section to `plugins/cmux/skills/cmux/SKILL.md`:

```
## When the prefix carries a reply instruction

If an incoming line begins with
`[Message from <name> via cmux, reply via: <command>] <body>`,
treat it as a request that REQUIRES a reply:

1. Produce your answer to <body> as you normally would (your visible response
   to the user is unchanged — they can still see it locally).
2. After answering, you MUST run <command> with `<your answer>` replaced by a
   concise string that conveys your answer to the sender.
3. If you cannot answer (refusal, missing info, blocked), still run the
   command — send a short string explaining why no answer is forthcoming, so
   the sender isn't left waiting.

If the prefix has no `reply via:` segment, do NOT run `cmux send` back to the
sender unless the user explicitly asks you to.
```

Also:

- Frontmatter `description` adds `reply via:` as a trigger phrase so the skill
  auto-activates on reply-expected messages.
- Examples section gains a `cmux send -r <name> "..."` example with one line
  explaining when to use it.

## Sender-side rule (also in SKILL.md)

Brief addition to the existing send guidance:

> When you are asking the peer for information you need to continue your own
> work, use `cmux send -r`. The receiver is contractually obligated to relay
> an answer back. For fire-and-forget notifications ("starting refactor",
> "tests passing"), keep using `cmux send` without the flag.

## Implementation notes

- Edit `cmd_send` in `cmux` to accept `expect_reply: bool` and adjust prefix
  accordingly. Argument parsing in `main()` recognizes `-r` / `--reply`
  anywhere within `cmux send`'s positional args.
- `cmux` docstring header gains one sentence summarizing `-r`.
- `HELP` string gains `cmux send [-r] <name> <message>` and a brief line for
  `-r`.
- `README.md` Usage block and "Two sessions talking" example get a `-r`
  variant illustration.
- Version bump: `0.1.1` → `0.1.2` in both `plugin.json` and
  `.claude-plugin/marketplace.json` (top-level + plugin entry).

## Testing

This repo has no test suite. Verification is manual:

1. Inside a wrapped `claude-1`, run `cmux send -r claude-2 "pwd?"`. Confirm
   `claude-2`'s input box receives the new prefix with `reply via:` segment.
2. Confirm `claude-2`'s agent, with the updated SKILL, runs
   `cmux send claude-1 "<answer>"` after answering.
3. Edge cases:
   - `cmux send -r claude-2 ""` outside a wrapped session → exit 1 with
     `CMUX_SESSION unset` error.
   - `cmux send -r claude-1 "x"` from inside `claude-1` → exit 1 with
     self-reply error.
   - `cmux send -r claude-2 ""` from inside `claude-1` → exit 1 with
     empty-message error.
   - `cmux send claude-2 "fyi"` still produces the unmodified `[Message from
     claude-1 via cmux] fyi` prefix.

## Out of scope (deferred)

- Tracking which `-r` requests have or have not been replied to.
- Programmatic correlation between an outgoing `-r` and the corresponding
  inbound reply.
- Receiver auto-ack ("ok, will reply shortly").
- Help text translation / i18n.
