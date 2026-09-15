#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/vms/demo/runtime"
cat > "$T/vms/demo/vm.conf" <<'CFG'
NAME=demo
UUID=11111111-1111-1111-1111-111111111111
MEMORY_MB=2048
VCPUS=2
DISK_0_FILE=disk0.qcow2
DISK_0_FORMAT=qcow2
DISK_0_BUS=virtio
NIC_0_MODE=nat
NIC_0_MODEL=virtio-net-pci
NIC_0_MAC=52:54:00:00:00:01
NIC_0_BRIDGE=
CFG
truncate -s 1048576 "$T/vms/demo/disk0.qcow2"

cat > "$T/qemu-img" <<'MOCK'
#!/usr/bin/env bash
cat <<'JSON'
{"virtual-size":10737418240,"actual-size":268435456,"format":"qcow2"}
JSON
MOCK
chmod +x "$T/qemu-img"

cat > "$T/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ ${1:-} == container && ${2:-} == inspect ]]; then
  if [[ "$*" == *'--size'* ]]; then echo '10485760|52428800'; exit 0; fi
  if [[ "$*" == *'--format'* ]]; then echo 'running|2000000000|536870912|0|0'; exit 0; fi
  echo '[{"Name":"/web"}]'; exit 0
fi
if [[ ${1:-} == stats ]]; then
  echo '50.00%|128MiB / 512MiB|25.00%|1.5MB / 2.5MB|3MB / 4MB|5'; exit 0
fi
echo "unhandled: $*" >&2; exit 9
MOCK
chmod +x "$T/docker"

export VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_CONFIG=/dev/null VM_ROOT="$T/vms" IMAGE_ROOT="$T/images" QEMU_IMG="$T/qemu-img" DOCKER_BIN="$T/docker" METRICS_SAMPLE_INTERVAL=0.01

"$ROOT/bin/metricsctl" host > "$T/host.json"
"$ROOT/bin/metricsctl" vm demo > "$T/vm.json"
"$ROOT/bin/metricsctl" container web > "$T/container.json"
python3 - <<PY
import json
for f in ['host.json','vm.json','container.json']:
    json.load(open('$T/'+f))
vm=json.load(open('$T/vm.json'))
assert vm['disk']['virtual_bytes']==10737418240
assert vm['disk']['host_allocated_bytes']==268435456
ctr=json.load(open('$T/container.json'))
assert ctr['memory']['used_bytes']==134217728
assert ctr['cpu']['allocated_cpus']==2
assert ctr['disk']['writable_layer_bytes']==10485760
PY

out=$(REQUEST_METHOD=GET PATH_INFO=/api/metrics METRICSCTL="$ROOT/bin/metricsctl" VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" "$ROOT/cgi/api.cgi")
grep -q 'Status: 200 OK' <<< "$out"
grep -q '"scope":"host"' <<< "$out"

out=$(REQUEST_METHOD=GET PATH_INFO=/api/vms/demo/metrics METRICSCTL="$ROOT/bin/metricsctl" VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" "$ROOT/cgi/api.cgi")
grep -q '"scope":"vm"' <<< "$out"

out=$(REQUEST_METHOD=GET PATH_INFO=/api/docker/containers/web/metrics METRICSCTL="$ROOT/bin/metricsctl" VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" "$ROOT/cgi/api.cgi")
grep -q '"scope":"container"' <<< "$out"

echo 'metrics smoke: PASS'
