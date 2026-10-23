#!/usr/bin/env bash
# Behavioural tests for root/etc/init.d/tailscale-settings.
#
# The script is sourced with the rc.common prologue stripped so the real
# functions run against a throwaway sandbox. Every external call that would
# touch the system (init.d, uci, logger, sleep, tailscale) is stubbed and
# recorded, and the assertions are about the *sequence* of calls, because the
# bug in issue #80 was an unexpected call, not a wrong value.
#
# Run: bash tests/init/settings-test.sh

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
INIT_SCRIPT="$REPO_ROOT/luci-app-tailscale-community/root/etc/init.d/tailscale-settings"

[ -f "$INIT_SCRIPT" ] || { echo "cannot find $INIT_SCRIPT" >&2; exit 1; }

failures=0
pass_count=0

fail() {
	echo "  FAIL: $*"
	failures=$((failures + 1))
}

pass() {
	pass_count=$((pass_count + 1))
}

# --- sandbox -------------------------------------------------------------

SANDBOX=$(mktemp -d)
trap 'rm -rf "$SANDBOX"' EXIT

CALLS="$SANDBOX/calls"
UCI_GET_FILE="$SANDBOX/uci"
DAEMON_RUNNING="$SANDBOX/running"
LOG="$SANDBOX/log"

reset_sandbox() {
	: > "$CALLS"
	: > "$UCI_GET_FILE"
	: > "$LOG"
	echo 0 > "$DAEMON_RUNNING"
	rm -rf "$SANDBOX/state"
}

record() {
	echo "$*" >> "$CALLS"
}

# stubs
config_load() { :; }

config_get() {
	# config_get <var> <section> <option> <default>
	local var="$1" section="$2" option="$3" def="${4-}" val
	val=$(grep "^$section.$option=" "$UCI_GET_FILE" | tail -n1 | cut -d= -f2-)
	[ -n "$val" ] || val="$def"
	eval "$var=\$val"
}

config_get_bool() {
	local var="$1" section="$2" option="$3" def="${4-0}" val
	val=$(grep "^$section.$option=" "$UCI_GET_FILE" | tail -n1 | cut -d= -f2-)
	[ -n "$val" ] || val="$def"
	eval "$var=\$val"
}

config_list_foreach() { :; }

logger() { record "logger $*"; }

sleep() { :; }

uci() { record "uci $*"; }

mk() {
	# create a fake init script that records which action was used
	local path="$1" name="$2"
	cat > "$path" <<EOF
#!/bin/sh
echo "$name \$1" >> "$CALLS"
case "\$1" in
	running) [ "\$(cat "$DAEMON_RUNNING")" = "1" ] ;;
esac
EOF
	chmod +x "$path"
}

# --- load the script under test -----------------------------------------

# shellcheck disable=SC1090
. "$INIT_SCRIPT"

setup() {
	reset_sandbox
	mk "$SANDBOX/tailscale.init" tailscale
	mk "$SANDBOX/tailscale.cli" tailscale-cli
	# redirect state and binaries into the sandbox
	STATE_DIR="$SANDBOX/state"
	DAEMON_SIG_FILE="$STATE_DIR/daemon"
	ENABLED_FILE="$STATE_DIR/enabled"
	DNS_MODE_FILE="$STATE_DIR/dns_mode"
	TAILSCALE_INIT="$SANDBOX/tailscale.init"
	mkdir -p "$STATE_DIR"
}

# apply_settings resolves the CLI from fixed paths; shadow it for the tests
apply_settings_stub() { record "apply_settings"; }

calls() { cat "$CALLS"; }

assert_no_call() {
	local pattern="$1"
	if calls | grep -q "$pattern"; then
		fail "unexpected call matching '$pattern': $(calls | grep "$pattern" | tr '\n' ';')"
	else
		pass
	fi
}

assert_call() {
	local pattern="$1"
	if calls | grep -q "$pattern"; then
		pass
	else
		fail "missing expected call matching '$pattern', got: $(calls | tr '\n' ';')"
	fi
}

assert_call_count() {
	local pattern="$1" want="$2" got
	got=$(calls | grep -c "$pattern")
	if [ "$got" = "$want" ]; then
		pass
	else
		fail "expected $want call(s) matching '$pattern', got $got"
	fi
}

# --- tests ---------------------------------------------------------------



test_apply_does_not_touch_running_daemon() {
	echo "test: a plain re-apply leaves a running daemon alone"
	setup
	apply_settings() { apply_settings_stub; }
	echo 1 > "$DAEMON_RUNNING"
	echo "settings.service_enabled=1" >> "$UCI_GET_FILE"
	echo "settings.fw_mode=nftables" >> "$UCI_GET_FILE"

	# first apply records the baseline signature
	handle_service_state
	: > "$CALLS"

	# second apply with identical config must not start/stop/restart
	handle_service_state
	assert_no_call "tailscale \(start\|stop\|restart\)"
	assert_call "apply_settings"
}

test_daemon_option_change_restarts_once() {
	echo "test: changing a daemon-level option restarts exactly once"
	setup
	apply_settings() { apply_settings_stub; }
	echo 1 > "$DAEMON_RUNNING"
	echo "settings.service_enabled=1" >> "$UCI_GET_FILE"
	echo "settings.fw_mode=nftables" >> "$UCI_GET_FILE"

	handle_service_state
	: > "$CALLS"

	echo "settings.fw_mode=iptables" >> "$UCI_GET_FILE"
	handle_service_state
	assert_call_count "tailscale restart" 1
	assert_no_call "tailscale start"
}

test_stopped_daemon_is_not_started_by_reload() {
	echo "test: apply never starts a daemon that is down"
	setup
	apply_settings() { apply_settings_stub; }
	echo 1 > "$DAEMON_RUNNING"
	echo "settings.service_enabled=1" >> "$UCI_GET_FILE"

	# baseline: the first apply records the enabled state
	handle_service_state
	: > "$CALLS"

	echo 0 > "$DAEMON_RUNNING"
	handle_service_state
	assert_no_call "tailscale \(start\|restart\)"
}

test_disable_stops_once() {
	echo "test: service_enabled=0 stops the daemon on transition only"
	setup
	apply_settings() { apply_settings_stub; }
	echo 1 > "$DAEMON_RUNNING"
	echo "settings.service_enabled=1" >> "$UCI_GET_FILE"

	handle_service_state
	: > "$CALLS"

	echo "settings.service_enabled=0" >> "$UCI_GET_FILE"
	handle_service_state
	assert_call "tailscale stop"
	assert_call "tailscale disable"
	assert_no_call "tailscale \(start\|restart\|enable\)"

	: > "$CALLS"
	handle_service_state
	assert_no_call "tailscale \(start\|stop\|enable\|disable\)"
}

test_enable_after_disable_starts() {
	echo "test: re-enabling brings the service back"
	setup
	apply_settings() { apply_settings_stub; }
	echo 0 > "$DAEMON_RUNNING"
	echo "settings.service_enabled=1" >> "$UCI_GET_FILE"
	handle_service_state
	: > "$CALLS"

	echo "settings.service_enabled=0" >> "$UCI_GET_FILE"
	handle_service_state
	: > "$CALLS"

	echo "settings.service_enabled=1" >> "$UCI_GET_FILE"
	handle_service_state
	assert_call "tailscale enable"
	assert_call "tailscale start"
}

test_boot_start_service_record_does_not_act() {
	echo "test: start_service only records state at boot"
	setup
	apply_settings() { apply_settings_stub; }
	echo 1 > "$DAEMON_RUNNING"
	echo "settings.service_enabled=0" >> "$UCI_GET_FILE"

	start_service
	assert_no_call "tailscale \(start\|stop\|restart\|enable\|disable\)"
	if [ "$(cat "$ENABLED_FILE")" = "0" ]; then pass; else fail "enabled state not recorded"; fi
}

test_missing_tailscale_init_is_tolerated() {
	echo "test: a missing tailscale init script does not abort the apply"
	setup
	apply_settings() { apply_settings_stub; }
	TAILSCALE_INIT="$SANDBOX/does-not-exist"
	handle_service_state
	assert_call "apply_settings"
}

for t in \
	test_apply_does_not_touch_running_daemon \
	test_daemon_option_change_restarts_once \
	test_stopped_daemon_is_not_started_by_reload \
	test_disable_stops_once \
	test_enable_after_disable_starts \
	test_boot_start_service_record_does_not_act \
	test_missing_tailscale_init_is_tolerated
do
	$t
done

echo
echo "passed: $pass_count  failed: $failures"
[ "$failures" -eq 0 ]
