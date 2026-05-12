#!/usr/bin/env bash
# tests/test_cmux.sh — manual end-to-end check for cmux.
# Run from the repo root: bash tests/test_cmux.sh
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CMUX="${CMUX_BIN:-$REPO_ROOT/cmux}"
TEST_TMP="$(mktemp -d -t cmux-test.XXXXXX)"
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
spawn_session() {
  local name="$1"; shift
  python3 -c "import os, sys; os.setsid(); os.execvp(sys.argv[1], sys.argv[1:])" \
    "$CMUX" run "$name" -- "$@" </dev/null >/dev/null 2>&1 &
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
