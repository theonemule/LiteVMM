#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
api(){ local profile=$1 path=$2; cat > "$T/vmapi.conf" <<CFG
VMAPI_PROFILE=$profile
VMAPI_HTTP_PORT=5186
VMAPI_TLS_ENABLED=false
VM_ROOT=$T/vms
DISK_ROOT=$T/disks
ISO_ROOT=$T/isos
CFG
  REQUEST_METHOD=GET PATH_INFO="$path" VMAPI_CONFIG="$T/vmapi.conf" VMAPI_LIB="$ROOT/lib/common.sh" bash "$ROOT/cgi/api.cgi"
}
json_body(){ tr -d '\r' | awk 'blank{print} /^$/{blank=1}'; }

backup=$(api backup /api/ | json_body)
python3 - "$backup" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['profile']=='backup'
assert x['port']==5186
assert 'backup-receiver' in x['capabilities']
assert 'replication-receiver' in x['capabilities']
assert 'replication-source' not in x['capabilities']
assert 'qemu-kvm' not in x['capabilities']
assert 'docker' not in x['capabilities']
PY
blocked=$(api backup /api/vms)
[[ $blocked == *'Status: 404 Not Found'* && $blocked == *'qemu-kvm'* ]]
blocked=$(api backup /api/backups/schedules)
[[ $blocked == *'Status: 404 Not Found'* && $blocked == *'require the virtualization profile'* ]]

docker=$(api docker /api/ | json_body)
python3 - "$docker" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['profile']=='docker'
assert 'docker' in x['capabilities'] and 'compose' in x['capabilities'] and 'registry' in x['capabilities']
assert 'qemu-kvm' not in x['capabilities'] and 'backup' not in x['capabilities']
assert 'replication-source' not in x['capabilities'] and 'replication-receiver' not in x['capabilities']
PY

virt=$(api virtualization /api/ | json_body)
python3 - "$virt" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['profile']=='virtualization'
for cap in ('qemu-kvm','backup','backup-create','vm-network','cloud-init','replication-source','replication-receiver'):
    assert cap in x['capabilities']
assert 'docker' not in x['capabilities']
PY


combo=$(api virtualization-docker /api/ | json_body)
python3 - "$combo" <<'PY2'
import json,sys
x=json.loads(sys.argv[1])
assert x['profile']=='virtualization-docker'
for cap in ('qemu-kvm','backup','backup-create','vm-network','cloud-init','replication-source','replication-receiver','docker','compose','container-terminal','registry'):
    assert cap in x['capabilities'], cap
PY2

echo 'profile API filtering: PASS'
