#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T"/{state,docker-state,remote/backplane/peers/source/docker-volumes}
PEER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
cat > "$T/backplanectl" <<SH2
#!/usr/bin/env bash
set -e
case "\${1:-}" in
  path) mkdir -p "$T/remote/docker-volumes/\${4}"; printf '%s\n' "$T/remote/docker-volumes/\${4}";;
  show) printf '%s\n' '{"mounted":true,"tunnel_running":true}';;
  reconcile) printf '%s\n' '{"ok":true}';;
  *) exit 2;;
esac
SH2
cat > "$T/fake-docker" <<'SH2'
#!/usr/bin/env bash
set -e
root=${FAKE_DOCKER_ROOT:?}
if [[ ${1:-} == volume && ${2:-} == inspect ]]; then [[ -f "$root/${3:-}" ]]; exit; fi
if [[ ${1:-} == volume && ${2:-} == create ]]; then name=${!#}; touch "$root/$name"; printf '%s\n' "$name"; exit; fi
if [[ ${1:-} == volume && ${2:-} == rm ]]; then rm -f "$root/${3:-}"; exit; fi
exit 2
SH2
chmod +x "$T/backplanectl" "$T/fake-docker"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_BACKPLANECTL="$T/backplanectl" DOCKER_BIN="$T/fake-docker" FAKE_DOCKER_ROOT="$T/docker-state" VMAPI_PEER_VOLUME_STATE_ROOT="$T/state" VMAPI_BACKPLANE_ROOT="$T/remote/backplane")
out=$(env "${common[@]}" bash "$ROOT/bin/peer-volumectl" attach "$PEER" appdata peerdata)
[[ $out == *'"transport":"nfs4-wss-backplane"'* ]]
[[ -f "$T/docker-state/peerdata" && -f "$T/state/peerdata.conf" ]]
printf 'persist\n' > "$T/remote/docker-volumes/appdata/file.txt"
env "${common[@]}" bash "$ROOT/bin/peer-volumectl" detach peerdata >/dev/null
[[ ! -f "$T/docker-state/peerdata" && ! -f "$T/state/peerdata.conf" ]]
[[ $(cat "$T/remote/docker-volumes/appdata/file.txt") == persist ]]

mkdir -p "$T/remote/backplane/peers/$PEER/docker-volumes/hosted"
printf x > "$T/remote/backplane/peers/$PEER/docker-volumes/hosted/x"
list=$(env "${common[@]}" bash "$ROOT/bin/peer-volumectl" list-hosted)
[[ $list == *'"name":"hosted"'* && $list == *'"transport":"nfs4-wss-backplane"'* ]]
echo 'peer Docker volume backplane lifecycle: PASS'
