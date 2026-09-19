#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/registry" "$T/etc"

cat >"$T/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
state=${FAKE_DOCKER_STATE:?}
printf '%s\n' "$*" >>"$state/docker.log"
case "${1:-} ${2:-}" in
  'image inspect') [[ ${3:-} == alpine:latest || ${3:-} == registry:3 || ${3:-} == 127.0.0.1:* ]] || exit 1;;
  'container inspect') [[ -f "$state/container" ]];;
  'inspect -f') [[ -f "$state/container" ]] && echo true || exit 1;;
  'image tag') exit 0;;
  'image push') echo pushed;;
  'rm -f') rm -f "$state/container";;
  'run -d') touch "$state/container"; echo fake-container;;
  *) [[ ${1:-} == pull ]] && exit 0; exit 0;;
esac
MOCK
chmod +x "$T/bin/docker"

common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" DOCKER_BIN="$T/bin/docker" FAKE_DOCKER_STATE="$T/state" VMAPI_REGISTRY_ROOT="$T/registry" VMAPI_REGISTRY_CONFIG="$T/etc/registry.conf" VMAPI_REGISTRY_PASSWD_FILE="$T/etc/registry.htpasswd" VMAPI_REGISTRY_WEB_MODE=none)
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" enable testregistry)
[[ $out == *'"enabled":true'* && $out == *'"running":true'* ]]
env "${common[@]}" bash "$ROOT/bin/registryctl" push alpine:latest team/local:latest >/dev/null
grep -Fq 'image tag alpine:latest 127.0.0.1:5000/team/local:latest' "$T/state/docker.log"
grep -Fq 'image push 127.0.0.1:5000/team/local:latest' "$T/state/docker.log"

# The registry is optional distribution infrastructure, not LiteVMM federation.
! grep -Eq 'peer-(pull|push|fetch)|shared-list|image save|image load|docker-images' "$ROOT/bin/registryctl"

out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" disable)
[[ $out == *'"enabled":false'* ]]
echo 'optional local OCI registry lifecycle: PASS'
