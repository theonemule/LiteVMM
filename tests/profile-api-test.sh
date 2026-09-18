#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
api(){
  local profile=$1 path=$2 server=${3:-false}
  local qemu="$T/no-qemu" docker="$T/no-docker"
  case "$profile" in
    virtualization) qemu="$T/qemu-system-x86_64";;
    docker) docker="$T/docker";;
    virtualization-docker) qemu="$T/qemu-system-x86_64"; docker="$T/docker";;
  esac
  cat > "$T/vmapi.conf" <<CFG
VMAPI_PROFILE=$profile
VMAPI_HTTP_PORT=5186
VMAPI_TLS_ENABLED=false
VMAPI_BACKPLANE_SERVER=$server
VM_ROOT=$T/vms
DISK_ROOT=$T/disks
ISO_ROOT=$T/isos
QEMU_BIN=$qemu
DOCKER_BIN=$docker
CFG
  REQUEST_METHOD=GET PATH_INFO="$path" VMAPI_CONFIG="$T/vmapi.conf" VMAPI_LIB="$ROOT/lib/common.sh" bash "$ROOT/cgi/api.cgi"
}

json_body(){ tr -d '\r' | awk 'blank{print} /^$/{blank=1}'; }

cat > "$T/qemu-system-x86_64" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/docker" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/qemu-system-x86_64" "$T/docker"

backup=$(api backup /api/ | json_body)
python3 - "$backup" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['profile']=='backup'
assert 'backup-storage' in x['capabilities']
assert 'storage-backplane' not in x['capabilities']
assert 'backplane-client' not in x['capabilities']
assert 'qemu-kvm' not in x['capabilities'] and 'docker' not in x['capabilities']
PY
backup_server=$(api backup /api/ true | json_body)
python3 - "$backup_server" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert 'storage-backplane' in x['capabilities']
PY

docker=$(api docker /api/ true | json_body)
python3 - "$docker" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert 'docker' in x['capabilities'] and 'registry' in x['capabilities']
assert 'backplane-client' in x['capabilities']
assert 'peer-volume-client' in x['capabilities']
assert 'backup' in x['capabilities'] and 'backup-storage' in x['capabilities']
assert 'storage-backplane' in x['capabilities']
assert 'qemu-kvm' not in x['capabilities']
PY

virt=$(api virtualization /api/ true | json_body)
python3 - "$virt" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
for cap in ('qemu-kvm','backup','backup-create','backup-storage','replication-source','backplane-client','storage-backplane'):
    assert cap in x['capabilities'], cap
assert 'docker' not in x['capabilities']
PY

combo=$(api virtualization-docker /api/ true | json_body)
python3 - "$combo" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
for cap in ('qemu-kvm','backup','backup-create','backup-storage','replication-source','docker','registry','peer-volume-client','backplane-client','storage-backplane'):
    assert cap in x['capabilities'], cap
PY
echo 'profile API filtering: PASS'
