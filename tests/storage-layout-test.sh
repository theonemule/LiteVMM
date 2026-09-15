#!/usr/bin/env bash
# Verifies that configuration and disks use separate roots and that a backup
# carries every attached disk through a restore.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT

mkdir -p "$T/bin"
cat > "$T/bin/qemu-img" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == create && $2 == -f ]] || exit 2
truncate -s 1048576 "$4"
SH
cat > "$T/bin/install" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
args=()
while (($#)); do
  case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac
done
exec /usr/bin/install "${args[@]}"
SH
cat > "$T/bin/sudo" <<'SH'
#!/usr/bin/env bash
[[ ${1:-} == -n ]] && shift
exec "$@"
SH
cat > "$T/bin/peerctl" <<'SH'
#!/usr/bin/env bash
# Minimal authenticated-peer receiver used to verify the sender only removes
# its staging archive after a successful remote receive.
set -Eeuo pipefail
[[ $1 == proxy && $3 == PUT ]] || exit 2
path=$4
archive=${path#/backups/receive/}
archive=${archive%%\?*}
VMAPI_BACKUP_ROOT="$FAKE_PEER_BACKUP_ROOT" "$VMAPI_BACKUPCTL" receive "$archive"
SH
chmod +x "$T/bin/qemu-img" "$T/bin/install" "$T/bin/sudo" "$T/bin/peerctl"

export PATH="$T/bin:$PATH"
export VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh"
export VM_ROOT="$T/vms" DISK_ROOT="$T/disks" ISO_ROOT="$T/isos"
export QEMU_IMG="$T/bin/qemu-img" QEMU_BIN=/bin/true
export VMCTL="$ROOT/bin/vmctl" VMAPI_BACKUP_ROOT="$T/backups" VMAPI_BACKUPCTL="$ROOT/bin/vmbackupctl"
export VMAPI_BACKUP_JOB_ROOT="$T/backup-jobs" VMAPI_BACKUP_LOG_ROOT="$T/backup-logs"
export VMAPI_PEERCTL="$T/bin/peerctl" FAKE_PEER_BACKUP_ROOT="$T/peer-backups"

"$ROOT/bin/vmctl" create demo --disk 1G --display none --network none >/dev/null
response=$(printf 'data-disk' | REQUEST_METHOD=PUT PATH_INFO=/api/vms/demo/disks/import/data.vmdk \
  QUERY_STRING='format=vmdk&bus=virtio' CONTENT_TYPE=application/octet-stream CONTENT_LENGTH=9 \
  "$ROOT/cgi/api.cgi")
grep -q 'Status: 201 Created' <<< "$response"
response=$(REQUEST_METHOD=GET PATH_INFO=/api/vms/demo/disks/1/download "$ROOT/cgi/api.cgi")
grep -q 'Content-Disposition: attachment; filename="data.vmdk"' <<< "$response"
grep -q 'data-disk' <<< "$response"
mkdir -p "$T/isos"
printf 'installer' > "$T/isos/demo.iso"
response=$(REQUEST_METHOD=GET PATH_INFO=/api/images/demo.iso IMAGECTL="$ROOT/bin/imagectl" "$ROOT/cgi/api.cgi")
grep -q 'Content-Disposition: attachment; filename="demo.iso"' <<< "$response"
grep -q 'installer' <<< "$response"
printf 'VM_ROOT=%s\nDISK_ROOT=%s\nISO_ROOT=%s\n' "$T/vms" "$T/disks" "$T/isos" > "$T/vmapi.conf"
body="kind=isos&path=$T/iso-library"
response=$(printf '%s' "$body" | REQUEST_METHOD=POST PATH_INFO=/api/storage CONTENT_TYPE=application/x-www-form-urlencoded \
  CONTENT_LENGTH=${#body} VMAPI_CONFIG="$T/vmapi.conf" STORAGECTL="$ROOT/bin/storagectl" "$ROOT/cgi/api.cgi")
grep -q 'Status: 200 OK' <<< "$response"
[[ -f "$T/iso-library/demo.iso" ]]
grep -qx "ISO_ROOT=$T/iso-library" "$T/vmapi.conf"
[[ -f "$T/vms/demo/vm.conf" ]]
[[ -f "$T/disks/demo/disk0.qcow2" && -f "$T/disks/demo/data.vmdk" ]]
[[ ! -f "$T/vms/demo/disk0.qcow2" ]]

"$ROOT/bin/vmbackupctl" create demo >/dev/null
archive=$(find "$T/backups" -name '*.tar.gz' -print -quit)
tar -tzf "$archive" > "$T/archive-members"
grep -qx 'demo/vm.conf' "$T/archive-members"
grep -qx 'demo/disks/disk0.qcow2' "$T/archive-members"
grep -qx 'demo/disks/data.vmdk' "$T/archive-members"

"$ROOT/bin/vmctl" delete demo
"$ROOT/bin/vmbackupctl" restore demo "$(basename "$archive")" >/dev/null
[[ -f "$T/vms/demo/vm.conf" ]]
[[ -f "$T/disks/demo/disk0.qcow2" && -f "$T/disks/demo/data.vmdk" ]]

# The foreground API returns a job ID quickly, then the job state reaches a
# completed result containing the archive metadata.
job=$($ROOT/bin/vmbackupctl start demo --label job)
job_id=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<< "$job")
[[ -n $job_id ]]
for _ in $(seq 1 100); do
  job=$($ROOT/bin/vmbackupctl job "$job_id")
  grep -q '"state":"completed"' <<< "$job" && break
  grep -q '"state":"failed"' <<< "$job" && { echo "$job" >&2; exit 1; }
  sleep 0.05
done
grep -q '"state":"completed"' <<< "$job"
grep -q '"target":"local"' <<< "$job"

# The CGI route accepts the job immediately and serves its status JSON.
body='name=demo&label=cgi'
response=$(printf '%s' "$body" | REQUEST_METHOD=POST PATH_INFO=/api/backups/start CONTENT_TYPE=application/x-www-form-urlencoded \
  CONTENT_LENGTH=${#body} BACKUPCTL="$ROOT/bin/vmbackupctl" "$ROOT/cgi/api.cgi")
grep -q 'Status: 202 Accepted' <<< "$response"
cgi_job=$(sed -n 's/.*"id":"\([^"]*\)".*/\1/p' <<< "$response")
[[ -n $cgi_job ]]
for _ in $(seq 1 100); do
  response=$(REQUEST_METHOD=GET PATH_INFO="/api/backups/jobs/$cgi_job" BACKUPCTL="$ROOT/bin/vmbackupctl" "$ROOT/cgi/api.cgi")
  grep -q '"state":"completed"' <<< "$response" && break
  grep -q '"state":"failed"' <<< "$response" && { echo "$response" >&2; exit 1; }
  sleep 0.05
done
grep -q '"state":"completed"' <<< "$response"

# A peer-targeted backup is received remotely and has no source-side copy.
peer_id=0123456789abcdef0123456789abcdef
peer_result=$($ROOT/bin/vmbackupctl create demo --label peer --peer "$peer_id")
grep -q '"target":"peer"' <<< "$peer_result"
peer_archive=$(sed -n 's/.*"archive":"\([^"]*\)".*/\1/p' <<< "$peer_result")
[[ -f "$T/peer-backups/demo/$peer_archive" ]]
[[ ! -f "$T/backups/demo/$peer_archive" ]]
tar -tzf "$T/peer-backups/demo/$peer_archive" | grep -qx 'demo/vm.conf'
printf 'storage layout: PASS\n'
