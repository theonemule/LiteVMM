#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'pkill -P $$ sleep 2>/dev/null || true; rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/replicas" "$T/jobs" "$T/receivers" "$T/run"
cat > "$T/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
set -e
case "$1" in
  create) file=${4}; : > "$file";;
  info) echo '{"virtual-size":1048576}';;
  *) exit 0;;
esac
SH
cat > "$T/bin/qemu-nbd" <<'SH'
#!/usr/bin/env bash
set -e
pidfile=''
for a in "$@"; do case "$a" in --pid-file=*) pidfile=${a#*=};; esac; done
file=${!#}; bash -c 'exec -a "$1" sleep 300' _ "$file" >/dev/null 2>&1 & echo $! > "$pidfile"
SH
cat > "$T/bin/gost" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 300 & wait $!; done
SH
chmod +x "$T/bin/"*
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" QEMU_IMG="$T/bin/qemu-img" QEMU_NBD="$T/bin/qemu-nbd" VMAPI_GOST="$T/bin/gost" REPLICA_ROOT="$T/replicas" VMAPI_REPLICATION_JOB_ROOT="$T/jobs" VMAPI_REPLICATION_RECEIVER_ROOT="$T/receivers" VMAPI_REPLICATION_RUN_ROOT="$T/run" VMAPI_REPLICATION_WEB_MODE=none VMAPI_REPLICATION_SKIP_PORT_WAIT=true)
out=$(env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-create peer-user demo 0 1048576)
id=$(printf '%s' "$out" | sed -n 's/.*"id":"\([a-f0-9]*\)".*/\1/p')
[[ ${#id} -eq 24 ]]
[[ -f "$T/replicas/peer-user/demo/disk0.qcow2" ]]
show=$(env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-show "$id")
[[ $show == *'"nbd_running":true'* && $show == *'"websocket_running":true'* ]]
# Simulate a host/service restart. The persisted receiver definition must recreate both processes.
source "$T/receivers/$id.conf"
kill "$(cat "$GOST_PID_FILE")" "$(cat "$NBD_PID_FILE")" 2>/dev/null || true
sleep .1
show=$(env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-start "$id")
[[ $show == *'"nbd_running":true'* && $show == *'"websocket_running":true'* ]]
env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-delete "$id" >/dev/null
[[ -f "$T/receivers/$id.conf" ]]
[[ -f "$T/replicas/peer-user/demo/disk0.qcow2" ]]
show=$(env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-show "$id")
[[ $show == *'"active":false'* && $show == *'"nbd_running":false'* && $show == *'"websocket_running":false'* ]]
if env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-start "$id" >/dev/null 2>&1; then echo 'expected inactive receiver restart to fail' >&2; exit 1; fi
# A new replication for the same peer/VM/disk reuses the retained replica file
# while replacing the inactive transport metadata.
out2=$(env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-create peer-user demo 0 1048576)
id2=$(printf '%s' "$out2" | sed -n 's/.*"id":"\([a-f0-9]*\)".*/\1/p')
[[ ${#id2} -eq 24 && $id2 != "$id" ]]
[[ ! -f "$T/receivers/$id.conf" && -f "$T/receivers/$id2.conf" ]]
env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-delete "$id2" >/dev/null
env "${common[@]}" bash "$ROOT/bin/replicationctl" receiver-purge "$id2" true >/dev/null
[[ ! -f "$T/receivers/$id2.conf" && ! -f "$T/replicas/peer-user/demo/disk0.qcow2" ]]
echo 'replication receiver retention lifecycle: PASS'
