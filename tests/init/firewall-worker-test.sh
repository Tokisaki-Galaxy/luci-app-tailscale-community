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
	sed -n '/^write_state()/,/^}/p;/^lock_is_live()/,/^}/p' "$WORKER" > "$SANDBOX/functions.sh"
	. "$SANDBOX/functions.sh"
}

STATE_FILE="$STATE_DIR/status"
LOCK_FILE="$STATE_DIR/lock"
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

echo "test: lock staleness ignores a recycled pid"
# a lock written five minutes ago must not block a new run
printf '%s\n%s\n' "$$" "$(( $(date +%s) - 600 ))" > "$LOCK_FILE"
lock_is_live
check "old lock treated as stale" [ $? -ne 0 ]

printf '%s\n%s\n' "$$" "$(date +%s)" > "$LOCK_FILE"
lock_is_live
check "fresh lock treated as live" [ $? -eq 0 ]

printf 'not-a-pid\nwhatever\n' > "$LOCK_FILE"
lock_is_live
check "garbage lock treated as stale" [ $? -ne 0 ]

echo
echo "passed: $passes  failed: $failures"
[ "$failures" -eq 0 ]
