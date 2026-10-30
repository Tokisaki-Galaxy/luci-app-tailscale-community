#!/bin/sh
# Tests for root/usr/libexec/tailscale-setup-firewall.
#
# The worker writes a line based status file so that a message containing a
# backslash, a quote or a tab cannot corrupt it. That property is what these
# tests pin down: an earlier JSON-with-tr-dedupe implementation silently
# produced invalid JSON for any message containing a backslash.
#
# Run: sh tests/init/firewall-worker-test.sh

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
WORKER="$REPO_ROOT/luci-app-tailscale-community/root/usr/libexec/tailscale-setup-firewall"

[ -f "$WORKER" ] || { echo "cannot find $WORKER" >&2; exit 1; }

passes=0
failures=0

check() {
	# usage: check "description" <command...>
	local desc="$1"
	shift
	if "$@" >/dev/null 2>&1; then
		passes=$((passes + 1))
	else
		echo "  FAIL: $desc"
		failures=$((failures + 1))
	fi
}

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

STATE_DIR="$SANDBOX/run"
mkdir -p "$STATE_DIR"

# Source the worker's functions only. The script body (which reloads the
# network) must never run inside a test, so the top level statements are
# stripped and only the function definitions are kept.
load_functions() {
	sed -n '/^write_state()/,/^}/p;/^lock_age()/,/^}/p;/^lock_holder_alive()/,/^}/p' "$WORKER" > "$SANDBOX/functions.sh"
	. "$SANDBOX/functions.sh"
}

# The worker reloads the real /etc/init.d scripts and writes to /var/run, so it
# cannot be run as is inside a test. A copy with those three paths rewritten to
# the sandbox runs the real lock logic end to end without touching the host.
build_worker() {
	mkdir -p "$SANDBOX/bin"
	cat > "$SANDBOX/bin/network" <<EOF
#!/bin/sh
echo network >> "$SANDBOX/reload.log"
EOF
	cat > "$SANDBOX/bin/firewall" <<EOF
#!/bin/sh
echo firewall >> "$SANDBOX/reload.log"
EOF
	chmod +x "$SANDBOX/bin/network" "$SANDBOX/bin/firewall"
	sed -e "s#^STATE_FILE=.*#STATE_FILE='$STATE_FILE'#" \
		-e "s#^LOCK_FILE=.*#LOCK_FILE='$LOCK_FILE'#" \
		-e "s#/etc/init.d/network#$SANDBOX/bin/network#g" \
		-e "s#/etc/init.d/firewall#$SANDBOX/bin/firewall#g" \
		"$WORKER" > "$SANDBOX/worker"
	chmod +x "$SANDBOX/worker"
}

STATE_FILE="$STATE_DIR/status"
LOCK_FILE="$STATE_DIR/lock"
LOCK_DIR="$LOCK_FILE.d"
RUN_ID="1234"
load_functions

echo "test: the worker can be started by path"
# tailscale.uc runs it as '/bin/sh -c "/usr/libexec/tailscale-setup-firewall <id> &"'.
# Without the execute bit (git mode 100755) that fails with "Permission denied",
# and because the shell is backgrounded nothing reports it.
check "worker has the execute bit" [ -x "$WORKER" ]

echo "test: plain messages round-trip"
write_state running network "Reloading network"
check "state line" [ "$(sed -n 1p "$STATE_FILE")" = "running" ]
check "step line" [ "$(sed -n 2p "$STATE_FILE")" = "network" ]
check "message line" [ "$(sed -n 3p "$STATE_FILE")" = "Reloading network" ]
check "run id line" [ "$(sed -n 4p "$STATE_FILE")" = "1234" ]

echo "test: backslashes and quotes do not corrupt the file"
write_state failed network 'path C:\temp\foo "quoted"'
check "backslash preserved" [ "$(sed -n 3p "$STATE_FILE")" = 'path C:\temp\foo "quoted"' ]
check "state readable after odd message" [ "$(sed -n 1p "$STATE_FILE")" = "failed" ]

echo "test: a trailing backslash is preserved"
write_state failed firewall 'ends with backslash \'
check "trailing backslash kept" [ "$(sed -n 3p "$STATE_FILE")" = 'ends with backslash \' ]

echo "test: carriage returns are stripped so the line count stays fixed"
write_state running firewall "$(printf 'a\rb')"
check "no carriage return" [ "$(sed -n 3p "$STATE_FILE" | tr -d '\r' | wc -c | tr -d ' ')" = "3" ]
check "still four lines" [ "$(wc -l < "$STATE_FILE" | tr -d ' ')" = "4" ]

echo "test: the file is replaced atomically, never left half written"
check "no temp file left behind" [ ! -e "$STATE_FILE.tmp" ]

echo "test: a message containing a newline does not shift the run id"
write_state failed network "$(printf 'Network reload failed\n    at line two')"
check "the file stays at four lines" [ "$(wc -l < "$STATE_FILE" | tr -d ' ')" = "4" ]
check "the run id stays on the last line" [ "$(tail -n1 "$STATE_FILE")" = "1234" ]

echo "test: lock age recognises a stale holder"
load_functions
LOCK_DIR="$SANDBOX/lockdir"
mkdir -p "$LOCK_DIR"
date +%s > "$LOCK_DIR/ts"
age=$(lock_age)
check "a fresh lock is young" [ "$age" -lt 60 ]

echo "$(( $(date +%s) - 600 ))" > "$LOCK_DIR/ts"
age=$(lock_age)
check "a six hundred second old lock is stale" [ "$age" -gt 300 ]

echo "test: a lock with no timestamp yet is fresh, not stale"
# mkdir wins the race before pid and ts are written. Reading that window as an
# ancient lock is what let two workers reload at the same time.
rm -f "$LOCK_DIR/ts"
age=$(lock_age)
check "missing timestamp counts as just created" [ "$age" -eq 0 ]

# The directory mtime keeps a worker that died before writing ts from leaving a
# lock nobody ever takes over.
touch -d '10 minutes ago' "$LOCK_DIR" 2>/dev/null || true
age=$(lock_age)
check "a lock without ts still ages out through the directory mtime" [ "$age" -gt 300 ]

printf 'not-a-number\n' > "$LOCK_DIR/ts"
touch -d '10 minutes ago' "$LOCK_DIR" 2>/dev/null || true
age=$(lock_age)
check "an unreadable timestamp follows the directory mtime" [ "$age" -gt 300 ]
rm -f "$LOCK_DIR/ts"
touch "$LOCK_DIR"

echo "test: lock holder liveness"
load_functions
not() { ! "$@"; }
LOCK_DIR="$SANDBOX/locklive"
mkdir -p "$LOCK_DIR"
check "no pid file means the holder is gone" not lock_holder_alive
echo $$ > "$LOCK_DIR/pid"
check "the recorded pid is alive" lock_holder_alive
sleep 5 &
DEAD_PID=$!
kill "$DEAD_PID" 2>/dev/null
wait "$DEAD_PID" 2>/dev/null
echo "$DEAD_PID" > "$LOCK_DIR/pid"
check "a reaped pid is gone" not lock_holder_alive
rm -rf "$LOCK_DIR"

echo "test: mkdir makes a second acquisition fail"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
check "mkdir makes a second acquisition fail" sh -c "! mkdir '$LOCK_DIR' 2>/dev/null"
rm -rf "$LOCK_DIR"

echo "test: a lock directory without a timestamp is not stolen"
build_worker
LOCK_DIR="$LOCK_FILE.d"
rm -rf "$LOCK_DIR" "$STATE_FILE" "$SANDBOX/reload.log"
mkdir -p "$LOCK_DIR"
echo $$ > "$LOCK_DIR/pid"
sh "$SANDBOX/worker" raceid
status=$?
check "the second worker exits 0" [ "$status" -eq 0 ]
check "busy state" [ "$(sed -n 1p "$STATE_FILE")" = "busy" ]
check "locked step" [ "$(sed -n 2p "$STATE_FILE")" = "locked" ]
check "busy message" [ "$(sed -n 3p "$STATE_FILE")" = "Another firewall reload is already running" ]
check "the lock is left alone" [ -d "$LOCK_DIR" ]
check "nothing was reloaded" [ ! -e "$SANDBOX/reload.log" ]

echo "test: an old lock held by a live pid is not stolen"
rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
echo $$ > "$LOCK_DIR/pid"
echo "$(( $(date +%s) - 600 ))" > "$LOCK_DIR/ts"
sh "$SANDBOX/worker" liveid
status=$?
check "the second worker exits 0" [ "$status" -eq 0 ]
check "busy state" [ "$(sed -n 1p "$STATE_FILE")" = "busy" ]
check "the lock is left alone" [ -d "$LOCK_DIR" ]
check "nothing was reloaded" [ ! -e "$SANDBOX/reload.log" ]

echo "test: an old lock with a dead pid is taken over"
rm -rf "$LOCK_DIR" "$STATE_FILE" "$SANDBOX/reload.log"
mkdir -p "$LOCK_DIR"
echo "$DEAD_PID" > "$LOCK_DIR/pid"
echo "$(( $(date +%s) - 600 ))" > "$LOCK_DIR/ts"
sh "$SANDBOX/worker" staleid
status=$?
check "the takeover worker exits 0" [ "$status" -eq 0 ]
check "done state" [ "$(sed -n 1p "$STATE_FILE")" = "done" ]
check "done step" [ "$(sed -n 2p "$STATE_FILE")" = "done" ]
check "run id kept" [ "$(sed -n 4p "$STATE_FILE")" = "staleid" ]
check "network was reloaded" grep -qx network "$SANDBOX/reload.log"
check "firewall was reloaded" grep -qx firewall "$SANDBOX/reload.log"
check "the lock is released" [ ! -e "$LOCK_DIR" ]
check "no renamed lock left behind" [ -z "$(ls -d "$LOCK_DIR".stale.* 2>/dev/null)" ]

echo "test: a lock killed before writing its timestamp is taken over once it ages"
rm -rf "$LOCK_DIR" "$STATE_FILE" "$SANDBOX/reload.log"
mkdir -p "$LOCK_DIR"
echo "$DEAD_PID" > "$LOCK_DIR/pid"
touch -d '10 minutes ago' "$LOCK_DIR" 2>/dev/null || true
sh "$SANDBOX/worker" notsid
status=$?
check "the takeover worker exits 0" [ "$status" -eq 0 ]
check "done state" [ "$(sed -n 1p "$STATE_FILE")" = "done" ]
check "run id kept" [ "$(sed -n 4p "$STATE_FILE")" = "notsid" ]
check "network was reloaded" grep -qx network "$SANDBOX/reload.log"
check "the lock is released" [ ! -e "$LOCK_DIR" ]

echo
echo "passed: $passes  failed: $failures"
[ "$failures" -eq 0 ]
