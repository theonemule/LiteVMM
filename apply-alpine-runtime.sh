#!/usr/bin/env bash
# Purpose: VMAPI installation or runtime maintenance script.
# Run on the target host with the documented privileges and arguments; it manages system-level VMAPI resources.
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo 'Run apply-alpine-runtime.sh as root' >&2; exit 1; }
BASE=$(cd -- "$(dirname -- "$0")" && pwd -P)

for required in \
  lib/common.sh \
  cgi/api.cgi \
  cgi/peer-api.cgi \
  openrc/fcgiwrap-vmapi \
  openrc/vmapi-autostart \
  openrc/vmapi-console-gc \
  openrc/websockify-vmapi \
  openrc/ttyd-vmapi openrc/ttyd-host-vmapi openrc/vmapi-overlay \
  lighttpd/vmapi.conf; do
  [[ -f "$BASE/$required" ]] || { echo "Missing required runtime source: $required" >&2; exit 1; }
done

tools=(
    vmctl imagectl netctl dockerctl dockerexecctl hostexecctl logctl docker-imagectl docker-netctl
  docker-volumectl dockercompoectl metricsctl consolectl peerctl vmbackupctl filectl storagectl
  vmapi-console-gc vmapi-autostart vmapi-stopall overlayctl
)
for tool in "${tools[@]}"; do
  [[ -f "$BASE/bin/$tool" ]] || { echo "Missing required runtime source: bin/$tool" >&2; exit 1; }
done

[[ -d "$BASE/www" ]] || { echo 'Missing required runtime source: www' >&2; exit 1; }

update_lighttpd_config() {
  local config=/etc/lighttpd/conf.d/vmapi.conf
  local rendered backup novnc_root candidate had_config=false

  install -d -m 0755 /etc/lighttpd/conf.d
  # A pre-fix generated overlay config sorts before vmapi.conf and therefore
  # references mod_proxy before that module is loaded.  Remove only that
  # obsolete generated file; named overlay definitions remain untouched.
  rm -f -- /etc/lighttpd/conf.d/vmapi-overlay.conf
  novnc_root=$(sed -n -E 's|^[[:space:]]*"/novnc"[[:space:]]*=>[[:space:]]*"([^"]+)"[[:space:]]*,?[[:space:]]*$|\1|p' "$config" 2>/dev/null | head -n 1 || true)
  if [[ ! -d $novnc_root ]]; then
    novnc_root=''
    for candidate in /usr/share/novnc /usr/share/webapps/novnc /usr/share/noVNC; do
      [[ -d $candidate ]] && { novnc_root=$candidate; break; }
    done
  fi
  [[ -n $novnc_root ]] || { echo 'noVNC web root not found; cannot render Lighttpd VMAPI config' >&2; return 1; }

  rendered=$(mktemp /etc/lighttpd/conf.d/.vmapi.conf.XXXXXX)
  backup=$(mktemp /etc/lighttpd/conf.d/.vmapi.conf.backup.XXXXXX)
  trap 'rm -f "$rendered" "$backup"' RETURN
  sed "s|@NOVNC_ROOT@|$novnc_root|g" "$BASE/lighttpd/vmapi.conf" > "$rendered"
  [[ -s $rendered ]] || { echo 'Rendered Lighttpd VMAPI config is empty' >&2; return 1; }

  if [[ -e $config ]]; then
    cp -p -- "$config" "$backup"
    had_config=true
  fi
  mv -f -- "$rendered" "$config"

  if ! lighttpd -tt -f /etc/lighttpd/lighttpd.conf; then
    if $had_config; then
      mv -f -- "$backup" "$config"
      echo 'Lighttpd validation failed; restored the previous VMAPI config' >&2
    else
      rm -f -- "$config"
      echo 'Lighttpd validation failed; removed the new VMAPI config' >&2
    fi
    return 1
  fi
  rm -f -- "$backup"
  trap - RETURN
}

install -d -m 0755 /usr/local/lib/vmapi /usr/local/bin /usr/lib/vmapi/cgi /usr/share/vmapi/www /etc/init.d
command -v zip >/dev/null 2>&1 || apk add --no-cache zip
command -v tcpdump >/dev/null 2>&1 || apk add --no-cache tcpdump
install -m 0755 "$BASE/tests/api-regression-curl.sh" /usr/local/bin/vmapi-api-regression
install -m 0755 "$BASE/tests/overlay-pair-curl.sh" /usr/local/bin/vmapi-overlay-pair-test
install -m 0755 "$BASE/tests/backup-pair-curl.sh" /usr/local/bin/vmapi-backup-pair-test
install -d -m 0750 /etc/sudoers.d
printf '%s\n' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/consolectl start *, /usr/local/bin/consolectl info *, /usr/local/bin/consolectl touch *, /usr/local/bin/consolectl stop *, /usr/local/bin/consolectl gc' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/dockerexecctl start *, /usr/local/bin/dockerexecctl info *, /usr/local/bin/dockerexecctl touch *, /usr/local/bin/dockerexecctl stop *, /usr/local/bin/dockerexecctl gc' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl list, /usr/local/bin/vmbackupctl create *, /usr/local/bin/vmbackupctl start *, /usr/local/bin/vmbackupctl job *, /usr/local/bin/vmbackupctl receive *, /usr/local/bin/vmbackupctl download *, /usr/local/bin/vmbackupctl delete *, /usr/local/bin/vmbackupctl schedule *, /usr/local/bin/vmbackupctl unschedule *, /usr/local/bin/vmbackupctl schedules' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/filectl list *, /usr/local/bin/filectl upload *, /usr/local/bin/filectl download *, /usr/local/bin/filectl mkdir *, /usr/local/bin/filectl move *, /usr/local/bin/filectl delete *, /usr/local/bin/filectl archive *' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/storagectl status, /usr/local/bin/storagectl relocate *' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/hostexecctl start, /usr/local/bin/hostexecctl stop' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/logctl *' > /etc/sudoers.d/vmapi-hostexec
printf '%s\n' 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmctl delete *' > /etc/sudoers.d/vmapi-vmctl
chmod 0440 /etc/sudoers.d/vmapi-hostexec
chmod 0440 /etc/sudoers.d/vmapi-vmctl
printf '%s\n' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/netctl bridge-create *, /usr/local/bin/netctl bridge-update *, /usr/local/bin/netctl bridge-delete *' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/overlayctl list, /usr/local/bin/overlayctl show *, /usr/local/bin/overlayctl health *, /usr/local/bin/overlayctl stage *, /usr/local/bin/overlayctl validate *, /usr/local/bin/overlayctl activate *, /usr/local/bin/overlayctl create *, /usr/local/bin/overlayctl delete *, /usr/local/bin/overlayctl reset' \
  'vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl identity, /usr/local/bin/peerctl request, /usr/local/bin/peerctl request *, /usr/local/bin/peerctl pending, /usr/local/bin/peerctl cancel-pending, /usr/local/bin/peerctl accept *, /usr/local/bin/peerctl complete *, /usr/local/bin/peerctl list, /usr/local/bin/peerctl set-url *, /usr/local/bin/peerctl overlay-credentials *, /usr/local/bin/peerctl overlay-profile *, /usr/local/bin/peerctl authorize-user *, /usr/local/bin/peerctl cors-origin *, /usr/local/bin/peerctl proxy *, /usr/local/bin/peerctl migrate *, /usr/local/bin/peerctl revoke *' > /etc/sudoers.d/vmapi-netctl
chmod 0440 /etc/sudoers.d/vmapi-netctl
rc-service vmapi-overlay stop >/dev/null 2>&1 || true
install -m 0644 "$BASE/lib/common.sh" /usr/local/lib/vmapi/common.sh

for tool in "${tools[@]}"; do
  install -m 0755 "$BASE/bin/$tool" "/usr/local/bin/$tool"
done

install -m 0755 "$BASE/cgi/api.cgi" /usr/lib/vmapi/cgi/api.cgi
install -m 0755 "$BASE/cgi/peer-api.cgi" /usr/lib/vmapi/cgi/peer-api.cgi

while IFS= read -r -d '' asset; do
  relative=${asset#"$BASE/www/"}
  install -D -m 0644 "$asset" "/usr/share/vmapi/www/$relative"
done < <(find "$BASE/www" -type f -print0)

init_scripts=(
  fcgiwrap-vmapi vmapi-autostart vmapi-console-gc websockify-vmapi ttyd-vmapi ttyd-host-vmapi vmapi-overlay
)
for script in "${init_scripts[@]}"; do
  install -m 0755 "$BASE/openrc/$script" "/etc/init.d/$script"
done
sed -i 's/\r$//' /etc/init.d/fcgiwrap-vmapi /etc/init.d/vmapi-autostart \
  /etc/init.d/vmapi-console-gc /etc/init.d/websockify-vmapi /etc/init.d/ttyd-vmapi /etc/init.d/ttyd-host-vmapi /etc/init.d/vmapi-overlay

# Both the API worker and vmctl must traverse this complete path to resolve a
# named overlay while creating or editing a VM.  Keeping only `overlays/`
# group-accessible is insufficient when an existing `/etc/vmapi` is 0700.
install -d -o root -g vmapi -m 0750 /etc/vmapi /etc/vmapi/overlays
chown root:vmapi /etc/vmapi /etc/vmapi/overlays
chmod 0750 /etc/vmapi /etc/vmapi/overlays
rc-update add vmapi-overlay default >/dev/null 2>&1 || true

# Migrate the existing pairing credentials without exchanging new bundles.
/usr/local/bin/peerctl sync-auth
update_lighttpd_config
if ! /usr/local/bin/overlayctl migrate-config; then
  echo 'Overlay configuration migration failed. Reset obsolete routed overlays on each endpoint, then recreate the hub and spoke overlays.' >&2
  exit 1
fi
/usr/local/bin/overlayctl render
/usr/local/bin/overlayctl restart-service

echo 'VMAPI Alpine runtime files updated.'
