#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/vms/demo/runtime"
cat > "$tmp/vms/demo/vm.conf" <<'EOF'
NAME=demo
UUID=11111111-1111-1111-1111-111111111111
MEMORY_MB=512
VCPUS=1
MACHINE=q35
CPU=host
FIRMWARE=bios
AUTOSTART=false
DISPLAY=none
BOOT_ORDER=c
ISO=
EOF

# Software emulation must be opt-in. A silent fallback pins host CPU and makes
# nested installers unusable, so the normal VM start path identifies the
# missing KVM device instead.
if VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$tmp/vms" IMAGE_ROOT="$tmp/images" \
  QEMU_BIN=/usr/bin/qemu-system-x86_64 KVM_DEVICE="$tmp/no-kvm" "$ROOT/bin/vmctl" command demo >"$tmp/out" 2>"$tmp/error"; then
  echo 'expected unavailable KVM to reject implicit software emulation' >&2
  exit 1
fi
grep -Fq 'KVM acceleration is unavailable' "$tmp/error"
printf 'ALLOW_TCG=true\n' >> "$tmp/vms/demo/vm.conf"
command=$(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$tmp/vms" IMAGE_ROOT="$tmp/images" \
  QEMU_BIN=/usr/bin/qemu-system-x86_64 KVM_DEVICE="$tmp/no-kvm" "$ROOT/bin/vmctl" command demo)
[[ $command == *'-cpu max'* ]]
[[ $command != *'-cpu host'* ]]
[[ $command == *'-accel tcg\,thread=multi'* ]]
echo 'vmctl acceleration guard: PASS'
