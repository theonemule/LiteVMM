#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
OWNER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$T/backplane/peers/$OWNER/replicas/demo"
FILE="$T/backplane/peers/$OWNER/replicas/demo/disk0.qcow2"
META="$T/backplane/peers/$OWNER/replicas/demo/disk0.meta"
truncate -s 1048576 "$FILE"
cat > "$META" <<META
OWNER=$OWNER
VM=demo
DISK_INDEX=0
BYTES=1048576
FILE_NAME=disk0.qcow2
ACTIVE=true
UPDATED=$(date +%s)
META
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_BACKPLANE_ROOT="$T/backplane" VMAPI_REPLICATION_STALE_SECONDS=45)
out=$(env "${common[@]}" bash "$ROOT/bin/replicationctl" replica-list)
[[ $out == *'"vm":"demo"'* && $out == *'"active":true'* && $out == *'"backplane":true'* ]]
id=$(printf '%s' "$OWNER/demo/0" | sha256sum | cut -c1-24)
sleep 1
sed -i 's/^ACTIVE=true/ACTIVE=false/' "$META"
out=$(env "${common[@]}" bash "$ROOT/bin/replicationctl" replica-show "$id")
[[ $out == *'"active":false'* ]]
env "${common[@]}" bash "$ROOT/bin/replicationctl" replica-purge "$id" true >/dev/null
[[ ! -e $FILE && ! -e $META ]]

# The mock mirrors real qemu-img >= 8.0 output: the protocol child node, whose
# "virtual-size" is the host file length (196616), is printed before the
# image's own fields. Replication reads source geometry from qemu-img, but QEMU
# itself now creates the destination mirror image on the backplane.
cat > "$T/qemu-img" <<'QEMU'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
  info)
    [[ " $* " == *" --force-share "* ]] || { echo "write lock is held" >&2; exit 1; }
    file=${!#}; size=1048576
    if [[ -f $file ]] && grep -q '^SIZE=' "$file"; then size=$(sed -n 's/^SIZE=//p' "$file"); fi
    printf '{\n    "children": [\n        {\n            "name": "file",\n            "info": {\n                "children": [\n                ],\n                "virtual-size": 196616,\n                "filename": "%s",\n                "format": "file",\n                "actual-size": 200704\n            }\n        }\n    ],\n    "virtual-size": %s,\n    "filename": "%s",\n    "format": "qcow2",\n    "actual-size": 200704\n}\n' "$file" "$size" "$file";;
  convert)
    src=${@: -2:1}; dst=${!#}
    cp "$src" "$dst";;
  create)
    echo "replication must not pre-create mirror targets with qemu-img" >&2
    exit 19;;
  *) echo "unexpected qemu-img $*" >&2; exit 9;;
esac
QEMU
chmod +x "$T/qemu-img"
export VMAPI_CONFIG=/dev/null
export VMAPI_LIB="$ROOT/lib/common.sh"
export QEMU_IMG="$T/qemu-img"
source <(sed '/^case ${1:-help} in/,$d' "$ROOT/bin/replicationctl")
[[ $(image_virtual_size "$T/locked.qcow2") == 1048576 ]]

# --- start/resume lifecycle, run as separate processes like the real CLI ----
PEER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
REMOTE="$T/peer/replicas/demo"; JOBS="$T/jobs"
mkdir -p "$REMOTE" "$T/vm"
printf 'DISK_0_FILE=disk0.qcow2\nDISK_0_FORMAT=qcow2\nDISK_0_BUS=virtio\n' > "$T/vm/demo.conf"
: > "$T/vm/disk0.qcow2"
cat > "$T/backplanectl" <<MOCK
#!/usr/bin/env bash
case \$1 in path) printf '%s\n' "$REMOTE";; connect) :;; show) echo '{"mounted":true,"tunnel_running":true}';; esac
MOCK
cat > "$T/peerctl" <<MOCK
#!/usr/bin/env bash
printf '{"node_id":"%s"}\n' "$OWNER"
MOCK
chmod +x "$T/backplanectl" "$T/peerctl"
cat > "$T/harness.sh" <<'HARNESS'
#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed '/^case ${1:-help} in/,$d' "$ROOT/bin/replicationctl")
require_vm(){ :; }; require_running(){ :; }; vm_state(){ printf '%s\n' "${VM_STATE:-running}"; }
vm_conf(){ printf '%s\n' "$T/vm/demo.conf"; }
vm_disk_path_index(){ printf '%s\n' "$T/vm/disk0.qcow2"; }
indexes_for(){ printf '0\n'; }
[[ ${USE_REAL_STATUS:-false} == true ]] || status_replication(){ printf '{"vm":"%s","configured":true}\n' "$1"; }
qmp(){
  case $2 in
    *query-block-jobs*)
      if [[ -f $T/job-active ]]; then
        if [[ ${JOB_READY:-false} == true ]]; then printf '%s\n' '{"return": [{"device":"repl-0","type":"mirror","offset":1048576,"len":1048576,"ready":true}]}'
        else printf '%s\n' '{"return": [{"device":"repl-0","type":"mirror","offset":1,"len":1048576,"ready":false}]}' ; fi
      else printf '%s\n' '{"return": []}'; fi;;
    *drive-mirror*)
      printf '%s\n' "$2" >> "$T/qmp.log"
      if [[ $MIRROR_REPLY == *'"error"'* ]]; then printf '%s\n' "$MIRROR_REPLY"
      else printf 'qemu-created\n' > "$REMOTE/disk0.qcow2"; : > "$T/job-active"; printf '%s\n' "$MIRROR_REPLY"; fi;;
    *block-job-cancel*) rm -f "$T/job-active"; printf '%s\n' "$2" >> "$T/qmp.log"; printf '%s\n' '{"return": {}}';;
    *) printf '%s\n' '{"return": {}}';;
  esac
}
"$@"
HARNESS
export ROOT T REMOTE QEMU_IMG_LOG="$T/qemu-img.log" VMAPI_BACKPLANECTL="$T/backplanectl" VMAPI_PEERCTL="$T/peerctl" VMAPI_REPLICATION_JOB_ROOT="$JOBS"
: > "$QEMU_IMG_LOG"
ok_reply='{"return": {}}'
size_reply='{"timestamp": {"seconds": 1, "microseconds": 2}, "event": "BLOCK_JOB_COMPLETED", "data": {"device": "repl-0", "len": 0, "offset": 0, "speed": 0, "type": "mirror", "error": "Source and target image have different sizes"}}'

# A rejected mirror must roll back the whole job. The target is deliberately
# not pre-created: QEMU receives absolute-paths and owns image creation/size.
printf 'stale-target\n' > "$REMOTE/disk0.qcow2"
rc=0; MIRROR_REPLY=$size_reply bash "$T/harness.sh" start_replication demo "$PEER" 0 >/dev/null 2>"$T/start.err" || rc=$?
[[ $rc -ne 0 ]]
grep -Fq 'QMP rejected replication request' "$T/start.err"
[[ ! -s $QEMU_IMG_LOG ]]
grep -Fq '"mode":"absolute-paths"' "$T/qmp.log"
[[ ! -e $JOBS/demo ]]
grep -Fq '"execute":"block-job-cancel","arguments":{"device":"repl-0"}' "$T/qmp.log"
grep -qx 'ACTIVE=false' "$REMOTE/disk0.meta"
grep -qx 'BYTES=1048576' "$REMOTE/disk0.meta"

# A successful start must keep its job once the process exits.
: > "$T/qmp.log"; rm -f "$T/job-active"
MIRROR_REPLY=$ok_reply bash "$T/harness.sh" start_replication demo "$PEER" 0 >/dev/null
grep -qx 'DISK_0_BYTES=1048576' "$JOBS/demo/state.conf"
grep -Fq '"job-id":"repl-0"' "$T/qmp.log"
grep -Fq '"mode":"absolute-paths"' "$T/qmp.log"
grep -qx 'qemu-created' "$REMOTE/disk0.qcow2"
grep -qx 'ACTIVE=true' "$REMOTE/disk0.meta"
grep -qx 'RECOVERABLE=false' "$REMOTE/disk0.meta"
# Once QEMU reports the full mirror ready, the replica becomes a valid recovery point.
USE_REAL_STATUS=true JOB_READY=true MIRROR_REPLY=$ok_reply bash "$T/harness.sh" status_replication demo >/dev/null
grep -qx 'RECOVERABLE=true' "$REMOTE/disk0.meta"
# Stop must load the job state so it can cancel the mirror and retire the replica.
MIRROR_REPLY=$ok_reply bash "$T/harness.sh" stop_replication demo true >/dev/null
[[ ! -e $JOBS/demo ]]
grep -Fq '"execute":"block-job-cancel","arguments":{"device":"repl-0"}' "$T/qmp.log"
grep -qx 'ACTIVE=false' "$REMOTE/disk0.meta"

# A stopped source VM can restore its retained replica back onto the disk that
# originally produced it. The replica stays retained after recovery.
printf 'source-before\n' > "$T/vm/disk0.qcow2"
printf 'replica-restored\n' > "$REMOTE/disk0.qcow2"
VM_STATE=stopped MIRROR_REPLY=$ok_reply bash "$T/harness.sh" restore_replica_to_source demo "$PEER" > "$T/restore.out"
grep -Fq '"restored":true' "$T/restore.out"
grep -Fq '"source":"continuous-replica"' "$T/restore.out"
grep -qx 'replica-restored' "$T/vm/disk0.qcow2"
grep -qx 'replica-restored' "$REMOTE/disk0.qcow2"
! find "$T/vm" -maxdepth 1 \( -name '*.replica-restore.*' -o -name '*.pre-replica-restore.*' \) | grep -q . || { echo "negative assertion failed: tests/replicationctl-test.sh:145" >&2; exit 1; }

# State written by the buggy parser (file length recorded as the size) heals
# on resume: state, peer metadata and the replica are all corrected.
mkdir -p "$JOBS/demo"
printf 'PEER=%s\nSPEED=0\nOWNER=%s\nDISK_0_JOB=repl-0\nDISK_0_TARGET=%s\nDISK_0_META=%s\nDISK_0_BYTES=196616\n' \
  "$PEER" "$OWNER" "$REMOTE/disk0.qcow2" "$REMOTE/disk0.meta" > "$JOBS/demo/state.conf"
printf 'SIZE=196616\n' > "$REMOTE/disk0.qcow2"
sed -i 's/^BYTES=.*/BYTES=196616/' "$REMOTE/disk0.meta"
: > "$T/qmp.log"; : > "$QEMU_IMG_LOG"; rm -f "$T/job-active"
MIRROR_REPLY=$ok_reply bash "$T/harness.sh" resume_replication demo
grep -qx 'DISK_0_BYTES=1048576' "$JOBS/demo/state.conf"
grep -qx 'BYTES=1048576' "$REMOTE/disk0.meta"
grep -qx 'ACTIVE=true' "$REMOTE/disk0.meta"
grep -qx 'qemu-created' "$REMOTE/disk0.qcow2"
[[ ! -s $QEMU_IMG_LOG ]]
grep -Fq '"mode":"absolute-paths"' "$T/qmp.log"
grep -Fq '"job-id":"repl-0"' "$T/qmp.log"

grep -Fq 'drive-mirror' bin/replicationctl
grep -Fq 'absolute-paths' bin/replicationctl
grep -Fq 'nfs4-wss-backplane' bin/replicationctl
echo 'replication backplane retention lifecycle: PASS'
