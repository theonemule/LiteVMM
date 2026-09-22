#!/usr/bin/env bash
# Purpose: VMAPI installation or runtime maintenance script.
# Run on the target host with the documented privileges and arguments; it manages system-level VMAPI resources.
set -Eeuo pipefail

VMAPI_CONFIG=${VMAPI_CONFIG:-/etc/vmapi/vmapi.conf}
[[ -r "$VMAPI_CONFIG" ]] && source "$VMAPI_CONFIG"

VMAPI_PROFILE=${VMAPI_PROFILE:-virtualization}
VMAPI_HTTP_PORT=${VMAPI_HTTP_PORT:-5186}
VMAPI_TLS_ENABLED=${VMAPI_TLS_ENABLED:-false}
VMAPI_TLS_CA_CERT_FILE=${VMAPI_TLS_CA_CERT_FILE:-}
VMAPI_TLS_CA_KEY_FILE=${VMAPI_TLS_CA_KEY_FILE:-}
VMAPI_BACKPLANE_SERVER=${VMAPI_BACKPLANE_SERVER:-false}
VMAPI_BACKPLANE_NFS_VERSION=${VMAPI_BACKPLANE_NFS_VERSION:-4.2}
VMAPI_BACKPLANE_NFS_EXPORT=${VMAPI_BACKPLANE_NFS_EXPORT:-/}
DOCKER_BIN=${DOCKER_BIN:-/usr/bin/docker}

vmapi_qemu_available() {
  [[ -x "$QEMU_BIN" ]]
}

vmapi_docker_available() {
  [[ -x "$DOCKER_BIN" ]]
}

vmapi_effective_profile() {
  if [[ $VMAPI_PROFILE == backup ]]; then
    printf 'backup\n'
    return 0
  fi
  local has_qemu=false has_docker=false
  vmapi_qemu_available && has_qemu=true
  vmapi_docker_available && has_docker=true
  if [[ $has_qemu == true && $has_docker == true ]]; then
    printf 'virtualization-docker\n'
  elif [[ $has_docker == true ]]; then
    printf 'docker\n'
  elif [[ $has_qemu == true ]]; then
    printf 'virtualization\n'
  else
    printf '%s\n' "$VMAPI_PROFILE"
  fi
}

vmapi_has_capability() {
  local cap=$1
  case "$cap" in
    api|system|metrics|cluster|admin|backup|backup-storage) return 0;;
    qemu-kvm|backup-create|vm-network|vm-console|storage|cloud-init|replication-source) vmapi_qemu_available;;
    docker|compose|container-terminal|registry|peer-volume-client) vmapi_docker_available;;
    backplane-client) vmapi_qemu_available || vmapi_docker_available;;
    storage-backplane) [[ $VMAPI_BACKPLANE_SERVER == true ]];;
    files|host-terminal) [[ $VMAPI_PROFILE == backup ]] || vmapi_qemu_available || vmapi_docker_available;;
    *) return 1;;
  esac
}

# VM_ROOT contains only VM configuration, firmware state, and transient runtime
# sockets.  Virtual disks are deliberately kept on a separate filesystem tree so
# they can be placed on storage with different performance or retention needs.
VM_ROOT=${VM_ROOT:-/var/lib/vmapi/vms}
DISK_ROOT=${DISK_ROOT:-/var/lib/vmapi/disks}
BACKPLANE_ROOT=${VMAPI_BACKPLANE_ROOT:-/var/lib/vmapi/backplane}
BACKPLANECTL=${BACKPLANECTL:-${VMAPI_BACKPLANECTL:-/usr/local/bin/backplanectl}}
PEERCTL=${PEERCTL:-${VMAPI_PEERCTL:-/usr/local/bin/peerctl}}
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
valid_peer_node_id() { [[ ${1:-} =~ ^[A-Fa-f0-9]{32}$ ]] || die "Invalid peer node id: ${1:-}"; }
peer_storage_dir() {
  local peer=${1:?peer required} kind=${2:?storage class required} name=${3:-} out
  valid_peer_node_id "$peer"; peer=${peer,,}
  if command -v sudo >/dev/null 2>&1 && sudo -n "$BACKPLANECTL" path "$peer" "$kind" ${name:+"$name"} >/dev/null 2>&1; then
    out=$(sudo -n "$BACKPLANECTL" path "$peer" "$kind" ${name:+"$name"})
  else
    out=$("$BACKPLANECTL" path "$peer" "$kind" ${name:+"$name"})
  fi
  [[ $out == /* ]] || die "Peer storage path is unavailable for $peer"
  printf '%s\n' "$out"
}
peer_shared_path() {
  local peer=${1:?peer required} kind=${2:?shared storage class required} name=${3:-} out
  valid_peer_node_id "$peer"; peer=${peer,,}
  if command -v sudo >/dev/null 2>&1 && sudo -n "$BACKPLANECTL" shared-path "$peer" "$kind" ${name:+"$name"} >/dev/null 2>&1; then
    out=$(sudo -n "$BACKPLANECTL" shared-path "$peer" "$kind" ${name:+"$name"})
  else
    out=$("$BACKPLANECTL" shared-path "$peer" "$kind" ${name:+"$name"})
  fi
  [[ $out == /* ]] || die "Peer shared storage path is unavailable for $peer"
  printf '%s\n' "$out"
}
disk_location_dir() {
  local name=$1 location=${2:-local} peer
  validate_vm_name "$name"
  case "$location" in
    ''|local) disk_dir "$name";;
    peer:*) peer=${location#peer:}; valid_peer_node_id "$peer"; peer_storage_dir "$peer" vm-disks "$name";;
    *) die "Invalid disk storage location: $location";;
  esac
}
disk_location_file() {
  local name=$1 file=$2 location=${3:-local}
  validate_filename "$file"
  printf '%s/%s\n' "$(disk_location_dir "$name" "$location")" "$file"
}
# Existing installations stored disks beside vm.conf.  Read those paths as a
# compatibility fallback; all newly-created local disks use disk_dir().
vm_disk_path() {
  local name=$1 file=$2 primary legacy
  primary=$(disk_file "$name" "$file")
  legacy="$(vm_dir "$name")/$file"
  [[ -f $primary ]] && { printf '%s\n' "$primary"; return; }
  [[ -f $legacy ]] && { printf '%s\n' "$legacy"; return; }
  printf '%s\n' "$primary"
}
vm_disk_path_index() {
  local name=$1 idx=$2 conf file location
  require_vm "$name"; validate_int "$idx"; conf=$(vm_conf "$name")
  file=$(cfg_get_file "$conf" "DISK_${idx}_FILE" '')
  [[ -n $file ]] || die "Disk index not found: $idx"
  location=$(cfg_get_file "$conf" "DISK_${idx}_LOCATION" local)
  if [[ $location == local || -z $location ]]; then
    vm_disk_path "$name" "$file"
  else
    disk_location_file "$name" "$file" "$location"
  fi
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
  local name=${1:-} peer=${2:-} path
  [[ -n "$name" ]] || { printf '\n'; return; }
  validate_filename "$name"
  if [[ -n $peer ]]; then
    valid_peer_node_id "$peer"
    path=$(peer_shared_path "$peer" isos "$name")
  else
    path="$ISO_ROOT/$name"
  fi
  [[ -f "$path" ]] || die "Image not found: $name${peer:+ on peer $peer}"
  printf '%s\n' "$path"
}

json_escape() {
  local s=${1-}
  s=${s//\\/\\\\}; s=${s//\"/\\\"}; s=${s//$'\n'/\\n}; s=${s//$'\r'/\\r}; s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

# Print only the direct members of the top-level JSON object read from stdin,
# dropping everything nested in child objects or arrays. qemu-img >= 8.0 puts a
# "children" array ahead of the top-level fields, and every child node carries
# its own "virtual-size"/"actual-size" (for the protocol node that is the host
# file length), so a first-match grep returns the wrong node's value.
json_top_level() {
  awk '{
    line = $0 "\n"; n = length(line)
    for (i = 1; i <= n; i++) {
      c = substr(line, i, 1)
      if (in_str) {
        if (depth == 1) printf "%s", c
        if (esc) esc = 0; else if (c == "\\") esc = 1; else if (c == "\"") in_str = 0
        continue
      }
      if (c == "\"") { in_str = 1; if (depth == 1) printf "%s", c; continue }
      if (c == "{" || c == "[") { depth++; continue }
      if (c == "}" || c == "]") { depth--; continue }
      if (depth == 1) printf "%s", c
    }
  }'
}

# qemu_img_top_int FIELD: read `qemu-img info --output=json` on stdin and print
# the image's own integer FIELD (e.g. virtual-size), ignoring child nodes.
qemu_img_top_int() {
  local field=${1:?field required}
  [[ $field =~ ^[a-z-]+$ ]] || die "Invalid qemu-img field: $field"
  json_top_level | sed -n 's/.*"'"$field"'"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n1
}

# --- QMP ---------------------------------------------------------------------
QMP_TIMEOUT=${VMAPI_QMP_TIMEOUT:-30}
qmp_call() {
  local name=$1 payload=$2 socket id line reply='' in out
  socket="$(vm_dir "$name")/runtime/qmp.sock"
  [[ -S $socket ]] || { err "QMP socket is unavailable for $name"; return 1; }
  command -v socat >/dev/null 2>&1 || { err 'socat is required for QMP'; return 1; }
  [[ $payload == '{"execute"'* ]] || { err 'Invalid QMP command'; return 1; }
  id="vmapi-$$-$RANDOM"
  coproc QMP_IO { exec socat - "UNIX-CONNECT:$socket" 2>/dev/null; }
  in=${QMP_IO[0]:-}; out=${QMP_IO[1]:-}
  if [[ -n $in && -n $out ]]; then
    printf '%s\n%s\n' '{"execute":"qmp_capabilities"}' "{\"id\":\"$id\",${payload#\{}" >&"$out" 2>/dev/null || true
    while IFS= read -r -t "$QMP_TIMEOUT" line <&"$in"; do
      if [[ $line == *"\"id\": \"$id\""* || $line == *"\"id\":\"$id\""* ]]; then reply=$line; break; fi
    done
  fi
  kill "$QMP_IO_PID" 2>/dev/null || true; wait "$QMP_IO_PID" 2>/dev/null || true
  [[ -n $reply ]] || { err "QMP did not answer for $name: $payload"; return 1; }
  printf '%s\n' "$reply"
}
qmp_do() {
  local out
  out=$(qmp_call "$1" "$2") || die "QMP ${3:-command} failed for $1"
  [[ $out == *'"return"'* ]] || die "QMP ${3:-command} failed for $1: $out"
  printf '%s\n' "$out"
}
json_flat_object() { printf '%s' "$1" | grep -o '{[^{}]*"'"$2"'": *"'"$3"'"[^{}]*}' | head -n1 || true; }
json_str_field() { printf '%s' "$1" | sed -n 's/.*"'"$2"'": *"\(\([^"\\]\|\\.\)*\)".*/\1/p' | head -n1; }
json_int_field() { printf '%s' "$1" | sed -n 's/.*"'"$2"'": *\([0-9][0-9]*\).*/\1/p' | head -n1; }
qmp_wait_job() {
  local vm=$1 job=$2 timeout=${3:-86400} start=$SECONDS info error
  while :; do
    info=$(json_flat_object "$(qmp_do "$vm" '{"execute":"query-jobs"}' 'job query')" id "$job")
    [[ -n $info ]] || die "QMP job $job for $vm disappeared before it completed"
    [[ $(json_str_field "$info" status) != concluded ]] || break
    (( SECONDS - start < timeout )) || die "QMP job $job for $vm did not finish within ${timeout}s"
    sleep 0.1
  done
  error=$(json_str_field "$info" error)
  qmp_call "$vm" "{\"execute\":\"job-dismiss\",\"arguments\":{\"id\":\"$job\"}}" >/dev/null || true
  [[ -z $error ]] || die "QMP job $job for $vm failed: $error"
}
FROZEN_VM=''
vm_freeze() {
  [[ $(qmp_do "$1" '{"execute":"query-status"}' 'status query') == *'"running": true'* ]] || return 0
  qmp_do "$1" '{"execute":"stop"}' 'vCPU stop' >/dev/null
  FROZEN_VM=$1
}
vm_thaw() {
  local vm=$FROZEN_VM; [[ -n $vm ]] || return 0
  FROZEN_VM=''
  qmp_call "$vm" '{"execute":"cont"}' >/dev/null 2>&1 || err "Could not resume the vCPUs of $vm; resume it with the QMP 'cont' command"
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
