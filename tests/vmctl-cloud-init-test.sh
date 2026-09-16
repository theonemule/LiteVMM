#!/usr/bin/env bash
# Verify NoCloud user-data lifecycle and QEMU seed attachment without requiring xorriso on the test host.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/vms/demo/runtime" "$tmp/disks/demo" "$tmp/images" "$tmp/bin"
touch "$tmp/kvm"
cat > "$tmp/vms/demo/vm.conf" <<'CFG'
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
VNC_BIND=127.0.0.1
VNC_DISPLAY=
BOOT_ORDER=c
ISO=
CLOUD_INIT=false
CFG
cat > "$tmp/bin/xorriso" <<'SH'
#!/usr/bin/env bash
set -e
out=''
while (($#)); do
  if [[ $1 == -output ]]; then out=${2:?}; shift 2; else shift; fi
done
[[ -n $out ]]
printf 'fake-iso\n' > "$out"
SH
chmod +x "$tmp/bin/xorriso"
common=(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VM_ROOT="$tmp/vms" DISK_ROOT="$tmp/disks" ISO_ROOT="$tmp/images" QEMU_BIN=/bin/true QEMU_IMG=/bin/true KVM_DEVICE="$tmp/kvm" XORRISO_BIN="$tmp/bin/xorriso")
user_data=$'#cloud-config\npackages:\n  - curl\nruncmd:\n  - echo hello > /tmp/cloud-init-worked'
id1=$(printf '%s' "$user_data" | env "${common[@]}" bash "$ROOT/bin/vmctl" cloud-init-set demo --hostname demo-ci)
grep -Fxq 'CLOUD_INIT=true' "$tmp/vms/demo/vm.conf"
grep -Fxq 'local-hostname: demo-ci' "$tmp/vms/demo/cloud-init/meta-data"
grep -Fxq '#cloud-config' "$tmp/vms/demo/cloud-init/user-data"
[[ -s "$tmp/vms/demo/cloud-init/seed.iso" ]]
show=$(env "${common[@]}" bash "$ROOT/bin/vmctl" cloud-init-show demo)
python3 - "$show" "$id1" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x['enabled'] is True
assert x['instance_id']==sys.argv[2]
assert x['local_hostname']=='demo-ci'
assert x['user_data'].startswith('#cloud-config\n')
PY
command=$(env "${common[@]}" bash "$ROOT/bin/vmctl" command demo)
[[ $command == *'cloud-init/seed.iso'* && $command == *'media=cdrom'* ]]
id2=$(printf '%s' "$user_data" | env "${common[@]}" bash "$ROOT/bin/vmctl" cloud-init-set demo --hostname demo-ci)
[[ $id1 != "$id2" ]]
env "${common[@]}" bash "$ROOT/bin/vmctl" cloud-init-disable demo
grep -Fxq 'CLOUD_INIT=false' "$tmp/vms/demo/vm.conf"
[[ ! -e "$tmp/vms/demo/cloud-init" ]]
command=$(env "${common[@]}" bash "$ROOT/bin/vmctl" command demo)
[[ $command != *'cloud-init/seed.iso'* ]]
grep -Fq -- '-volid cidata' "$ROOT/bin/vmctl"
echo 'vmctl cloud-init provisioning: PASS'
