#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# Load controller functions without dispatching a CLI command.
VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" source <(sed '/^case ${1:-help} in/,$d' "$ROOT/bin/replicationctl")
qmp(){
  cat <<'JSON'
{"QMP":{"version":{"qemu":{"major":10,"minor":2,"micro":1}}}}
{"return":{}}
{"return": [{"auto-finalize": true, "io-status": "ok", "device": "repl-0", "auto-dismiss": true, "busy": false, "len": 33554432, "offset": 33554432, "status": "ready", "paused": false, "speed": 0, "ready": true, "type": "mirror"}]}
JSON
}
obj=$(query_job_json demo repl-0)
[[ $obj == *'"device":"repl-0"'* ]]
[[ $obj == *'"ready":true'* ]]
offset=$(printf '%s' "$obj" | sed -n 's/.*"offset":\([0-9][0-9]*\).*/\1/p' | head -n1)
len=$(printf '%s' "$obj" | sed -n 's/.*"len":\([0-9][0-9]*\).*/\1/p' | head -n1)
[[ $offset == 33554432 && $len == 33554432 ]]
echo 'replication QMP JSON parsing: PASS'
