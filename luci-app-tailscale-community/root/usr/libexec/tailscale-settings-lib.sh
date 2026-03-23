#!/bin/sh

ts_bool_cli() {
	[ "${1:-0}" = "1" ] && printf 'true' || printf 'false'
}

ts_print_arg() {
	printf '%s\n' "$1"
}

ts_trim() {
	printf '%s' "${1:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

ts_normalize_csv() {
	printf '%s' "${1:-}" \
		| tr ',' '\n' \
		| sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
		| awk 'NF { print }' \
		| sort -u \
		| paste -sd',' -
}

ts_first_nonempty() {
	while [ "$#" -gt 0 ]; do
		if [ -n "${1:-}" ]; then
			printf '%s' "$1"
			return 0
		fi
		shift
	done

	return 1
}

ts_should_reset() {
	[ "${desired_accept_routes:-0}" != "${runtime_accept_routes:-0}" ] && return 0
	[ "${desired_advertise_exit_node:-0}" != "${runtime_advertise_exit_node:-0}" ] && return 0
	[ "$(ts_normalize_csv "${desired_advertise_routes:-}")" != "$(ts_normalize_csv "${runtime_advertise_routes:-}")" ] && return 0
	[ "${desired_exit_node:-}" != "${runtime_exit_node:-}" ] && return 0
	[ "${desired_exit_node_allow_lan_access:-0}" != "${runtime_exit_node_allow_lan_access:-0}" ] && return 0
	[ "${desired_nosnat:-0}" != "${runtime_nosnat:-0}" ] && return 0
	[ "${desired_disable_magic_dns:-0}" != "${runtime_disable_magic_dns:-0}" ] && return 0
	[ "${desired_login_server:-}" != "${runtime_login_server:-}" ] && return 0

	return 1
}

ts_build_up_reset_args() {
	local routes login_server

	routes="$(ts_normalize_csv "${desired_advertise_routes:-}")"
	login_server="$(ts_first_nonempty "${desired_login_server:-}" "${runtime_login_server:-}" 2>/dev/null || true)"

	ts_print_arg 'up'
	ts_print_arg '--reset'
	ts_print_arg "--accept-routes=$(ts_bool_cli "${desired_accept_routes:-0}")"
	ts_print_arg "--advertise-exit-node=$(ts_bool_cli "${desired_advertise_exit_node:-0}")"
	ts_print_arg "--advertise-routes=$routes"
	ts_print_arg "--exit-node=${desired_exit_node:-}"
	ts_print_arg "--exit-node-allow-lan-access=$(ts_bool_cli "${desired_exit_node_allow_lan_access:-0}")"
	ts_print_arg "--accept-dns=$(ts_bool_cli "$( [ "${desired_disable_magic_dns:-0}" = "1" ] && printf 0 || printf 1 )")"
	ts_print_arg "--snat-subnet-routes=$(ts_bool_cli "$( [ "${desired_nosnat:-0}" = "1" ] && printf 0 || printf 1 )")"
	ts_print_arg "--ssh=$(ts_bool_cli "${desired_ssh:-0}")"
	ts_print_arg "--shields-up=$(ts_bool_cli "${desired_shields_up:-0}")"
	ts_print_arg "--webclient=$(ts_bool_cli "${desired_runwebclient:-0}")"

	if [ -n "${desired_hostname:-}" ]; then
		ts_print_arg "--hostname=${desired_hostname}"
	fi

	if [ -n "$login_server" ]; then
		ts_print_arg "--login-server=$login_server"
	fi

	if [ "${ts_supports_relay_server_port:-1}" = "1" ]; then
		if [ "${desired_enable_relay:-0}" = "1" ]; then
			ts_print_arg "--relay-server-port=${desired_relay_server_port:-40000}"
		else
			ts_print_arg '--relay-server-port='
		fi
	fi
}

ts_build_set_args() {
	ts_print_arg 'set'
	ts_print_arg "--ssh=$(ts_bool_cli "${desired_ssh:-0}")"
	ts_print_arg "--shields-up=$(ts_bool_cli "${desired_shields_up:-0}")"
	ts_print_arg "--webclient=$(ts_bool_cli "${desired_runwebclient:-0}")"

	if [ -n "${desired_hostname:-}" ]; then
		ts_print_arg "--hostname=${desired_hostname}"
	fi

	if [ "${ts_supports_relay_server_port:-1}" = "1" ]; then
		if [ "${desired_enable_relay:-0}" = "1" ]; then
			ts_print_arg "--relay-server-port=${desired_relay_server_port:-40000}"
		else
			ts_print_arg '--relay-server-port='
		fi
	fi
}

ts_compute_health() {
	if [ "${diag_logged_in:-0}" != "1" ]; then
		printf 'health=warn reason=not_logged_in'
		return 0
	fi

	if [ -z "${diag_ts_ip4:-}" ] || [ "${diag_ts_ip4:-}" = "No IP assigned" ]; then
		printf 'health=warn reason=no_tailscale_ip'
		return 0
	fi

	if [ "${diag_self_active:-0}" != "1" ] || [ "${diag_self_in_engine:-0}" != "1" ]; then
		printf 'health=fail reason=runtime_mismatch'
		return 0
	fi

	case "${diag_peer_route_status:-unavailable}" in
		ok)
			printf 'health=ok reason=ok'
			return 0
			;;
		wan)
			printf 'health=fail reason=peer_route_via_wan'
			return 0
			;;
		unavailable)
			printf 'health=warn reason=no_peer'
			return 0
			;;
	esac

	printf 'health=warn reason=%s' "${diag_peer_route_status:-unknown}"
}
