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
chmod 0755 "$T/etc"
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" enable testregistry)
[[ $(stat -c %a "$T/etc") == 755 ]] || { echo "registryctl enable re-moded the config directory"; exit 1; }
[[ $out == *'"enabled":true'* && $out == *'"running":true'* ]]
env "${common[@]}" bash "$ROOT/bin/registryctl" push alpine:latest team/local:latest >/dev/null
grep -Fq 'image tag alpine:latest 127.0.0.1:5000/team/local:latest' "$T/state/docker.log"
grep -Fq 'image push 127.0.0.1:5000/team/local:latest' "$T/state/docker.log"

# The registry is optional distribution infrastructure, not LiteVMM federation.
! grep -Eq 'peer-(pull|push|fetch)|shared-list|image save|image load|docker-images' "$ROOT/bin/registryctl" || { echo "negative assertion failed: tests/registryctl-test.sh:35" >&2; exit 1; }

out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" disable)
[[ $out == *'"enabled":false'* ]]
echo 'optional local OCI registry lifecycle: PASS'

# lighttpd mode: generated config must be accepted by lighttpd, and a rejected config must be rolled back.
mkdir -p "$T/lighttpd/conf.d"; : > "$T/lighttpd/lighttpd.conf"
cat >"$T/bin/lighttpd" <<'MOCK'
#!/usr/bin/env bash
# Mimic lighttpd 1.4.x: proxy.header only accepts known keys.
[[ -n ${FAKE_LIGHTTPD_FAIL:-} ]] && { echo 'forced failure' >&2; exit 255; }
if grep -hE 'proxy\.header' "$(dirname "${@: -1}")"/conf.d/*.conf 2>/dev/null | grep -Eq '"host"'; then
  echo '(../src/mod_proxy.c.287) unexpected key for proxy.header: host' >&2; exit 255; fi
exit 0
MOCK
chmod +x "$T/bin/lighttpd"; printf '#!/bin/sh\nexit 0\n' >"$T/bin/reload"; chmod +x "$T/bin/reload"
lt=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" DOCKER_BIN="$T/bin/docker" FAKE_DOCKER_STATE="$T/state" VMAPI_REGISTRY_ROOT="$T/registry" VMAPI_REGISTRY_CONFIG="$T/etc/registry.conf" VMAPI_REGISTRY_PASSWD_FILE="$T/etc/registry.htpasswd" VMAPI_REGISTRY_WEB_MODE=lighttpd VMAPI_LIGHTTPD_ROOT="$T/lighttpd" VMAPI_WEB_RELOAD="$T/bin/reload" PATH="$T/bin:$PATH")
out=$(env "${lt[@]}" bash "$ROOT/bin/registryctl" enable testregistry)
[[ $out == *'"enabled":true'* ]]
grep -Fq 'proxy.server' "$T/lighttpd/conf.d/zz-vmapi-registry.conf"
! grep -Fq 'proxy.header' "$T/lighttpd/conf.d/zz-vmapi-registry.conf" || { echo "negative assertion failed: tests/registryctl-test.sh:56" >&2; exit 1; }
env "${lt[@]}" bash "$ROOT/bin/registryctl" disable >/dev/null
[[ ! -s "$T/lighttpd/conf.d/zz-vmapi-registry.conf" ]]
if env "${lt[@]}" FAKE_LIGHTTPD_FAIL=1 bash "$ROOT/bin/registryctl" enable testregistry >/dev/null 2>&1; then echo 'expected enable to fail'; exit 1; fi
[[ ! -s "$T/lighttpd/conf.d/zz-vmapi-registry.conf" ]]
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" status)
[[ $out == *'"enabled":false'* && $out == *'"running":false'* ]]
echo 'registry lighttpd proxy config + rollback: PASS'
