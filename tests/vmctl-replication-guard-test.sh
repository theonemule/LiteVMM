#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/vms/demo/runtime" "$T/disks/demo" "$T/isos" "$T/jobs/demo"
cat > "$T/vms/demo/vm.conf" <<'CFG'
NAME=demo
UUID=11111111-1111-1111-1111-111111111111
MEMORY_MB=512
VCPUS=1
MACHINE=q35
CPU=host
ALLOW_TCG=false
FIRMWARE=bios
AUTOSTART=false
DISPLAY=none
BOOT_ORDER=c
ISO=
CLOUD_INIT=false
DISK_0_FILE=disk0.qcow2
DISK_0_FORMAT=qcow2
DISK_0_BUS=virtio
CFG
: > "$T/disks/demo/disk0.qcow2"
printf 'PEER=%s\nSPEED=0\nDISK_0_JOB=repl-0\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa > "$T/jobs/demo/state.conf"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$T/vms" DISK_ROOT="$T/disks" ISO_ROOT="$T/isos" VMAPI_REPLICATION_JOB_ROOT="$T/jobs" QEMU_IMG=/bin/true)
if env "${common[@]}" bash "$ROOT/bin/vmctl" disk-set demo 0 bus sata >/dev/null 2>&1; then echo 'expected disk change to be blocked while replication is configured' >&2; exit 1; fi
if env "${common[@]}" bash "$ROOT/bin/vmctl" delete demo >/dev/null 2>&1; then echo 'expected VM delete to be blocked while replication is configured' >&2; exit 1; fi
rm -rf "$T/jobs/demo"
env "${common[@]}" bash "$ROOT/bin/vmctl" disk-set demo 0 bus sata
grep -Fxq 'DISK_0_BUS=sata' "$T/vms/demo/vm.conf"
echo 'vmctl replication topology guard: PASS'
