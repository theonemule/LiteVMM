#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state" "$T/registry" "$T/etc"
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
set -e
state=${FAKE_DOCKER_STATE:?}
printf '%s\n' "$*" >> "$state/docker.log"
case "$1 $2" in
  'image inspect') [[ -f "$state/image" ]];;
  'container inspect') [[ -f "$state/container" ]];;
  'inspect -f') [[ -f "$state/container" ]] && echo true || exit 1;;
  'image tag') exit 0;;
  'image push') echo pushed;;
  'image pull') echo pulled;;
  'rm -f') rm -f "$state/container";;
  'run -d') touch "$state/container"; echo fake-container;;
  'login peer.example:5186') cat >/dev/null; echo login-ok;;
  *)
    [[ $1 == pull ]] && touch "$state/image"
    exit 0;;
esac
SH
cat > "$T/bin/peerctl" <<'SH'
#!/usr/bin/env bash
set -e
case "$1" in
  overlay-profile) echo '{"node_id":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","endpoint":"wss://peer.example:5186/overlay","username":"pair-user","password":"pair-pass"}';;
  proxy) echo '{"username":"registry-user","password":"registry-pass","path":"/v2/"}';;
  *) exit 2;;
esac
SH
chmod +x "$T/bin/docker" "$T/bin/peerctl"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" DOCKER_BIN="$T/bin/docker" VMAPI_PEERCTL="$T/bin/peerctl" FAKE_DOCKER_STATE="$T/state" VMAPI_REGISTRY_ROOT="$T/registry" VMAPI_REGISTRY_CONFIG="$T/etc/registry.conf" VMAPI_REGISTRY_PASSWD_FILE="$T/etc/registry.htpasswd" VMAPI_REGISTRY_WEB_MODE=none)
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" enable testregistry)
[[ $out == *'"enabled":true'* && $out == *'"running":true'* ]]
cred=$(env "${common[@]}" bash "$ROOT/bin/registryctl" credentials)
[[ $cred == *'"username":"testregistry"'* && $cred == *'"password":"'* ]]
env "${common[@]}" bash "$ROOT/bin/registryctl" push alpine:latest team/app:latest >/dev/null
peer=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" peer-pull "$peer" team/app:latest)
[[ $out == *'"pulled":true'* && $out == *'peer.example:5186/team/app:latest'* ]]
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" peer-push "$peer" alpine:latest team/pushed:latest)
[[ $out == *'"published":true'* && $out == *'peer.example:5186/team/pushed:latest'* ]]
grep -Fq 'login peer.example:5186 --username registry-user --password-stdin' "$T/state/docker.log"
grep -Fq 'image pull peer.example:5186/team/app:latest' "$T/state/docker.log"
grep -Fq 'image push peer.example:5186/team/pushed:latest' "$T/state/docker.log"
out=$(env "${common[@]}" bash "$ROOT/bin/registryctl" disable)
[[ $out == *'"enabled":false'* ]]
echo 'local and peer registry lifecycle: PASS'
