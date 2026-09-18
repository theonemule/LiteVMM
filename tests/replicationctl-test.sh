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

cat > "$T/qemu-img" <<'QEMU'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == info ]]
[[ " $* " == *" --force-share "* ]] || { echo "write lock is held" >&2; exit 1; }
printf '%s\n' '{"virtual-size":1048576}'
QEMU
chmod +x "$T/qemu-img"
export VMAPI_CONFIG=/dev/null
export VMAPI_LIB="$ROOT/lib/common.sh"
export QEMU_IMG="$T/qemu-img"
source <(sed '/^case ${1:-help} in/,$d' "$ROOT/bin/replicationctl")
[[ $(image_virtual_size "$T/locked.qcow2") == 1048576 ]]
touch "$T/replica-permissions.qcow2"
chmod 0644 "$T/replica-permissions.qcow2"
prepare_replica_file_access "$T/replica-permissions.qcow2"
[[ $(stat -c %a "$T/replica-permissions.qcow2") == 660 ]]
grep -Fq 'drive-mirror' bin/replicationctl
grep -Fq '"mode":"existing"' bin/replicationctl
grep -Fq 'nfs4-wss-backplane' bin/replicationctl
echo 'replication backplane retention lifecycle: PASS'
