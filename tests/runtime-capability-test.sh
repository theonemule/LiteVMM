#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/vmapi.conf" <<CFG
VMAPI_PROFILE=virtualization
VMAPI_HTTP_PORT=5186
VMAPI_TLS_ENABLED=false
VMAPI_BACKPLANE_SERVER=true
QEMU_BIN=$T/bin/qemu-system-x86_64
DOCKER_BIN=$T/bin/docker
CFG

cat > "$T/bin/qemu-system-x86_64" <<'MOCK'
#!/bin/sh
exit 0
MOCK

cat > "$T/bin/docker" <<'MOCK'
#!/bin/sh
exit 0
MOCK

cat > "$T/bin/dockerctl" <<'MOCK'
#!/bin/sh
case "$1" in
  list-json) printf '%s
' '{"Name":"demo","State":"running","Image":"alpine","Status":"Up"}';;
  *) exit 2;;
esac
MOCK

chmod +x "$T/bin/qemu-system-x86_64" "$T/bin/docker" "$T/bin/dockerctl"

out=$(
  PATH="$T/bin:/usr/bin:/bin"   VMAPI_CONFIG="$T/vmapi.conf"   VMAPI_LIB="$ROOT/lib/common.sh"   REQUEST_METHOD=GET   PATH_INFO=/api/   REMOTE_USER=test   bash "$ROOT/cgi/api.cgi"
)

body=$(printf '%s
' "$out" | tr -d '' | sed '1,/^$/d')
python3 - "$body" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["configured_profile"] == "virtualization"
assert x["profile"] == "virtualization-docker"
for cap in ("qemu-kvm","docker","compose","container-terminal","backup","backup-storage","storage-backplane"):
    assert cap in x["capabilities"], cap
PY

docker_out=$(
  PATH="$T/bin:/usr/bin:/bin"   VMAPI_CONFIG="$T/vmapi.conf"   VMAPI_LIB="$ROOT/lib/common.sh"   DOCKERCTL="$T/bin/dockerctl"   REQUEST_METHOD=GET   PATH_INFO=/api/docker/containers   REMOTE_USER=test   bash "$ROOT/cgi/api.cgi"
)

docker_body=$(printf '%s
' "$docker_out" | tr -d '' | sed '1,/^$/d')
python3 - "$docker_body" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert isinstance(x,list) and x and x[0]["Name"] == "demo"
PY

echo 'runtime capability detection: PASS'
