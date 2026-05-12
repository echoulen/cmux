#!/usr/bin/env bash
# tests/test_cmux.sh — manual end-to-end check for cmux.
# Run from the repo root: bash tests/test_cmux.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMUX="${CMUX_BIN:-$REPO_ROOT/cmux}"
# macOS sockaddr_un is capped at 104 bytes; the default $TMPDIR
# (/var/folders/...) plus ~/.cmux/<name>.sock overflows it. Force /tmp.
TEST_TMP="$(TMPDIR=/tmp mktemp -d -t cmux-test.XXXXXX)"
# Isolate ~/.cmux for tests so we never touch the user's real sessions.
# cmux resolves ~/.cmux from $HOME at startup, so override before invoking it.
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"

PASS=0
FAIL=0
SESSION_PIDS=()

cleanup() {
  for pid in "${SESSION_PIDS[@]+"${SESSION_PIDS[@]}"}"; do
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
# cmux exits the moment its stdin EOFs, so /dev/null won't work — we wrap
# the child in a real pty (same as how a human actually runs cmux).
spawn_session() {
  local name="$1"; shift
  python3 -c '
import os, pty, signal, sys, time
cmux, name, *args = sys.argv[1:]
os.setsid()
pid, _fd = pty.fork()
if pid == 0:
    os.execvp(cmux, [cmux, "run", name, "--"] + args)
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
time.sleep(3600)
' "$CMUX" "$name" "$@" >/dev/null 2>&1 &
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
  if python3 - "$meta" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert isinstance(m.get("pid"), int), m
assert isinstance(m.get("cwd"), str) and m["cwd"], m
assert isinstance(m.get("started_at"), int), m
PY
  then
    ok "sidecar JSON has pid/cwd/started_at"
  else
    bad "sidecar JSON has pid/cwd/started_at" "shape mismatch"
  fi
  # Kill the session and confirm the sidecar is unlinked.
  kill "${SESSION_PIDS[${#SESSION_PIDS[@]}-1]}" 2>/dev/null || true
  sleep 0.3
  if [[ ! -f "$meta" ]]; then
    ok "sidecar JSON removed when session exits"
  else
    bad "sidecar JSON removed when session exits" "still present"
  fi
}

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
  kill "${SESSION_PIDS[${#SESSION_PIDS[@]}-1]}" 2>/dev/null || true
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
  kill "${SESSION_PIDS[${#SESSION_PIDS[@]}-1]}" 2>/dev/null || true
  sleep 0.3
}

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
  # Header must be indented exactly two spaces (matches indent="  " in cmd_send).
  if echo "$err" | grep -qE "^  NAME[[:space:]]+START[[:space:]]+CWD$"; then
    ok "send fallback shows long-form header"
  else
    bad "send fallback shows long-form header" "got: $err"
  fi
  if echo "$err" | grep -q "shell-fallback"; then
    ok "send fallback lists the live session"
  else
    bad "send fallback lists the live session" "got: $err"
  fi
  kill "${SESSION_PIDS[${#SESSION_PIDS[@]}-1]}" 2>/dev/null || true
  sleep 0.3
}

test_statusline_widget
test_sidecar_metadata
test_list_default_unchanged
test_list_long
test_send_fallback_long
test_help

echo
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
