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
# Real qemu-img >= 8.0 shape: the protocol child's sizes (the host file) come
# first and must not be mistaken for the image's own.
cat <<'JSON'
{
    "children": [
        {
            "name": "file",
            "info": {
                "children": [
                ],
                "virtual-size": 268500992,
                "filename": "disk0.qcow2",
                "format": "file",
                "actual-size": 111
            }
        }
    ],
    "virtual-size": 10737418240,
    "filename": "disk0.qcow2",
    "format": "qcow2",
    "actual-size": 268435456
}
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

# Host gauges: storage matches df's Use% (used / (used + available)), so the
# root-reserved blocks cannot hide a nearly full disk; memory says whether a
# hypervisor balloon sets its total; the platform is never blank.
"$ROOT/bin/metricsctl" system > "$T/system.json"
python3 - "$T/host.json" "$T/system.json" <<'PY2'
import json, sys
h = json.load(open(sys.argv[1])); s = json.load(open(sys.argv[2]))
d = h['disk']; expect = round(d['used_bytes'] * 100 / (d['used_bytes'] + d['available_bytes']), 2)
assert abs(d['utilization_percent'] - expect) < 0.011, (d, expect)
assert h['memory']['balloon'] in ('hyperv', 'virtio', 'none'), h['memory']
# Memory: total is physical RAM (zoneinfo "present"), never below the kernel's
# MemTotal; used is MemTotal - MemAvailable; the percentage is used / physical.
m = h['memory']
assert m['total_bytes'] >= m['assigned_bytes'] > 0, m
assert m['used_bytes'] == m['assigned_bytes'] - m['available_bytes'], m
assert abs(m['utilization_percent'] - round(m['used_bytes'] * 100 / m['total_bytes'], 2)) < 0.011, m
assert s['hardware']['memory_total_bytes'] >= m['assigned_bytes'], s['hardware']
# Disk: when a single backing disk is found it is at least the filesystem size.
if d['device_bytes'] is not None: assert d['device'] and d['device_bytes'] >= d['total_bytes'], d
assert s['host']['virtualization_type'], s['host']
PY2

echo 'metrics smoke: PASS'
