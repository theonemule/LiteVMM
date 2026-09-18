#!/usr/bin/env bash
# Live backup against a real QEMU, including a VM under continuous replication.
# QEMU refuses a backup job on a disk that a replication mirror job owns, so
# vmbackupctl must pause replication around the copy and resume it afterwards.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for c in qemu-system-x86_64 qemu-img qemu-io socat; do
  command -v "$c" >/dev/null 2>&1 || { echo "vmbackupctl live backup: SKIP ($c not installed)"; exit 0; }
done
# vmctl opens disks with cache=none (O_DIRECT), which tmpfs lacks, so stay off /tmp.
T=$(mktemp -d "${VMAPI_TEST_TMP:-/var/tmp}/vmapi-live-backup.XXXXXX")
QPID=''; SLEEPER=''
cleanup(){ [[ -z $QPID ]] || kill "$QPID" 2>/dev/null || true; [[ -z $SLEEPER ]] || kill "$SLEEPER" 2>/dev/null || true; rm -rf "$T"; }
trap cleanup EXIT

OWNER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; PEER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$T/vms" DISK_ROOT="$T/disks"
export VMAPI_REPLICATIONCTL="$ROOT/bin/replicationctl" VMAPI_REPLICATION_JOB_ROOT="$T/repl-jobs"
export VMAPI_BACKPLANECTL="$T/backplanectl" VMAPI_PEERCTL="$T/peerctl" ROOT
REPLICA="$T/peer/replicas/demo"; RUNTIME="$VM_ROOT/demo/runtime"
mkdir -p "$RUNTIME" "$DISK_ROOT/demo" "$REPLICA" "$T/out"
printf 'NAME=demo\nDISK_0_FILE=disk0.qcow2\nDISK_0_FORMAT=qcow2\nDISK_0_BUS=virtio\n' > "$VM_ROOT/demo/vm.conf"
cat > "$T/backplanectl" <<MOCK
#!/usr/bin/env bash
case \$1 in path) printf '%s\n' "$REPLICA";; connect) :;; show) echo '{"mounted":true,"tunnel_running":true}';; esac
MOCK
cat > "$T/peerctl" <<MOCK
#!/usr/bin/env bash
printf '{"node_id":"%s"}\n' "$OWNER"
MOCK
chmod +x "$T/backplanectl" "$T/peerctl"

DISK="$DISK_ROOT/demo/disk0.qcow2"
qemu-img create -f qcow2 "$DISK" 256M >/dev/null
qemu-io -c 'write -P 0x5a 0 24M' -c 'write -P 0xa5 200M 8M' "$DISK" >/dev/null
# Same drive/device arguments vmctl uses for a virtio disk; paused, no guest needed.
if ! qemu-system-x86_64 -machine q35 -accel tcg -S -display none -nodefaults -no-user-config -m 64 \
    -drive "file=$DISK,format=qcow2,if=none,id=drive0,cache=none,aio=threads" \
    -device virtio-blk-pci,drive=drive0,id=disk0 \
    -qmp "unix:$RUNTIME/qmp.sock,server=on,wait=off" -pidfile "$RUNTIME/qemu.pid" -daemonize 2>"$T/qemu.err"; then
  echo "vmbackupctl live backup: SKIP (QEMU could not start: $(head -n1 "$T/qemu.err"))"; exit 0
fi
QPID=$(cat "$RUNTIME/qemu.pid")

# Run vmbackupctl / replicationctl functions in their own process, as the CLI does.
cat > "$T/backup.sh" <<'H'
#!/usr/bin/env bash
set -Eeuo pipefail
source <(sed '/^case "${1:-help}" in/,$d' "$ROOT/bin/vmbackupctl")
"$@"
H
repl(){ bash "$ROOT/bin/replicationctl" "$@"; }
backup(){ bash "$T/backup.sh" "$@"; }
mirror_running(){ [[ $(repl status demo) == *'"job":"repl-0","ready":true'* ]]; }
wait_mirror(){ local i; for i in $(seq 1 60); do mirror_running && return 0; sleep 0.5; done; return 1; }

# Continuous replication, started through the real replicationctl and qemu-img:
# the replica must get the disk's virtual size, not its host file length.
repl start demo "$PEER" 0 >/dev/null
[[ $(qemu-img info -U --output=json "$REPLICA/disk0.qcow2") == *'"virtual-size": 268435456,'* ]]
wait_mirror

# 1. The reported failure: a backup job on a mirrored disk. The real QEMU error
#    must surface; the bogus virtio<n> retry used to replace it.
rc=0; backup live_disk_copy demo "$T/out" 2>"$T/busy.err" || rc=$?
[[ $rc -ne 0 ]]
grep -Fq "Node 'drive0' is busy: block device is in use by block job: mirror" "$T/busy.err"
! grep -Fq virtio0 "$T/busy.err"

# 2. The cmd_create sequence: pause replication, copy, resume. Checks run inside
#    the holder process while the pause is in effect.
cat > "$T/while-paused.sh" <<'H'
[[ -f $VMAPI_REPLICATION_JOB_ROOT/demo/paused ]]
[[ $(bash "$ROOT/bin/replicationctl" status demo) == *'"paused":true'* ]]
# The replication daemon must leave a paused VM alone.
bash "$ROOT/bin/replicationctl" resume demo >/dev/null
[[ $(bash "$ROOT/bin/replicationctl" status demo) != *'"ready":true'* ]]
H
backup bash -c 'source <(sed "/^case \"\${1:-help}\" in/,\$d" "$ROOT/bin/vmbackupctl")
  pause_replication_for_backup demo
  source "$1"
  live_disk_copy demo "$2"
  resume_paused_replication' _ "$T/while-paused.sh" "$T/out"
qemu-img compare -U "$DISK" "$T/out/disk0.qcow2" >/dev/null
[[ ! -e $VMAPI_REPLICATION_JOB_ROOT/demo/paused ]]
[[ $(repl status demo) == *'"paused":false'* ]]
wait_mirror

# 3. A pause whose holder died without unpausing is stale: the daemon resumes.
sleep 300 & SLEEPER=$!
repl pause demo "$SLEEPER" >/dev/null
! mirror_running
repl resume demo >/dev/null
! mirror_running
kill "$SLEEPER"; wait "$SLEEPER" 2>/dev/null || true; SLEEPER=''
repl resume demo >/dev/null
[[ ! -e $VMAPI_REPLICATION_JOB_ROOT/demo/paused ]]
wait_mirror

# 4. A finished-but-undismissed backup job left by a crashed run must not block
#    the next backup. Replication is stopped for this part.
repl stop demo >/dev/null
q(){ { printf '%s\n' '{"execute":"qmp_capabilities"}' "$1"; sleep 0.3; } | socat - "UNIX-CONNECT:$RUNTIME/qmp.sock"; }
q "{\"execute\":\"drive-backup\",\"arguments\":{\"device\":\"drive0\",\"target\":\"$T/stale.qcow2\",\"format\":\"qcow2\",\"sync\":\"full\",\"job-id\":\"vmapi-backup-0\",\"auto-dismiss\":false}}" >/dev/null
for i in $(seq 1 40); do [[ $(q '{"execute":"query-jobs"}') == *'"status": "concluded"'* ]] && break; sleep 0.25; done
rm -f "$T/out/disk0.qcow2"
backup live_disk_copy demo "$T/out"
qemu-img compare -U "$DISK" "$T/out/disk0.qcow2" >/dev/null
[[ $(q '{"execute":"query-jobs"}') == *'"return": []'* ]]

echo 'vmbackupctl live backup with replication: PASS'
