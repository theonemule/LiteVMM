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
cat > "$T/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/bin/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/qemu-system-x86_64" "$T/bin/docker"

out=$(PATH="$T/bin:/usr/bin:/bin" \
  VMAPI_CONFIG="$T/vmapi.conf" \
  VMAPI_LIB="$ROOT/lib/common.sh" \
  REQUEST_METHOD=GET \
  PATH_INFO=/api/ \
  REMOTE_USER=test \
  bash "$ROOT/cgi/api.cgi")

body=$(printf '%s\n' "$out" | tr -d '\r' | sed '1,/^$/d')
python3 - "$body" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["configured_profile"] == "virtualization"
assert x["profile"] == "virtualization-docker"
for cap in ("qemu-kvm","docker","compose","container-terminal","backup","backup-storage","storage-backplane"):
    assert cap in x["capabilities"], cap
PY

echo 'runtime capability detection: PASS'
