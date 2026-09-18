#!/usr/bin/env bash
# Purpose: FastCGI entry point for VMAPI HTTP requests.
# Input comes from the web server CGI environment; responses are emitted as HTTP headers plus JSON.
# Keep authorization and validation ahead of commands that change host state.
set -Eeuo pipefail

VMCTL=${VMCTL:-/usr/local/bin/vmctl}
IMAGECTL=${IMAGECTL:-/usr/local/bin/imagectl}
NETCTL=${NETCTL:-/usr/local/bin/netctl}
DOCKERCTL=${DOCKERCTL:-/usr/local/bin/dockerctl}
DOCKER_IMAGECTL=${DOCKER_IMAGECTL:-/usr/local/bin/docker-imagectl}
DOCKER_NETCTL=${DOCKER_NETCTL:-/usr/local/bin/docker-netctl}
DOCKER_VOLUMECTL=${DOCKER_VOLUMECTL:-/usr/local/bin/docker-volumectl}
METRICSCTL=${METRICSCTL:-/usr/local/bin/metricsctl}
CONSOLECTL=${CONSOLECTL:-/usr/local/bin/consolectl}
DOCKEREXECCTL=${DOCKEREXECCTL:-/usr/local/bin/dockerexecctl}
HOSTEXECCTL=${HOSTEXECCTL:-/usr/local/bin/hostexecctl}
LOGCTL=${LOGCTL:-/usr/local/bin/logctl}
OVERLAYCTL=${OVERLAYCTL:-/usr/local/bin/overlayctl}
COMPOSECTL=${COMPOSECTL:-/usr/local/bin/dockercompoectl}
LIB=${VMAPI_LIB:-/usr/local/lib/vmapi/common.sh}
[[ -r "$LIB" ]] || LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/common.sh"
source "$LIB"

# API handlers commonly discard successful command output with `>/dev/null`.
# Keep a duplicate of the FastCGI response stream so run_cmd can still return a
# valid JSON error response when one of those commands fails.  Without this,
# redirecting run_cmd also redirects its error headers/body and Lighttpd reports
# a misleading 502 "no response received".
exec 3>&1

PEERCTL=${PEERCTL:-/usr/local/bin/peerctl}
BACKUPCTL=${BACKUPCTL:-/usr/local/bin/vmbackupctl}
FILECTL=${FILECTL:-/usr/local/bin/filectl}
STORAGECTL=${STORAGECTL:-/usr/local/bin/storagectl}
CERTCTL=${CERTCTL:-/usr/local/bin/certctl}
REPLICATIONCTL=${REPLICATIONCTL:-/usr/local/bin/replicationctl}
REGISTRYCTL=${REGISTRYCTL:-/usr/local/bin/registryctl}
PEER_VOLUMECTL=${PEER_VOLUMECTL:-/usr/local/bin/peer-volumectl}
BACKPLANECTL=${BACKPLANECTL:-/usr/local/bin/backplanectl}
declare -A FORM=()
# peer-api.cgi sets this before executing us. This survives Lighttpd's internal
# rewrite, which otherwise makes the original /peer-api route indistinguishable
# from an ordinary /api request during authentication.
PEER_API_REQUEST=${VMAPI_PEER_API:-false}

cors_headers() {
  local allowed
  [[ $PEER_API_REQUEST == true && -n ${HTTP_ORIGIN:-} ]] || return 0
  if allowed=$(peer_cmd cors-origin "$HTTP_ORIGIN" 2>/dev/null); then
    printf 'Access-Control-Allow-Origin: %s\r\nVary: Origin\r\nAccess-Control-Allow-Methods: GET, POST, PUT, PATCH, DELETE, HEAD, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\n' "$allowed"
  fi
}
header() { printf 'Status: %s\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n' "$1"; cors_headers; printf '\r\n'; }
reply() { header "$1"; printf '%s\n' "$2"; exit 0; }
error_reply() { local code=$1 msg=$2; reply "$code" "{\"error\":\"$(json_escape "$msg")\"}"; }
require_capability() {
  local cap=$1
  vmapi_has_capability "$cap" || error_reply '404 Not Found' "Capability is not installed or available on this host: $cap"
}
capabilities_json() {
  local all=(api system metrics cluster admin backup backup-storage qemu-kvm backup-create vm-network vm-console storage cloud-init replication-source docker compose container-terminal registry peer-volume-client backplane-client storage-backplane files host-terminal)
  local cap first=true
  printf '['
  for cap in "${all[@]}"; do
    vmapi_has_capability "$cap" || continue
    $first || printf ','
    first=false
    printf '"%s"' "$cap"
  done
  printf ']'
}
registry_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$REGISTRYCTL" "$@"; else "$REGISTRYCTL" "$@"; fi
}
replication_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$REPLICATIONCTL" "$@"; else "$REPLICATIONCTL" "$@"; fi
}
peer_volume_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$PEER_VOLUMECTL" "$@"; else "$PEER_VOLUMECTL" "$@"; fi
}
cert_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$CERTCTL" "$@"; else "$CERTCTL" "$@"; fi
}
cert_import_signed_cmd() {
  local pem=$1 tmp out rc
  tmp=$(mktemp); chmod 0600 "$tmp"; printf '%s\n' "$pem" > "$tmp"
  set +e; out=$(cert_cmd import-signed "$tmp" 2>&1); rc=$?; set -e
  rm -f -- "$tmp"
  ((rc==0)) || { printf '%s' "$out" >&2; return "$rc"; }
  printf '%s' "$out"
}
cert_import_pair_cmd() {
  local cert_pem=$1 key_pem=$2 domain=${3-} ctmp ktmp out rc
  ctmp=$(mktemp); ktmp=$(mktemp); chmod 0600 "$ctmp" "$ktmp"
  printf '%s\n' "$cert_pem" > "$ctmp"; printf '%s\n' "$key_pem" > "$ktmp"
  set +e; out=$(cert_cmd import-pair "$ctmp" "$ktmp" "$domain" 2>&1); rc=$?; set -e
  rm -f -- "$ctmp" "$ktmp"
  ((rc==0)) || { printf '%s' "$out" >&2; return "$rc"; }
  printf '%s' "$out"
}
cgi_require_vm() { [[ ${1:-} =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] && [[ -f "$VM_ROOT/$1/vm.conf" ]] || error_reply '404 Not Found' 'VM not found'; }

url_decode() {
  local s=${1//+/ }
  s=${s//\\/\\\\}
  printf '%b' "${s//%/\\x}"
}
parse_pairs() {
  local data=${1-} pair key value
  IFS='&' read -ra pairs <<< "$data"
  for pair in "${pairs[@]}"; do
    [[ -n $pair ]] || continue
    key=${pair%%=*}; value=''
    [[ $pair == *=* ]] && value=${pair#*=}
    key=$(url_decode "$key"); value=$(url_decode "$value")
    [[ $key =~ ^[A-Za-z0-9_.-]{1,64}$ ]] || continue
    FORM[$key]=$value
  done
}
read_params() {
  parse_pairs "${QUERY_STRING:-}"
  local ct=${CONTENT_TYPE:-} len=${CONTENT_LENGTH:-0} body=''
  if [[ $ct == application/x-www-form-urlencoded* && $len =~ ^[0-9]+$ && $len -gt 0 ]]; then
    (( len <= 1048576 )) || error_reply '413 Payload Too Large' 'Form body exceeds 1 MiB'
    # FastCGI request bodies are not line-oriented. read -N can return an
    # empty value on some fcgiwrap/BusyBox combinations; read the exact byte
    # count instead so pairing bundles and ordinary form submissions survive.
    body=$(dd bs=1 count="$len" status=none 2>/dev/null || true)
    parse_pairs "$body"
  fi
}
param() { printf '%s' "${FORM[$1]-${2-}}"; }

run_cmd() {
  local out
  # FD 3 preserves the FastCGI response stream for error reporting when a
  # caller redirects this function's normal output.  Do not let managed
  # commands inherit it: QEMU daemonizes and an inherited response descriptor
  # keeps Lighttpd waiting even after the API handler has replied.
  if out=$( (exec 3>&-; "$@") 2>&1); then
    printf '%s' "$out"
  else
    header '400 Bad Request' >&3
    printf '%s\n' "{\"error\":\"$(json_escape "$out")\"}" >&3
    # Return a failure after writing directly to the preserved FastCGI stream.
    # A `reply` call would exit only a command-substitution subshell, allowing
    # its parent route to append a misleading success response.
    return 1
  fi
}
peer_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$PEERCTL" "$@"; else "$PEERCTL" "$@"; fi
}
backup_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$BACKUPCTL" "$@"; else "$BACKUPCTL" "$@"; fi
}
file_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$FILECTL" "$@"; else "$FILECTL" "$@"; fi
}
storage_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$STORAGECTL" "$@"; else "$STORAGECTL" "$@"; fi
}
overlay_cmd() {
  if command -v sudo >/dev/null 2>&1; then sudo -n "$OVERLAYCTL" "$@"; else "$OVERLAYCTL" "$@"; fi
}
overlay_remote_create() {
  local peer_id=$1 name=$2 bridge=$3 role=$4 mtu=$5 staged=$6 body out
  body="name=$name&bridge=$bridge&role=$role&mtu=$mtu"
  [[ $staged == true ]] && body+="&staged=true"
  out=$(printf '%s' "$body" | peer_cmd proxy "$peer_id" POST /overlays application/x-www-form-urlencoded 2>&1) || return 1
  printf '%s' "$out"
}
overlay_remote_delete() {
  local peer_id=$1 name=$2
  peer_cmd proxy "$peer_id" DELETE "/overlays/$name" application/x-www-form-urlencoded </dev/null
}
vm_delete_cmd() {
  # VM directories can legitimately be root-owned after an import, restore,
  # migration, or older installation. vmctl still validates the VM name,
  # stopped state, and final path before removing anything.
  if command -v sudo >/dev/null 2>&1; then sudo -n "$VMCTL" delete "$1"; else "$VMCTL" delete "$1"; fi
}

json_lines_reply() {
  local status=$1; shift
  local out line first=true
  out=$(run_cmd "$@")
  header "$status"
  printf '['
  while IFS= read -r line; do
    [[ -n $line ]] || continue
    $first || printf ','; first=false
    printf '%s' "$line"
  done <<< "$out"
  printf ']\n'
  exit 0
}

raw_json_reply() {
  local status=$1; shift
  local out; out=$(run_cmd "$@")
  header "$status"; printf '%s\n' "$out"; exit 0
}

text_reply() {
  local status=$1; shift
  printf 'Status: %s\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n' "$status"
  exec "$@"
}
download_reply() {
  local filename=$1; shift
  validate_filename "$filename"
  printf 'Status: 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="%s"\r\nCache-Control: no-store\r\n\r\n' "$filename"
  exec "$@"
}

json_config() {
  local name=$1 conf; conf=$(vm_conf "$name")
  local first=true line key value
  printf '{"name":"%s","state":"%s","config":{' "$(json_escape "$name")" "$(vm_state "$name")"
  while IFS= read -r line; do
    [[ $line == *=* ]] || continue
    key=${line%%=*}; value=${line#*=}
    $first || printf ','; first=false
    if [[ $value =~ ^[0-9]+$ ]]; then printf '"%s":%s' "$(json_escape "$key")" "$value"
    elif [[ $value == true || $value == false ]]; then printf '"%s":%s' "$(json_escape "$key")" "$value"
    else printf '"%s":"%s"' "$(json_escape "$key")" "$(json_escape "$value")"; fi
  done < "$conf"
  printf '},"storage":{"config_path":"%s","disk_path":"%s","iso_path":"%s"}}' \
    "$(json_escape "$(vm_dir "$name")")" "$(json_escape "$(disk_dir "$name")")" "$(json_escape "$ISO_ROOT")"
}

json_vm_list() {
  local first=true name
  printf '['
  while IFS= read -r name; do
    [[ -n $name ]] || continue
    $first || printf ','; first=false
    printf '{"name":"%s","state":"%s"}' "$(json_escape "$name")" "$(vm_state "$name")"
  done < <("$VMCTL" list)
  printf ']'
}

peer_request_uri=${REQUEST_URI:-${PATH_INFO:-/}}
request_path=${peer_request_uri%%\?*}
if [[ $request_path == /peer-api.cgi || $request_path == /peer-api.cgi/* ]]; then
  # Lighttpd can expose the internal FastCGI target here. Peer signatures are
  # always made for the externally-addressed /peer-api route.
  peer_request_uri="/peer-api${request_path#/peer-api.cgi}"
  [[ $REQUEST_URI == *\?* ]] && peer_request_uri+="?${REQUEST_URI#*\?}"
elif [[ $request_path == /peer-api || $request_path == /peer-api/* ]]; then
  PEER_API_REQUEST=true
fi
if [[ $peer_request_uri != *\?* && -n ${QUERY_STRING:-} ]]; then
  peer_request_uri+="?${QUERY_STRING}"
fi
request_path=${peer_request_uri%%\?*}
[[ $request_path == /peer-api || $request_path == /peer-api/* ]] && PEER_API_REQUEST=true
route=${PATH_INFO:-$request_path}
route=${route%%\?*}
route=${route#/api}
route=${route#/}
method=${REQUEST_METHOD:-GET}
IFS='/' read -ra P <<< "$route"

# Lighttpd authenticates /peer-api (including its direct CGI alias) against
# the paired-credential file before FastCGI. Never accept a client identity header.
if [[ $PEER_API_REQUEST == true ]]; then
  [[ ${AUTH_TYPE:-} =~ ^[Bb][Aa][Ss][Ii][Cc]$ && -n ${REMOTE_USER:-} ]] || error_reply '401 Unauthorized' 'HTTP Basic peer authentication required'
  out=$(peer_cmd authorize-user "$REMOTE_USER" 2>&1) || error_reply '401 Unauthorized' "$out"
fi

# Deployment profiles are an API boundary, not just a UI preference. Reject
# routes whose backing platform is not installed on this host.
case "${P[0]-}" in
  backups) require_capability backup;;
  replications) [[ ${P[1]-} == replicas ]] && require_capability storage-backplane || require_capability replication-source;;
  backplane) require_capability storage-backplane;;
  vms|images|migrations|storage|networks|overlays) require_capability qemu-kvm;;
  docker|compose) require_capability docker;;
  files) require_capability files;;
  host) require_capability host-terminal;;
  ''|cluster|logs|metrics|system|admin) :;;
  *) :;;
esac

# A local console session can manage a paired host through this same-origin
# proxy. Its paired credential remains on the local host; the browser never receives
# it and never needs the remote host's user login. The request body is streamed
# unchanged through peerctl to support form data and file uploads.
if [[ ${P[0]-} == cluster && ${P[1]-} == peers && -n ${P[2]-} && ${P[3]-} == proxy && -z ${P[4]-} ]]; then
  parse_pairs "${QUERY_STRING:-}"
  proxy_path=$(param path)
  [[ -n $proxy_path ]] || error_reply '400 Bad Request' 'proxy path is required'
  [[ $proxy_path == /* ]] || proxy_path="/$proxy_path"
  out=$(peer_cmd proxy "${P[2]}" "$method" "$proxy_path" "${CONTENT_TYPE:-}" 2>&1) || error_reply '502 Bad Gateway' "$out"
  reply '200 OK' "$out"
fi

# Raw image upload: PUT /api/images/<filename>, body is the file bytes.
if [[ $method == PUT && ${P[0]-} == images && -n ${P[1]-} && -z ${P[2]-} ]]; then
  out=$(run_cmd "$IMAGECTL" upload-stdin "${P[1]}")
  reply '201 Created' "{\"name\":\"$(json_escape "$out")\"}"
fi

if [[ $method == PUT && ${P[0]-} == compose && ${P[1]-} == projects && -n ${P[2]-} && -z ${P[3]-} ]]; then
  out=$(run_cmd "$COMPOSECTL" upload-stdin "${P[2]}")
  reply '201 Created' "$out"
fi

# Stream a Docker build context directly to the daemon. The CGI never extracts
# client-controlled tar members onto the host filesystem.
if [[ $method == PUT && ${P[0]-} == docker && ${P[1]-} == images && ${P[2]-} == build && -z ${P[3]-} ]]; then
  parse_pairs "${QUERY_STRING:-}"; image=$(param tag); dockerfile=$(param dockerfile Dockerfile)
  [[ -n $image ]] || error_reply '400 Bad Request' 'tag is required'
  out=$(run_cmd "$DOCKER_IMAGECTL" build-stdin "$image" --file "$dockerfile")
  reply '201 Created' "$out"
fi

if [[ $method == POST && ${P[0]-} == migrations && ${P[1]-} == import && -n ${P[2]-} && -z ${P[3]-} ]]; then
  out=$(backup_cmd import "${P[2]}" 2>&1) || error_reply '400 Bad Request' "$out"
  reply '201 Created' "$out"
fi

# Raw file upload. The destination is carried in the query string so the body
# can remain an arbitrary binary stream.
if [[ $method == PUT && ${P[0]-} == files && ${P[1]-} == content && -z ${P[2]-} ]]; then
  parse_pairs "${QUERY_STRING:-}"; path=$(param path); [[ -n $path ]] || error_reply '400 Bad Request' 'path is required'
  out=$(file_cmd upload "$path" 2>&1) || error_reply '400 Bad Request' "$out"
  reply '201 Created' "$out"
fi

read_params

if [[ -z $route ]]; then
  caps=$(capabilities_json)
  effective_profile=$(vmapi_effective_profile)
  reply '200 OK' "{\"service\":\"litevmm\",\"version\":12,\"profile\":\"$(json_escape "$effective_profile")\",\"configured_profile\":\"$(json_escape "$VMAPI_PROFILE")\",\"port\":$VMAPI_HTTP_PORT,\"tls_enabled\":$VMAPI_TLS_ENABLED,\"user\":\"$(json_escape "${REMOTE_USER:-}")\",\"capabilities\":$caps}"
fi

case "${P[0]-}" in
  backplane)
    [[ $PEER_API_REQUEST != true ]] || error_reply '403 Forbidden' 'Backplane inventory is a local administration endpoint'
    case "${P[1]-}" in
      docker-volumes)
        case "${P[2]-}" in
          '') [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'; raw_json_reply '200 OK' peer_volume_cmd list-hosted;;
          *)
            case "$method" in
              GET) raw_json_reply '200 OK' peer_volume_cmd show-hosted "${P[2]}";;
              DELETE) raw_json_reply '200 OK' peer_volume_cmd delete-hosted "${P[2]}" "$(param delete_data false)";;
              *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
            esac;;
        esac;;
      status)
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
        raw_json_reply '200 OK' "$BACKPLANECTL" server-status;;
      *) error_reply '404 Not Found' 'Unknown backplane endpoint';;
    esac;;

  replications)
    if [[ ${P[1]-} == replicas ]]; then
      [[ $PEER_API_REQUEST != true ]] || error_reply '403 Forbidden' 'Replica inventory is a local administration endpoint'
      case "${P[2]-}" in
        '')
          [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
          raw_json_reply '200 OK' replication_cmd replica-list;;
        *)
          case "$method" in
            GET) raw_json_reply '200 OK' replication_cmd replica-show "${P[2]}";;
            DELETE) raw_json_reply '200 OK' replication_cmd replica-purge "${P[2]}" "$(param delete_file false)";;
            *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
          esac;;
      esac
    fi
    case "${P[1]-}" in
      '')
        case "$method" in
          GET) raw_json_reply '200 OK' replication_cmd list;;
          POST)
            name=$(param name); peer_id=$(param peer_id); [[ -n $name && -n $peer_id ]] || error_reply '400 Bad Request' 'name and peer_id are required'
            speed=$(param speed 0); raw_json_reply '201 Created' replication_cmd start "$name" "$peer_id" "$speed";;
          *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
        esac;;
      *)
        case "$method" in
          GET) raw_json_reply '200 OK' replication_cmd status "${P[1]}";;
          DELETE) raw_json_reply '200 OK' replication_cmd stop "${P[1]}";;
          *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
        esac;;
    esac;;

  backups)
    if [[ $VMAPI_PROFILE == backup ]]; then
      case "${P[1]-}" in schedules|schedule|unschedule|create|start|jobs|restore) error_reply '404 Not Found' 'Backup creation, scheduling, and restore require the virtualization profile';; esac
    fi
    case "${P[1]-}" in
      '')
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
        json_lines_reply '200 OK' backup_cmd list;;
      schedules)
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
        json_lines_reply '200 OK' backup_cmd schedules;;
      schedule)
        name=$(param name); cron=$(param cron); [[ -n $name && -n $cron ]] || error_reply '400 Bad Request' 'name and cron are required'
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        [[ -z $(param transport) && -z $(param ssh) && -z $(param remote_dir) ]] || error_reply '400 Bad Request' 'SSH, SCP, and SFTP backup destinations are not supported; use peer_id'
        args=(schedule "$name" "$cron"); [[ -n $(param label) ]] && args+=(--label "$(param label)"); [[ -n $(param destination) ]] && args+=(--destination "$(param destination)"); [[ -n $(param keep) ]] && args+=(--keep "$(param keep)"); [[ $(param live false) == true ]] && args+=(--live); [[ -n $(param peer_id) ]] && args+=(--peer "$(param peer_id)")
        run_cmd backup_cmd "${args[@]}" >/dev/null; reply '201 Created' '{"scheduled":true}';;
      unschedule)
        name=$(param name); [[ $method == DELETE ]] || error_reply '405 Method Not Allowed' 'Use DELETE'; args=(unschedule "$name"); [[ -n $(param label) ]] && args+=("$(param label)"); run_cmd backup_cmd "${args[@]}" >/dev/null; reply '200 OK' '{"unscheduled":true}';;
      create)
        name=$(param name); [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'; [[ -z $(param transport) && -z $(param ssh) && -z $(param remote_dir) ]] || error_reply '400 Bad Request' 'SSH, SCP, and SFTP backup destinations are not supported; use peer_id'; args=(create "$name"); [[ $(param live false) == true ]] && args+=(--live); [[ -n $(param label) ]] && args+=(--label "$(param label)"); [[ -n $(param destination) ]] && args+=(--destination "$(param destination)"); [[ -n $(param keep) ]] && args+=(--keep "$(param keep)"); [[ -n $(param peer_id) ]] && args+=(--peer "$(param peer_id)"); raw_json_reply '201 Created' backup_cmd "${args[@]}";;
      start)
        name=$(param name); [[ $method == POST && -n $name ]] || error_reply '400 Bad Request' 'name is required'; [[ -z $(param transport) && -z $(param ssh) && -z $(param remote_dir) ]] || error_reply '400 Bad Request' 'SSH, SCP, and SFTP backup destinations are not supported; use peer_id'; args=(start "$name"); [[ $(param live false) == true ]] && args+=(--live); [[ -n $(param label) ]] && args+=(--label "$(param label)"); [[ -n $(param destination) ]] && args+=(--destination "$(param destination)"); [[ -n $(param keep) ]] && args+=(--keep "$(param keep)"); [[ -n $(param peer_id) ]] && args+=(--peer "$(param peer_id)"); raw_json_reply '202 Accepted' backup_cmd "${args[@]}";;
      jobs)
        job=${P[2]-}; [[ $method == GET && -n $job ]] || error_reply '400 Bad Request' 'job id is required'; raw_json_reply '200 OK' backup_cmd job "$job";;
      restore)
        name=$(param name); archive=$(param archive); [[ $method == POST && -n $name && -n $archive ]] || error_reply '400 Bad Request' 'name and archive are required'; args=(restore "$name" "$archive"); [[ -n $(param destination) ]] && args+=(--destination "$(param destination)"); raw_json_reply '201 Created' backup_cmd "${args[@]}";;
      *)
        name=${P[1]}; archive=${P[2]-}; [[ $method == GET || $method == DELETE ]] || error_reply '405 Method Not Allowed' 'Use GET or DELETE'
        [[ -n $archive ]] || error_reply '400 Bad Request' 'archive is required'
        if [[ $method == GET ]]; then
          printf 'Status: 200 OK\r\nContent-Type: application/gzip\r\nContent-Disposition: attachment; filename="%s"\r\nCache-Control: no-store\r\n\r\n' "$archive"
          if command -v sudo >/dev/null 2>&1; then exec sudo -n "$BACKUPCTL" download "$name" "$archive"; else exec "$BACKUPCTL" download "$name" "$archive"; fi
        fi
        run_cmd backup_cmd delete "$name" "$archive" >/dev/null; reply '200 OK' '{"deleted":true}';;
    esac;;

  files)
    case "${P[1]-}" in
      '')
        case "$method" in
          GET) raw_json_reply '200 OK' file_cmd list "$(param path /)";;
          DELETE)
            args=(delete); for ((i=0;i<256;i++)); do v=$(param "path_$i"); [[ -n $v ]] && args+=("$v"); done
            ((${#args[@]} > 1)) || error_reply '400 Bad Request' 'At least one path is required'
            raw_json_reply '200 OK' file_cmd "${args[@]}";;
          *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
        esac;;
      content)
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET or PUT'
        path=$(param path); [[ -n $path && $path != *$'\r'* && $path != *$'\n'* ]] || error_reply '400 Bad Request' 'path is required'
        filename=${path##*/}; filename=${filename//\"/_}
        printf 'Status: 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Disposition: attachment; filename="%s"\r\nCache-Control: no-store\r\n\r\n' "$filename"
        if command -v sudo >/dev/null 2>&1; then exec sudo -n "$FILECTL" download "$path"; else exec "$FILECTL" download "$path"; fi;;
      directories)
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        path=$(param path); [[ -n $path ]] || error_reply '400 Bad Request' 'path is required'; raw_json_reply '201 Created' file_cmd mkdir "$path";;
      move)
        [[ $method == PATCH ]] || error_reply '405 Method Not Allowed' 'Use PATCH'
        source=$(param source); destination=$(param destination); [[ -n $source && -n $destination ]] || error_reply '400 Bad Request' 'source and destination are required'; raw_json_reply '200 OK' file_cmd move "$source" "$destination";;
      archive)
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        args=(archive); for ((i=0;i<256;i++)); do v=$(param "path_$i"); [[ -n $v ]] && args+=("$v"); done
        ((${#args[@]} > 1)) || error_reply '400 Bad Request' 'At least one path is required'
        printf 'Status: 200 OK\r\nContent-Type: application/zip\r\nContent-Disposition: attachment; filename="vmapi-files.zip"\r\nCache-Control: no-store\r\n\r\n'
        if command -v sudo >/dev/null 2>&1; then exec sudo -n "$FILECTL" "${args[@]}"; else exec "$FILECTL" "${args[@]}"; fi;;
      *) error_reply '404 Not Found' 'Unknown file endpoint';;
    esac;;

  cluster)
    case "${P[1]-}" in
      identity)
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
        out=$(peer_cmd identity 2>&1) || error_reply '500 Internal Server Error' "$out"
        reply '200 OK' "$out";;
      peers)
        if [[ -z ${P[2]-} ]]; then
          [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
          out=$(peer_cmd list 2>&1) || error_reply '500 Internal Server Error' "$out"
          reply '200 OK' "$out"
        fi
        if [[ ${P[3]-} == overlay-credentials && -z ${P[4]-} ]]; then
          require_capability vm-network
          [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
          out=$(peer_cmd overlay-credentials "${P[2]}" 2>&1) || error_reply '400 Bad Request' "$out"
          reply '200 OK' "$out"
        fi
        [[ $method == DELETE ]] || error_reply '405 Method Not Allowed' 'Use DELETE'
        run_cmd peer_cmd revoke "${P[2]}" >/dev/null; reply '200 OK' '{"revoked":true}';;
      peer-url)
        [[ $method == PATCH ]] || error_reply '405 Method Not Allowed' 'Use PATCH'
        run_cmd peer_cmd set-url "$(param node_id)" "$(param url)" >/dev/null; reply '200 OK' '{"updated":true}';;
      migrate)
        require_capability qemu-kvm
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        out=$(peer_cmd migrate "$(param vm)" "$(param node_id)" 2>&1) || error_reply '400 Bad Request' "$out"
        reply '200 OK' "$out";;
      pair)
        case "${P[2]-}" in
          request)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            out=$(peer_cmd request "$(param name)" "$(param endpoint)" 2>&1) || error_reply '400 Bad Request' "$out"
            printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n%s\n' "$out"; exit 0;;
          pending)
            case $method in
              GET)
                # No pending exchange is normal steady-state, not an API error.
                # Return an empty successful text response so the UI has no noisy
                # failed-request entry in the browser console.
                out=$(peer_cmd pending 2>/dev/null) || out=''
                if [[ -n $out ]]; then
                  printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n%s\n' "$out"
                else
                  printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n'
                fi
                exit 0;;
              DELETE)
                out=$(peer_cmd cancel-pending 2>&1) || error_reply '404 Not Found' "$out"
                reply '200 OK' "$out";;
              *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
            esac;;
          accept)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            out=$(peer_cmd accept "$(param bundle)" "$(param name)" "$(param endpoint)" 2>&1) || error_reply '400 Bad Request' "$out"
            printf 'Status: 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\n\r\n%s\n' "$out"; exit 0;;
          complete)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            out=$(peer_cmd complete "$(param bundle)" 2>&1) || error_reply '400 Bad Request' "$out"
            reply '200 OK' "$out";;
          *) error_reply '404 Not Found' 'Unknown cluster pairing endpoint';;
        esac;;
      *) error_reply '404 Not Found' 'Unknown cluster endpoint';;
    esac;;

  admin)
    case "${P[1]-}" in
      '')
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
        raw_json_reply '200 OK' cert_cmd status;;
      certificates)
        case "${P[2]-}" in
          '')
            case "$method" in
              GET) raw_json_reply '200 OK' cert_cmd status;;
              POST) domain=$(param domain); email=$(param email); [[ -n $domain && -n $email ]] || error_reply '400 Bad Request' 'domain and email are required'; raw_json_reply '200 OK' cert_cmd issue "$domain" "$email";;
              DELETE) raw_json_reply '200 OK' cert_cmd disable;;
              *) error_reply '405 Method Not Allowed' 'Use GET, POST, or DELETE';;
            esac;;
          letsencrypt)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            domain=$(param domain); email=$(param email); [[ -n $domain && -n $email ]] || error_reply '400 Bad Request' 'domain and email are required'
            raw_json_reply '200 OK' cert_cmd issue "$domain" "$email";;
          renew)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            raw_json_reply '200 OK' cert_cmd renew;;
          csr)
            case "$method" in
              GET) text_reply '200 OK' cert_cmd csr-show;;
              POST)
                domain=$(param domain); [[ -n $domain ]] || error_reply '400 Bad Request' 'domain is required'
                raw_json_reply '201 Created' cert_cmd csr-generate "$domain" "$(param sans)" "$(param organization)" "$(param organizational_unit)" "$(param country)" "$(param state)" "$(param locality)" "$(param key_type rsa2048)";;
              *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
            esac;;
          signed)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            certificate=$(param certificate); [[ -n $certificate ]] || error_reply '400 Bad Request' 'certificate is required'
            out=$(cert_import_signed_cmd "$certificate" 2>&1) || error_reply '400 Bad Request' "$out"
            reply '200 OK' "$out";;
          import)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            certificate=$(param certificate); private_key=$(param private_key)
            [[ -n $certificate && -n $private_key ]] || error_reply '400 Bad Request' 'certificate and private_key are required'
            out=$(cert_import_pair_cmd "$certificate" "$private_key" "$(param domain)" 2>&1) || error_reply '400 Bad Request' "$out"
            reply '200 OK' "$out";;
          *) error_reply '404 Not Found' 'Unknown certificate endpoint';;
        esac;;
      *) error_reply '404 Not Found' 'Unknown admin endpoint';;
    esac;;

  host)
    [[ ${P[1]-} == terminal && ${P[2]-} == session ]] || error_reply '404 Not Found' 'Unknown host endpoint'
    if command -v sudo >/dev/null 2>&1; then host_exec=(sudo -n "$HOSTEXECCTL"); else host_exec=("$HOSTEXECCTL"); fi
    case "$method" in POST) raw_json_reply '201 Created' "${host_exec[@]}" start;; DELETE) run_cmd "${host_exec[@]}" stop >/dev/null; reply '200 OK' '{"stopped":true}';; *) error_reply '405 Method Not Allowed' 'Use POST or DELETE';; esac;;
  logs)
    [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
    source=$(param source all); limit=$(param limit 300)
    if command -v sudo >/dev/null 2>&1; then log_cmd=(sudo -n "$LOGCTL"); else log_cmd=("$LOGCTL"); fi
    json_lines_reply '200 OK' "${log_cmd[@]}" "$source" "$limit";;

  metrics)
    [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
    raw_json_reply '200 OK' "$METRICSCTL" host;;
  system)
    [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
    raw_json_reply '200 OK' "$METRICSCTL" system;;

  vms)
    if [[ -z ${P[1]-} ]]; then
      case "$method" in
        GET) body=$(json_vm_list); reply '200 OK' "$body";;
        POST)
          name=$(param name); [[ -n $name ]] || error_reply '400 Bad Request' 'name is required'
          requested_network=$(param network)
          args=(create "$name")
          [[ -n $(param memory_mb) ]] && args+=(--memory "$(param memory_mb)")
          [[ -n $(param vcpus) ]] && args+=(--cpus "$(param vcpus)")
          [[ -n $(param disk_size) ]] && args+=(--disk "$(param disk_size)")
          [[ -n $(param disk_format) ]] && args+=(--disk-format "$(param disk_format)")
          [[ -n $(param disk_bus) ]] && args+=(--disk-bus "$(param disk_bus)")
          [[ -n $(param iso) ]] && args+=(--iso "$(param iso)")
          [[ -n $requested_network ]] && args+=(--network "$requested_network")
          [[ -n $(param bridge) ]] && args+=(--bridge "$(param bridge)")
          [[ -n $(param overlay) ]] && args+=(--overlay "$(param overlay)")
          [[ -n $(param nic_model) ]] && args+=(--nic-model "$(param nic_model)")
          [[ -n $(param vlan) ]] && args+=(--vlan "$(param vlan)")
          [[ -n $(param autostart) ]] && args+=(--autostart "$(param autostart)")
          [[ -n $(param firmware) ]] && args+=(--firmware "$(param firmware)")
          [[ -n $(param machine) ]] && args+=(--machine "$(param machine)")
          [[ -n $(param cpu) ]] && args+=(--cpu "$(param cpu)")
          [[ -n $(param emulation) ]] && args+=(--emulation "$(param emulation)")
          [[ -n $(param vnc_display) ]] && args+=(--vnc-display "$(param vnc_display)")
          [[ -n $(param vnc_bind) ]] && args+=(--vnc-bind "$(param vnc_bind)")
          [[ -n $(param display) ]] && args+=(--display "$(param display)")
          [[ -n $(param boot) ]] && args+=(--boot "$(param boot)")
          cloud_user_data=$(param cloud_init_user_data); cloud_hostname=$(param cloud_init_hostname); [[ -n $cloud_hostname ]] || cloud_hostname=$name
          run_cmd "$VMCTL" "${args[@]}" >/dev/null
          if [[ -n $cloud_user_data ]]; then
            if ! cloud_out=$(printf '%s' "$cloud_user_data" | "$VMCTL" cloud-init-set "$name" --hostname "$cloud_hostname" 2>&1); then
              vm_delete_cmd "$name" >/dev/null 2>&1 || true
              error_reply '400 Bad Request' "Cloud-init configuration failed: $cloud_out"
            fi
          fi
          body=$(json_config "$name"); reply '201 Created' "$body";;
        *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
      esac
    fi

    name=${P[1]}
    case "${P[2]-}" in
      '')
        case "$method" in
          GET) cgi_require_vm "$name"; body=$(json_config "$name"); reply '200 OK' "$body";;
          DELETE) run_cmd vm_delete_cmd "$name" >/dev/null; reply '200 OK' '{"deleted":true}';;
          PATCH|POST)
            field=$(param field); value=$(param value); [[ -n $field ]] || error_reply '400 Bad Request' 'field is required'
            run_cmd "$VMCTL" set "$name" "$field" "$value" >/dev/null; body=$(json_config "$name"); reply '200 OK' "$body";;
          *) error_reply '405 Method Not Allowed' 'Unsupported method';;
        esac;;
      cloud-init)
        cgi_require_vm "$name"
        case "$method" in
          GET) raw_json_reply '200 OK' "$VMCTL" cloud-init-show "$name";;
          PUT|POST)
            user_data=$(param user_data); hostname=$(param hostname); [[ -n $hostname ]] || hostname=$name
            [[ -n $user_data ]] || error_reply '400 Bad Request' 'user_data is required'
            if ! cloud_out=$(printf '%s' "$user_data" | "$VMCTL" cloud-init-set "$name" --hostname "$hostname" 2>&1); then error_reply '400 Bad Request' "$cloud_out"; fi
            raw_json_reply '200 OK' "$VMCTL" cloud-init-show "$name";;
          DELETE)
            run_cmd "$VMCTL" cloud-init-disable "$name" >/dev/null
            raw_json_reply '200 OK' "$VMCTL" cloud-init-show "$name";;
          *) error_reply '405 Method Not Allowed' 'Use GET, PUT, POST, or DELETE';;
        esac;;
      start)
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        pid=$(run_cmd "$VMCTL" start "$name"); reply '200 OK' "{\"state\":\"running\",\"pid\":$pid}";;
      stop)
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        args=(stop "$name"); [[ $(param force false) == true ]] && args+=(--force)
        run_cmd "$VMCTL" "${args[@]}" >/dev/null; reply '200 OK' '{"state":"stopped"}';;
      shutdown)
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        args=(shutdown "$name"); [[ -n $(param timeout) ]] && args+=(--timeout "$(param timeout)"); [[ $(param force false) == true ]] && args+=(--force)
        run_cmd "$VMCTL" "${args[@]}" >/dev/null; reply '200 OK' '{"state":"stopped","graceful":true}';;
      reboot)
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        args=(reboot "$name"); [[ $(param force false) == true ]] && args+=(--force)
        run_cmd "$VMCTL" "${args[@]}" >/dev/null; reply '200 OK' '{"rebooted":true,"graceful":false}';;
      restart)
        [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
        args=(restart "$name"); [[ -n $(param timeout) ]] && args+=(--timeout "$(param timeout)"); [[ $(param force false) == true ]] && args+=(--force)
        run_cmd "$VMCTL" "${args[@]}" >/dev/null; reply '200 OK' '{"restarted":true,"graceful":true}';;
      metrics)
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
        raw_json_reply '200 OK' "$METRICSCTL" vm "$name";;
      console)
        if [[ ${P[3]-} == session ]]; then
          if command -v sudo >/dev/null 2>&1; then console_cmd=(sudo -n "$CONSOLECTL"); else console_cmd=("$CONSOLECTL"); fi
          case "$method" in
            GET) raw_json_reply '200 OK' "${console_cmd[@]}" info "$name";;
            POST) raw_json_reply '201 Created' "${console_cmd[@]}" start "$name";;
            PATCH) raw_json_reply '200 OK' "${console_cmd[@]}" touch "$name";;
            DELETE) run_cmd "${console_cmd[@]}" stop "$name" >/dev/null; reply '200 OK' '{"stopped":true}';;
            *) error_reply '405 Method Not Allowed' 'Use GET, POST, PATCH, or DELETE';;
          esac
        fi
        [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
        out=$(run_cmd "$VMCTL" console-info "$name")
        first=true; printf 'Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n{'
        while IFS='=' read -r k v; do $first || printf ','; first=false; [[ $k == vnc_port && $v =~ ^[0-9]+$ ]] && printf '"%s":%s' "$k" "$v" || printf '"%s":"%s"' "$(json_escape "$k")" "$(json_escape "$v")"; done <<< "$out"
        printf '}\n'; exit 0;;
      disks)
        if [[ ${P[3]-} == import && -n ${P[4]-} ]]; then
          [[ $method == PUT ]] || error_reply '405 Method Not Allowed' 'Use PUT'
          args=(disk-import-stdin "$name" "${P[4]}")
          [[ -n $(param format) ]] && args+=(--format "$(param format)")
          [[ -n $(param bus) ]] && args+=(--bus "$(param bus)")
          idx=$(run_cmd "$VMCTL" "${args[@]}")
          reply '201 Created' "{\"index\":$idx}"
        fi
        if [[ -n ${P[3]-} && ${P[4]-} == download && -z ${P[5]-} ]]; then
          [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
          validate_int "${P[3]}"
          file=$(cfg_get_file "$(vm_conf "$name")" "DISK_${P[3]}_FILE" '')
          [[ -n $file ]] || error_reply '404 Not Found' 'Disk not found'
          download_reply "$file" "$VMCTL" disk-download "$name" "${P[3]}"
        fi
        if [[ -z ${P[3]-} ]]; then
          [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
          size=$(param size); [[ -n $size ]] || error_reply '400 Bad Request' 'size is required'
          args=(disk-add "$name" --size "$size")
          [[ -n $(param file) ]] && args+=(--file "$(param file)")
          [[ -n $(param format) ]] && args+=(--format "$(param format)")
          [[ -n $(param bus) ]] && args+=(--bus "$(param bus)")
          idx=$(run_cmd "$VMCTL" "${args[@]}"); reply '201 Created' "{\"index\":$idx}" 
        else
          case "$method" in
            DELETE)
              args=(disk-remove "$name" "${P[3]}"); [[ $(param delete_file false) == true ]] && args+=(--delete-file)
              run_cmd "$VMCTL" "${args[@]}" >/dev/null; reply '200 OK' '{"deleted":true}';;
            PATCH|POST)
              field=$(param field); value=$(param value); [[ -n $field ]] || error_reply '400 Bad Request' 'field is required'
              if [[ $field == size ]]; then run_cmd "$VMCTL" disk-resize "$name" "${P[3]}" "$value" >/dev/null
              else run_cmd "$VMCTL" disk-set "$name" "${P[3]}" "$field" "$value" >/dev/null; fi
              reply '200 OK' '{"updated":true}';;
            *) error_reply '405 Method Not Allowed' 'Use DELETE or PATCH';;
          esac
        fi;;
      nics)
        if [[ -z ${P[3]-} ]]; then
          [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
          mode=$(param mode); [[ -n $mode ]] || error_reply '400 Bad Request' 'mode is required'
          args=(nic-add "$name" --mode "$mode")
          [[ -n $(param bridge) ]] && args+=(--bridge "$(param bridge)")
          [[ -n $(param overlay) ]] && args+=(--overlay "$(param overlay)")
          [[ -n $(param model) ]] && args+=(--model "$(param model)")
          [[ -n $(param mac) ]] && args+=(--mac "$(param mac)")
          [[ -n $(param vlan) ]] && args+=(--vlan "$(param vlan)")
          idx=$(run_cmd "$VMCTL" "${args[@]}"); reply '201 Created' "{\"index\":$idx}"
        else
          case "$method" in
            DELETE) run_cmd "$VMCTL" nic-remove "$name" "${P[3]}" >/dev/null; reply '200 OK' '{"deleted":true}';;
            PATCH|POST)
              field=$(param field); value=$(param value); [[ -n $field ]] || error_reply '400 Bad Request' 'field is required'
              run_cmd "$VMCTL" nic-set "$name" "${P[3]}" "$field" "$value" >/dev/null; reply '200 OK' '{"updated":true}';;
            *) error_reply '405 Method Not Allowed' 'Use DELETE or PATCH';;
          esac
        fi;;
      pci)
        if [[ -z ${P[3]-} ]]; then
          [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
          bdf=$(param bdf); [[ -n $bdf ]] || error_reply '400 Bad Request' 'bdf is required'
          idx=$(run_cmd "$VMCTL" pci-add "$name" "$bdf"); reply '201 Created' "{\"index\":$idx}"
        else
          [[ $method == DELETE ]] || error_reply '405 Method Not Allowed' 'Use DELETE'
          run_cmd "$VMCTL" pci-remove "$name" "${P[3]}" >/dev/null; reply '200 OK' '{"deleted":true}'
        fi;;
      *) error_reply '404 Not Found' 'Unknown VM endpoint';;
    esac;;

  docker)
    case "${P[1]-}" in
      containers)
        if [[ -z ${P[2]-} ]]; then
          case "$method" in
            GET) json_lines_reply '200 OK' "$DOCKERCTL" list-json;;
            POST)
              name=$(param name); image=$(param image)
              [[ -n $name ]] || error_reply '400 Bad Request' 'name is required'
              [[ -n $image ]] || error_reply '400 Bad Request' 'image is required'
              requested_network=$(param network)
              args=(create "$name" "$image")
              [[ -n $(param hostname) ]] && args+=(--hostname "$(param hostname)")
              [[ -n $(param restart) ]] && args+=(--restart "$(param restart)")
              [[ -n $(param cpus) ]] && args+=(--cpus "$(param cpus)")
              [[ -n $(param memory) ]] && args+=(--memory "$(param memory)")
              [[ -n $requested_network ]] && args+=(--network "$requested_network")
              [[ -n $(param ip) ]] && args+=(--ip "$(param ip)")
              [[ -n $(param user) ]] && args+=(--user "$(param user)")
              [[ -n $(param workdir) ]] && args+=(--workdir "$(param workdir)")
              [[ -n $(param entrypoint) ]] && args+=(--entrypoint "$(param entrypoint)")
              [[ $(param read_only false) == true ]] && args+=(--read-only)
              for prefix in env publish volume label; do
                case "$prefix" in env) opt=--env;; publish) opt=--publish;; volume) opt=--volume;; label) opt=--label;; esac
                for ((i=0;i<64;i++)); do
                  v=$(param "${prefix}_${i}")
                  [[ -n $v ]] || continue
                  args+=("$opt" "$v")
                done
              done
              cmdargs=()
              for ((i=0;i<64;i++)); do v=$(param "cmd_${i}"); [[ -n $v ]] && cmdargs+=("$v"); done
              ((${#cmdargs[@]})) && args+=(-- "${cmdargs[@]}")
              run_cmd "$DOCKERCTL" "${args[@]}" >/dev/null
              raw_json_reply '201 Created' "$DOCKERCTL" show "$name";;
            *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
          esac
        fi
        name=${P[2]}
        case "${P[3]-}" in
          '')
            case "$method" in
              GET) raw_json_reply '200 OK' "$DOCKERCTL" show "$name";;
              PATCH|POST)
                field=$(param field); value=$(param value)
                [[ -n $field ]] || error_reply '400 Bad Request' 'field is required'
                run_cmd "$DOCKERCTL" update "$name" "$field" "$value" >/dev/null
                raw_json_reply '200 OK' "$DOCKERCTL" show "$name";;
              DELETE)
                args=(delete "$name")
                [[ $(param force false) == true ]] && args+=(--force)
                [[ $(param volumes false) == true ]] && args+=(--volumes)
                run_cmd "$DOCKERCTL" "${args[@]}" >/dev/null
                reply '200 OK' '{"deleted":true}';;
              *) error_reply '405 Method Not Allowed' 'Unsupported method';;
            esac;;
          start)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            run_cmd "$DOCKERCTL" start "$name" >/dev/null; reply '200 OK' '{"state":"running"}';;
          stop)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            args=(stop "$name")
            [[ -n $(param time) ]] && args+=(--time "$(param time)")
            [[ $(param force false) == true ]] && args+=(--force)
            run_cmd "$DOCKERCTL" "${args[@]}" >/dev/null; reply '200 OK' '{"state":"stopped"}';;
          restart|reboot)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            args=(restart "$name"); [[ -n $(param time) ]] && args+=(--time "$(param time)")
            run_cmd "$DOCKERCTL" "${args[@]}" >/dev/null; reply '200 OK' '{"restarted":true}';;
          metrics)
            [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
            raw_json_reply '200 OK' "$METRICSCTL" container "$name";;
          logs)
            [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
            args=(logs "$name")
            [[ -n $(param tail) ]] && args+=(--tail "$(param tail)")
            [[ -n $(param since) ]] && args+=(--since "$(param since)")
            [[ $(param timestamps false) == true ]] && args+=(--timestamps)
            [[ $(param follow false) == true ]] && args+=(--follow)
            text_reply '200 OK' "$DOCKERCTL" "${args[@]}";;
          commit)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            image=$(param image); [[ -n $image ]] || error_reply '400 Bad Request' 'image is required'
            args=(commit "$name" "$image")
            [[ -n $(param author) ]] && args+=(--author "$(param author)")
            [[ -n $(param message) ]] && args+=(--message "$(param message)")
            [[ -n $(param pause) ]] && args+=(--pause "$(param pause)")
            id=$(run_cmd "$DOCKERCTL" "${args[@]}")
            reply '201 Created' "{\"image\":\"$(json_escape "$image")\",\"id\":\"$(json_escape "$id")\"}";;
          exec)
            [[ ${P[4]-} == session ]] || error_reply '404 Not Found' 'Unknown Docker exec endpoint'
            if command -v sudo >/dev/null 2>&1; then exec_cmd=(sudo -n "$DOCKEREXECCTL"); else exec_cmd=("$DOCKEREXECCTL"); fi
            case "$method" in
              GET) raw_json_reply '200 OK' "${exec_cmd[@]}" info "$name";;
              POST)
                args=(start "$name")
                [[ -n $(param shell) ]] && args+=(--shell "$(param shell)")
                raw_json_reply '201 Created' "${exec_cmd[@]}" "${args[@]}";;
              PATCH) raw_json_reply '200 OK' "${exec_cmd[@]}" touch "$name";;
              DELETE) run_cmd "${exec_cmd[@]}" stop "$name" >/dev/null; reply '200 OK' '{"stopped":true}';;
              *) error_reply '405 Method Not Allowed' 'Use GET, POST, PATCH, or DELETE';;
            esac;;
          *) error_reply '404 Not Found' 'Unknown Docker container endpoint';;
        esac;;

      images)
        case "${P[2]-}" in
          '')
            case "$method" in
              GET)
                image=$(param image)
                if [[ -n $image ]]; then raw_json_reply '200 OK' "$DOCKER_IMAGECTL" inspect "$image"
                else json_lines_reply '200 OK' "$DOCKER_IMAGECTL" list-json; fi;;
              DELETE)
                image=$(param image); [[ -n $image ]] || error_reply '400 Bad Request' 'image is required'
                args=(remove "$image"); [[ $(param force false) == true ]] && args+=(--force)
                output=$(run_cmd "$DOCKER_IMAGECTL" "${args[@]}")
                reply '200 OK' "{\"deleted\":true,\"output\":\"$(json_escape "$output")\"}";;
              *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
            esac;;
          pull)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            image=$(param image); [[ -n $image ]] || error_reply '400 Bad Request' 'image is required'
            output=$(run_cmd "$DOCKER_IMAGECTL" pull "$image")
            reply '200 OK' "{\"image\":\"$(json_escape "$image")\",\"output\":\"$(json_escape "$output")\"}";;
          tag)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            source=$(param source); target=$(param target)
            [[ -n $source && -n $target ]] || error_reply '400 Bad Request' 'source and target are required'
            run_cmd "$DOCKER_IMAGECTL" tag "$source" "$target" >/dev/null; reply '200 OK' '{"tagged":true}';;
          *) error_reply '404 Not Found' 'Unknown Docker image endpoint';;
        esac;;

      registry)
        case "${P[2]-}" in
          '')
            case "$method" in
              GET) raw_json_reply '200 OK' registry_cmd status;;
              POST) username=$(param username registry); raw_json_reply '201 Created' registry_cmd enable "$username";;
              DELETE) raw_json_reply '200 OK' registry_cmd disable;;
              *) error_reply '405 Method Not Allowed' 'Use GET, POST, or DELETE';;
            esac;;
          credentials)
            [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
            raw_json_reply '200 OK' registry_cmd credentials;;
          catalog)
            [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
            raw_json_reply '200 OK' registry_cmd catalog;;
          push)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            source=$(param source); repository=$(param repository); [[ -n $source && -n $repository ]] || error_reply '400 Bad Request' 'source and repository are required'
            raw_json_reply '200 OK' registry_cmd push "$source" "$repository";;
          peer-pull)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            peer_id=$(param peer_id); repository=$(param repository); [[ -n $peer_id && -n $repository ]] || error_reply '400 Bad Request' 'peer_id and repository are required'
            raw_json_reply '200 OK' registry_cmd peer-pull "$peer_id" "$repository";;
          peer-push)
            [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
            peer_id=$(param peer_id); source=$(param source); repository=$(param repository); [[ -n $peer_id && -n $source && -n $repository ]] || error_reply '400 Bad Request' 'peer_id, source, and repository are required'
            raw_json_reply '200 OK' registry_cmd peer-push "$peer_id" "$source" "$repository";;
          *) error_reply '404 Not Found' 'Unknown registry endpoint';;
        esac;;

      networks)
        if [[ -z ${P[2]-} ]]; then
          case "$method" in
            GET) json_lines_reply '200 OK' "$DOCKER_NETCTL" list-json;;
            POST)
              name=$(param name); [[ -n $name ]] || error_reply '400 Bad Request' 'name is required'
              args=(create "$name")
              [[ -n $(param driver) ]] && args+=(--driver "$(param driver)")
              [[ -n $(param subnet) ]] && args+=(--subnet "$(param subnet)")
              [[ -n $(param gateway) ]] && args+=(--gateway "$(param gateway)")
              [[ $(param internal false) == true ]] && args+=(--internal)
              [[ $(param ipv6 false) == true ]] && args+=(--ipv6)
              for ((i=0;i<64;i++)); do v=$(param "label_${i}"); [[ -n $v ]] && args+=(--label "$v"); done
              for ((i=0;i<64;i++)); do v=$(param "opt_${i}"); [[ -n $v ]] && args+=(--opt "$v"); done
              run_cmd "$DOCKER_NETCTL" "${args[@]}" >/dev/null; raw_json_reply '201 Created' "$DOCKER_NETCTL" inspect "$name";;
            *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
          esac
        fi
        name=${P[2]}
        case "$method" in
          GET) raw_json_reply '200 OK' "$DOCKER_NETCTL" inspect "$name";;
          DELETE) run_cmd "$DOCKER_NETCTL" remove "$name" >/dev/null; reply '200 OK' '{"deleted":true}';;
          *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
        esac;;

      peer-volumes)
        require_capability peer-volume-client
        if [[ -z ${P[2]-} ]]; then
          case "$method" in
            GET) raw_json_reply '200 OK' peer_volume_cmd mount-list;;
            POST)
              peer_id=$(param peer_id); remote_name=$(param remote_name); name=$(param name)
              [[ -n $peer_id && -n $remote_name ]] || error_reply '400 Bad Request' 'peer_id and remote_name are required'
              [[ -n $name ]] || name=$remote_name
              raw_json_reply '201 Created' peer_volume_cmd attach "$peer_id" "$remote_name" "$name";;
            *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
          esac
        fi
        name=${P[2]}
        case "$method" in
          GET) raw_json_reply '200 OK' peer_volume_cmd mount-show "$name";;
          DELETE) raw_json_reply '200 OK' peer_volume_cmd detach "$name";;
          *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
        esac;;

      volumes)
        if [[ -z ${P[2]-} ]]; then
          case "$method" in
            GET) json_lines_reply '200 OK' "$DOCKER_VOLUMECTL" list-json;;
            POST)
              name=$(param name); [[ -n $name ]] || error_reply '400 Bad Request' 'name is required'
              args=(create "$name")
              [[ -n $(param driver) ]] && args+=(--driver "$(param driver)")
              for ((i=0;i<64;i++)); do
                v=$(param "label_${i}"); [[ -n $v ]] && args+=(--label "$v")
                v=$(param "opt_${i}"); [[ -n $v ]] && args+=(--opt "$v")
              done
              run_cmd "$DOCKER_VOLUMECTL" "${args[@]}" >/dev/null; raw_json_reply '201 Created' "$DOCKER_VOLUMECTL" inspect "$name";;
            *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
          esac
        fi
        name=${P[2]}
        case "$method" in
          GET) raw_json_reply '200 OK' "$DOCKER_VOLUMECTL" inspect "$name";;
          DELETE)
            args=(remove "$name"); [[ $(param force false) == true ]] && args+=(--force)
            run_cmd "$DOCKER_VOLUMECTL" "${args[@]}" >/dev/null; reply '200 OK' '{"deleted":true}';;
          *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
        esac;;
      *) error_reply '404 Not Found' 'Unknown Docker endpoint';;
    esac;;

  compose)
    case "${P[1]-}" in
      projects)
        if [[ -z ${P[2]-} ]]; then
          [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
          raw_json_reply '200 OK' "$COMPOSECTL" list
        fi
        project=${P[2]}
        case "${P[3]-}" in
          '')
            case "$method" in
              GET) text_reply '200 OK' "$COMPOSECTL" show "$project";;
              DELETE) run_cmd "$COMPOSECTL" delete "$project" >/dev/null; reply '200 OK' '{"deleted":true}';;
              *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
            esac;;
          deploy) [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'; raw_json_reply '200 OK' "$COMPOSECTL" deploy "$project";;
          down) [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'; raw_json_reply '200 OK' "$COMPOSECTL" down "$project";;
          *) error_reply '404 Not Found' 'Unknown Compose project endpoint';;
        esac;;
      *) error_reply '404 Not Found' 'Unknown Compose endpoint';;
    esac;;

  images)
    if [[ -z ${P[1]-} ]]; then
      [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
      first=true; printf 'Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n['
      while IFS=$'\t' read -r n s; do [[ -n $n ]] || continue; $first || printf ','; first=false; printf '{"name":"%s","bytes":%s}' "$(json_escape "$n")" "$s"; done < <("$IMAGECTL" list)
      printf ']\n'; exit 0
    fi
    case "$method" in
      GET) download_reply "${P[1]}" "$IMAGECTL" download "${P[1]}";;
      DELETE) run_cmd "$IMAGECTL" delete "${P[1]}" >/dev/null; reply '200 OK' '{"deleted":true}';;
      *) error_reply '405 Method Not Allowed' 'Use GET or DELETE';;
    esac;;

  storage)
    case "$method" in
      GET) raw_json_reply '200 OK' storage_cmd status;;
      POST)
        kind=$(param kind); path=$(param path)
        [[ -n $kind && -n $path ]] || error_reply '400 Bad Request' 'kind and path are required'
        raw_json_reply '200 OK' storage_cmd relocate "$kind" "$path";;
      *) error_reply '405 Method Not Allowed' 'Use GET or POST';;
    esac;;

  networks)
    case "$method" in
      GET)
        name=$(param name)
        if [[ -n $name ]]; then raw_json_reply '200 OK' "$NETCTL" bridge-info "$name"; fi
        first=true; printf 'Status: 200 OK\r\nContent-Type: application/json\r\nCache-Control: no-store\r\n\r\n{"bridges":['
        while IFS= read -r br; do [[ -n $br ]] || continue; $first || printf ','; first=false; printf '"%s"' "$(json_escape "$br")"; done < <("$NETCTL" bridges)
        printf '],"interfaces":['; first=true
        while IFS= read -r i; do [[ -n $i ]] || continue; $first || printf ','; first=false; printf '"%s"' "$(json_escape "$i")"; done < <("$NETCTL" interfaces)
        printf ']}\n'; exit 0;;
      POST)
        name=$(param name); [[ -n $name ]] || error_reply '400 Bad Request' 'name is required'
        if command -v sudo >/dev/null 2>&1; then args=(sudo -n "$NETCTL" bridge-create "$name"); else args=("$NETCTL" bridge-create "$name"); fi
        [[ -n $(param address) ]] && args+=(--address "$(param address)")
        [[ $(param dhcp false) == true ]] && args+=(--dhcp)
        [[ $(param manual false) == true ]] && args+=(--manual)
        [[ -n $(param gateway) ]] && args+=(--gateway "$(param gateway)")
        for ((i=0;i<16;i++)); do v=$(param "member_${i}"); [[ -n $v ]] && args+=(--member "$v"); done
        [[ $(param persist false) == true ]] && args+=(--persist)
        if ! out=$("${args[@]}" 2>&1); then error_reply '400 Bad Request' "$out"; fi
        reply '201 Created' "{\"name\":\"$(json_escape "$out")\"}";;
      PATCH)
        name=$(param name); [[ -n $name ]] || error_reply '400 Bad Request' 'name is required'
        if command -v sudo >/dev/null 2>&1; then args=(sudo -n "$NETCTL" bridge-update "$name"); else args=("$NETCTL" bridge-update "$name"); fi
        [[ -n ${FORM[address]+set} ]] && args+=(--address "$(param address)")
        [[ $(param dhcp false) == true ]] && args+=(--dhcp)
        [[ $(param manual false) == true ]] && args+=(--manual)
        [[ -n ${FORM[gateway]+set} ]] && args+=(--gateway "$(param gateway)")
        args+=(--clear-members)
        for ((i=0;i<16;i++)); do v=$(param "member_${i}"); [[ -n $v ]] && args+=(--member "$v"); done
        if [[ $(param persist false) == true ]]; then args+=(--persist); else args+=(--no-persist); fi
        if ! out=$("${args[@]}" 2>&1); then error_reply '400 Bad Request' "$out"; fi
        raw_json_reply '200 OK' "$NETCTL" bridge-info "$name";;
      DELETE)
        name=$(param name); [[ -n $name ]] || error_reply '400 Bad Request' 'name is required'
        if command -v sudo >/dev/null 2>&1; then args=(sudo -n "$NETCTL" bridge-delete "$name"); else args=("$NETCTL" bridge-delete "$name"); fi
        run_cmd "${args[@]}" >/dev/null; reply '200 OK' '{"deleted":true}';;
      *) error_reply '405 Method Not Allowed' 'Use GET, POST, or DELETE';;
    esac;;

  overlays)
    if [[ ${P[2]-} == stage || ${P[2]-} == validate || ${P[2]-} == activate ]]; then
      [[ $method == POST ]] || error_reply '405 Method Not Allowed' 'Use POST'
      raw_json_reply '200 OK' overlay_cmd "${P[2]}" "${P[1]}"
    fi
    if [[ ${P[2]-} == health ]]; then
      [[ $method == GET ]] || error_reply '405 Method Not Allowed' 'Use GET'
      [[ -n ${P[1]-} ]] || error_reply '400 Bad Request' 'overlay name is required'
      raw_json_reply '200 OK' overlay_cmd health "${P[1]}"
    fi
    case "$method" in
      GET)
        if [[ -n ${P[1]-} ]]; then raw_json_reply '200 OK' overlay_cmd show "${P[1]}"; else raw_json_reply '200 OK' overlay_cmd list; fi;;
      POST)
        name=$(param name); bridge=$(param bridge); role=$(param role); mtu=$(param mtu 1400); staged=$(param staged false)
        [[ $name =~ ^[a-z][a-z0-9-]{0,10}$ ]] || error_reply '400 Bad Request' 'invalid overlay name'
        [[ $bridge =~ ^[a-zA-Z][a-zA-Z0-9_-]{0,14}$ ]] || error_reply '400 Bad Request' 'invalid Linux bridge name'
        [[ $role == hub || $role == spoke ]] || error_reply '400 Bad Request' 'role must be hub or spoke'
        [[ $mtu =~ ^[0-9]{4}$ && $mtu -ge 1200 && $mtu -le 1499 ]] || error_reply '400 Bad Request' 'MTU must be 1200-1499'
        [[ $staged == true || $staged == false ]] || error_reply '400 Bad Request' 'staged must be true or false'

        if [[ $PEER_API_REQUEST == true ]]; then
          caller_peer=$(peer_cmd peer-id-for-user "$REMOTE_USER" 2>&1) || error_reply '401 Unauthorized' "$caller_peer"
          args=(create "$name" --bridge "$bridge" --role "$role" --peer "$caller_peer" --mtu "$mtu")
          [[ $staged == true ]] && args+=(--staged)
          out=$(overlay_cmd "${args[@]}" 2>&1) || error_reply '400 Bad Request' "$out"
          reply '201 Created' "$out"
        fi

        peers=()
        for ((i=0;i<16;i++)); do
          v=$(param "peer_$i")
          [[ -n $v ]] || continue
          [[ $v =~ ^[a-fA-F0-9]{32}$ ]] || error_reply '400 Bad Request' 'invalid paired host id'
          peers+=("${v,,}")
        done
        ((${#peers[@]} > 0)) || error_reply '400 Bad Request' 'at least one paired host is required'
        [[ $role == hub || ${#peers[@]} == 1 ]] || error_reply '400 Bad Request' 'a spoke requires exactly one paired hub'

        local_args=(create "$name" --bridge "$bridge" --role "$role")
        for v in "${peers[@]}"; do local_args+=(--peer "$v"); done
        local_args+=(--mtu "$mtu")
        [[ $staged == true ]] && local_args+=(--staged)

        created_remote=()
        rollback_overlay() {
          local peer
          for peer in "${created_remote[@]}"; do overlay_remote_delete "$peer" "$name" >/dev/null 2>&1 || true; done
          overlay_cmd delete "$name" >/dev/null 2>&1 || true
        }

        if [[ $role == hub ]]; then
          out=$(overlay_cmd "${local_args[@]}" 2>&1) || error_reply '400 Bad Request' "$out"
          for v in "${peers[@]}"; do
            if ! remote_out=$(overlay_remote_create "$v" "$name" "$bridge" spoke "$mtu" "$staged" 2>&1); then
              rollback_overlay
              error_reply '502 Bad Gateway' "Peer overlay creation failed for $v: $remote_out"
            fi
            created_remote+=("$v")
          done
        else
          v=${peers[0]}
          if ! remote_out=$(overlay_remote_create "$v" "$name" "$bridge" hub "$mtu" "$staged" 2>&1); then
            error_reply '502 Bad Gateway' "Peer overlay creation failed for $v: $remote_out"
          fi
          created_remote+=("$v")
          if ! out=$(overlay_cmd "${local_args[@]}" 2>&1); then
            rollback_overlay
            error_reply '400 Bad Request' "$out"
          fi
        fi
        raw_json_reply '201 Created' overlay_cmd show "$name";;
      DELETE)
        name=${P[1]-}; [[ -n $name ]] || name=$(param name); [[ -n $name ]] || error_reply '400 Bad Request' 'overlay name is required'
        [[ $name =~ ^[a-z][a-z0-9-]{0,10}$ ]] || error_reply '400 Bad Request' 'invalid overlay name'
        if [[ $PEER_API_REQUEST == true ]]; then
          overlay_cmd delete "$name" >/dev/null 2>&1 || true
          reply '200 OK' '{"deleted":true,"remote_cleanup":"not_applicable"}'
        fi
        peers=()
        mapfile -t peers < <(overlay_cmd peer-list "$name" 2>/dev/null || true)
        local_out=$(overlay_cmd delete "$name" 2>&1) || error_reply '500 Internal Server Error' "Local overlay cleanup failed: $local_out"
        warnings=()
        for v in "${peers[@]}"; do
          [[ $v =~ ^[a-f0-9]{32}$ ]] || continue
          if ! out=$(overlay_remote_delete "$v" "$name" 2>&1); then warnings+=("peer $v: $out"); fi
        done
        if ((${#warnings[@]})); then
          warning=$(printf '%s; ' "${warnings[@]}")
          warning=${warning%; }
          reply '200 OK' "{\"deleted\":true,\"remote_cleanup\":\"warning\",\"warning\":\"$(json_escape "$warning")\"}"
        fi
        reply '200 OK' '{"deleted":true,"remote_cleanup":"complete"}';;
      *) error_reply '405 Method Not Allowed' 'Use GET, POST, or DELETE';;
    esac;;

  *) error_reply '404 Not Found' 'Unknown endpoint';;
esac
