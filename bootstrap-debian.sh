#!/usr/bin/env bash
# Purpose: VMAPI installation or runtime maintenance script.
# Run on the target host with the documented privileges and arguments; it manages system-level VMAPI resources.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  qemu-system-x86 qemu-utils ovmf docker.io nginx fcgiwrap socat sudo iptables \
  iproute2 iputils-ping kmod gost curl openssl tcpdump libnginx-mod-http-auth-pam
exec "$(dirname "$0")/install.sh" "$@"
