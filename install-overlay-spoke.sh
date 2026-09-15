#!/usr/bin/env bash
# Minimal Alpine spoke: pairing tools, GOST and an OpenRC supervisor.
set -Eeuo pipefail
[[ $EUID -eq 0 ]] || { echo 'Run as root' >&2; exit 1; }
BASE=$(cd "$(dirname "$0")" && pwd)
apk add --no-cache bash coreutils util-linux iproute2 iputils kmod curl openssl gost
install -d -m 0755 /usr/local/bin /usr/local/lib/vmapi /etc/init.d
install -d -m 0700 /var/lib/vmapi/peers /etc/vmapi/identity
install -d -m 0750 /etc/vmapi/overlays
install -m 0644 "$BASE/lib/common.sh" /usr/local/lib/vmapi/common.sh
for tool in peerctl overlayctl netctl; do
  install -m 0755 "$BASE/bin/$tool" "/usr/local/bin/$tool"
done
install -m 0755 "$BASE/openrc/vmapi-overlay" /etc/init.d/vmapi-overlay
modprobe tun
grep -qxF tun /etc/modules 2>/dev/null || echo tun >> /etc/modules
rc-update add vmapi-overlay default
echo 'Spoke installed. Pair with the hub using peerctl, then create a spoke overlay.'
