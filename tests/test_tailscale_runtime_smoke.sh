#!/bin/sh

set -eu

ROOT_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
UCODE_FILE="$ROOT_DIR/luci-app-tailscale-community/root/usr/share/rpcd/ucode/tailscale.uc"
JS_FILE="$ROOT_DIR/luci-app-tailscale-community/htdocs/luci-static/resources/view/tailscale.js"

[ -f "$UCODE_FILE" ] || {
	echo "missing ucode file"
	exit 1
}

[ -f "$JS_FILE" ] || {
	echo "missing LuCI view file"
	exit 1
}

grep -q "methods.get_runtime" "$UCODE_FILE" || {
	echo "missing get_runtime RPC method"
	exit 1
}

grep -q "methods.get_diagnostics" "$UCODE_FILE" || {
	echo "missing get_diagnostics RPC method"
	exit 1
}

grep -q "callGetRuntime" "$JS_FILE" || {
	echo "missing runtime RPC binding in LuCI"
	exit 1
}

grep -q "callGetDiagnostics" "$JS_FILE" || {
	echo "missing diagnostics RPC binding in LuCI"
	exit 1
}

grep -q "desired/runtime/diagnostics" "$JS_FILE" || {
	echo "missing desired/runtime/diagnostics health section"
	exit 1
}

echo "tailscale runtime smoke test passed"
