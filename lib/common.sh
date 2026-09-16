#!/usr/bin/env bash
# Purpose: VMAPI installation or runtime maintenance script.
# Run on the target host with the documented privileges and arguments; it manages system-level VMAPI resources.
set -Eeuo pipefail

VMAPI_CONFIG=${VMAPI_CONFIG:-/etc/vmapi/vmapi.conf}
[[ -r "$VMAPI_CONFIG" ]] && source "$VMAPI_CONFIG"

VMAPI_PROFILE=${VMAPI_PROFILE:-virtualization}
VMAPI_HTTP_PORT=${VMAPI_HTTP_PORT:-5186}
VMAPI_TLS_ENABLED=${VMAPI_TLS_ENABLED:-false}

valid_vmapi_profile() { [[ ${1:-} == virtualization || ${1:-} == docker || ${1:-} == virtualization-docker || ${1:-} == backup ]]; }
vmapi_has_capability() {
  local cap=${1:-}
  case "$cap" in
    api|system|metrics|cluster|admin) return 0;;
    backup) [[ $VMAPI_PROFILE == virtualization || $VMAPI_PROFILE == virtualization-docker || $VMAPI_PROFILE == backup ]];;
    backup-create|qemu-kvm|vm-network|vm-console|storage) [[ $VMAPI_PROFILE == virtualization || $VMAPI_PROFILE == virtualization-docker ]];;
    docker|compose|container-terminal) [[ $VMAPI_PROFILE == docker || $VMAPI_PROFILE == virtualization-docker ]];;
    files|host-terminal) [[ $VMAPI_PROFILE == virtualization || $VMAPI_PROFILE == docker || $VMAPI_PROFILE == virtualization-docker ]];;
    *) return 1;;
  esac
}

# VM_ROOT contains only VM configuration, firmware state, and transient runtime
# sockets.  Virtual disks are deliberately kept on a separate filesystem tree so
# they can be placed on storage with different performance or retention needs.
VM_ROOT=${VM_ROOT:-/var/lib/vmapi/vms}
DISK_ROOT=${DISK_ROOT:-/var/lib/vmapi/disks}
# IMAGE_ROOT was the original public setting.  Keep it as a fallback so an
# upgraded installation that has not yet changed its config continues to find
# its existing installation media.
ISO_ROOT=${ISO_ROOT:-${IMAGE_ROOT:-/var/lib/vmapi/isos}}
IMAGE_ROOT=$ISO_ROOT
QEMU_BIN=${QEMU_BIN:-/usr/bin/qemu-system-x86_64}
QEMU_IMG=${QEMU_IMG:-/usr/bin/qemu-img}
# Can be overridden by tests or unusual host configurations.  `host` CPU
# passthrough is only valid when this device is usable by the VMAPI worker.
KVM_DEVICE=${KVM_DEVICE:-/dev/kvm}
DEFAULT_MACHINE=${DEFAULT_MACHINE:-q35}
DEFAULT_CPU=${DEFAULT_CPU:-host}
DEFAULT_MEMORY_MB=${DEFAULT_MEMORY_MB:-2048}
DEFAULT_VCPUS=${DEFAULT_VCPUS:-2}
DEFAULT_DISK_FORMAT=${DEFAULT_DISK_FORMAT:-qcow2}
DEFAULT_DISK_BUS=${DEFAULT_DISK_BUS:-virtio}
DEFAULT_NIC_MODEL=${DEFAULT_NIC_MODEL:-virtio-net-pci}
DEFAULT_VNC_BIND=${DEFAULT_VNC_BIND:-127.0.0.1}
STOP_TIMEOUT=${STOP_TIMEOUT:-20}

err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
need_cmd() { command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"; }

validate_vm_name() {
  [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || die "Invalid VM name: ${1:-}"
}
validate_filename() {
  local n=${1:-}
  [[ -n "$n" && "$n" != */* && "$n" != .* && "$n" =~ ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$ ]] || die "Invalid filename: $n"
}
validate_int() { [[ ${1:-} =~ ^[0-9]+$ ]] || die "Expected integer: ${1:-}"; }
validate_positive_int() { validate_int "$1"; (( 10#$1 > 0 )) || die "Expected positive integer: $1"; }
validate_bool() { [[ ${1:-} == true || ${1:-} == false ]] || die "Expected true or false"; }
validate_size() { [[ ${1:-} =~ ^[1-9][0-9]*([KMGTP])?$ ]] || die "Invalid size: ${1:-}"; }
validate_no_newline() { [[ ${1:-} != *$'\n'* && ${1:-} != *$'\r'* ]] || die "Newlines are not allowed"; }

vm_dir() { validate_vm_name "$1"; printf '%s/%s\n' "$VM_ROOT" "$1"; }
vm_conf() { printf '%s/vm.conf\n' "$(vm_dir "$1")"; }
disk_dir() { validate_vm_name "$1"; printf '%s/%s\n' "$DISK_ROOT" "$1"; }
disk_file() { validate_vm_name "$1"; validate_filename "$2"; printf '%s/%s\n' "$(disk_dir "$1")" "$2"; }
# Existing installations stored disks beside vm.conf.  Read those paths as a
# compatibility fallback; all newly-created disks use disk_dir().
vm_disk_path() {
  local name=$1 file=$2 primary legacy
  primary=$(disk_file "$name" "$file")
  legacy="$(vm_dir "$name")/$file"
  [[ -f $primary ]] && { printf '%s\n' "$primary"; return; }
  [[ -f $legacy ]] && { printf '%s\n' "$legacy"; return; }
  printf '%s\n' "$primary"
}
require_vm() { [[ -f "$(vm_conf "$1")" ]] || die "VM does not exist: $1"; }

cfg_get_file() {
  local file=$1 key=$2 default=${3-}
  local value
  value=$(awk -v k="$key" 'index($0,k"=")==1 {print substr($0,length(k)+2); found=1; exit} END{if(!found) exit 1}' "$file" 2>/dev/null) || value=$default
  printf '%s\n' "$value"
}
cfg_set_file() {
  local file=$1 key=$2 value=${3-}
  validate_no_newline "$value"
  [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Invalid config key: $key"
  local tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  awk -v k="$key" -v v="$value" '
    BEGIN{done=0}
    index($0,k"=")==1 {if(!done){print k"="v; done=1}; next}
    {print}
    END{if(!done) print k"="v}
  ' "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0640 "$tmp"
  mv -f "$tmp" "$file"
}
cfg_set() { require_vm "$1"; cfg_set_file "$(vm_conf "$1")" "$2" "$3"; }

cfg_delete_prefix_file() {
  local file=$1 prefix=$2 tmp
  tmp=$(mktemp "${file}.tmp.XXXXXX")
  awk -v p="$prefix" 'index($0,p)!=1 {print}' "$file" > "$tmp"
  chmod --reference="$file" "$tmp" 2>/dev/null || chmod 0640 "$tmp"
  mv -f "$tmp" "$file"
}

indexes_for() {
  local file=$1 prefix=$2
  sed -nE "s/^${prefix}_([0-9]+)_.*/\\1/p" "$file" | sort -n -u
}
next_index() {
  local file=$1 prefix=$2 max=-1 i
  while read -r i; do [[ -n "$i" ]] && (( i > max )) && max=$i; done < <(indexes_for "$file" "$prefix")
  printf '%d\n' $((max+1))
}

random_mac() {
  local a b c
  read -r a b c < <(od -An -N3 -tu1 /dev/urandom)
  printf '52:54:00:%02x:%02x:%02x\n' "$a" "$b" "$c"
}

vm_pid() {
  local p="$(vm_dir "$1")/runtime/qemu.pid"
  [[ -r "$p" ]] || return 1
  local pid; pid=$(cat "$p" 2>/dev/null || true)
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s\n' "$pid"
}
vm_state() { vm_pid "$1" >/dev/null 2>&1 && printf 'running\n' || printf 'stopped\n'; }
require_stopped() { [[ $(vm_state "$1") == stopped ]] || die "VM must be stopped: $1"; }
require_running() { [[ $(vm_state "$1") == running ]] || die "VM is not running: $1"; }

next_vnc_display() {
  local n used conf
  for ((n=1;n<100;n++)); do
    used=false
    shopt -s nullglob
    for conf in "$VM_ROOT"/*/vm.conf; do
      [[ $(cfg_get_file "$conf" VNC_DISPLAY '') == "$n" ]] && { used=true; break; }
    done
    shopt -u nullglob
    $used || { printf '%d\n' "$n"; return; }
  done
  die "No free VNC display found"
}

resolve_image() {
  local name=${1:-}
  [[ -n "$name" ]] || { printf '\n'; return; }
  validate_filename "$name"
  local path="$ISO_ROOT/$name"
  [[ -f "$path" ]] || die "Image not found: $name"
  printf '%s\n' "$path"
}

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

probe_ovmf_code() {
  local p
  [[ -n ${OVMF_CODE:-} && -r ${OVMF_CODE:-} ]] && { printf '%s\n' "$OVMF_CODE"; return; }
  for p in /usr/share/OVMF/OVMF_CODE_4M.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/ovmf/OVMF.fd; do
    [[ -r "$p" ]] && { printf '%s\n' "$p"; return; }
  done
  return 1
}
probe_ovmf_vars() {
  local p
  [[ -n ${OVMF_VARS_TEMPLATE:-} && -r ${OVMF_VARS_TEMPLATE:-} ]] && { printf '%s\n' "$OVMF_VARS_TEMPLATE"; return; }
  for p in /usr/share/OVMF/OVMF_VARS_4M.fd /usr/share/OVMF/OVMF_VARS.fd; do
    [[ -r "$p" ]] && { printf '%s\n' "$p"; return; }
  done
  return 1
}
