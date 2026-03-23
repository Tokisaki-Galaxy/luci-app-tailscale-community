#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
LIB="$ROOT_DIR/luci-app-tailscale-community/root/usr/libexec/tailscale-settings-lib.sh"

[ -f "$LIB" ] || {
	echo "missing tailscale settings library: $LIB"
	exit 1
}

. "$LIB"

assert_contains() {
	case "$1" in
		*"$2"*) ;;
		*)
			echo "expected to find '$2' in: $1"
			exit 1
			;;
	esac
}

assert_not_contains() {
	case "$1" in
		*"$2"*)
			echo "did not expect to find '$2' in: $1"
			exit 1
			;;
		*) ;;
	esac
}

desired_accept_routes=1
runtime_accept_routes=1
desired_advertise_exit_node=0
runtime_advertise_exit_node=0
desired_advertise_routes='192.168.11.0/24'
runtime_advertise_routes=''
desired_exit_node=''
runtime_exit_node=''
desired_exit_node_allow_lan_access=0
runtime_exit_node_allow_lan_access=0
desired_nosnat=0
runtime_nosnat=0
desired_disable_magic_dns=1
runtime_disable_magic_dns=1
desired_login_server='https://headscale.example.com'
runtime_login_server='https://headscale.example.com'

ts_should_reset || {
	echo "expected reset-worthy advertise_routes mismatch to require up --reset"
	exit 1
}

desired_advertise_routes='192.168.11.0/24'
runtime_advertise_routes='192.168.11.0/24'
desired_ssh=1
runtime_ssh=0

if ts_should_reset; then
	echo "expected ssh-only mismatch to stay on tailscale set"
	exit 1
fi

desired_accept_routes=1
desired_advertise_exit_node=0
desired_advertise_routes='192.168.11.0/24'
desired_exit_node=''
desired_exit_node_allow_lan_access=0
desired_ssh=1
desired_disable_magic_dns=1
desired_shields_up=0
desired_runwebclient=0
desired_nosnat=0
desired_hostname='openwrt-router'
desired_enable_relay=1
desired_relay_server_port='40000'
desired_login_server='https://headscale.example.com'
runtime_login_server='https://headscale.example.com'

up_args="$(ts_build_up_reset_args)"
assert_contains "$up_args" 'up'
assert_contains "$up_args" '--reset'
assert_contains "$up_args" '--login-server=https://headscale.example.com'
assert_contains "$up_args" '--accept-routes=true'
assert_contains "$up_args" '--accept-dns=false'
assert_contains "$up_args" '--advertise-routes=192.168.11.0/24'
assert_contains "$up_args" '--hostname=openwrt-router'
assert_contains "$up_args" '--ssh=true'
assert_not_contains "$up_args" '--auth-key'

diag_logged_in=1
diag_self_active=1
diag_self_in_engine=1
diag_ts_ip4='100.64.0.5'
diag_peer_route_status='ok'
diag_table_route_count=0
diag_peer_candidate='100.64.0.27'

health_result="$(ts_compute_health)"
assert_contains "$health_result" 'health=ok'
assert_contains "$health_result" 'reason=ok'

diag_peer_route_status='wan'
health_result="$(ts_compute_health)"
assert_contains "$health_result" 'health=fail'
assert_contains "$health_result" 'reason=peer_route_via_wan'

echo "tailscale settings behavior test passed"
