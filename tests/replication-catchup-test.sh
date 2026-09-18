#!/usr/bin/env bash
# Replication pause/resume against a real, running QEMU guest. After a pause the
# replica must catch up from tracked changes (not a full resync), stay exact,
# and the guest may only be frozen briefly. QEMU's own STOP/RESUME events,
# read from a second monitor, measure the freezes.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for c in qemu-system-x86_64 qemu-img qemu-io socat; do
  command -v "$c" >/dev/null 2>&1 || { echo "replication catch-up: SKIP ($c not installed)"; exit 0; }
done
T=$(mktemp -d "${VMAPI_TEST_TMP:-/var/tmp}/vmapi-catchup.XXXXXX")
QPID=''; LISTENER=''; HOLDER=''
cleanup(){ local p; for p in "$QPID" "$LISTENER" "$HOLDER"; do [[ -z $p ]] || kill "$p" 2>/dev/null || true; done; rm -rf "$T"; }
trap cleanup EXIT

OWNER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa; PEER=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
export VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$T/vms" DISK_ROOT="$T/disks"
export VMAPI_REPLICATION_JOB_ROOT="$T/repl-jobs" VMAPI_BACKPLANECTL="$T/backplanectl" VMAPI_PEERCTL="$T/peerctl"
REPLICA="$T/peer/replicas/demo"; RUNTIME="$VM_ROOT/demo/runtime"; DISK="$DISK_ROOT/demo/disk0.qcow2"
mkdir -p "$RUNTIME" "$DISK_ROOT/demo" "$REPLICA"
printf 'NAME=demo\nDISK_0_FILE=disk0.qcow2\nDISK_0_FORMAT=qcow2\nDISK_0_BUS=virtio\n' > "$VM_ROOT/demo/vm.conf"
printf '#!/usr/bin/env bash\ncase $1 in path) echo %s;; show) echo %s;; esac\n' "$REPLICA" "'{\"mounted\":true,\"tunnel_running\":true}'" > "$T/backplanectl"
printf '#!/usr/bin/env bash\necho %s\n' "'{\"node_id\":\"$OWNER\"}'" > "$T/peerctl"
chmod +x "$T/backplanectl" "$T/peerctl"

# A real running guest: a boot sector that loops incrementing a RAM counter.
printf '\x31\xc0\x8e\xd8\x66\xc7\x06\x00\x80\x45\x56\x49\x4c\x66\xff\x06\x04\x80\xeb\xf9' > "$T/mbr"
truncate -s 510 "$T/mbr"; printf '\x55\xaa' >> "$T/mbr"; truncate -s 256M "$T/mbr"
qemu-img convert -f raw -O qcow2 "$T/mbr" "$DISK"
qemu-io -c 'write -P 0x5a 1M 40M' "$DISK" >/dev/null
qemu-system-x86_64 -machine q35 -accel tcg -cpu max -smp 1 -m 64 -display none -nodefaults -no-user-config \
    -drive "file=$DISK,format=qcow2,if=none,id=drive0,cache=none,aio=threads" -device virtio-blk-pci,drive=drive0,id=disk0 \
    -qmp "unix:$RUNTIME/qmp.sock,server=on,wait=off" -qmp "unix:$T/events.sock,server=on,wait=off" \
    -pidfile "$RUNTIME/qemu.pid" -daemonize 2>"$T/qemu.err" \
  || { echo "replication catch-up: SKIP (QEMU could not start: $(head -n1 "$T/qemu.err"))"; exit 0; }
QPID=$(cat "$RUNTIME/qemu.pid")
{ printf '%s\n' '{"execute":"qmp_capabilities"}'; sleep 3600; } | socat - "UNIX-CONNECT:$T/events.sock" > "$T/events.log" & LISTENER=$!

source "$ROOT/lib/common.sh"
repl(){ bash "$ROOT/bin/replicationctl" "$@"; }
hmp(){ qmp_do demo "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"$1\"}}" >/dev/null; }
guest_write(){ hmp "qemu-io drive0 \\\"write -P $1 $2 $3\\\""; }
counter(){ qmp_do demo '{"execute":"human-monitor-command","arguments":{"command-line":"xp /1wx 0x8004"}}' | grep -o '0x[0-9a-f]*\\r' | head -n1 | sed 's/\\r//'; }
guest_running(){ [[ $(qmp_do demo '{"execute":"query-status"}') == *'"running": true'* ]]; }
mirror(){ json_flat_object "$(qmp_do demo '{"execute":"query-block-jobs"}')" device repl-0; }
tracking(){ json_flat_object "$(qmp_do demo '{"execute":"query-block"}')" name vmapi-repl-0; }
wait_synced(){ local i m; for i in $(seq 1 100); do m=$(mirror); [[ $m == *'"ready": true'* && $(json_int_field "$m" offset) == "$(json_int_field "$m" len)" ]] && return 0; sleep 0.1; done; return 1; }
# The replica is compared with a mirror cancelled while it is in sync, which
# leaves the replica an exact point-in-time copy (the mirror then restarts).
replica_exact(){
  wait_synced; qmp_do demo '{"execute":"stop"}' >/dev/null
  qmp_do demo '{"execute":"block-job-cancel","arguments":{"device":"repl-0"}}' >/dev/null
  while [[ -n $(mirror) ]]; do sleep 0.05; done
  qemu-img compare -U "$DISK" "$REPLICA/disk0.qcow2" >/dev/null; local rc=$?
  qmp_do demo '{"execute":"cont"}' >/dev/null; repl resume demo >/dev/null; return $rc
}
# Freeze durations (ms) from STOP/RESUME event pairs logged since mark $1.
freezes_since(){ tail -n +"$(($1 + 1))" "$T/events.log" | sed -n 's/.*"seconds": \([0-9]*\), "microseconds": \([0-9]*\)}, "event": "\(STOP\|RESUME\)".*/\3 \1 \2/p' \
  | awk '{t = $2 * 1000000 + $3} $1=="STOP"{s=t} $1=="RESUME"&&s{printf "%d ", (t-s)/1000; s=0}'; }
mark(){ wc -l < "$T/events.log"; }
short_freezes(){ local f; for f in $1; do (( f < 2000 )) || return 1; done; }

repl start demo "$PEER" 0 >/dev/null
wait_synced
c0=$(counter); sleep 0.3; [[ $(counter) != "$c0" ]]   # the guest is executing

# 1. Pause: mirror stopped, changes tracked, guest still running afterwards.
sleep 300 & HOLDER=$!
m=$(mark); repl pause demo "$HOLDER" >/dev/null
[[ -z $(mirror) ]]
[[ $(tracking) == *'"persistent": true'* ]]
guest_running
pause_freeze=$(freezes_since "$m")

# 2. Changes while paused, then unpause: catch-up, not a full resync.
guest_write 0x11 60M 3M; guest_write 0x22 150M 5M
[[ $(json_int_field "$(tracking)" count) -ge $((8 << 20)) ]]
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null || true; HOLDER=''
m=$(mark); repl unpause demo >/dev/null
resume_freeze=$(freezes_since "$m")
[[ -n $(mirror) && -z $(tracking) ]]
guest_running
# A full resync would have to copy the 40 MiB already on the disk; the
# restarted mirror only forwards new writes.
[[ $(json_int_field "$(mirror)" len) -lt $((1 << 20)) ]]
guest_write 0x33 200M 2M
replica_exact

# 3. Service stop/start (as during an upgrade) also catches up.
wait_synced
repl suspend >/dev/null
[[ -z $(mirror) && -n $(tracking) ]]
guest_write 0x44 100M 4M
repl resume demo >/dev/null
[[ -n $(mirror) && -z $(tracking) && $(json_int_field "$(mirror)" len) -lt $((1 << 20)) ]]
replica_exact

# 4. Lost tracking falls back to a full resync, which is still exact.
wait_synced
sleep 300 & HOLDER=$!
repl pause demo "$HOLDER" >/dev/null
qmp_do demo '{"execute":"block-dirty-bitmap-remove","arguments":{"node":"drive0","name":"vmapi-repl-0"}}' >/dev/null
guest_write 0x55 70M 1M
kill "$HOLDER"; wait "$HOLDER" 2>/dev/null || true; HOLDER=''
repl unpause demo >/dev/null
[[ $(json_int_field "$(mirror)" len) -ge $((40 << 20)) ]]
replica_exact
guest_running

short_freezes "$pause_freeze $resume_freeze"
echo "replication catch-up: PASS (guest freezes: pause ${pause_freeze% }ms, resume ${resume_freeze% }ms)"
