#!/usr/bin/env bash
# Real LiteVMM VM lifecycle in a disposable privileged container on a KVM host.
# Never mounts the host VM store and creates no guest network interfaces.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v docker >/dev/null
docker info >/dev/null
docker run --rm --privileged --network bridge --memory 1536m --cpus 2 \
  -v "$ROOT:/src:ro" alpine:3.24 /bin/sh -ec '
  apk add --no-cache -q bash coreutils qemu-system-x86_64 qemu-img jq openssl socat >/dev/null
  test -c /dev/kvm || { echo "KVM device unavailable to the disposable test container" >&2; exit 1; }
  export VM_ROOT=/tmp/ci-vms DISK_ROOT=/tmp/ci-disks ISO_ROOT=/tmp/ci-isos
  export VMAPI_LIB=/src/lib/common.sh VMAPI_CONFIG=/dev/null
  export QEMU_BIN=/usr/bin/qemu-system-x86_64 QEMU_IMG=/usr/bin/qemu-img
  mkdir -p "$VM_ROOT" "$DISK_ROOT" "$ISO_ROOT"
  cleanup() {
    bash /src/bin/vmctl stop ci-kvm-smoke --force >/dev/null 2>&1 || true
    bash /src/bin/vmctl delete ci-kvm-smoke >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  bash /src/bin/vmctl create ci-kvm-smoke --memory 256 --cpus 1 \
    --disk 64M --network none --display none >/dev/null
  test -s "$VM_ROOT/ci-kvm-smoke/vm.conf"
  qemu-img info "$DISK_ROOT/ci-kvm-smoke/disk0.qcow2" | grep -q "file format: qcow2"
  bash /src/bin/vmctl start ci-kvm-smoke >/dev/null
  test "$(bash /src/bin/vmctl status ci-kvm-smoke)" = running
  bash /src/bin/vmctl stop ci-kvm-smoke --force
  test "$(bash /src/bin/vmctl status ci-kvm-smoke)" = stopped
  bash /src/bin/vmctl delete ci-kvm-smoke
  test ! -e "$VM_ROOT/ci-kvm-smoke"
  test ! -e "$DISK_ROOT/ci-kvm-smoke"
  echo "PASS: real LiteVMM KVM VM create/start/status/stop/delete with qcow2"
'
