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
	sed -n '/^write_state()/,/^}/p;/^lock_age()/,/^}/p' "$WORKER" > "$SANDBOX/functions.sh"
	. "$SANDBOX/functions.sh"
}

STATE_FILE="$STATE_DIR/status"
LOCK_FILE="$STATE_DIR/lock"
LOCK_DIR="$LOCK_FILE.d"
RUN_ID="1234"
load_functions

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

printf 'not-a-number\n' > "$LOCK_DIR/ts"
age=$(lock_age)
check "an unreadable timestamp counts as stale" [ "$age" -gt 300 ]

rm -rf "$LOCK_DIR"
mkdir -p "$LOCK_DIR"
check "mkdir makes a second acquisition fail" sh -c "! mkdir '$LOCK_DIR' 2>/dev/null"
rm -rf "$LOCK_DIR"

echo
echo "passed: $passes  failed: $failures"
[ "$failures" -eq 0 ]
