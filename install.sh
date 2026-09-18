#!/bin/sh
# LiteVMM's single, idempotent installer for Alpine and Debian-family hosts.
# This POSIX shell prelude exists so a stock Alpine image can start the installer
# before Bash itself has been installed. It re-executes this same file in Bash.
if [ "${VMAPI_INSTALL_BASH:-}" != 1 ]; then
  [ "$(id -u)" -eq 0 ] || { echo 'Run with: sudo ./install.sh' >&2; exit 1; }
  if ! command -v bash >/dev/null 2>&1; then
    [ -r /etc/os-release ] || { echo 'Unsupported host: /etc/os-release is missing' >&2; exit 1; }
    # shellcheck disable=SC1091
    . /etc/os-release
    case ${ID:-} in
      alpine) apk update && apk add --no-cache bash ;;
      debian|ubuntu|linuxmint|pop) apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends bash ;;
      *) echo "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}" >&2; exit 1 ;;
    esac
  fi
  exec env VMAPI_INSTALL_BASH=1 bash "$0" "$@"
fi

set -Eeuo pipefail
umask 022

[[ $EUID -eq 0 ]] || { echo 'Run with: sudo ./install.sh' >&2; exit 1; }

BASE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PLATFORM=''
ADMIN_USER=${VMAPI_ADMIN_USER:-${SUDO_USER:-}}
GOST_VERSION=3.2.6
PROFILE=${VMAPI_INSTALL_PROFILE:-}
HTTP_PORT=${VMAPI_HTTP_PORT:-5186}

usage() {
  cat <<'TXT'
Usage: sudo ./install.sh [--profile backup|virtualization|docker|virtualization-docker] [--port PORT]

The LiteVMM API and backup storage are always installed. Choose one workload profile:
  backup                  Backup only
  virtualization          VM + backup
  docker                  Docker + backup
  virtualization-docker   VM + Docker + backup
TXT
}
valid_port() { [[ ${1:-} =~ ^[0-9]{1,5}$ ]] && ((10#$1 >= 1024 && 10#$1 <= 65535)); }
parse_args() {
  while (($#)); do
    case "$1" in
      --profile) PROFILE=${2:?profile required}; shift 2;;
      --port) HTTP_PORT=${2:?port required}; shift 2;;
      -h|--help) usage; exit 0;;
      *) die "Unknown installer option: $1";;
    esac
  done
}
choose_profile() {
  if [[ -z $PROFILE && -t 0 ]]; then
    printf '%s\n' 'Select LiteVMM installation profile:' '  1) backup                 Backup only' '  2) virtualization         VM + backup' '  3) docker                 Docker + backup' '  4) virtualization-docker  VM + Docker + backup'
    read -r -p 'Profile [1]: ' choice
    case ${choice:-1} in 1) PROFILE=backup;; 2) PROFILE=virtualization;; 3) PROFILE=docker;; 4) PROFILE=virtualization-docker;; *) die 'Invalid profile selection';; esac
  fi
  PROFILE=${PROFILE:-backup}
  [[ $PROFILE == virtualization || $PROFILE == docker || $PROFILE == virtualization-docker || $PROFILE == backup ]] || die "Invalid profile: $PROFILE"
  valid_port "$HTTP_PORT" || die "Invalid management port: $HTTP_PORT (use 1024-65535)"
}
die() { echo "ERROR: $*" >&2; exit 1; }
need_source() { [[ -e "$BASE/$1" ]] || die "Missing installer source: $1"; }

detect_platform() {
  [[ -r /etc/os-release ]] || die 'Unsupported host: /etc/os-release is missing'
  # shellcheck disable=SC1091
  . /etc/os-release
  case ${ID:-} in
    alpine) PLATFORM=alpine ;;
    debian|ubuntu|linuxmint|pop) PLATFORM=debian ;;
    *) die "Unsupported operating system: ${PRETTY_NAME:-${ID:-unknown}}. Supported: Alpine and Debian-family Linux." ;;
  esac
}

ensure_admin_user() {
  if [[ -n $ADMIN_USER ]]; then id "$ADMIN_USER" >/dev/null 2>&1 || die "VMAPI_ADMIN_USER is not an existing account: $ADMIN_USER"; return; fi
  [[ -t 0 ]] || return 0
  read -r -p 'Existing Linux account to authorize for VMAPI (leave blank to configure later): ' ADMIN_USER
  [[ -z $ADMIN_USER ]] || id "$ADMIN_USER" >/dev/null 2>&1 || die "Account does not exist: $ADMIN_USER"
}

enable_alpine_community() {
  grep -Eq '^[^#].*/v[0-9.]+/community' /etc/apk/repositories && return
  sed -i -E 's|^#(.*://.*/v[0-9.]+/community)$|\1|' /etc/apk/repositories
}

install_packages() {
  case $PLATFORM in
    alpine)
      enable_alpine_community
      apk update
      apk add --no-cache bash coreutils findutils gawk grep sed shadow util-linux iproute2 iputils curl openssl ca-certificates sudo tar gzip zip fcgiwrap spawn-fcgi lighttpd lighttpd-openrc lighttpd-mod_auth apache2-utils openssh-client-default
      case $PROFILE in
        virtualization) apk add --no-cache iptables nftables socat kmod tcpdump qemu-img qemu-system-x86_64 ovmf novnc websockify ttyd xorriso nfs-utils websocat;;
        docker) apk add --no-cache docker docker-openrc docker-cli-compose ttyd nfs-utils websockify websocat;;
        virtualization-docker) apk add --no-cache iptables nftables socat kmod tcpdump qemu-img qemu-system-x86_64 ovmf novnc websockify ttyd xorriso docker docker-openrc docker-cli-compose nfs-utils websocat;;
        backup) apk add --no-cache iproute2 nfs-utils websockify;;
      esac
      apk add --no-cache certbot
      ;;
    debian)
      export DEBIAN_FRONTEND=noninteractive
      apt-get update
      apt-get install -y --no-install-recommends bash coreutils findutils gawk grep sed passwd util-linux iproute2 iputils-ping curl openssl ca-certificates sudo tar gzip zip nginx fcgiwrap libnginx-mod-http-auth-pam openssh-client apache2-utils
      case $PROFILE in
        virtualization) apt-get install -y --no-install-recommends iptables nftables socat kmod tcpdump qemu-system-x86 qemu-utils ovmf ttyd xorriso nfs-common nfs-kernel-server websockify;;
        docker) apt-get install -y --no-install-recommends docker.io ttyd nfs-common nfs-kernel-server websockify;;
        virtualization-docker) apt-get install -y --no-install-recommends iptables nftables socat kmod tcpdump qemu-system-x86 qemu-utils ovmf docker.io ttyd xorriso nfs-common nfs-kernel-server websockify;;
        backup) apt-get install -y --no-install-recommends iproute2 nfs-common nfs-kernel-server websockify;;
      esac
      apt-get install -y --no-install-recommends certbot
      ;;
  esac
  update-ca-certificates 2>/dev/null || true
}

install_websocat() {
  command -v websocat >/dev/null 2>&1 && return
  local asset sha work
  case $(uname -m) in
    x86_64|amd64) asset=websocat.x86_64-unknown-linux-musl; sha=66f8dd3a0394761556339117f8bb5123bddefd44e087af2a72ec22b0bd08d514 ;;
    aarch64|arm64) asset=websocat.aarch64-unknown-linux-musl; sha=711a69576a2ff473fb01a90ffafb571c2ed019e55479d7ae71b12c2eadeb7011 ;;
    *) die "Unsupported CPU for bundled Websocat v1.14.1: $(uname -m)" ;;
  esac
  work=$(mktemp -d); trap 'rm -rf -- "$work"' RETURN
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3     -o "$work/websocat" "https://github.com/vi/websocat/releases/download/v1.14.1/$asset"
  echo "$sha  $work/websocat" | sha256sum -c -
  install -m 0755 "$work/websocat" /usr/local/bin/websocat
  trap - RETURN; rm -rf -- "$work"
}

install_gost() {
  local arch asset sha archive work binary
  case $(uname -m) in
    x86_64|amd64) arch=amd64; sha=b39037b0380ea001fb3c0c28441c2e10bfc694f90682739a65b53e55dce5238b ;;
    aarch64|arm64) arch=arm64; sha=f674c8f4a033dc1dfd4f0d5e9602fbe5b0d0f81307bf3794f44b5b5d6d622eae ;;
    *) die "Unsupported CPU for bundled GOST v3: $(uname -m)" ;;
  esac
  if command -v gost >/dev/null 2>&1 && gost -V 2>&1 | grep -Eq '(^|[[:space:]])v?3\.'; then return; fi
  asset="gost_${GOST_VERSION}_linux_${arch}.tar.gz"
  work=$(mktemp -d); trap 'rm -rf -- "$work"' RETURN
  archive="$work/$asset"
  curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
    -o "$archive" "https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}/$asset"
  printf '%s  %s\n' "$sha" "$archive" | sha256sum -c -
  tar -xzf "$archive" -C "$work"
  binary=$(find "$work" -type f -name gost -print -quit)
  [[ -n $binary ]] || die 'GOST release archive did not contain its binary'
  install -m 0755 "$binary" /usr/local/bin/gost
  gost -V 2>&1 | grep -Eq '(^|[[:space:]])v?3\.' || die 'Installed GOST is not version 3'
  trap - RETURN
  rm -rf -- "$work"
}

ensure_tun() {
  modprobe tun 2>/dev/null || true
  install -d -m 0755 /dev/net
  [[ -c /dev/net/tun ]] || mknod /dev/net/tun c 10 200
  chmod 0666 /dev/net/tun
  [[ $PLATFORM != alpine ]] || grep -qxF tun /etc/modules 2>/dev/null || echo tun >> /etc/modules
}

set_host_config() {
  local key=$1 value=$2 file=/etc/vmapi/vmapi.conf tmp
  tmp=$(mktemp)
  awk -v k="$key" -v v="$value" 'BEGIN{done=0} index($0,k"=")==1 {if(!done){print k"="v;done=1};next} {print} END{if(!done)print k"="v}' "$file" > "$tmp"
  cat "$tmp" > "$file"; rm -f "$tmp"
}

activate_requested_profile() {
  install -d -m 0755 /etc/vmapi
  [[ -f /etc/vmapi/vmapi.conf ]] || install -m 0644 "$BASE/etc/vmapi.conf" /etc/vmapi/vmapi.conf
  set_host_config VMAPI_PROFILE "$PROFILE"
  set_host_config VMAPI_HTTP_PORT "$HTTP_PORT"
  set_host_config VMAPI_BACKPLANE_SERVER true
}

disable_native_nfs() {
  case $PLATFORM in
    alpine)
      for svc in nfs nfs-server; do rc-update del "$svc" default >/dev/null 2>&1 || true; rc-service "$svc" stop >/dev/null 2>&1 || true; done;;
    debian)
      systemctl disable --now nfs-server.service nfs-kernel-server.service >/dev/null 2>&1 || true;;
  esac
}

install_common_files() {
  local tool spec wrapper sub asset relative
  for required in etc/vmapi.conf lib/common.sh cgi/api.cgi cgi/peer-api.cgi lighttpd/vmapi.conf nginx/vmapi.conf; do need_source "$required"; done
  install -d -m 0755 /etc/vmapi /usr/local/lib/vmapi /usr/local/bin /usr/lib/vmapi/cgi /usr/share/vmapi/www
  install -d -o root -g vmapi -m 0750 /etc/vmapi/overlays
  install -d -o vmapi -g vmapi -m 0750 /var/lib/vmapi /var/lib/vmapi/vms /var/lib/vmapi/disks /var/lib/vmapi/isos /var/lib/vmapi/backup-jobs /var/lib/vmapi/replication-jobs /var/lib/vmapi/peer-volume-bindings /var/log/vmapi/backups
  install -d -m 0750 /var/lib/vmapi/backplane /var/lib/vmapi/backplane-peers
  install -d -m 0770 /var/lib/vmapi/backplane/peers
  install -d -m 0755 /var/lib/vmapi/peer-storage
  install -d -m 0700 /var/lib/vmapi/peers /etc/vmapi/identity
  [[ -f /etc/vmapi/vmapi.conf ]] || install -m 0644 "$BASE/etc/vmapi.conf" /etc/vmapi/vmapi.conf
  set_host_config VMAPI_PROFILE "$PROFILE"
  set_host_config VMAPI_HTTP_PORT "$HTTP_PORT"
  set_host_config VMAPI_BACKPLANE_SERVER true
  install -m 0644 "$BASE/lib/common.sh" /usr/local/lib/vmapi/common.sh
  install -m 0644 "$BASE/VERSION" /usr/share/vmapi/VERSION
  for tool in vmapi-web-reload vmctl imagectl netctl dockerctl dockerexecctl hostexecctl logctl docker-imagectl docker-netctl docker-volumectl dockercompoectl metricsctl consolectl peerctl vmbackupctl replicationctl registryctl peer-volumectl backplanectl filectl storagectl overlayctl certctl vmapi-console-gc vmapi-autostart vmapi-stopall; do
    need_source "bin/$tool"; install -m 0755 "$BASE/bin/$tool" "/usr/local/bin/$tool"
  done
  install -m 0755 "$BASE/cgi/api.cgi" /usr/lib/vmapi/cgi/api.cgi
  install -m 0755 "$BASE/cgi/peer-api.cgi" /usr/lib/vmapi/cgi/peer-api.cgi
  while IFS= read -r -d '' asset; do relative=${asset#"$BASE/www/"}; install -D -m 0644 "$asset" "/usr/share/vmapi/www/$relative"; done < <(find "$BASE/www" -type f -print0)
  for spec in 'vm-list list' 'vm-show show' 'vm-status status' 'vm-create create' 'vm-set set' 'vm-start start' 'vm-stop stop' 'vm-shutdown shutdown' 'vm-reboot reboot' 'vm-restart restart' 'vm-delete delete' 'vm-disk-add disk-add' 'vm-disk-remove disk-remove' 'vm-disk-resize disk-resize' 'vm-disk-set disk-set' 'vm-nic-add nic-add' 'vm-nic-remove nic-remove' 'vm-nic-set nic-set' 'vm-pci-add pci-add' 'vm-pci-remove pci-remove' 'vm-cloud-init-set cloud-init-set' 'vm-cloud-init-show cloud-init-show' 'vm-cloud-init-disable cloud-init-disable' 'vm-console-info console-info' 'vm-command command'; do
    set -- $spec; wrapper=$1; sub=$2
    printf '#!/usr/bin/env bash\nexec /usr/local/bin/vmctl %s "$@"\n' "$sub" > "/usr/local/bin/$wrapper"; chmod 0755 "/usr/local/bin/$wrapper"
  done
  for spec in 'metrics-host host' 'vm-metrics vm' 'docker-metrics container'; do
    set -- $spec; printf '#!/usr/bin/env bash\nexec /usr/local/bin/metricsctl %s "$@"\n' "$2" > "/usr/local/bin/$1"; chmod 0755 "/usr/local/bin/$1"
  done
  for spec in 'docker-list list' 'docker-show show' 'docker-status status' 'docker-create create' 'docker-update update' 'docker-start start' 'docker-stop stop' 'docker-restart restart' 'docker-delete delete'; do
    set -- $spec; printf '#!/usr/bin/env bash\nexec /usr/local/bin/dockerctl %s "$@"\n' "$2" > "/usr/local/bin/$1"; chmod 0755 "/usr/local/bin/$1"
  done
}

write_sudoers() {
  install -d -m 0750 /etc/sudoers.d
  {
    echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/logctl *'
    echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/certctl status, /usr/local/bin/certctl issue *, /usr/local/bin/certctl renew, /usr/local/bin/certctl csr-generate *, /usr/local/bin/certctl csr-show, /usr/local/bin/certctl import-signed *, /usr/local/bin/certctl import-pair *, /usr/local/bin/certctl disable'
    echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl identity, /usr/local/bin/peerctl request, /usr/local/bin/peerctl request *, /usr/local/bin/peerctl pending, /usr/local/bin/peerctl cancel-pending, /usr/local/bin/peerctl accept *, /usr/local/bin/peerctl complete *, /usr/local/bin/peerctl list, /usr/local/bin/peerctl set-url *, /usr/local/bin/peerctl authorize-user *, /usr/local/bin/peerctl cors-origin *, /usr/local/bin/peerctl proxy *, /usr/local/bin/peerctl revoke *'
    echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/backplanectl list, /usr/local/bin/backplanectl show *, /usr/local/bin/backplanectl server-status'
    echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peer-volumectl list-hosted, /usr/local/bin/peer-volumectl list-hosted *, /usr/local/bin/peer-volumectl show-hosted *, /usr/local/bin/peer-volumectl delete-hosted *'
    case $PROFILE in
      virtualization)
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/replicationctl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/netctl bridge-create *, /usr/local/bin/netctl bridge-update *, /usr/local/bin/netctl bridge-delete *, /usr/local/bin/netctl vm-tap-up *, /usr/local/bin/netctl vm-tap-down *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/consolectl start *, /usr/local/bin/consolectl info *, /usr/local/bin/consolectl touch *, /usr/local/bin/consolectl stop *, /usr/local/bin/consolectl gc'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/hostexecctl start, /usr/local/bin/hostexecctl stop'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/filectl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/storagectl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmctl delete *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/overlayctl list, /usr/local/bin/overlayctl show *, /usr/local/bin/overlayctl peer-list *, /usr/local/bin/overlayctl health *, /usr/local/bin/overlayctl stage *, /usr/local/bin/overlayctl validate *, /usr/local/bin/overlayctl activate *, /usr/local/bin/overlayctl create *, /usr/local/bin/overlayctl delete *, /usr/local/bin/overlayctl reset'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl node-id, /usr/local/bin/peerctl peer-id-for-user *, /usr/local/bin/peerctl overlay-credentials *, /usr/local/bin/peerctl overlay-profile *, /usr/local/bin/peerctl transport-profile *, /usr/local/bin/peerctl migrate *'
        ;;
      docker)
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl list, /usr/local/bin/vmbackupctl list *, /usr/local/bin/vmbackupctl download *, /usr/local/bin/vmbackupctl delete *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/replicationctl replica-purge *, /usr/local/bin/replicationctl replica-show *, /usr/local/bin/replicationctl replica-list'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/dockerexecctl start *, /usr/local/bin/dockerexecctl info *, /usr/local/bin/dockerexecctl touch *, /usr/local/bin/dockerexecctl stop *, /usr/local/bin/dockerexecctl gc'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/registryctl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl transport-profile *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peer-volumectl attach *, /usr/local/bin/peer-volumectl detach *, /usr/local/bin/peer-volumectl mount-show *, /usr/local/bin/peer-volumectl mount-list'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/hostexecctl start, /usr/local/bin/hostexecctl stop'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/filectl *'
        ;;
      virtualization-docker)
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/replicationctl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/netctl bridge-create *, /usr/local/bin/netctl bridge-update *, /usr/local/bin/netctl bridge-delete *, /usr/local/bin/netctl vm-tap-up *, /usr/local/bin/netctl vm-tap-down *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/consolectl start *, /usr/local/bin/consolectl info *, /usr/local/bin/consolectl touch *, /usr/local/bin/consolectl stop *, /usr/local/bin/consolectl gc'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/dockerexecctl start *, /usr/local/bin/dockerexecctl info *, /usr/local/bin/dockerexecctl touch *, /usr/local/bin/dockerexecctl stop *, /usr/local/bin/dockerexecctl gc'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/registryctl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peer-volumectl attach *, /usr/local/bin/peer-volumectl detach *, /usr/local/bin/peer-volumectl mount-show *, /usr/local/bin/peer-volumectl mount-list'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/hostexecctl start, /usr/local/bin/hostexecctl stop'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/filectl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/storagectl *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmctl delete *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/overlayctl list, /usr/local/bin/overlayctl show *, /usr/local/bin/overlayctl peer-list *, /usr/local/bin/overlayctl health *, /usr/local/bin/overlayctl stage *, /usr/local/bin/overlayctl validate *, /usr/local/bin/overlayctl activate *, /usr/local/bin/overlayctl create *, /usr/local/bin/overlayctl delete *, /usr/local/bin/overlayctl reset'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl node-id, /usr/local/bin/peerctl peer-id-for-user *, /usr/local/bin/peerctl overlay-credentials *, /usr/local/bin/peerctl overlay-profile *, /usr/local/bin/peerctl transport-profile *, /usr/local/bin/peerctl migrate *'
        ;;
      backup)
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl list, /usr/local/bin/vmbackupctl list *, /usr/local/bin/vmbackupctl download *, /usr/local/bin/vmbackupctl delete *'
        echo 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/replicationctl replica-purge *, /usr/local/bin/replicationctl replica-show *, /usr/local/bin/replicationctl replica-list'
        ;;
    esac
  } > /etc/sudoers.d/vmapi
  chmod 0440 /etc/sudoers.d/vmapi
}

configure_alpine() {
  local novnc_root=/usr/share/vmapi/empty p hash
  install -d -m 0755 "$novnc_root"
  install -m 0755 "$BASE/openrc/fcgiwrap-vmapi" /etc/init.d/fcgiwrap-vmapi
  install -m 0755 "$BASE/openrc/vmapi-autostart" /etc/init.d/vmapi-autostart
  install -m 0755 "$BASE/openrc/vmapi-console-gc" /etc/init.d/vmapi-console-gc
  install -m 0755 "$BASE/openrc/websockify-vmapi" /etc/init.d/websockify-vmapi
  install -m 0755 "$BASE/openrc/ttyd-vmapi" /etc/init.d/ttyd-vmapi
  install -m 0755 "$BASE/openrc/ttyd-host-vmapi" /etc/init.d/ttyd-host-vmapi
  install -m 0755 "$BASE/openrc/vmapi-overlay" /etc/init.d/vmapi-overlay
  install -m 0755 "$BASE/openrc/vmapi-network" /etc/init.d/vmapi-network
  install -m 0755 "$BASE/openrc/vmapi-replication" /etc/init.d/vmapi-replication
  install -m 0755 "$BASE/openrc/vmapi-backplane" /etc/init.d/vmapi-backplane
  install -m 0755 "$BASE/openrc/vmapi-backplane-server" /etc/init.d/vmapi-backplane-server
  sed -i 's/\r$//' /etc/init.d/fcgiwrap-vmapi /etc/init.d/vmapi-autostart /etc/init.d/vmapi-console-gc /etc/init.d/websockify-vmapi /etc/init.d/ttyd-vmapi /etc/init.d/ttyd-host-vmapi /etc/init.d/vmapi-overlay /etc/init.d/vmapi-network /etc/init.d/vmapi-replication /etc/init.d/vmapi-backplane /etc/init.d/vmapi-backplane-server
  install -d -m 0755 /etc/lighttpd/conf.d /run/vmapi/consoles /run/vmapi/docker-exec
  chown vmapi:vmapi /run/vmapi /run/vmapi/consoles /run/vmapi/docker-exec
  : > /run/vmapi/console.tokens; chmod 0640 /run/vmapi/console.tokens; chown vmapi:vmapi /run/vmapi/console.tokens
  if [[ -n ${VMAPI_HTTP_USER:-} || -n ${VMAPI_HTTP_PASSWORD:-} ]]; then
    [[ -n ${VMAPI_HTTP_USER:-} && -n ${VMAPI_HTTP_PASSWORD:-} ]] || die 'Set both VMAPI_HTTP_USER and VMAPI_HTTP_PASSWORD together'
    hash=$(openssl passwd -apr1 "$VMAPI_HTTP_PASSWORD"); printf '%s:%s\n' "$VMAPI_HTTP_USER" "$hash" > /etc/lighttpd/vmapi.htpasswd
  elif [[ ! -s /etc/lighttpd/vmapi.htpasswd ]]; then
    [[ -n $ADMIN_USER ]] || die 'No web administrator is known. Re-run from sudo or set VMAPI_ADMIN_USER.'
    [[ -t 0 ]] || die 'Set VMAPI_HTTP_USER and VMAPI_HTTP_PASSWORD for a noninteractive first install.'
    read -r -s -p "HTTP Basic password for $ADMIN_USER: " password; echo
    [[ -n $password ]] || die 'An HTTP Basic password is required'
    hash=$(openssl passwd -apr1 "$password"); printf '%s:%s\n' "$ADMIN_USER" "$hash" > /etc/lighttpd/vmapi.htpasswd; unset password
  fi
  chmod 0640 /etc/lighttpd/vmapi.htpasswd; chown root:lighttpd /etc/lighttpd/vmapi.htpasswd
  if [[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]]; then
    novnc_root=''
    for p in /usr/share/novnc /usr/share/webapps/novnc /usr/share/noVNC; do [[ -d $p ]] && { novnc_root=$p; break; }; done
    [[ -n $novnc_root ]] || die 'noVNC web root not found'
  fi
  sed "s|@NOVNC_ROOT@|$novnc_root|g" "$BASE/lighttpd/vmapi.conf" > /etc/lighttpd/conf.d/vmapi.conf
  sed -i -E 's|^[#[:space:]]*server\.document-root[[:space:]]*=.*|server.document-root = "/usr/share/vmapi/www"|' /etc/lighttpd/lighttpd.conf
  sed -i -E "s|^[#[:space:]]*server\\.port[[:space:]]*=.*|server.port = $HTTP_PORT|" /etc/lighttpd/lighttpd.conf
  grep -Eq '^[[:space:]]*include_shell[[:space:]]+"cat /etc/lighttpd/conf.d/\*\.conf"' /etc/lighttpd/lighttpd.conf || printf '\ninclude_shell "cat /etc/lighttpd/conf.d/*.conf"\n' >> /etc/lighttpd/lighttpd.conf
  for svc in vmapi-network vmapi-autostart websockify-vmapi ttyd-vmapi ttyd-host-vmapi vmapi-console-gc vmapi-overlay vmapi-replication vmapi-backplane vmapi-backplane-server; do rc-update del "$svc" default >/dev/null 2>&1 || true; done
  for svc in websockify-vmapi ttyd-vmapi ttyd-host-vmapi vmapi-overlay vmapi-replication vmapi-backplane vmapi-backplane-server; do rc-service "$svc" stop >/dev/null 2>&1 || true; done
  for svc in fcgiwrap-vmapi lighttpd; do rc-update add "$svc" default >/dev/null 2>&1 || true; done
  rc-service fcgiwrap-vmapi restart
  case $PROFILE in
    virtualization)
      for svc in vmapi-backplane-server vmapi-backplane vmapi-network vmapi-autostart websockify-vmapi ttyd-host-vmapi vmapi-console-gc vmapi-overlay vmapi-replication; do rc-update add "$svc" default >/dev/null 2>&1 || true; done
      rc-service vmapi-backplane-server restart; rc-service vmapi-backplane restart; rc-service websockify-vmapi restart; rc-service ttyd-host-vmapi restart; rc-service vmapi-console-gc restart;;
    docker)
      rc-update add vmapi-backplane-server default >/dev/null 2>&1 || true
      rc-service vmapi-backplane-server start || true
      rc-update add vmapi-backplane default >/dev/null 2>&1 || true
      rc-service vmapi-backplane start || true
      rc-update add docker default >/dev/null 2>&1 || true; rc-service docker start || true
      for svc in ttyd-vmapi ttyd-host-vmapi; do rc-update add "$svc" default >/dev/null 2>&1 || true; done
      rc-service ttyd-vmapi restart; rc-service ttyd-host-vmapi restart;;
    virtualization-docker)
      rc-update add vmapi-backplane-server default >/dev/null 2>&1 || true
      rc-service vmapi-backplane-server start || true
      rc-update add vmapi-backplane default >/dev/null 2>&1 || true
      rc-service vmapi-backplane start || true
      rc-update add docker default >/dev/null 2>&1 || true; rc-service docker start || true
      for svc in vmapi-network vmapi-autostart websockify-vmapi ttyd-vmapi ttyd-host-vmapi vmapi-console-gc vmapi-overlay vmapi-replication vmapi-backplane vmapi-backplane-server; do rc-update add "$svc" default >/dev/null 2>&1 || true; done
      rc-service websockify-vmapi restart; rc-service ttyd-vmapi restart; rc-service ttyd-host-vmapi restart; rc-service vmapi-console-gc restart;;
    backup) rc-update add vmapi-backplane-server default >/dev/null 2>&1 || true; rc-service vmapi-backplane-server restart || true;;
  esac
}

configure_debian() {
  install -m 0644 "$BASE/systemd/fcgiwrap-vmapi.socket" /etc/systemd/system/fcgiwrap-vmapi.socket
  install -m 0644 "$BASE/systemd/fcgiwrap-vmapi.service" /etc/systemd/system/fcgiwrap-vmapi.service
  case $PROFILE in virtualization) sed -i 's/^SupplementaryGroups=.*/SupplementaryGroups=kvm/' /etc/systemd/system/fcgiwrap-vmapi.service;; docker) sed -i 's/^SupplementaryGroups=.*/SupplementaryGroups=docker/' /etc/systemd/system/fcgiwrap-vmapi.service;; virtualization-docker) sed -i 's/^SupplementaryGroups=.*/SupplementaryGroups=kvm docker/' /etc/systemd/system/fcgiwrap-vmapi.service;; backup) sed -i 's/^SupplementaryGroups=.*/SupplementaryGroups=/' /etc/systemd/system/fcgiwrap-vmapi.service;; esac
  install -m 0644 "$BASE/systemd/vmapi-autostart.service" /etc/systemd/system/vmapi-autostart.service
  install -m 0644 "$BASE/systemd/vmapi-overlay.service" /etc/systemd/system/vmapi-overlay.service
  install -m 0644 "$BASE/systemd/vmapi-network.service" /etc/systemd/system/vmapi-network.service
  install -m 0644 "$BASE/systemd/vmapi-replication.service" /etc/systemd/system/vmapi-replication.service
  install -m 0644 "$BASE/systemd/vmapi-backplane.service" /etc/systemd/system/vmapi-backplane.service
  install -m 0644 "$BASE/systemd/vmapi-backplane-server.service" /etc/systemd/system/vmapi-backplane-server.service
  install -m 0644 "$BASE/systemd/ttyd-vmapi.service" /etc/systemd/system/ttyd-vmapi.service
  install -m 0644 "$BASE/systemd/ttyd-host-vmapi.service" /etc/systemd/system/ttyd-host-vmapi.service
  install -m 0644 "$BASE/pam/nginx-vmapi" /etc/pam.d/nginx-vmapi
  install -d -o vmapi -g vmapi -m 0755 /run/vmapi /run/vmapi/docker-exec
  install -d -o root -g root -m 0700 /run/vmapi/host-exec
  install -d -m 0755 /etc/nginx/sites-available /etc/nginx/sites-enabled
  : > /etc/nginx/vmapi-registry.conf
  sed "s/listen 127\.0\.0\.1:5186;/listen 127.0.0.1:$HTTP_PORT;/" "$BASE/nginx/vmapi.conf" > /etc/nginx/sites-available/vmapi
  ln -sfn /etc/nginx/sites-available/vmapi /etc/nginx/sites-enabled/vmapi
  systemctl daemon-reload
  systemctl disable --now ttyd-vmapi.service ttyd-host-vmapi.service vmapi-overlay.service vmapi-replication.service vmapi-backplane.service vmapi-backplane-server.service >/dev/null 2>&1 || true
  systemctl disable vmapi-network.service vmapi-autostart.service vmapi-replication.service >/dev/null 2>&1 || true
  systemctl enable --now fcgiwrap-vmapi.socket
  systemctl try-restart fcgiwrap-vmapi.service >/dev/null 2>&1 || true
  case $PROFILE in
    virtualization) systemctl enable --now vmapi-backplane-server.service vmapi-backplane.service; systemctl enable --now vmapi-network.service; systemctl enable vmapi-autostart.service vmapi-replication.service; systemctl enable --now ttyd-host-vmapi.service;;
    docker) systemctl enable --now vmapi-backplane-server.service vmapi-backplane.service; systemctl enable --now docker.service; systemctl enable --now ttyd-vmapi.service ttyd-host-vmapi.service;;
    virtualization-docker) systemctl enable --now vmapi-backplane-server.service vmapi-backplane.service; systemctl enable --now docker.service; systemctl enable --now vmapi-network.service; systemctl enable vmapi-autostart.service vmapi-replication.service; systemctl enable --now ttyd-vmapi.service ttyd-host-vmapi.service;;
    backup) systemctl enable --now vmapi-backplane-server.service;;
  esac
  nginx -t && systemctl reload nginx
}

verify_active_profile_config() {
  local installed_profile
  installed_profile=$(awk -F= '$1=="VMAPI_PROFILE"{print $2}' /etc/vmapi/vmapi.conf | tail -n1)
  [[ $installed_profile == "$PROFILE" ]] ||
    die "Profile activation failed: requested $PROFILE but /etc/vmapi/vmapi.conf contains ${installed_profile:-none}"
}

verify_profile_install() {
  local installed_profile
  installed_profile=$(awk -F= '$1=="VMAPI_PROFILE"{print $2}' /etc/vmapi/vmapi.conf | tail -n1)
  [[ $installed_profile == "$PROFILE" ]] || die "Profile verification failed: requested $PROFILE but /etc/vmapi/vmapi.conf contains ${installed_profile:-none}"

  case "$PROFILE" in
    virtualization)
      command -v qemu-system-x86_64 >/dev/null 2>&1 || die 'VM profile verification failed: qemu-system-x86_64 is not installed'
      ;;
    docker)
      command -v docker >/dev/null 2>&1 || die 'Docker profile verification failed: docker is not installed'
      docker info >/dev/null 2>&1 || die 'Docker profile verification failed: Docker daemon is not running'
      ;;
    virtualization-docker)
      command -v qemu-system-x86_64 >/dev/null 2>&1 || die 'VM + Docker profile verification failed: qemu-system-x86_64 is not installed'
      command -v docker >/dev/null 2>&1 || die 'VM + Docker profile verification failed: docker is not installed'
      docker info >/dev/null 2>&1 || die 'VM + Docker profile verification failed: Docker daemon is not running'
      ;;
    backup) ;;
  esac

  [[ $(awk -F= '$1=="VMAPI_BACKPLANE_SERVER"{print $2}' /etc/vmapi/vmapi.conf | tail -n1) == true ]] ||
    die 'Backup-storage verification failed: VMAPI_BACKPLANE_SERVER is not enabled'
}

finalize() {
  /usr/local/bin/peerctl sync-auth
  if [[ $PROFILE == docker || $PROFILE == virtualization-docker ]]; then
    /usr/local/bin/registryctl render-web || true
  else
    /usr/local/bin/registryctl disable >/dev/null 2>&1 || true
  fi
  if [[ $PROFILE == docker ]]; then
    /usr/local/bin/replicationctl suspend >/dev/null 2>&1 || true
  fi
  if [[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]]; then
    /usr/local/bin/overlayctl migrate-config
    case $PLATFORM in
      alpine) /usr/local/bin/overlayctl render; rc-service vmapi-overlay restart;;
      debian) systemctl enable --now vmapi-overlay.service;;
    esac
  fi
  case $PLATFORM in
    alpine)
      lighttpd -tt -f /etc/lighttpd/lighttpd.conf; rc-service lighttpd restart
      [[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]] && rc-service vmapi-replication restart || true;;
    debian)
      nginx -t >/dev/null; systemctl reload nginx
      [[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]] && systemctl restart vmapi-replication.service || true;;
  esac
}

report_nested_hyperv_requirement() {
  local driver
  for driver in /sys/class/net/*/device/driver; do
    [[ -e $driver ]] || continue
    [[ $(readlink -f "$driver") == */hv_netvsc ]] || continue
    cat <<'MESSAGE'
Nested Hyper-V uplink detected. A bridged LiteVMM guest needs MAC address
spoofing enabled on this VM's adapter at the parent Hyper-V host:
  Set-VMNetworkAdapter -VMName <LiteVMM-VM> -MacAddressSpoofing On
This parent-host setting survives Alpine guest reinstallation.
MESSAGE
    return
  done
}

parse_args "$@"
choose_profile
detect_platform
ensure_admin_user
install_packages
activate_requested_profile
verify_active_profile_config
disable_native_nfs
getent group vmapi-admin >/dev/null || groupadd --system vmapi-admin
getent group vmapi >/dev/null || groupadd --system vmapi
case $PROFILE in virtualization) getent group kvm >/dev/null || groupadd --system kvm;; docker) getent group docker >/dev/null || groupadd --system docker;; virtualization-docker) getent group kvm >/dev/null || groupadd --system kvm; getent group docker >/dev/null || groupadd --system docker;; esac
id vmapi >/dev/null 2>&1 || useradd --system --gid vmapi --home-dir /var/lib/vmapi --create-home --shell "$( [[ $PLATFORM == alpine ]] && echo /sbin/nologin || echo /usr/sbin/nologin )" vmapi
for stale_group in kvm qemu docker; do getent group "$stale_group" >/dev/null 2>&1 && gpasswd -d vmapi "$stale_group" >/dev/null 2>&1 || true; done
case $PROFILE in
  virtualization) usermod -aG kvm vmapi; getent group qemu >/dev/null && usermod -aG qemu vmapi;;
  docker) usermod -aG docker vmapi;;
  virtualization-docker) usermod -aG kvm,docker vmapi; getent group qemu >/dev/null && usermod -aG qemu vmapi;;
esac
[[ -z $ADMIN_USER ]] || usermod -aG vmapi-admin "$ADMIN_USER"
if [[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]]; then ensure_tun; fi
if [[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]]; then install_gost; fi
if [[ $PLATFORM == debian && ( $PROFILE == virtualization || $PROFILE == docker || $PROFILE == virtualization-docker ) ]]; then install_websocat; fi
install_common_files
write_sudoers
case $PLATFORM in alpine) configure_alpine;; debian) configure_debian;; esac
finalize
verify_profile_install
if [[ $(awk -F= '$1=="VMAPI_TLS_ENABLED"{print $2}' /etc/vmapi/vmapi.conf | tail -n1) == true ]]; then /usr/local/bin/certctl apply; fi
[[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]] && report_nested_hyperv_requirement || true
scheme=http; [[ $(awk -F= '$1=="VMAPI_TLS_ENABLED"{print $2}' /etc/vmapi/vmapi.conf | tail -n1) == true ]] && scheme=https
echo "LiteVMM $PROFILE profile installed on $PLATFORM. Open $scheme://HOST:$HTTP_PORT/."
