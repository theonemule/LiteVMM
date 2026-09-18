#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/registry" "$T/etc" "$T/peer-images"
cat > "$T/bin/docker" <<'SH2'
#!/usr/bin/env bash
set -e
state=${FAKE_DOCKER_STATE:?}
printf '%s\n' "$*" >> "$state/docker.log"
case "${1:-} ${2:-}" in
  'image inspect')
    [[ ${3:-} == alpine:latest || ${3:-} == registry:3 || ${3:-} == 127.0.0.1:* ]] && exit 0
    exit 1;;
  'container inspect') [[ -f "$state/container" ]];;
  'inspect -f') [[ -f "$state/container" ]] && echo true || exit 1;;
  'image tag') exit 0;;
  'image push') echo pushed;;
  'image save')
    out=''; shift 2
    while (($#)); do case "$1" in --output) out=$2; shift 2;; *) shift;; esac; done
    printf 'fake image archive\n' > "$out";;
  'image load')
    [[ ${3:-} == --input ]] && file=${4:-} || file=${3:-}
    [[ -f $file ]]; echo 'Loaded image: team/app:latest';;
  'image rm') exit 0;;
  'rm -f') rm -f "$state/container";;
  'run -d') touch "$state/container"; echo fake-container;;
  *) [[ ${1:-} == pull ]] && exit 0; exit 0;;
esac
SH2
cat > "$T/bin/backplanectl" <<SH2
#!/usr/bin/env bash
set -e
[[ \${1:-} == path && \${3:-} == docker-images ]] || exit 2
mkdir -p "$T/peer-images"
printf '%s\n' "$T/peer-images"
SH2
chmod +x "$T/bin/docker" "$T/bin/backplanectl"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" DOCKER_BIN="$T/bin/docker" VMAPI_BACKPLANECTL="$T/bin/backplanectl" FAKE_DOCKER_STATE="$T/state" VMAPI_REGISTRY_ROOT="$T/registry" VMAPI_REGISTRY_CONFIG="$T/etc/registry.conf" VMAPI_REGISTRY_PASSWD_FILE="$T/etc/registry.htpasswd" VMAPI_REGISTRY_WEB_MODE=none)
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" enable testregistry)
[[ $out == *'"enabled":true'* && $out == *'"running":true'* ]]
env "${common[@]}" bash "$ROOT/bin/registryctl" push alpine:latest team/local:latest >/dev/null
peer=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" peer-push "$peer" alpine:latest team/app:latest)
[[ $out == *'"published":true'* && $out == *'"transport":"nfs4-wss-backplane"'* ]]
id=$(printf '%s' team/app:latest | sha256sum | cut -c1-24)
[[ -s "$T/peer-images/$id.tar" && $(cat "$T/peer-images/$id.ref") == team/app:latest ]]
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" peer-pull "$peer" team/app:latest)
[[ $out == *'"pulled":true'* && $out == *'"transport":"nfs4-wss-backplane"'* ]]
grep -Fq 'image save --output' "$T/state/docker.log"
grep -Fq 'image load --input' "$T/state/docker.log"
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" disable)
[[ $out == *'"enabled":false'* ]]
echo 'local registry and peer image backplane lifecycle: PASS'
