#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/ss" <<'SS'
#!/usr/bin/env bash
case "$*" in
  *-ltnH*) printf '%s\n' 'LISTEN 0 128 127.0.0.1:2049 0.0.0.0:*' 'LISTEN 0 128 127.0.0.1:6091 0.0.0.0:*';;
  *-lunH*) :;;
esac
SS
chmod +x "$T/ss"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_BACKPLANE_SERVER=true VMAPI_SS="$T/ss")
out=$(env "${common[@]}" bash "$ROOT/bin/backplanectl" server-status)
[[ $out == *'"nfs_bind":"127.0.0.1"'* ]]
[[ $out == *'"nfs_listening":true'* && $out == *'"websocket_listening":true'* ]]
[[ $out == *'"external_exposure":false'* ]]

cat > "$T/ss" <<'SS'
#!/usr/bin/env bash
case "$*" in
  *-ltnH*) printf '%s\n' 'LISTEN 0 128 0.0.0.0:2049 0.0.0.0:*' 'LISTEN 0 128 127.0.0.1:6091 0.0.0.0:*';;
  *-lunH*) :;;
esac
SS
out=$(env "${common[@]}" VMAPI_BACKPLANE_NFS_BIND=0.0.0.0 bash "$ROOT/bin/backplanectl" server-status)
[[ $out == *'"external_exposure":true'* ]]
echo 'backplane loopback exposure checks: PASS'
