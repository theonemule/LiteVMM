#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T"/{hosted,shares,mount-state,mounts,run}
common=(
  VMAPI_CONFIG=/dev/null
  VMAPI_LIB="$ROOT/lib/common.sh"
  VMAPI_REMOTE_VOLUME_ROOT="$T/hosted"
  VMAPI_REMOTE_VOLUME_SHARE_ROOT="$T/shares"
  VMAPI_REMOTE_MOUNT_STATE_ROOT="$T/mount-state"
  VMAPI_REMOTE_MOUNT_ROOT="$T/mounts"
  VMAPI_REMOTE_VOLUME_RUN_ROOT="$T/run"
  VMAPI_REMOTE_FS_USER="$(id -un)"
)
ctl(){ env "${common[@]}" bash "$ROOT/bin/remote-volumectl" "$@"; }
out=$(ctl share-create peer-user appdata)
id=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])' <<<"$out")
[[ $id =~ ^[a-f0-9]{24}$ ]]
[[ $(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["active"])' <<<"$out") == True ]]
# Same peer/name reuses the durable share rather than creating another namespace.
out2=$(ctl share-create peer-user appdata)
[[ $(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])' <<<"$out2") == "$id" ]]
printf 'durable-data\n' > "$T/hosted/peer-user/appdata/example.txt"
ctl share-stop peer-user "$id" >/dev/null
show=$(ctl share-show peer-user "$id")
[[ $(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["active"])' <<<"$show") == False ]]
ctl share-start peer-user "$id" >/dev/null
ctl share-stop-admin "$id" >/dev/null
ctl share-purge "$id" false >/dev/null
[[ ! -e "$T/shares/$id.json" ]]
[[ $(cat "$T/hosted/peer-user/appdata/example.txt") == durable-data ]]
# Reattaching after metadata removal must rediscover the same data path.
out3=$(ctl share-create peer-user appdata)
id3=$(python3 -c 'import json,sys; print(json.loads(sys.stdin.read())["id"])' <<<"$out3")
[[ $id3 != "$id" ]]
[[ $(cat "$T/hosted/peer-user/appdata/example.txt") == durable-data ]]
ctl share-stop peer-user "$id3" >/dev/null
ctl share-purge "$id3" true >/dev/null
[[ ! -e "$T/hosted/peer-user/appdata" ]]
echo 'remote volume share lifecycle: PASS'
