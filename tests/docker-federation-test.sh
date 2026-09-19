#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
PEER=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
PEER2=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
mkdir -p "$T/bin" "$T/peers"
cat > "$T/peers/$PEER.conf" <<CFG
NAME=peer-b
NODE_ID=$PEER
URL=https://peer-b:5186
CFG
cat > "$T/peers/$PEER2.conf" <<CFG
NAME=peer-c
NODE_ID=$PEER2
URL=https://peer-c:5186
CFG

cat > "$T/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "${1:-} ${2:-}" in
  'image inspect') [[ ${3:-} == local/app:1 ]] || exit 1;;
  'image ls')
    printf '%s\n' '{"Repository":"local/app","Tag":"1","ID":"sha256:111","Size":"10MB","CreatedSince":"1 day ago"}';;
  *) echo "unexpected docker call: $*" >&2; exit 9;;
esac
MOCK

cat > "$T/bin/peerctl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == proxy ]] || exit 2
peer=${2:?}; method=${3:?}; path=${4:?}
case "$method $path" in
  'GET /docker/images')
    if [[ $peer == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]]; then
      printf '%s\n' '[{"Repository":"remote/app","Tag":"2","ID":"sha256:222","Size":"20MB","CreatedSince":"2 days ago"},{"Repository":"same/tag","Tag":"latest","ID":"sha256:aaa","Size":"11MB","CreatedSince":"2 days ago"}]'
    else
      printf '%s\n' '[{"Repository":"same/tag","Tag":"latest","ID":"sha256:bbb","Size":"12MB","CreatedSince":"3 days ago"}]'
    fi;;
  GET\ /docker/images?image=remote%2Fapp%3A2)
    [[ $peer == aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ]] || exit 22
    printf '%s\n' '[{"Id":"sha256:222","RepoTags":["remote/app:2"]}]';;
  GET\ /docker/images?image=*) exit 22;;
  *) exit 9;;
esac
MOCK
chmod +x "$T/bin/"*

export VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh"
export DOCKER_BIN="$T/bin/docker" VMAPI_PEERCTL="$T/bin/peerctl" VMAPI_PEER_ROOT="$T/peers"

catalog=$(bash "$ROOT/bin/docker-federationctl" catalog-json)
python3 - "$catalog" <<'PY'
import json,sys
rows={x["ref"]:x for x in json.loads(sys.argv[1])}
assert rows["local/app:1"]["local"] is True
assert rows["remote/app:2"]["local"] is False
assert rows["remote/app:2"]["sources"] == ["peer-b"]
assert rows["same/tag:latest"]["conflict"] is True
assert set(rows["same/tag:latest"]["sources"]) == {"peer-b","peer-c"}
PY
out=$(bash "$ROOT/bin/docker-federationctl" resolve remote/app:2)
[[ $out == *'"source":"peer"'* && $out == *'"peer_name":"peer-b"'* ]]
if grep -Eq 'materialize|peer-fetch|image save|image load' "$ROOT/bin/docker-federationctl"; then
  echo 'catalog helper still contains image-copy materialization code' >&2
  exit 1
fi
echo 'docker federation catalog: PASS'
