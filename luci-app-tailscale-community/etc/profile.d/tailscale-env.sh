#!/bin/sh
# This script is managed by luci-app-tailscale-community.
uci_get_state() { uci get tailscale.settings."$1" 2>/dev/null; }
if [ "$(uci_get_state daemon_reduce_memory)" = "1" ]; then export GOGC=10; fi
TS_MTU=$(uci_get_state daemon_mtu)
if [ -n "$TS_MTU" ]; then export TS_DEBUG_MTU="$TS_MTU"; fi
