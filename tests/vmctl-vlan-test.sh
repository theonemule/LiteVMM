#!/usr/bin/env bash
# Verify that VLAN-tagged bridged NICs use a managed TAP and preserve VLAN metadata.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/vms/demo/runtime" "$tmp/disks/demo" "$tmp/images"
touch "$tmp/kvm"
cat > "$tmp/vms/demo/vm.conf" <<'EOF'
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
NIC_0_MODE=bridge
NIC_0_MODEL=virtio-net-pci
NIC_0_MAC=52:54:00:11:22:33
NIC_0_BRIDGE=br0
NIC_0_OVERLAY=
NIC_0_VLAN=42
EOF
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$tmp/vms" DISK_ROOT="$tmp/disks" ISO_ROOT="$tmp/images" QEMU_BIN=/bin/true QEMU_IMG=/bin/true KVM_DEVICE="$tmp/kvm")
command=$(env "${common[@]}" bash "$ROOT/bin/vmctl" command demo)
[[ $command == *'ifname=tap'* ]]
[[ $command == *'script=no'* && $command == *'downscript=no'* ]]
[[ $command != *'bridge\,id=net0'* ]]
env "${common[@]}" bash "$ROOT/bin/vmctl" nic-set demo 0 vlan 4094
grep -Fxq 'NIC_0_VLAN=4094' "$tmp/vms/demo/vm.conf"
if env "${common[@]}" bash "$ROOT/bin/vmctl" nic-set demo 0 vlan 4095 >/dev/null 2>&1; then
  echo 'expected VLAN 4095 to be rejected' >&2; exit 1
fi
echo 'vmctl vlan configuration: PASS'
