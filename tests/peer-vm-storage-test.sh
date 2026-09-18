#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
peer=0123456789abcdef0123456789abcdef
mkdir -p "$T/bin" "$T/vms" "$T/disks" "$T/isos" "$T/peer-disks" "$T/peer-isos"
chmod 0777 "$T/peer-disks"
printf x > "$T/peer-isos/remote.iso"; chmod 0644 "$T/peer-isos/remote.iso"
cat > "$T/bin/backplanectl" <<SCRIPT
#!/usr/bin/env bash
set -Eeuo pipefail
case "\$1" in
  path) mkdir -p "$T/peer-disks/\$4"; chmod 0777 "$T/peer-disks/\$4"; printf '%s\n' "$T/peer-disks/\$4";;
  shared-path) printf '%s/%s\n' "$T/peer-isos" "\$4";;
  *) exit 2;;
esac
SCRIPT
cat > "$T/bin/qemu-img" <<'SCRIPT'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  create) target=$4; mkdir -p "$(dirname "$target")"; : > "$target";;
  resize) :;;
  info) printf '%s\n' '{"virtual-size":1048576,"actual-size":0}';;
  *) exit 2;;
esac
SCRIPT
chmod +x "$T/bin/backplanectl" "$T/bin/qemu-img"
touch "$T/kvm"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$T/vms" DISK_ROOT="$T/disks" ISO_ROOT="$T/isos" VMAPI_BACKPLANECTL="$T/bin/backplanectl" QEMU_BIN=/bin/true QEMU_IMG="$T/bin/qemu-img" KVM_DEVICE="$T/kvm")
env "${common[@]}" bash "$ROOT/bin/vmctl" create demo --disk 1G --disk-location "peer:$peer" --iso remote.iso --iso-peer "$peer" --network none --display none >/dev/null
[[ -f "$T/peer-disks/demo/disk0.qcow2" ]]
grep -Fxq "DISK_0_LOCATION=peer:$peer" "$T/vms/demo/vm.conf"
grep -Fxq "ISO_PEER=$peer" "$T/vms/demo/vm.conf"
command=$(env "${common[@]}" bash "$ROOT/bin/vmctl" command demo)
grep -Fq "$T/peer-disks/demo/disk0.qcow2" <<<"$command"
grep -Fq "$T/peer-isos/remote.iso" <<<"$command"
env "${common[@]}" bash "$ROOT/bin/vmctl" disk-add demo --size 2G --location "peer:$peer" >/dev/null
[[ -f "$T/peer-disks/demo/disk1.qcow2" ]]
env "${common[@]}" bash "$ROOT/bin/vmctl" disk-remove demo 1 --delete-file
[[ ! -e "$T/peer-disks/demo/disk1.qcow2" ]]
env "${common[@]}" bash "$ROOT/bin/vmctl" delete demo
[[ ! -e "$T/peer-disks/demo/disk0.qcow2" ]]
echo 'peer VM storage: PASS'
