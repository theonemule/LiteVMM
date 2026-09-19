#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PEER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
ID=sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EID=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
mkdir -p "$T/bin" "$T/peers" "$T/layers/top" "$T/layers/l1" "$T/layers/l2" "$T/shared/docker-rootfs" "$T/peer-shared/$EID/rootfs" "$T/state"
cat >"$T/peers/$PEER.conf" <<CFG
NAME=peer-a
NODE_ID=$PEER
URL=https://peer-a:5186
CFG

image_json(){
cat <<JSON
[{"Id":"$FAKE_IMAGE_ID","RepoTags":["remote/app:2"],"RepoDigests":[],"Config":{"Env":["MODE=prod"],"WorkingDir":"/work","User":"","StopSignal":"SIGTERM","Entrypoint":["/bin/sh","-c"],"Cmd":["echo hi"],"ExposedPorts":{"8080/tcp":{}},"Volumes":null,"Labels":{"app":"remote"}},"GraphDriver":{"Name":"overlay2","Data":{"UpperDir":"$TEST_ROOT/layers/top","LowerDir":"$TEST_ROOT/layers/l1:$TEST_ROOT/layers/l2"}}}]
JSON
}
export -f image_json
export TEST_ROOT="$T" FAKE_IMAGE_ID="$ID" FAKE_EXPORT_ID="$EID"

cat >"$T/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker' >>"$TEST_ROOT/docker.log"; printf ' %q' "$@" >>"$TEST_ROOT/docker.log"; printf '\n' >>"$TEST_ROOT/docker.log"
case "${1:-} ${2:-}" in
  'image inspect')
    ref=${3:-}
    if [[ "$ref" == remote/app:2 && ${FAKE_ROLE:-dest} == source ]]; then image_json; exit 0; fi
    if [[ "$ref" == litevmm-remote/*:stub && -f "$TEST_ROOT/state/stub" ]]; then printf '[{"Id":"sha256:stub"}]\n'; exit 0; fi
    exit 1;;
  'image import')
    ref=${!#}; cat >/dev/null; printf '%s\n' "$ref" >"$TEST_ROOT/state/stub"; printf 'sha256:stub\n';;
  'image pull'|'image save'|'image load')
    echo 'image copy operation must not be used by zero-copy federation' >&2; exit 88;;
  'container inspect') exit 1;;
  'container create') printf 'container-id\n';;
  *) echo "unexpected docker call: $*" >&2; exit 9;;
esac
MOCK

cat >"$T/bin/mount" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'mount' >>"$TEST_ROOT/mount.log"; printf ' %q' "$@" >>"$TEST_ROOT/mount.log"; printf '\n' >>"$TEST_ROOT/mount.log"
target=${!#}; mkdir -p "$target"; touch "$target/.fake-mount"
MOCK
cat >"$T/bin/mountpoint" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == -q ]] && shift
[[ -e "$1/.fake-mount" ]]
MOCK
cat >"$T/bin/umount" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
rm -f "$1/.fake-mount"
MOCK
cat >"$T/bin/backplanectl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == shared-path && ${3:-} == docker-rootfs ]] || exit 2
[[ ${4:-} == "$FAKE_EXPORT_ID" ]] || exit 2
printf '%s/%s\n' "$FAKE_PEER_SHARED" "$FAKE_EXPORT_ID"
MOCK
cat >"$T/bin/peerctl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == proxy ]] || exit 2
peer=${2:?}; method=${3:?}; path=${4:?}
case "$method $path" in
  GET\ /docker/images?image=remote%2Fapp%3A2)
    if [[ ${FAKE_CONFLICT:-false} == true && "$peer" != aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]; then
      printf '[{"Id":"sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"}]\n'
    else
      printf '[{"Id":"%s","RepoTags":["remote/app:2"]}]\n' "$FAKE_IMAGE_ID"
    fi;;
  'POST /docker/images/expose')
    cat >/dev/null
    mkdir -p "$FAKE_PEER_SHARED/$FAKE_EXPORT_ID/rootfs"
    image_json >"$FAKE_PEER_SHARED/$FAKE_EXPORT_ID/image.json"
    printf '{"image":"remote/app:2","image_id":"%s","export_id":"%s","backend":"overlay2"}\n' "$FAKE_IMAGE_ID" "$FAKE_EXPORT_ID";;
  *) exit 22;;
esac
MOCK
cat >"$T/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} == -n ]] && shift
exec "$@"
MOCK
chmod +x "$T/bin/"*

export PATH="$T/bin:/usr/bin:/bin"
export VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh"
export DOCKER_BIN="$T/bin/docker" VMAPI_PEERCTL="$T/bin/peerctl" VMAPI_BACKPLANECTL="$T/bin/backplanectl"
export VMAPI_PEER_ROOT="$T/peers" VMAPI_DOCKER_ROOTFS_EXPORT_ROOT="$T/shared/docker-rootfs"
export VMAPI_MOUNT_BIN="$T/bin/mount" VMAPI_UMOUNT_BIN="$T/bin/umount" VMAPI_MOUNTPOINT_BIN="$T/bin/mountpoint"
export VMAPI_JQ=/usr/bin/jq FAKE_PEER_SHARED="$T/peer-shared"

# Source-side expose mounts Docker's existing immutable overlay layers. It must
# not docker save, load, or pull anything.
export FAKE_ROLE=source
out=$(bash "$ROOT/bin/docker-rootfsctl" expose remote/app:2)
[[ "$out" == *'"backend":"overlay2"'* && "$out" == *'"reused":false'* ]]
[[ -s "$T/shared/docker-rootfs/$EID/image.json" ]]
grep -Fq "lowerdir=$T/layers/top:$T/layers/l1:$T/layers/l2" "$T/mount.log"

# Destination-side prepare discovers the peer, asks it to expose the rootfs,
# mounts the existing backplane, and creates only a metadata-only scratch stub.
export FAKE_ROLE=dest
out=$(bash "$ROOT/bin/docker-rootfsctl" prepare remote/app:2)
[[ "$out" == *'"source":"peer-rootfs"'* ]]
[[ "$out" == *"\"lowerdir\":\"$T/peer-shared/$EID/rootfs\""* ]]
[[ -s "$T/state/stub" ]]
grep -Fq 'image import' "$T/docker.log"
! grep -Eq 'image (pull|save|load)' "$T/docker.log"

# dockerctl uses the same zero-copy preparation path for UI/API container create.
export VMAPI_DOCKER_ROOTFSCTL="$ROOT/bin/docker-rootfsctl"
: >"$T/docker.log"
bash "$ROOT/bin/dockerctl" create web remote/app:2 --env MODE=test >/dev/null
grep -Fq -- '--runtime litevmm-remote' "$T/docker.log"
grep -Fq -- "--annotation io.litevmm.remote.lowerdir=$T/peer-shared/$EID/rootfs" "$T/docker.log"
grep -Fq -- 'litevmm-remote/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:stub' "$T/docker.log"
! grep -Eq 'image (pull|save|load)' "$T/docker.log"

# Conflicting tags across peers are never selected silently.
PEER2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
cat >"$T/peers/$PEER2.conf" <<CFG
NAME=peer-b
NODE_ID=$PEER2
URL=https://peer-b:5186
CFG
export FAKE_CONFLICT=true
if bash "$ROOT/bin/docker-rootfsctl" prepare remote/app:2 >"$T/conflict" 2>&1; then
  echo 'conflicting peer tag should fail' >&2; exit 1
fi
grep -Fq 'Federated tag conflict' "$T/conflict"

echo 'Docker zero-copy peer rootfs: PASS'
