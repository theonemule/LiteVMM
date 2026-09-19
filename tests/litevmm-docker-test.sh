#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
LOG="$T/log"
LOWER=/var/lib/vmapi/peer-storage/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/shared/docker-rootfs/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/rootfs

cat >"$T/bin/docker-real" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf 'docker' >>"${FAKE_LOG:?}"; printf ' %q' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
if [[ ${1:-} == image && ${2:-} == inspect ]]; then
  [[ ${3:-} == local/app:1 ]] && exit 0
  exit 1
fi
printf 'native:%s\n' "$*"
MOCK

cat >"$T/bin/fed" <<'MOCK'
#!/usr/bin/env bash
printf 'fed' >>"${FAKE_LOG:?}"; printf ' %q' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
[[ ${1:-} == images ]] && { printf 'FEDERATED IMAGES\n'; exit 0; }
exit 2
MOCK

cat >"$T/bin/rootfsctl" <<'MOCK'
#!/usr/bin/env bash
printf 'rootfs' >>"${FAKE_LOG:?}"; printf ' %q' "$@" >>"$FAKE_LOG"; printf '\n' >>"$FAKE_LOG"
[[ ${1:-} == prepare && ${2:-} == remote/app:2 ]] || exit 2
printf '{"source":"peer-rootfs","remote":true,"peer_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","peer_name":"peer-a","stub_ref":"litevmm-remote/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:stub","lowerdir":"%s"}\n' "$FAKE_LOWER"
MOCK

cat >"$T/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} == -n ]] && shift
exec "$@"
MOCK
chmod +x "$T/bin/"*

export FAKE_LOG="$LOG" FAKE_LOWER="$LOWER"
export LITEVMM_REAL_DOCKER="$T/bin/docker-real" VMAPI_DOCKER_FEDERATIONCTL="$T/bin/fed" VMAPI_DOCKER_ROOTFSCTL="$T/bin/rootfsctl" VMAPI_JQ=/usr/bin/jq
export PATH="$T/bin:/usr/bin:/bin"

out=$(bash "$ROOT/bin/litevmm-docker" images)
[[ $out == 'FEDERATED IMAGES' ]]
grep -Fq 'fed images' "$LOG"

# Explicit pull now means exactly what Docker normally means: store it locally.
: >"$LOG"
out=$(bash "$ROOT/bin/litevmm-docker" pull remote/app:2)
grep -Fq 'docker pull remote/app:2' "$LOG"
! grep -Fq 'rootfs prepare' "$LOG"

# Remote run is rewritten to the metadata stub plus LiteVMM remote-rootfs runtime.
: >"$LOG"
out=$(bash "$ROOT/bin/litevmm-docker" run --rm remote/app:2 echo hi)
grep -Fq 'rootfs prepare remote/app:2' "$LOG"
grep -Fq -- '--runtime litevmm-remote' "$LOG"
grep -Fq -- "--annotation io.litevmm.remote.lowerdir=$LOWER" "$LOG"
grep -Fq -- '--annotation io.litevmm.remote.image=remote/app:2' "$LOG"
grep -Fq -- 'litevmm-remote/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:stub echo hi' "$LOG"

# Local images remain completely native.
: >"$LOG"
out=$(bash "$ROOT/bin/litevmm-docker" run --rm local/app:1 echo hi)
grep -Fq 'docker run --rm local/app:1 echo hi' "$LOG"
! grep -Fq 'rootfs prepare' "$LOG"

# Explicit pull/platform/runtime semantics are never silently overridden.
: >"$LOG"
out=$(bash "$ROOT/bin/litevmm-docker" run --pull=never remote/app:2 echo hi)
grep -Fq 'docker run --pull=never remote/app:2 echo hi' "$LOG"
! grep -Fq 'rootfs prepare' "$LOG"

: >"$LOG"
out=$(bash "$ROOT/bin/litevmm-docker" run --platform linux/arm64 remote/app:2 echo hi)
grep -Fq 'docker run --platform linux/arm64 remote/app:2 echo hi' "$LOG"
! grep -Fq 'rootfs prepare' "$LOG"

: >"$LOG"
out=$(bash "$ROOT/bin/litevmm-docker" ps)
grep -Fq 'docker ps' "$LOG"
[[ $out == 'native:ps' ]]

echo 'LiteVMM Docker CLI zero-copy federation shim: PASS'
