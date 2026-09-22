#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/ss" <<'SS'
#!/usr/bin/env bash
case "$*" in
  *-ltnH*) printf '%s\n' 'LISTEN 0 128 127.0.0.1:2049 0.0.0.0:*' 'LISTEN 0 128 127.0.0.1:6091 0.0.0.0:*';;
  *-lunH*) :;;
esac
SS
chmod +x "$T/ss"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_BACKPLANE_SERVER=true VMAPI_SS="$T/ss")
out=$(env "${common[@]}" bash "$ROOT/bin/backplanectl" server-status)
[[ $out == *'"nfs_bind":"127.0.0.1"'* ]]
[[ $out == *'"nfs_listening":true'* && $out == *'"websocket_listening":true'* ]]
[[ $out == *'"external_exposure":false'* ]]

cat > "$T/ss" <<'SS'
#!/usr/bin/env bash
case "$*" in
  *-ltnH*) printf '%s\n' 'LISTEN 0 128 0.0.0.0:2049 0.0.0.0:*' 'LISTEN 0 128 127.0.0.1:6091 0.0.0.0:*';;
  *-lunH*) :;;
esac
SS
out=$(env "${common[@]}" VMAPI_BACKPLANE_NFS_BIND=0.0.0.0 bash "$ROOT/bin/backplanectl" server-status)
[[ $out == *'"external_exposure":true'* ]]

# Export roots must be traversable by the unprivileged QEMU/vmapi process.
# Peer namespaces themselves retain their stricter per-client ownership.
PERMROOT="$T/perm-root"
mkdir -p "$PERMROOT"
export VMAPI_CONFIG=/dev/null
export VMAPI_LIB="$ROOT/lib/common.sh"
export VMAPI_BACKPLANE_ROOT="$PERMROOT/backplane"
export VMAPI_BACKPLANE_STATE_ROOT="$PERMROOT/state"
export VMAPI_BACKPLANE_MOUNT_ROOT="$PERMROOT/mounts"
export VMAPI_BACKPLANE_RUN_ROOT="$PERMROOT/run"
source <(sed '/^case ${1:-help} in/,$d' "$ROOT/bin/backplanectl")
ensure_dirs
[[ $(stat -c %a "$PERMROOT/backplane") == 711 ]]
[[ $(stat -c %a "$PERMROOT/backplane/peers") == 711 ]]
[[ $(stat -c %a "$PERMROOT/backplane/shared") == 755 ]]

# The unprivileged container backend binds loopback as an IPv4-mapped IPv6
# address on Linux. It is still loopback-only and must verify as healthy.
cat > "$T/ss" <<'SS'
#!/usr/bin/env bash
case "$*" in
  *-ltnH*) printf '%s\n' 'LISTEN 0 128 [::ffff:127.0.0.1]:12049 *:*' 'LISTEN 0 128 127.0.0.1:6091 0.0.0.0:*';;
  *-lunH*) :;;
esac
SS
out=$(env "${common[@]}" VMAPI_BACKPLANE_NFS_BACKEND=unfs3 VMAPI_BACKPLANE_NFS_PORT=12049 bash "$ROOT/bin/backplanectl" server-status)
[[ $out == *'"nfs_listening":true'* && $out == *'"external_exposure":false'* ]]

# New peers advertise the NFS protocol and export path. Container storage
# nodes use NFSv3 because UNFS3 runs entirely in userspace; older peers omit
# these fields and continue to default to the kernel NFSv4.2 root export.
cat > "$T/peerctl" <<'PEERCTL'
#!/usr/bin/env bash
case "${1:-}" in
  proxy) printf '%s\n' '{"capabilities":["storage-backplane"],"backplane_nfs_version":"3","backplane_nfs_export":"/var/lib/vmapi/backplane"}';;
  identity) printf '%s\n' '{"node_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}';;
  *) exit 2;;
esac
PEERCTL
cat > "$T/mount" <<'MOUNT'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$VMAPI_TEST_MOUNT_ARGS"
MOUNT
chmod +x "$T/peerctl" "$T/mount"
NEGROOT="$T/negotiate"
mkdir -p "$NEGROOT"
export VMAPI_PEERCTL="$T/peerctl"
export VMAPI_MOUNT_BIN="$T/mount"
export VMAPI_TEST_MOUNT_ARGS="$T/mount.args"
export VMAPI_BACKPLANE_ROOT="$NEGROOT/backplane"
export VMAPI_BACKPLANE_STATE_ROOT="$NEGROOT/state"
export VMAPI_BACKPLANE_MOUNT_ROOT="$NEGROOT/mounts"
export VMAPI_BACKPLANE_RUN_ROOT="$NEGROOT/run"
# backplanectl was sourced above, so update its resolved runtime variables too.
PEERCTL="$T/peerctl"
MOUNT_BIN="$T/mount"
BACKPLANE_ROOT="$NEGROOT/backplane"
MOUNT_ROOT="$NEGROOT/mounts"
SHARED_ROOT="$BACKPLANE_ROOT/shared"
STATE_ROOT="$NEGROOT/state"
RUN_ROOT="$NEGROOT/run"
peer_supports_backplane aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
[[ $PEER_NFS_VERSION == 3 ]]
[[ $PEER_NFS_EXPORT == /var/lib/vmapi/backplane ]]
mount_peer aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 33001 "$PEER_NFS_VERSION" "$PEER_NFS_EXPORT"
grep -Fq 'vers=3,proto=tcp,port=33001,mountport=33001,nolock' "$T/mount.args"
grep -Fq '127.0.0.1:/var/lib/vmapi/backplane' "$T/mount.args"

echo 'backplane loopback exposure checks: PASS'
