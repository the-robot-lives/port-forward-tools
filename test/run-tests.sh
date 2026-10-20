#!/usr/bin/env bash
# test/run-tests.sh — plain bash assertions for cluster-port-forward.
# Sandboxed HOME/XDG_RUNTIME_DIR; fake kubectl/ssh on PATH; no cluster access.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
BIN="$ROOT/bin/cluster-port-forward"
FIX="$HERE/fixtures"

PASS=0
FAIL=0
FAILED_NAMES=()

SANDBOX="$(mktemp -d)"
cleanup() {
  [[ -n "${LISTENER_PID:-}" ]] && kill "$LISTENER_PID" 2>/dev/null || true
  CPF_WEB_PORT=4499 CPF_STATE_DIR="$SB_RUN" "$BIN" daemon stop >/dev/null 2>&1 || true
  CPF_WEB_PORT=4498 CPF_STATE_DIR="$SB_RUN-plain" "$BIN" daemon stop >/dev/null 2>&1 || true
  CPF_WEB_PORT=4497 CPF_STATE_DIR="$SB_RUN-surv" "$BIN" daemon stop >/dev/null 2>&1 || true
  pkill -f "$BIN __daemon-loop" 2>/dev/null || true
  pkill -f "$HERE/../share/web/server.py" 2>/dev/null || true
  rm -rf "$SANDBOX"
}
trap cleanup EXIT

export HOME="$SANDBOX/home"
export XDG_RUNTIME_DIR="$SANDBOX/run"
export FIXTURES="$FIX"
mkdir -p "$HOME/.config/tunnel-watcher" "$XDG_RUNTIME_DIR" "$SANDBOX/empty" "$SANDBOX/cwd"
SB_RUN="$SANDBOX/run/pf-state"

# minimal PATH: fixtures first, then system dirs — no autossh, no real kubectl/ssh
export PATH="$FIX:/usr/bin:/bin:/usr/sbin:/sbin"

cp "$ROOT/share/profiles/noizu.yaml.example" "$HOME/.config/tunnel-watcher/noizu.yaml"

# default profile for most tests; explicit `env -u TUNNEL_WATCHER_PROFILE` where
# the no-profile behaviour itself is under test.
export TUNNEL_WATCHER_PROFILE=noizu

cpf() { CPF_STATE_DIR="$SB_RUN" "$BIN" "$@"; }

# Pre-clean: kill orphans from earlier crashed runs on OUR test ports / fixture
# paths only (fixture argv carries the worktree path — nothing else can match).
preclean() {
  local p pid ppid
  for p in 6308 6314 6316 6318 6320 6322 6360 64108 64114 64116 64118 64120 64122 60998 60999; do
    for pid in $(lsof -ti tcp:"$p" 2>/dev/null); do
      ppid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
      kill "$pid" 2>/dev/null || true
      [[ -n "$ppid" && "$ppid" != "1" ]] && kill "$ppid" 2>/dev/null || true
    done
  done
  pkill -f "$HERE/fixtures/kubectl" 2>/dev/null || true
  pkill -f "$HERE/fixtures/ssh" 2>/dev/null || true
  pkill -f "$BIN __daemon-loop" 2>/dev/null || true
  pkill -f "$HERE/../share/web/server.py" 2>/dev/null || true
  local port spid
  for port in 4497 4498 4499; do
    for spid in $(lsof -ti tcp:"$port" -sTCP:LISTEN 2>/dev/null); do
      case "$(ps -o command= -p "$spid" 2>/dev/null)" in
        *cluster-port-forward*|*server.py*) kill "$spid" 2>/dev/null || true ;;
      esac
    done
  done
  sleep 0.3
  return 0
}
preclean

# --- test daemons: the CLI `up`/`stop`/`status` surface talks to the daemon ----
# 4499 = bind-mode daemon (default; fake port-forwards actually listen)
# 4498 = plain daemon (never-binding forwards → the timeout/offline path)
# started AFTER preclean — preclean kills anything on our ports by design
export CPF_WEB_PORT=4499
_start_out=$(FAKE_KUBE_BIND=1 CPF_STATE_DIR="$SB_RUN" "$BIN" daemon start 2>&1) \
  || { echo "FATAL: bind-mode test daemon failed to start:"; echo "$_start_out"; exit 1; }
_start_out=$(CPF_WEB_PORT=4498 CPF_STATE_DIR="$SB_RUN-plain" "$BIN" daemon start 2>&1) \
  || { echo "FATAL: plain test daemon failed to start:"; echo "$_start_out"; exit 1; }
unset _start_out
# dedicated port range for the plain (never-binding) daemon — the bind daemon's
# children hold 6308..6322, and an already-open local port is legitimately
# treated as an online external forward
sed 's/default_port: 6308/default_port: 64308/' \
  "$HOME/.config/tunnel-watcher/noizu.yaml" > "$HOME/.config/tunnel-watcher/plain.yaml"
export CPF_WEB_PORT=4499

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

# --- 0. syntax ----------------------------------------------------------------
bash -n "$BIN"
assert_rc "bash -n" 0 $?

# --- 1. parser: valid profile --------------------------------------------------
out=$(cpf profile-parse 2>&1); rc=$?
assert_rc "profile-parse rc" 0 "$rc"
assert_contains "parser profile name" "$out" "profile=noizu ssh_host=noizu.server"
assert_contains "parser valkey line" "$out" "slug=valkey ns=apps svc=app-valkey kind=service dir=k2l default_port=6308 instances=true default_instance=latest"
assert_contains "parser platform line" "$out" "slug=platform-valkey ns=platform svc=platform-valkey kind=service dir=k2l default_port=6360 instances=false"
assert_not_contains "commented l2k stays commented" "$out" "timescale-local"

# --- 2. parser: malformed profiles fail loud with line numbers -----------------
declare -A MALFORMED=(
  [malformed-tab]="line 3"
  [malformed-indent]="line 4"
  [malformed-flow]="line 4"
  [malformed-unknown]="line 1"
  [malformed-dup]="line 2"
  [malformed-quote]="line 2"
  [malformed-listfirst]="line 2"
  [malformed-novalue]="line 3"
)
for name in "${!MALFORMED[@]}"; do
  err=$(cpf profile-parse "$FIX/profiles/$name.yaml" 2>&1 >/dev/null); rc=$?
  assert_rc "$name rc" 1 "$rc"
  assert_contains "$name line no" "$err" "profile error, ${MALFORMED[$name]}"
done

# --- 3. profile resolution -----------------------------------------------------
err=$(cpf profile-parse missing-one 2>&1 >/dev/null); rc=$?
assert_rc "resolution missing rc" 1 "$rc"
assert_contains "resolution lists config path" "$err" "$HOME/.config/tunnel-watcher/missing-one.yaml"
assert_contains "resolution lists cwd path" "$err" "./missing-one.yaml"

cp "$ROOT/share/profiles/noizu.yaml.example" "$SANDBOX/cwd/noizu.yaml"
out=$( cd "$SANDBOX/cwd" && TUNNEL_WATCHER_DIR="$SANDBOX/empty" CPF_STATE_DIR="$SB_RUN" "$BIN" profile-parse 2>&1 ); rc=$?
assert_rc "resolution cwd fallback" 0 "$rc"
assert_contains "cwd fallback parsed" "$out" "profile=noizu"

out=$(cpf profile-parse "$ROOT/share/profiles/noizu.yaml.example" 2>&1); rc=$?
assert_rc "resolution explicit path" 0 "$rc"

err=$( { unset TUNNEL_WATCHER_PROFILE; cpf up --dry-run; } 2>&1 >/dev/null ); rc=$?
assert_rc "no profile anywhere rc" 1 "$rc"
assert_contains "no profile names the fix" "$err" "--profile"

# --- 4. spec grammar + instance math (owner example: base 6308) ----------------
out=$(cpf up --dry-run --json --include valkey 2>/dev/null); rc=$?
assert_rc "dry-run json rc" 0 "$rc"
assert_contains "json k2l direction" "$out" '"direction":"k2l"'
assert_contains "instance n1 port" "$out" '"local_port":6314'
assert_contains "instance n2 port" "$out" '"local_port":6316'
assert_contains "instance n3 port" "$out" '"local_port":6318'
assert_contains "instance n4 port" "$out" '"local_port":6320'
assert_contains "instance n5 port" "$out" '"local_port":6322'
assert_contains "default row pod empty" "$out" '"target":"svc/app-valkey"'
assert_contains "json slug n5" "$out" '"slug":"valkey"'

out=$(cpf up --dry-run --include valkey 2>/dev/null)
assert_contains "k2l dry-run argv" "$out" "DRY-RUN: kubectl --context noizu -n apps port-forward svc/app-valkey --address 127.0.0.1 6308:6379"
assert_contains "instance pod target" "$out" "pod/app-valkey-aaa1 --address 127.0.0.1 6314:6379"

# single-instance selectors
out=$(cpf up --dry-run --include valkey-latest 2>/dev/null)
assert_contains "latest = n5" "$out" "pod/app-valkey-eee5 --address 127.0.0.1 6322:6379"
out=$(cpf up --dry-run --include valkey-num-3 2>/dev/null)
assert_contains "num-3 = n3" "$out" "pod/app-valkey-ccc3 --address 127.0.0.1 6318:6379"
out=$(cpf up --dry-run --include valkey-oldest 2>/dev/null)
assert_contains "oldest = n1" "$out" "pod/app-valkey-aaa1 --address 127.0.0.1 6314:6379"
out=$(cpf up --dry-run --include valkey:7000 2>/dev/null)
assert_contains "port override default" "$out" "svc/app-valkey --address 127.0.0.1 7000:6379"
out=$(cpf up --dry-run --include valkey-oldest:7100 2>/dev/null)
assert_contains "port override instance" "$out" "pod/app-valkey-aaa1 --address 127.0.0.1 7100:6379"

# default_instance honored via -default
out=$(cpf up --dry-run --profile "$FIX/profiles/numdef.yaml" --include nd-default 2>/dev/null)
assert_contains "default_instance num-2" "$out" "pod/app-valkey-bbb2 --address 127.0.0.1 6508:6379"

# out-of-range instance
err=$(cpf up --dry-run --include valkey-num-9 2>&1 >/dev/null); rc=$?
assert_rc "num-9 out of range rc" 1 "$rc"
assert_contains "num-9 message" "$err" "out of range"

# raw name/namespace specs
out=$(cpf up --dry-run --include app-valkey/apps 2>/dev/null)
assert_contains "raw catalog ports" "$out" "svc/app-valkey --address 127.0.0.1 56379:6379"
out=$(cpf up --dry-run --include weaviate/platform-ai:9999 2>/dev/null)
assert_contains "raw port override" "$out" "svc/weaviate --address 127.0.0.1 9999:80"

# --- 4b. regression: REAL kubectl shapes (post-merge smoke defect) -------------
# Real kubectl renders {.spec.selector} as JSON {"k":"v"}; the tool must
# normalize it to k=v (a k:v selector is an API BadRequest). The fake kubectl
# now rejects non-k=v selectors like the real API, and pods fixtures carry the
# real custom-columns shape (aligned NAME/PHASE header + PHASE column).

# the fixture double must be honest about selector shape (guards the sed fix)
err=$("$FIX/kubectl" --context noizu -n apps get pods -l "app.kubernetes.io/name:app-valkey" -o custom-columns=NAME:.metadata.name 2>&1 >/dev/null); rc=$?
assert_rc "fake rejects k:v selector rc" 1 "$rc"
assert_contains "fake rejects k:v selector err" "$err" "BadRequest"

# bare slug = default row + ALL instance rows (symptom-3 guard)
out=$(cpf up --dry-run --json --include valkey 2>/dev/null)
assert_contains "bare slug keeps default 6308" "$out" '"local_port":6308'
assert_contains "bare slug adds instance n1 6314" "$out" '"local_port":6314'

# n=1 resolution against the verbatim live-captured fixture (real pod name)
out=$(FAKE_PODS_SUFFIX=_live cpf up --dry-run --json --include valkey-oldest 2>/dev/null); rc=$?
assert_rc "live-shape enumeration rc" 0 "$rc"
assert_contains "live-shape real pod name" "$out" '"pod":"app-valkey-6c986598d6-7pxf9"'
assert_contains "live-shape owner math 6314" "$out" '"local_port":6314'
out=$(FAKE_PODS_SUFFIX=_live cpf up --dry-run --include valkey-oldest 2>/dev/null)
assert_contains "live-shape argv" "$out" "pod/app-valkey-6c986598d6-7pxf9 --address 127.0.0.1 6314:6379"

# --- 5. missing-port refusals --------------------------------------------------
err=$(cpf up --dry-run --profile "$FIX/profiles/no-port.yaml" 2>&1 >/dev/null); rc=$?
assert_rc "no-port refusal rc" 1 "$rc"
assert_contains "no-port message" "$err" "🔥 no port for orphan — add default_port to the profile or pass orphan:PORT"

err=$(cpf up --dry-run --profile "$FIX/profiles/no-remote.yaml" 2>&1 >/dev/null); rc=$?
assert_rc "no-remote refusal rc" 1 "$rc"
assert_contains "no-remote message" "$err" "no remote port for ghost"

err=$(cpf up --dry-run --include no-such-svc/apps 2>&1 >/dev/null); rc=$?
assert_rc "raw refusal rc" 1 "$rc"
assert_contains "raw refusal message" "$err" "🔥 no port for no-such-svc/apps"

# --- 6. l2k dry-run argv (exact ssh -R shape) ----------------------------------
out=$(cpf up --dry-run --profile "$FIX/profiles/l2k-dry.yaml" 2>/dev/null); rc=$?
assert_rc "l2k dry-run rc" 0 "$rc"
assert_contains "l2k argv exact" "$out" \
  "DRY-RUN: ssh -N -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -R *:6001:127.0.0.1:6987 noizu.server"

# --- 7. overlap: defaults take precedence, colliding instances dropped ---------
err=$(cpf up --dry-run --profile "$FIX/profiles/collision.yaml" 2>"$SANDBOX/err.txt" >/dev/null); rc=$?
assert_rc "collision plan rc" 0 "$rc"
warnfile=$(cat "$SANDBOX/err.txt")
assert_contains "collision 🔥 warning" "$warnfile" "🔥 WARNING: dropping beta instance n3 — local port 7000 collides"
assert_contains "gap guidance warning" "$warnfile" "gap alpha ↔ beta is 10 ports"
out=$(cpf up --dry-run --json --profile "$FIX/profiles/collision.yaml" 2>/dev/null)
assert_contains "collision kept n1" "$out" '"local_port":6996'
assert_contains "collision kept n2" "$out" '"local_port":6998'
n7000=$(printf '%s' "$out" | grep -oF '"local_port":7000' | wc -l | tr -d ' ')
assert_eq "collision n3 dropped (one 7000 = alpha default)" "$n7000" "1"

# --- 8. timeout path (never-binding fake, own port range) → exit 1 -------------
# ("$BIN" direct: the cpf() wrapper would override the CPF_STATE_DIR prefix)
t0=$(date +%s)
out=$(CPF_WEB_PORT=4498 CPF_STATE_DIR="$SB_RUN-plain" "$BIN" up --profile plain --include valkey --timeout 1 2>&1); rc=$?
t1=$(date +%s)
assert_rc "timeout rc" 1 "$rc"
assert_contains "timeout row offline" "$out" "offline"
(( t1 - t0 <= 15 )) && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILED_NAMES+=("timeout duration"); echo "FAIL: timeout took $((t1 - t0))s"; }

# daemon unreachable → loud refusal with fix hint (no silent local supervisor)
err=$(CPF_WEB_PORT=4490 cpf up --include valkey --timeout 1 2>&1 >/dev/null); rc=$?
assert_rc "up no-daemon refusal rc" 1 "$rc"
assert_contains "up no-daemon hint" "$err" "daemon not running"

err=$(cpf up --dry-run --timeout bogus 2>&1 >/dev/null); rc=$?
assert_rc "bad duration rc" 1 "$rc"
assert_contains "bad duration msg" "$err" "bad --timeout"

# --- 9. online path (bind listeners) → exit 0, status + json + stop all --------
out=$(FAKE_KUBE_BIND=1 cpf up --profile "$FIX/profiles/live.yaml" --include lv --timeout 20 2>/dev/null); rc=$?
assert_rc "online rc" 0 "$rc"
assert_contains "online row" "$out" "online"
assert_contains "online n1" "$out" "tw-lv-n1"
out=$(FAKE_KUBE_BIND=1 cpf up --dry-run --json --profile "$FIX/profiles/live.yaml" --include lv 2>/dev/null)
assert_contains "live profile math n1" "$out" '"local_port":64114'
assert_contains "live profile math n5" "$out" '"local_port":64122'

out=$(cpf status 2>&1)
assert_contains "status appendix header" "$out" "tunnel profiles"
assert_contains "status shows tunnel" "$out" "tw-lv"

out=$(cpf up --dry-run --json --profile "$FIX/profiles/live.yaml" --include lv 2>/dev/null)
assert_contains "json pod field" "$out" '"pod":"app-valkey-aaa1"'

# tui degrades without a TTY
out=$(cpf tui </dev/null 2>&1); rc=$?
assert_rc "tui degrade rc" 0 "$rc"
assert_contains "tui degrade table" "$out" "SLUG"

# stop all tears down tunnels + state
cpf stop all >/dev/null 2>&1
[[ -f "$SB_RUN/tunnels.tsv" ]] && { FAIL=$((FAIL + 1)); FAILED_NAMES+=("state file gone"); echo "FAIL: tunnels.tsv still present"; } || PASS=$((PASS + 1))

# --- 10. l2k online path (fake ssh child + local listener) ---------------------
LISTENER_PID=""
( while true; do nc -l 127.0.0.1 60999 >/dev/null 2>&1 || sleep 0.1; done ) &
LISTENER_PID=$!
out=$(cpf up --profile "$FIX/profiles/l2k-live.yaml" --timeout 10 2>/dev/null); rc=$?
assert_rc "l2k online rc" 0 "$rc"
assert_contains "l2k online row" "$out" "tw-l2k-rev"
kill "$LISTENER_PID" 2>/dev/null || true
LISTENER_PID=""
cpf stop all >/dev/null 2>&1

# --- 11. doctor additions ------------------------------------------------------
err=$(TUNNEL_WATCHER_PROFILE="$FIX/profiles/collision.yaml" cpf doctor 2>&1 >/dev/null); rc=$?
assert_rc "doctor rc" 0 "$rc"
assert_contains "doctor GatewayPorts warning" "$err" "GatewayPorts not enabled on noizu.server"
assert_contains "doctor GatewayPorts remediation" "$err" "GatewayPorts clientspecified"
assert_contains "doctor gap warning" "$err" "is 10 ports"

out=$(FAKE_SSH_GATEWAYPORTS="GatewayPorts clientspecified" TUNNEL_WATCHER_PROFILE="$FIX/profiles/collision.yaml" cpf doctor 2>&1); rc=$?
assert_rc "doctor gw-ok rc" 0 "$rc"
assert_contains "doctor gw ok line" "$out" "GatewayPorts on noizu.server: GatewayPorts clientspecified"
assert_not_contains "doctor no gw warning" "$out" "GatewayPorts not enabled"

out=$( { unset TUNNEL_WATCHER_PROFILE; cpf doctor; } 2>&1 ); rc=$?
assert_rc "doctor no-profile rc" 0 "$rc"
assert_contains "doctor no-profile note" "$out" "tunnel profiles: none active"

# --- 12. old surface regression ------------------------------------------------
out=$(cpf list 2>&1); rc=$?
assert_rc "list rc" 0 "$rc"
assert_contains "list shows catalog" "$out" "app-tsdb"
out=$(cpf hosts print 2>&1); rc=$?
assert_rc "hosts print rc" 0 "$rc"
assert_contains "hosts block marker" "$out" "BEGIN noizu-local-dev"
out=$(cpf status 2>&1); rc=$?
assert_rc "status rc" 0 "$rc"
assert_contains "status catalog table" "$out" "NAME"
out=$(cpf --help 2>&1)
assert_contains "help shows up" "$out" "up [--profile P]"
assert_contains "help shows tui" "$out" "cluster-port-forward tui"
assert_contains "help shows specs" "$out" "slug-num-N"

# --- 13. regressions: tui --profile, flag-position hint, status profile section -
seed_state() {
  local now; now=$(date +%s)
  {
    printf 'tw-valkey|valkey|service|k2l|apps|svc/app-valkey|6308|6379|||%d|0|default\n' "$now"
    printf 'tw-valkey-n1|valkey|service|k2l|apps|pod/app-valkey-aaa1|6314|6379|||%d|0|n1\n' "$now"
    printf 'tw-ghost|ghost|service|k2l|apps|svc/ghost|6600|6379|||%d|0|default\n' "$now"
  } >"$SB_RUN/tunnels.tsv"
}
seed_state

# tui honors --profile without the env var (defect: flag was ignored entirely)
out=$({ unset TUNNEL_WATCHER_PROFILE; cpf tui --profile noizu </dev/null; } 2>&1); rc=$?
assert_rc "tui --profile rc" 0 "$rc"
assert_contains "tui --profile renders rows" "$out" "tw-valkey"
assert_not_contains "tui --profile no refusal" "$out" "no profile given"

out=$({ unset TUNNEL_WATCHER_PROFILE; cpf tui </dev/null; } 2>&1 >/dev/null); rc=$?
assert_rc "tui no-profile refusal rc" 1 "$rc"
assert_contains "tui no-profile refusal msg" "$out" "no profile"

# global flags before the subcommand get the positional hint (defect: bare "Unknown command")
err=$(cpf --profile noizu tui 2>&1 >/dev/null); rc=$?
assert_rc "flag-before-subcommand rc" 1 "$rc"
assert_contains "flag-before-subcommand hint" "$err" "flags go after the subcommand"

# status renders the profile-tunnel section from seeded state
seed_state
out=$(cpf status 2>&1); rc=$?
assert_rc "status with state rc" 0 "$rc"
assert_contains "status profile header" "$out" "--- tunnel profiles (up/tui) ---"
assert_contains "status shows tw-valkey" "$out" "tw-valkey"
assert_contains "status shows foreign slug" "$out" "tw-ghost"

# status --profile filters to that profile's slugs
out=$({ unset TUNNEL_WATCHER_PROFILE; cpf status --profile noizu; } 2>&1); rc=$?
assert_rc "status --profile rc" 0 "$rc"
assert_contains "status --profile keeps valkey" "$out" "tw-valkey"
assert_not_contains "status --profile drops foreign" "$out" "tw-ghost"

# no state file → section always renders, names the state dir (env-split tell)
# (call the binary directly: the cpf() wrapper would override CPF_STATE_DIR)
# no state file → section always renders, names the state dir (env-split tell).
# also point CPF_WEB_PORT at a dead port: with a live daemon the rows come from
# the daemon's own state (correct behaviour), which would mask this path.
out=$(CPF_WEB_PORT=4490 CPF_STATE_DIR="$SANDBOX/no-such-state" "$BIN" status 2>&1); rc=$?
assert_rc "status no-state rc" 0 "$rc"
assert_contains "status no-state header" "$out" "--- tunnel profiles (up/tui) ---"
assert_contains "status no-state names dir" "$out" "no tunnel sessions (state dir:"
cpf stop all >/dev/null 2>&1

# --- 14. daemon API + web + plist + survivability ------------------------------
# tiny stdlib HTTP helper (mirrors the CLI client)
api() { # method path [json] → body; rc: 0 ok / 1 HTTP error / 2 unreachable
  python3 - "$CPF_WEB_PORT" "$1" "$2" "${3:-}" <<'PY'
import sys, urllib.request, urllib.error
port, method, path, body = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
req = urllib.request.Request("http://127.0.0.1:%s%s" % (port, path),
                             data=(body.encode() if body else None), method=method,
                             headers={"Content-Type": "application/json"})
try:
    sys.stdout.write(urllib.request.urlopen(req, timeout=60).read().decode())
except urllib.error.HTTPError as e:
    sys.stdout.write(e.read().decode()); sys.exit(1)
except Exception:
    sys.exit(2)
PY
}

# health
out=$(api GET /api/health); rc=$?
assert_rc "api health rc" 0 "$rc"
assert_contains "api health ok" "$out" '"ok": true'
assert_contains "api health loopback pid" "$out" '"daemon_pid"'

# up lifecycle through the API (bind daemon): rows online
out=$(api POST /api/up "{\"profile\":\"$FIX/profiles/live.yaml\",\"include\":[\"lv\"],\"timeout\":\"20s\"}"); rc=$?
assert_rc "api up rc" 0 "$rc"
assert_contains "api up all online" "$out" '"all_online": true'

# repoint validation: unknown pod → 400 with message (server + CLI double-check)
out=$(api POST /api/repoint '{"local_port":64114,"pod":"ghost-pod-xyz"}'); rc=$?
assert_rc "api repoint unknown pod rc" 1 "$rc"
assert_contains "api repoint 400 msg" "$out" "not found"

# repoint to a real fixture pod succeeds
out=$(api POST /api/repoint '{"local_port":64114,"pod":"app-valkey-ccc3"}'); rc=$?
assert_rc "api repoint real pod rc" 0 "$rc"
grep -q "pod/app-valkey-ccc3" "$SB_RUN/tunnels.tsv" \
  && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILED_NAMES+=("api repoint row updated"); echo "FAIL: api repoint row updated"; }

# down via API removes the slug's rows
out=$(api POST /api/down '{"slug":["lv"]}'); rc=$?
assert_rc "api down slug rc" 0 "$rc"
grep -q "tw-lv" "$SB_RUN/tunnels.tsv" \
  && { FAIL=$((FAIL + 1)); FAILED_NAMES+=("api down removed rows"); echo "FAIL: api down removed rows"; } \
  || PASS=$((PASS + 1))

# reload picks up a profile edit
sed 's/default_port: 6308/default_port: 6302/' "$HOME/.config/tunnel-watcher/noizu.yaml" > "$HOME/.config/tunnel-watcher/noizu.yaml.new" \
  && mv "$HOME/.config/tunnel-watcher/noizu.yaml.new" "$HOME/.config/tunnel-watcher/noizu.yaml"
out=$(api POST /api/reload '{"profile":"noizu"}'); rc=$?
assert_rc "api reload rc" 0 "$rc"
assert_contains "api reload sees edit" "$out" "6302"
mv "$HOME/.config/tunnel-watcher/noizu.yaml.bak" "$HOME/.config/tunnel-watcher/noizu.yaml" 2>/dev/null || \
  cp "$ROOT/share/profiles/noizu.yaml.example" "$HOME/.config/tunnel-watcher/noizu.yaml"

# setport persists to the profile yaml (same semantics as TUI `p`)
out=$(api POST /api/setport '{"slug":"valkey","port":6306}'); rc=$?
assert_rc "api setport rc" 0 "$rc"
grep -q "default_port: 6306" "$HOME/.config/tunnel-watcher/noizu.yaml" \
  && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILED_NAMES+=("api setport persisted"); echo "FAIL: api setport persisted"; }
out=$(api POST /api/setport '{"slug":"valkey","port":6307}'); rc=$?
assert_rc "api setport odd rejected rc" 1 "$rc"
cp "$ROOT/share/profiles/noizu.yaml.example" "$HOME/.config/tunnel-watcher/noizu.yaml"

# plist generation: content assertions only — launchctl is NEVER invoked
mkdir -p "$SANDBOX/plisthome"
HOME="$SANDBOX/plisthome" CPF_NO_LAUNCHCTL=1 CPF_STATE_DIR="$SB_RUN" "$BIN" daemon install >/dev/null 2>&1
plist="$SANDBOX/plisthome/Library/LaunchAgents/com.noizu.cluster-port-forward.plist"
[[ -f "$plist" ]] && PASS=$((PASS + 1)) || { FAIL=$((FAIL + 1)); FAILED_NAMES+=("plist exists"); echo "FAIL: plist exists"; }
plist_txt=$(cat "$plist" 2>/dev/null)
assert_contains "plist label" "$plist_txt" "com.noizu.cluster-port-forward"
assert_contains "plist KeepAlive" "$plist_txt" "KeepAlive"
assert_contains "plist RunAtLoad" "$plist_txt" "RunAtLoad"
assert_contains "plist daemon loop argv" "$plist_txt" "__daemon-loop"
assert_contains "plist binary path" "$plist_txt" "$BIN"

# survivability: daemon + children outlive the subshell that spawned them
(
  export CPF_WEB_PORT=4497 CPF_STATE_DIR="$SB_RUN-surv" FAKE_KUBE_BIND=1
  "$BIN" daemon start >/dev/null 2>&1
  exit 0
)
sleep 1
dpid=$(cat "$SB_RUN-surv/daemon.pid" 2>/dev/null)
if [[ -n "$dpid" ]] && kill -0 "$dpid" 2>/dev/null; then PASS=$((PASS + 1)); else
  FAIL=$((FAIL + 1)); FAILED_NAMES+=("daemon survives subshell"); echo "FAIL: daemon survives subshell"; fi
CPF_WEB_PORT=4497 CPF_STATE_DIR="$SB_RUN-surv" cpf up --profile "$FIX/profiles/live.yaml" --include lv --timeout 20 >/dev/null 2>&1
assert_rc "surv daemon up rc" 0 $?
sleep 2   # spawning CLI + subshell contexts are long gone by now
out=$(CPF_WEB_PORT=4497 api GET /api/tunnels)
assert_contains "surv tunnels still online" "$out" '"state": "online"'
CPF_WEB_PORT=4497 CPF_STATE_DIR="$SB_RUN-surv" "$BIN" daemon stop >/dev/null 2>&1 || true

# doctor sees the daemon + web UI
out=$(cpf doctor 2>&1); rc=$?
assert_rc "doctor daemon rc" 0 "$rc"
assert_contains "doctor daemon healthy" "$out" "daemon running"
assert_contains "doctor web api" "$out" "web API healthy on 127.0.0.1:4499"
assert_contains "doctor web ui 200" "$out" "web UI serves 200"

# --- summary -------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
if [[ $FAIL -gt 0 ]]; then
  printf 'failed: %s\n' "${FAILED_NAMES[@]}"
  exit 1
fi
exit 0
