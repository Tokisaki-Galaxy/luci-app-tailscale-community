#!/usr/bin/env bash
# Behavioural tests for root/etc/init.d/tailscale-settings.
#
# The script is sourced with the rc.common prologue stripped so the real
# functions run against a throwaway sandbox. Every external call that would
# touch the system (init.d, uci, logger, sleep) is stubbed and recorded, and
# the assertions are about the *sequence* of calls: the bug in issue #80 was
# one unexpected `tailscale start`, not a wrong value.
#
# Run:      bash tests/init/settings-test.sh
# Negative: bash tests/init/settings-test.sh --negative-control
#           Runs the suite against the frozen pre-fix script in
#           fixtures/tailscale-settings.prefix-80 and expects it to fail.
#           A frozen fixture is used on purpose: pointing at origin/master
#           would silently turn into a comparison with the fixed version
#           once this lands.

set -u

REPO_ROOT=$(cd "$(dirname "$0")/../.." && pwd)
FIXTURE_PREFIX="$REPO_ROOT/tests/init/fixtures/tailscale-settings.prefix-80"

# --negative-control runs the same suite against the frozen pre-fix script and
# inverts the exit status: the suite must FAIL there, otherwise it no longer
# guards issue #80.
NEGATIVE=0
if [ "${1:-}" = "--negative-control" ]; then
	NEGATIVE=1
fi

if [ "$NEGATIVE" -eq 1 ]; then
	INIT_SCRIPT="$FIXTURE_PREFIX"
	[ -f "$INIT_SCRIPT" ] || { echo "missing fixture $INIT_SCRIPT" >&2; exit 1; }
	echo "negative control mode: running against the pre-fix script"
else
	INIT_SCRIPT=${SETTINGS_INIT:-"$REPO_ROOT/luci-app-tailscale-community/root/etc/init.d/tailscale-settings"}
fi

[ -f "$INIT_SCRIPT" ] || { echo "cannot find $INIT_SCRIPT" >&2; exit 1; }

if [ -n "${SETTINGS_INIT:-}" ] && [ "$NEGATIVE" -eq 0 ]; then
	echo "custom script under test: $INIT_SCRIPT"
	echo "note: versions that call /etc/init.d/tailscale by absolute path are not fully observable here"
fi

failures=0
pass_count=0
current_test=''

fail() {
	echo "  FAIL [$current_test]: $*"
	failures=$((failures + 1))
}

pass() {
	pass_count=$((pass_count + 1))
}

# --- sandbox -------------------------------------------------------------

SANDBOX=$(mktemp -d)
trap 'remove_abs_stub 2>/dev/null; rm -rf "$SANDBOX"' EXIT

CALLS="$SANDBOX/calls"
UCI_GET_FILE="$SANDBOX/uci"
DAEMON_RUNNING="$SANDBOX/running"

reset_sandbox() {
	: > "$CALLS"
	: > "$UCI_GET_FILE"
	echo 0 > "$DAEMON_RUNNING"
	rm -rf "$SANDBOX/state"
	mkdir -p "$SANDBOX/state"
}

record() {
	echo "$*" >> "$CALLS"
}

# stubs
# CONFIG_STRICT=1 mimics a fresh rc.common shell: config_get only answers with
# its default until config_load tailscale has run, like the real CONFIG_*
# variables. Off by default, so the tests that call the handlers directly keep
# reading the sandbox config without a config_load.
CONFIG_STRICT=0
CONFIG_LOADED=0
config_load() { [ "$1" = tailscale ] && CONFIG_LOADED=1; return 0; }

uci_value() {
	# last assignment wins, like a real uci commit
	grep "^$1=" "$UCI_GET_FILE" | tail -n1 | cut -d= -f2-
}

config_get() {
	local var="$1" section="$2" option="$3" def="${4-}" val=''
	if [ "$CONFIG_STRICT" -ne 1 ] || [ "$CONFIG_LOADED" -eq 1 ]; then
		val=$(uci_value "$section.$option")
	fi
	[ -n "$val" ] || val="$def"
	eval "$var=\$val"
}

config_get_bool() {
	local var="$1" section="$2" option="$3" def="${4-0}" val=''
	if [ "$CONFIG_STRICT" -ne 1 ] || [ "$CONFIG_LOADED" -eq 1 ]; then
		val=$(uci_value "$section.$option")
	fi
	[ -n "$val" ] || val="$def"
	eval "$var=\$val"
}

config_list_foreach() { :; }

logger() { record "logger $*"; }

sleep() { record "sleep"; }

uci() { record "uci $*"; }

mk() {
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

# Versions before this change call /etc/init.d/tailscale by absolute path,
# so the sandbox override alone would leave their lifecycle calls invisible
# and the assertions vacuous. Where /etc is writable (CI containers, WSL as
# root) a recording stub is installed at that path; where it is not, the
# affected tests are skipped loudly instead of passing silently.
AI_ABS=/etc/init.d/tailscale
abs_observable=0

install_abs_stub() {
	if [ -e "$AI_ABS" ]; then
		return 0
	fi
	if [ -d /etc/init.d ] && [ -w /etc/init.d ]; then
		mk "$AI_ABS" tailscale-abs
		abs_observable=1
	fi
}

remove_abs_stub() {
	[ "$abs_observable" = "1" ] && rm -f "$AI_ABS"
	abs_observable=0
}

# --- load the script under test -----------------------------------------

# shellcheck disable=SC1090
. "$INIT_SCRIPT"

# apply_settings resolves the CLI from fixed paths; shadow it for the tests
apply_settings_stub() { record "apply_settings"; }

setup() {
	reset_sandbox
	mk "$SANDBOX/tailscale.init" tailscale
	STATE_DIR="$SANDBOX/state"
	DAEMON_SIG_FILE="$STATE_DIR/daemon"
	ENABLED_FILE="$STATE_DIR/enabled"
	DISABLE_REQUEST_FILE="$STATE_DIR/disable-requested"
	DNS_MODE_FILE="$STATE_DIR/dns_mode"
	TAILSCALE_INIT="$SANDBOX/tailscale.init"
	apply_settings() { apply_settings_stub; }
	install_abs_stub
}

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

set_option() {
	echo "settings.$1=$2" >> "$UCI_GET_FILE"
}

# Source level guard, independent of observable syscalls. The reported bug was
# a `start` reachable from the reload path; assert it is gone.
test_source_never_starts_from_reload() {
	# Every `start` of the daemon in the whole file must sit in the enable
	# path. Scanning the file rather than one function body keeps the guard
	# from being fooled by nested braces or by moving the code.
	local starts bad
	starts=$(grep -nE '^[^#]*[[:space:]]start([[:space:]]|$)' "$INIT_SCRIPT" | grep -vE '^[0-9]+:[[:space:]]*start_service\(\)')
	bad=$(printf '%s\n' "$starts" | grep -vE 'TAILSCALE_INIT"?[[:space:]]+start' | grep -v '^$')
	if [ -z "$bad" ]; then
		pass
	else
		fail "daemon start outside the enable path: $bad"
	fi

	if grep -q 'killall' "$INIT_SCRIPT"; then
		fail "the init script still kills tailscaled by name"
	else
		pass
	fi
}

# --- tests ---------------------------------------------------------------

# The reported scenario itself: a node that already applied its settings once
# and is running, then applies again without changing a daemon option.
# Old code: `tailscale start` -> tailscaled --cleanup -> addresses and table 52
# gone. This is the assertion that guards issue #80.
test_second_apply_leaves_running_daemon_alone() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	set_option fw_mode nftables

	handle_service_state
	: > "$CALLS"

	handle_service_state
	# positive anchor: the reload really did run and did inspect the daemon,
	# so an empty call log can never be mistaken for "nothing happened"
	assert_call "tailscale running"
	assert_call_count "tailscale start" 0
	assert_call_count "tailscale restart" 0
	assert_call_count "tailscale stop" 0
	assert_call "apply_settings"
}

# First apply after an upgrade: no state files at all, daemon up, defaults.
# Old code calls `tailscale start` here too, which is the same corruption.
test_first_apply_without_state_files() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1

	handle_service_state
	# with no state file this must adopt the config, not start anything
	assert_call "tailscale running"
	assert_call_count "tailscale start" 0
	assert_call_count "tailscale restart" 0
	assert_call_count "tailscale stop" 0
	# the baseline is recorded for the next apply
	assert_call "apply_settings"
	if [ "$(cat "$ENABLED_FILE" 2>/dev/null)" = "1" ]; then
		pass
	else
		fail "enabled baseline not adopted"
	fi
}

test_daemon_option_change_restarts_once() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	set_option fw_mode nftables

	handle_service_state
	: > "$CALLS"

	set_option fw_mode iptables
	handle_service_state
	assert_call_count "tailscale restart" 1
	assert_call_count "tailscale start" 0
}

test_apply_never_starts_a_stopped_daemon() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1

	handle_service_state
	: > "$CALLS"

	echo 0 > "$DAEMON_RUNNING"
	handle_service_state
	assert_call_count "tailscale start" 0
	assert_call_count "tailscale restart" 0
}

test_disable_requires_armed_request() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	handle_service_state
	: > "$CALLS"

	# hand edited config, no UI request: keep the tunnel, drop autostart
	set_option service_enabled 0
	handle_service_state
	assert_call_count "tailscale stop" 0
	assert_call "tailscale disable"

	: > "$CALLS"
	echo 1 > "$ENABLED_FILE"
	touch "$DISABLE_REQUEST_FILE"
	set_option service_enabled 0
	handle_service_state
	assert_call "tailscale stop"
	if [ -f "$DISABLE_REQUEST_FILE" ]; then
		fail "disable request should be consumed"
	else
		pass
	fi
}

test_rolled_back_disable_keeps_daemon() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	handle_service_state
	: > "$CALLS"

	# RPC armed the request, user rolled the config back to enabled
	touch "$DISABLE_REQUEST_FILE"
	set_option service_enabled 1
	handle_service_state
	assert_call_count "tailscale stop" 0
	if [ -f "$DISABLE_REQUEST_FILE" ]; then
		fail "stale disable request not cleared"
	else
		pass
	fi
}

test_enable_after_disable_starts() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	handle_service_state

	touch "$DISABLE_REQUEST_FILE"
	set_option service_enabled 0
	handle_service_state
	: > "$CALLS"

	echo 0 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	handle_service_state
	assert_call "tailscale enable"
	assert_call "tailscale start"
}

test_boot_start_service_record_does_not_act() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 0

	start_service
	assert_no_call "tailscale \(start\|stop\|restart\|enable\|disable\)"
	if [ "$(cat "$ENABLED_FILE")" = "0" ]; then pass; else fail "enabled state not recorded"; fi
}

# A manual `disable` in the shell, or a config edited by hand, can leave the
# recorded state saying "enabled" while the daemon is down. The reload handler
# must bring it back: that is the only thing that will.
test_manual_disable_then_enabled_config_starts() {
	setup
	echo 0 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	echo 0 > "$ENABLED_FILE"

	handle_service_state
	assert_call "tailscale enable"
	assert_call "tailscale start"
}

# Boot must not overwrite a state the reload handler is still learning from,
# otherwise a manual `disable` is resurrected by the next `start_service`.
test_boot_keeps_existing_state_record() {
	setup
	echo 0 > "$DAEMON_RUNNING"
	set_option service_enabled 0
	echo 1 > "$ENABLED_FILE"

	start_service
	if [ "$(cat "$ENABLED_FILE")" = "1" ]; then
		pass
	else
		fail "start_service overwrote the recorded state"
	fi
}

# Enabling must not restart a daemon that is already up. Dropping the running
# probe here reintroduces issue #80 through the enable path instead of the
# plain apply path, which is how the first fixed version missed it.
test_enable_does_not_start_a_running_daemon() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	echo 0 > "$ENABLED_FILE"

	handle_service_state
	assert_no_call "tailscale \(start\|restart\|stop\)"
	# the recorded state is corrected without touching the running daemon
	if [ "$(cat "$ENABLED_FILE")" = "1" ]; then
		pass
	else
		fail "recorded state not corrected"
	fi
}

# The dangerous shape: the flag flips to enabled while the daemon is already
# running. A naive implementation reaches the start call from here, which runs
# the upstream `tailscaled --cleanup` against a live daemon. This is how the
# first version reintroduced #80 through the enable path.
test_enable_path_keeps_the_running_probe() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	echo 0 > "$ENABLED_FILE"
	rm -f "$DISABLE_REQUEST_FILE"

	handle_service_state
	assert_call_count "tailscale start" 0
	assert_call_count "tailscale restart" 0
}

# rc.common runs every action in a fresh shell, so when procd's config.change
# trigger calls reload_service nothing has read /etc/config/tailscale yet. The
# handler reads service_enabled and the daemon options itself, so
# reload_service has to load the config first. The tests above call
# handle_service_state directly and cannot see a missing config_load.
fresh_boot() { ( CONFIG_STRICT=1; CONFIG_LOADED=0; start_service ); }
fresh_reload() { ( CONFIG_STRICT=1; CONFIG_LOADED=0; reload_service ); }

# The UI disables the service: request armed, config committed, then reload.
test_reload_service_stops_a_disabled_service() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	fresh_boot
	: > "$CALLS"

	touch "$DISABLE_REQUEST_FILE"
	set_option service_enabled 0
	fresh_reload
	assert_call "tailscale stop"
}

# A service that is disabled and down must stay that way when an unrelated
# option is saved.
test_reload_service_keeps_a_disabled_service_down() {
	setup
	echo 0 > "$DAEMON_RUNNING"
	set_option service_enabled 0
	fresh_boot
	: > "$CALLS"

	set_option hostname lab
	fresh_reload
	assert_call_count "tailscale start" 0
	assert_call_count "tailscale enable" 0
}

# A daemon option that is not at its default must not look like a change.
test_reload_service_nondefault_daemon_option_no_restart() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	set_option port 12345
	fresh_boot
	: > "$CALLS"

	set_option hostname lab
	fresh_reload
	assert_call_count "tailscale restart" 0
}

# ...and a real change of it has to be noticed.
test_reload_service_restarts_on_daemon_option_change() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	fresh_boot
	: > "$CALLS"

	set_option port 23456
	fresh_reload
	assert_call_count "tailscale restart" 1
}

test_missing_tailscale_init_is_tolerated() {
	setup
	TAILSCALE_INIT="$SANDBOX/does-not-exist"
	handle_service_state
	assert_call "apply_settings"
}

test_dns_forward_only_on_transition() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	echo openwrt_forward > "$DNS_MODE_FILE"

	handle_service_state
	: > "$CALLS"
	handle_service_state
	assert_call_count "uci" 0
}

test_dns_forward_survives_switch_to_disabled() {
	setup
	echo 1 > "$DAEMON_RUNNING"
	set_option service_enabled 1
	set_option dns_mode disabled
	echo openwrt_forward > "$DNS_MODE_FILE"

	handle_service_state
	: > "$CALLS"
	set_option dns_mode disabled
	handle_service_state
	assert_call_count "uci del_list" 0
}

# --- run_tailscale_set -----------------------------------------------------
#
# A daemon built without auto-update support (ts_omit_clientupdate) rejects
# every 'tailscale set' while the saved prefs have AutoUpdate.Apply=true. The
# helper resets that flag once and retries, and must leave every other failure
# alone.
#
# The fake CLI answers from a queue, one "<exit code>|<stderr text>" line per
# invocation, and records every call. An invocation beyond the queue fails
# with exit code 99, so an unbounded retry shows up as extra calls instead of
# hanging the suite.
UNSUPPORTED_MSG='Error: Auto-update support is disabled in this build'

mk_fake_tailscale() {
	TS_FAKE="$SANDBOX/tailscale"
	TS_REPLIES="$SANDBOX/ts-replies"
	TS_STDERR="$SANDBOX/ts-stderr"
	: > "$TS_REPLIES"
	cat > "$TS_FAKE" <<EOF
#!/bin/sh
echo "tailscale \$*" >> "$CALLS"
reply=\$(head -n1 "$TS_REPLIES")
[ -n "\$reply" ] || reply='99|unexpected extra tailscale call'
tail -n +2 "$TS_REPLIES" > "$TS_REPLIES.next"
mv "$TS_REPLIES.next" "$TS_REPLIES"
msg=\${reply#*|}
[ -z "\$msg" ] || echo "\$msg" >&2
exit "\${reply%%|*}"
EOF
	chmod +x "$TS_FAKE"
}

ts_reply() {
	echo "$1|$2" >> "$TS_REPLIES"
}

# Sets rc; whatever the helper writes to stderr ends up in $TS_STDERR.
run_set() {
	run_tailscale_set "$TS_FAKE" set --accept-routes=true 2> "$TS_STDERR"
	rc=$?
}

assert_rc() {
	if [ "$rc" = "$1" ]; then
		pass
	else
		fail "exit code: want $1, got $rc"
	fi
}

assert_ts_calls() {
	local want="$1" got
	got=$(calls | grep '^tailscale ')
	if [ "$got" = "$want" ]; then
		pass
	else
		fail "tailscale calls: want [$(printf '%s' "$want" | tr '\n' ';')], got [$(printf '%s' "$got" | tr '\n' ';')]"
	fi
}

assert_stderr_has() {
	if grep -qF -- "$1" "$TS_STDERR"; then
		pass
	else
		fail "stderr lacks '$1', got: $(tr '\n' ';' < "$TS_STDERR")"
	fi
}

assert_stderr_lacks() {
	if grep -qF -- "$1" "$TS_STDERR"; then
		fail "stderr unexpectedly has '$1'"
	else
		pass
	fi
}

test_set_success_runs_once_without_reset() {
	setup
	mk_fake_tailscale
	ts_reply 0 ''

	run_set
	assert_rc 0
	assert_ts_calls "tailscale set --accept-routes=true"
	assert_no_call "logger"
}

# The reported bug: reset the flag, then apply the very same arguments again.
test_set_unsupported_auto_update_resets_and_retries() {
	setup
	mk_fake_tailscale
	ts_reply 1 "$UNSUPPORTED_MSG"
	ts_reply 0 ''
	ts_reply 0 ''

	run_set
	assert_rc 0
	assert_ts_calls "tailscale set --accept-routes=true
tailscale set --auto-update=false
tailscale set --accept-routes=true"
	assert_call "logger .*resetting it"
	# the first attempt was recovered from, so its error must not leak out
	assert_stderr_lacks "Auto-update support is disabled"
}

# Any other failure is not ours to fix: no reset, same exit code, same message.
test_set_other_failure_is_left_alone() {
	setup
	mk_fake_tailscale
	ts_reply 7 'failed to connect to local tailscaled'

	run_set
	assert_rc 7
	assert_ts_calls "tailscale set --accept-routes=true"
	assert_stderr_has "failed to connect to local tailscaled"
}

# When the reset itself fails there is nothing to retry: report the original error.
test_set_failed_reset_skips_retry() {
	setup
	mk_fake_tailscale
	ts_reply 1 "$UNSUPPORTED_MSG"
	ts_reply 1 'reset failed'

	run_set
	assert_rc 1
	assert_ts_calls "tailscale set --accept-routes=true
tailscale set --auto-update=false"
	assert_stderr_has "Auto-update support is disabled in this build"
	assert_call "logger .*Failed to reset auto-update"
}

# One retry only: a second rejection is returned as is, never reset in a loop.
test_set_retry_is_bounded() {
	setup
	mk_fake_tailscale
	ts_reply 1 "$UNSUPPORTED_MSG"
	ts_reply 0 ''
	ts_reply 1 "$UNSUPPORTED_MSG"

	run_set
	assert_rc 1
	assert_ts_calls "tailscale set --accept-routes=true
tailscale set --auto-update=false
tailscale set --accept-routes=true"
	assert_stderr_has "Auto-update support is disabled in this build"
}

# The message alone is not enough, the command has to have failed.
test_set_message_on_success_is_ignored() {
	setup
	mk_fake_tailscale
	ts_reply 0 "$UNSUPPORTED_MSG"

	run_set
	assert_rc 0
	assert_ts_calls "tailscale set --accept-routes=true"
}

# The caller gets the exit code and message of the retry, not of the first try.
test_set_reports_the_retry_result() {
	setup
	mk_fake_tailscale
	ts_reply 1 "$UNSUPPORTED_MSG"
	ts_reply 0 ''
	ts_reply 3 'some other error'

	run_set
	assert_rc 3
	assert_stderr_has "some other error"
	assert_stderr_lacks "Auto-update support is disabled"
}

# --- apply_settings and a daemon that is not running -----------------------
#
# apply_settings resolves the CLI from fixed paths, so it is run from a copy of
# the script whose CLI paths point at the fake CLI.
load_apply_settings() {
	sed -e "s|/usr/sbin/tailscale|$TS_FAKE|g" \
	    -e "s|/usr/bin/tailscale|$TS_FAKE|g" "$INIT_SCRIPT" > "$SANDBOX/init-fake-cli"
	# shellcheck disable=SC1090,SC1091
	. "$SANDBOX/init-fake-cli"
	# sourcing put the production defaults back
	STATE_DIR="$SANDBOX/state"
	DAEMON_SIG_FILE="$STATE_DIR/daemon"
	ENABLED_FILE="$STATE_DIR/enabled"
	DISABLE_REQUEST_FILE="$STATE_DIR/disable-requested"
	DNS_MODE_FILE="$STATE_DIR/dns_mode"
	TAILSCALE_INIT="$SANDBOX/tailscale.init"
}

# Boot with the service disabled: the autostart link is gone, the daemon is not
# running and `tailscale set` could only wait and fail.
test_apply_settings_skips_set_when_daemon_not_running() {
	setup
	mk_fake_tailscale
	load_apply_settings
	echo 0 > "$DAEMON_RUNNING"

	apply_settings
	rc=$?
	assert_rc 0
	# positive anchor: the daemon really was probed
	assert_call "tailscale running"
	assert_no_call "tailscale set"
	assert_call "logger .*skip applying settings"
}

# The normal case: the daemon is up, so the settings are applied as before.
test_apply_settings_runs_set_when_daemon_running() {
	setup
	mk_fake_tailscale
	load_apply_settings
	echo 1 > "$DAEMON_RUNNING"
	ts_reply 0 ''
	ts_reply 0 ''

	apply_settings
	rc=$?
	assert_rc 0
	assert_call "tailscale set"
	assert_no_call "skip applying settings"
}

# Without the init script the daemon cannot be probed, so keep applying.
test_apply_settings_runs_set_without_init_script() {
	setup
	mk_fake_tailscale
	load_apply_settings
	TAILSCALE_INIT="$SANDBOX/does-not-exist"
	ts_reply 0 ''
	ts_reply 0 ''

	apply_settings
	rc=$?
	assert_rc 0
	assert_call "tailscale set"
}

# apply_settings resolves the CLI from fixed paths, so the call site cannot be
# exercised from here. Guard it at source level instead.
test_source_apply_settings_uses_the_helper() {
	if grep -qE '^[[:space:]]*run_tailscale_set "\$ts_bin" "\$@"' "$INIT_SCRIPT"; then
		pass
	else
		fail "apply_settings does not call run_tailscale_set"
	fi

	if grep -qE '^[[:space:]]*"\$ts_bin" "\$@"' "$INIT_SCRIPT"; then
		fail "a bare tailscale call bypasses run_tailscale_set"
	else
		pass
	fi
}

# Some older versions call /etc/init.d/tailscale by absolute path and cannot
# be observed. Those are skipped in negative-control mode so a red test always
# means "the suite caught something", never "the harness could not see it".
skipped=0
for t in \
	test_source_never_starts_from_reload \
	test_second_apply_leaves_running_daemon_alone \
	test_first_apply_without_state_files \
	test_daemon_option_change_restarts_once \
	test_apply_never_starts_a_stopped_daemon \
	test_disable_requires_armed_request \
	test_rolled_back_disable_keeps_daemon \
	test_enable_after_disable_starts \
	test_boot_start_service_record_does_not_act \
	test_manual_disable_then_enabled_config_starts \
	test_boot_keeps_existing_state_record \
	test_enable_does_not_start_a_running_daemon \
	test_reload_service_stops_a_disabled_service \
	test_reload_service_keeps_a_disabled_service_down \
	test_reload_service_nondefault_daemon_option_no_restart \
	test_reload_service_restarts_on_daemon_option_change \
	test_missing_tailscale_init_is_tolerated \
	test_dns_forward_only_on_transition \
	test_dns_forward_survives_switch_to_disabled \
	test_set_success_runs_once_without_reset \
	test_set_unsupported_auto_update_resets_and_retries \
	test_set_other_failure_is_left_alone \
	test_set_failed_reset_skips_retry \
	test_set_retry_is_bounded \
	test_set_message_on_success_is_ignored \
	test_set_reports_the_retry_result \
	test_apply_settings_skips_set_when_daemon_not_running \
	test_apply_settings_runs_set_when_daemon_running \
	test_apply_settings_runs_set_without_init_script \
	test_source_apply_settings_uses_the_helper
do
	if [ -n "${SETTINGS_INIT:-}" ] && [ "$t" = "test_enable_after_disable_starts" ] && [ "$abs_observable" -eq 0 ]; then
		echo "skip: $t (absolute init path not observable here)"
		skipped=$((skipped + 1))
		continue
	fi
	# The frozen pre-fix script predates run_tailscale_set, so these tests would
	# fail there for a reason unrelated to issue #80.
	# It also loads the config inside handle_service_state and calls the daemon
	# init by absolute path, so the reload_service tests cannot be evaluated
	# against it.
	if [ "$NEGATIVE" -eq 1 ]; then
		case "$t" in
			test_apply_settings_*)
				echo "skip: $t (not about issue #80)"
				skipped=$((skipped + 1))
				continue
				;;
			test_set_*|test_source_apply_settings_uses_the_helper)
				echo "skip: $t (the pre-fix script predates run_tailscale_set)"
				skipped=$((skipped + 1))
				continue
				;;
			test_reload_service_*)
				echo "skip: $t (the pre-fix script loads the config itself and is not observable here)"
				skipped=$((skipped + 1))
				continue
				;;
		esac
	fi
	current_test="$t"
	echo "test: $t"
	$t
done

echo
echo "passed: $pass_count  failed: $failures  skipped: $skipped"
remove_abs_stub

if [ "$NEGATIVE" -eq 1 ]; then
	if [ "$failures" -eq 0 ]; then
		echo "NEGATIVE CONTROL FAILED: the suite passes against the pre-fix script"
		exit 1
	fi
	echo "negative control ok: the suite fails against the pre-fix script as expected"
	exit 0
fi

[ "$failures" -eq 0 ]
