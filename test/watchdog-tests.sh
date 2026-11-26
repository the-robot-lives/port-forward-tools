#!/usr/bin/env bash
# test/watchdog-tests.sh — plain bash assertions for tunnel-watchdog and the
# db/valkey/weaviate-watchdog thin entries.
# Sandboxed XDG_STATE_HOME; fixture ssh/pg_isready/redis-cli/curl first on PATH;
# no cluster access, no real ssh, and the real loopback ports 54330/56379/18081
# are never bound (probes are fixtures, tunnels are fixture processes).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
FIX="$HERE/fixtures/watchdog"

PASS=0
FAIL=0
FAILED_NAMES=()

SANDBOX="$(mktemp -d)"
CTL="$SANDBOX/ctl"
STATE="$SANDBOX/state"
SV="$STATE/tunnel-watchdog" # script layout: <XDG_STATE_HOME>/tunnel-watchdog/<service>

cleanup() {
  local s
  for s in db valkey weaviate; do
    XDG_STATE_HOME="$STATE" WD_FIXTURE_DIR="$CTL" "$ROOT/bin/${s}-watchdog" stop >/dev/null 2>&1 || true
  done
  pkill -f "$FIX/ssh" 2>/dev/null || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

mkdir -p "$STATE" "$CTL"
export XDG_STATE_HOME="$STATE"
export WD_FIXTURE_DIR="$CTL"
# fixture probes + fixture ssh first; no real cluster anything
export PATH="$ROOT/bin:$FIX:/usr/bin:/bin:/usr/sbin:/sbin"

# fast watchdog knobs (documented test hooks; shipped defaults: 20s/3/60s/60s)
export TUNNEL_CHECK_INTERVAL=1
export TUNNEL_FAIL_THRESHOLD=3
export TUNNEL_BACKOFF_MAX=2
export TUNNEL_HELD_RESET=3
export TUNNEL_SSH_HOST=noizu.server

assert_eq() { # desc got want
  if [[ "$2" == "$3" ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    echo "FAIL: $1"
    echo "  got:  $2"
    echo "  want: $3"
  fi
}

assert_rc() { # desc want_rc actual_rc
  if [[ "$3" == "$2" ]]; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    echo "FAIL: $1 (rc $3 != $2)"
  fi
}

assert_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then PASS=$((PASS + 1)); else
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    echo "FAIL: $1"
    echo "  haystack: $(printf '%s' "$2" | head -c 400)"
    echo "  missing:  $3"
  fi
}

assert_not_contains() { # desc haystack needle
  if printf '%s' "$2" | grep -qF -- "$3"; then
    FAIL=$((FAIL + 1)); FAILED_NAMES+=("$1")
    echo "FAIL: $1 (found unexpected: $3)"
  else
    PASS=$((PASS + 1))
  fi
}

reset_fixtures() {
  rm -f "$CTL/tunnel-live" "$CTL/ssh-exit" "$CTL/ssh-fail" "$CTL/ssh-invocations"
}

stop_all() {
  local s
  for s in db valkey weaviate; do
    "$ROOT/bin/${s}-watchdog" stop >/dev/null 2>&1 || true
  done
}

reset_all() {
  stop_all
  reset_fixtures
}

await() { # desc max_sec cmd... — wait until cmd succeeds (1s steps)
  local desc="$1" max="$2"; shift 2
  local n=0
  until "$@" >/dev/null 2>&1; do
    if [ "$n" -ge "$max" ]; then
      echo "TIMEOUT after ${max}s waiting for: $desc"
      return 1
    fi
    sleep 1
    n=$(( n + 1 ))
  done
  return 0
}

invocations() { cat "$CTL/ssh-invocations" 2>/dev/null || true; }

# --- 0. syntax -----------------------------------------------------------------
bash -n "$ROOT/bin/tunnel-watchdog"
assert_rc "bash -n tunnel-watchdog" 0 $?
bash -n "$ROOT/bin/db-watchdog"
assert_rc "bash -n db-watchdog" 0 $?
bash -n "$ROOT/bin/valkey-watchdog"
assert_rc "bash -n valkey-watchdog" 0 $?
bash -n "$ROOT/bin/weaviate-watchdog"
assert_rc "bash -n weaviate-watchdog" 0 $?

# --- 1. status: down when nothing answers --------------------------------------
reset_all
out=$("$ROOT/bin/db-watchdog" status); rc=$?
assert_rc "status down rc" 1 "$rc"
assert_contains "status down service+port" "$out" "db down local_port=54330"
assert_contains "status down supervisor" "$out" "supervisor=none"
assert_contains "status down probe" "$out" "probe=no-answer"

# --- 2. another forward holds the port: wait, never fight ----------------------
reset_all
touch "$CTL/tunnel-live"
out=$("$ROOT/bin/db-watchdog" up); rc=$?
assert_rc "waiting up rc" 0 "$rc"
assert_contains "waiting status text" "$out" "up (served by another forward)"
assert_contains "waiting local port" "$out" "local_port=54330"
assert_not_contains "waiting never started a tunnel" "$(invocations)" " -L "
assert_not_contains "waiting resolved nothing" "$(invocations)" "get svc"
stop_all

# --- 3. up: supervisor + tunnel to the resolved cluster address ----------------
reset_all
echo "10.0.0.144" > "$CTL/cluster-ip"
out=$("$ROOT/bin/db-watchdog" up); rc=$?
assert_rc "up rc" 0 "$rc"
assert_contains "up status up" "$out" "db up local_port=54330 address=10.0.0.144:5432"
assert_contains "up probe answer" "$out" "probe=accepting connections"
tpid=$(cat "$SV/db/tunnel.pid" 2>/dev/null)
case $tpid in ''|*[!0-9]*) tpid_valid=no ;; *) tpid_valid=yes ;; esac
assert_eq "tunnel pidfile holds a pid" "$tpid_valid" "yes"
kill -0 "$tpid" 2>/dev/null
assert_rc "tunnel process alive" 0 $?
inv=$(invocations)
assert_contains "resolve uses host kubectl context" "$inv" "--context noizu"
assert_contains "resolve targets apps/app-timescaledb" "$inv" "-n apps get svc app-timescaledb"
assert_contains "tunnel binds loopback to cluster address" "$inv" "-L 127.0.0.1:54330:10.0.0.144:5432"
assert_contains "tunnel is read-only batch ssh" "$inv" "ExitOnForwardFailure=yes"
out=$("$ROOT/bin/db-watchdog" status)
assert_contains "status shows supervisor pid" "$out" "supervisor=$(cat "$SV/db/supervisor.pid")"

# --- 4. tunnel exit -> automatic restart ----------------------------------------
old_tpid=$(cat "$SV/db/tunnel.pid")
touch "$CTL/ssh-exit"
pid_changed() { [ "$(cat "$SV/db/tunnel.pid" 2>/dev/null)" != "$old_tpid" ]; }
await "tunnel restarted with a new pid" 10 pid_changed
assert_rc "restart happened within 10s" 0 $?
log=$(cat "$SV/db/watchdog.log")
assert_contains "log records the exit" "$log" "exited after"
starts=$(grep -c 'tunnel started (pid' "$SV/db/watchdog.log")
if [ "${starts:-0}" -ge 2 ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); FAILED_NAMES+=("log records a second tunnel start")
  echo "FAIL: log records a second tunnel start (count=${starts:-0})"
fi
new_tpid=$(cat "$SV/db/tunnel.pid" 2>/dev/null)
if [ -n "$new_tpid" ] && [ "$new_tpid" != "$old_tpid" ]; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); FAILED_NAMES+=("new tunnel pid differs")
  echo "FAIL: new tunnel pid differs (old=$old_tpid new=$new_tpid)"
fi
out=$("$ROOT/bin/db-watchdog" status); rc=$?
assert_rc "status up after restart" 0 "$rc"
assert_contains "status address after restart" "$out" "address=10.0.0.144:5432"

# --- 5. stop: kills the supervisor and its tunnel, nothing else -----------------
sup=$(cat "$SV/db/supervisor.pid")
out=$("$ROOT/bin/db-watchdog" stop); rc=$?
assert_rc "stop rc" 0 "$rc"
assert_eq "stop says stopped" "$out" "db stopped"
kill -0 "$sup" 2>/dev/null
assert_rc "supervisor dead after stop" 1 $?
kill -0 "$new_tpid" 2>/dev/null
assert_rc "tunnel dead after stop" 1 $?
[ -f "$SV/db/supervisor.pid" ] && found_sup=yes || found_sup=no
assert_eq "supervisor pidfile removed" "$found_sup" "no"
out=$("$ROOT/bin/db-watchdog" status); rc=$?
assert_rc "status down after stop" 1 "$rc"
assert_contains "status supervisor none after stop" "$out" "supervisor=none"

# --- 6. logs ---------------------------------------------------------------------
out=$("$ROOT/bin/db-watchdog" logs)
assert_contains "logs show supervisor start" "$out" "supervisor started"

# --- 7. valkey + weaviate table facts (ns/svc/ports/probes) ----------------------
reset_all
echo "10.0.0.95" > "$CTL/cluster-ip"
touch "$CTL/tunnel-live"
out=$("$ROOT/bin/valkey-watchdog" up); rc=$?
assert_rc "valkey waiting rc" 0 "$rc"
assert_contains "valkey waiting line" "$out" "valkey up (served by another forward) local_port=56379"
assert_contains "valkey probe answer" "$out" "probe=NOAUTH"
stop_all
reset_fixtures
out=$("$ROOT/bin/valkey-watchdog" up)
await "valkey tunnel up" 10 "$ROOT/bin/valkey-watchdog" status
assert_contains "valkey address" "$("$ROOT/bin/valkey-watchdog" status)" "address=10.0.0.95:6379"
assert_contains "valkey resolves app-valkey" "$(invocations)" "get svc app-valkey"
stop_all

reset_all
echo "10.0.0.123" > "$CTL/cluster-ip"
out=$("$ROOT/bin/weaviate-watchdog" up); rc=$?
assert_rc "weaviate up rc" 0 "$rc"
assert_contains "weaviate line" "$out" "weaviate up local_port=18081 address=10.0.0.123:80"
assert_contains "weaviate probe 200" "$out" "probe=200"
inv=$(invocations)
assert_contains "weaviate resolves platform-ai/weaviate" "$inv" "-n platform-ai get svc weaviate"
assert_contains "weaviate tunnel spec" "$inv" "-L 127.0.0.1:18081:10.0.0.123:80"
stop_all

# --- 8. thin entries resolve their own directory (copy + symlink, install-style)
reset_all
INSTALLED="$SANDBOX/installed"
mkdir -p "$INSTALLED"
cp "$ROOT/bin/tunnel-watchdog" "$ROOT/bin/db-watchdog" \
   "$ROOT/bin/valkey-watchdog" "$ROOT/bin/weaviate-watchdog" "$INSTALLED/"
out=$("$INSTALLED/db-watchdog" status); rc=$?
assert_rc "installed copy status rc" 1 "$rc"
assert_contains "installed copy serves db table" "$out" "db down local_port=54330"
ln -s "$INSTALLED/weaviate-watchdog" "$SANDBOX/weaviate-link"
out=$("$SANDBOX/weaviate-link" status); rc=$?
assert_rc "symlinked entry status rc" 1 "$rc"
assert_contains "symlinked entry serves weaviate table" "$out" "weaviate down local_port=18081"

# --- 9. restart command ----------------------------------------------------------
echo "10.0.0.144" > "$CTL/cluster-ip"
out=$("$INSTALLED/db-watchdog" restart); rc=$?
assert_rc "restart rc" 0 "$rc"
await "restart brings the tunnel up" 10 "$INSTALLED/db-watchdog" status
assert_contains "restart status address" "$("$INSTALLED/db-watchdog" status)" "address=10.0.0.144:5432"
stop_all

# --- summary ---------------------------------------------------------------------
if [ "$FAIL" -eq 0 ]; then
  echo "watchdog tests: $PASS/$((PASS + FAIL)) assertions passed"
else
  echo "watchdog tests: $PASS passed, $FAIL failed"
  for name in "${FAILED_NAMES[@]}"; do echo "  failed: $name"; done
  exit 1
fi
