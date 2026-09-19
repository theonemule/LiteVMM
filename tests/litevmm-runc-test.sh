#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PEER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
LOWER="$T/peer-storage/$PEER/shared/docker-rootfs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/rootfs"
mkdir -p "$T/bin" "$T/bundle/rootfs" "$T/local-bundle/rootfs" "$LOWER"

cat >"$T/bundle/config.json" <<JSON
{"root":{"path":"rootfs"},"annotations":{"io.litevmm.remote.image":"remote/app:2","io.litevmm.remote.peer":"$PEER","io.litevmm.remote.lowerdir":"$LOWER"}}
JSON
cat >"$T/local-bundle/config.json" <<'JSON'
{"root":{"path":"rootfs"},"annotations":{}}
JSON

cat >"$T/bin/runc-real" <<'MOCK'
#!/usr/bin/env bash
printf 'runc' >>"$FAKE_LOG"; printf ' %q' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
exit 0
MOCK
cat >"$T/bin/rootfsctl" <<'MOCK'
#!/usr/bin/env bash
printf 'rootfsctl' >>"$FAKE_LOG"; printf ' %q' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
[[ ${1:-} == prepare-peer && ${2:-} == remote/app:2 ]] || exit 2
printf '{"source":"peer-rootfs","lowerdir":"%s"}\n' "$FAKE_LOWER"
MOCK
cat >"$T/bin/mount" <<'MOCK'
#!/usr/bin/env bash
printf 'mount' >>"$FAKE_LOG"; printf ' %q' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
exit 0
MOCK
cat >"$T/bin/umount" <<'MOCK'
#!/usr/bin/env bash
printf 'umount' >>"$FAKE_LOG"; printf ' %q' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
exit 0
MOCK
chmod +x "$T/bin/"*

export FAKE_LOG="$T/log" FAKE_LOWER="$LOWER"
export LITEVMM_REAL_RUNC="$T/bin/runc-real" VMAPI_DOCKER_ROOTFSCTL="$T/bin/rootfsctl"
export VMAPI_BACKPLANE_MOUNT_ROOT="$T/peer-storage" VMAPI_DOCKER_REMOTE_LAYER_ROOT="$T/state"
export VMAPI_MOUNT_BIN="$T/bin/mount" VMAPI_UMOUNT_BIN="$T/bin/umount" VMAPI_JQ=/usr/bin/jq

bash "$ROOT/bin/litevmm-runc" --root "$T/runc" create --bundle "$T/bundle" abc
grep -Fq 'rootfsctl prepare-peer remote/app:2' "$T/log"
grep -Fq "lowerdir=$LOWER" "$T/log"
grep -Fq "upperdir=$T/state/abc/upper" "$T/log"
grep -Fq "workdir=$T/state/abc/work" "$T/log"
grep -Fq "runc --root $T/runc create --bundle $T/bundle abc" "$T/log"
[[ -f "$T/state/abc/rootfs" ]]

bash "$ROOT/bin/litevmm-runc" --root "$T/runc" delete -f abc
grep -Fq 'runc --root' "$T/log"
grep -Fq "umount $T/bundle/rootfs" "$T/log"
# OCI task deletion happens on container stop as well as container removal.
# Preserve the writable upper/work layer until Docker's container-destroy path
# explicitly calls docker-rootfsctl cleanup-container.
[[ -d "$T/state/abc/upper" && -d "$T/state/abc/work" ]]
[[ ! -e "$T/state/abc/active-rootfs" ]]

: >"$T/log"
bash "$ROOT/bin/litevmm-runc" create --bundle "$T/local-bundle" local
grep -Fq 'runc create' "$T/log"
! grep -Fq 'mount ' "$T/log"
! grep -Fq 'rootfsctl ' "$T/log"

echo 'LiteVMM remote OCI runtime: PASS'
