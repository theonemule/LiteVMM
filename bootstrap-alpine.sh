#!/usr/bin/env bash
# Purpose: VMAPI installation or runtime maintenance script.
# Run on the target host with the documented privileges and arguments; it manages system-level VMAPI resources.
set -Eeuo pipefail

ADMIN_USER=''
BRIDGE=''
ENABLE_LIGHTTPD=true
while (($#)); do
  case "$1" in
    --admin) ADMIN_USER=${2:?}; shift 2;;
    --bridge) BRIDGE=${2:?}; shift 2;;
    --no-nginx|--no-lighttpd) ENABLE_LIGHTTPD=false; shift;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'Run bootstrap-alpine.sh as root' >&2; exit 1; }
BASE=$(cd "$(dirname "$0")" && pwd)

restart_lighttpd() {
  lock=/run/vmapi/lighttpd-restart.lock
  mkdir -p /run/vmapi
  while ! mkdir "$lock" 2>/dev/null; do sleep 0.2; done
  trap 'rmdir /run/vmapi/lighttpd-restart.lock 2>/dev/null || true' RETURN
  lighttpd -tt -f /etc/lighttpd/lighttpd.conf
  rc-service lighttpd stop >/dev/null 2>&1 || true
  rc-service lighttpd zap >/dev/null 2>&1 || true
  pkill -TERM lighttpd >/dev/null 2>&1 || true
  pids=$(pgrep lighttpd 2>/dev/null || true)
  [[ -z $pids ]] || kill $pids 2>/dev/null || true
  sleep 0.2
  pkill -KILL lighttpd >/dev/null 2>&1 || true
  pids=$(pgrep lighttpd 2>/dev/null || true)
  [[ -z $pids ]] || kill -KILL $pids 2>/dev/null || true
  sleep 0.2
  rc-service lighttpd start
  trap - RETURN
  rmdir "$lock" 2>/dev/null || true
}

ensure_tun() {
  modprobe tun 2>/dev/null || true
  install -d -m 0755 /dev/net
  [[ -c /dev/net/tun ]] || mknod /dev/net/tun c 10 200
  chmod 0666 /dev/net/tun
  grep -Fxq tun /etc/modules 2>/dev/null || echo tun >> /etc/modules
}

if ! grep -Eq '^[^#].*/v[0-9.]+/community' /etc/apk/repositories; then
  sed -i -E 's|^#(.*://.*/v[0-9.]+/community)$|\1|' /etc/apk/repositories
fi
apk update
apk add --no-cache \
  bash coreutils findutils gawk grep sed shadow util-linux \
  iproute2 iputils iptables nftables socat curl openssl sudo kmod gost tcpdump \
  qemu-img qemu-system-x86_64 ovmf \
  docker docker-openrc docker-cli-compose \
  fcgiwrap spawn-fcgi \
  novnc websockify ttyd zip

getent group kvm >/dev/null || groupadd --system kvm
getent group vmapi-admin >/dev/null || groupadd --system vmapi-admin
getent group docker >/dev/null || groupadd --system docker
id vmapi >/dev/null 2>&1 || useradd --system --home-dir /var/lib/vmapi --create-home --shell /sbin/nologin --groups kvm vmapi
usermod -aG kvm,docker vmapi
getent group qemu >/dev/null && usermod -aG qemu vmapi
ensure_tun
if [[ -n $ADMIN_USER ]]; then
  id "$ADMIN_USER" >/dev/null 2>&1 || { echo "Admin user does not exist: $ADMIN_USER" >&2; exit 1; }
  usermod -aG vmapi-admin "$ADMIN_USER"
fi

install -d -m 0755 /etc/vmapi /usr/local/lib/vmapi /usr/local/bin /usr/lib/vmapi/cgi
install -d -o root -g vmapi -m 0750 /etc/vmapi/overlays
install -d -o vmapi -g vmapi -m 0750 /var/lib/vmapi /var/lib/vmapi/vms /var/lib/vmapi/disks /var/lib/vmapi/isos /var/lib/vmapi/backup-jobs
install -d -o vmapi -g vmapi -m 0750 /var/log/vmapi/backups
install -d -m 0700 /var/lib/vmapi/peers
install -m 0644 "$BASE/etc/vmapi.conf" /etc/vmapi/vmapi.conf
install -m 0644 "$BASE/lib/common.sh" /usr/local/lib/vmapi/common.sh
for tool in vmctl imagectl netctl dockerctl dockerexecctl hostexecctl logctl docker-imagectl docker-netctl docker-volumectl dockercompoectl metricsctl consolectl peerctl vmbackupctl filectl storagectl overlayctl vmapi-console-gc vmapi-autostart vmapi-stopall; do
  install -m 0755 "$BASE/bin/$tool" "/usr/local/bin/$tool"
done
install -m 0755 "$BASE/tests/api-regression-curl.sh" /usr/local/bin/vmapi-api-regression
install -m 0755 "$BASE/tests/overlay-pair-curl.sh" /usr/local/bin/vmapi-overlay-pair-test
install -m 0755 "$BASE/tests/backup-pair-curl.sh" /usr/local/bin/vmapi-backup-pair-test
install -m 0755 "$BASE/cgi/api.cgi" /usr/lib/vmapi/cgi/api.cgi
install -m 0755 "$BASE/cgi/peer-api.cgi" /usr/lib/vmapi/cgi/peer-api.cgi
install -d -m 0750 /etc/sudoers.d
cat > /etc/sudoers.d/vmapi-netctl <<'SUDOERS'
vmapi ALL=(root) NOPASSWD: /usr/local/bin/netctl bridge-create *, /usr/local/bin/netctl bridge-update *, /usr/local/bin/netctl bridge-delete *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/consolectl start *, /usr/local/bin/consolectl info *, /usr/local/bin/consolectl touch *, /usr/local/bin/consolectl stop *, /usr/local/bin/consolectl gc
vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl identity, /usr/local/bin/peerctl request, /usr/local/bin/peerctl request *, /usr/local/bin/peerctl pending, /usr/local/bin/peerctl cancel-pending, /usr/local/bin/peerctl accept *, /usr/local/bin/peerctl complete *, /usr/local/bin/peerctl list, /usr/local/bin/peerctl set-url *, /usr/local/bin/peerctl overlay-credentials *, /usr/local/bin/peerctl overlay-profile *, /usr/local/bin/peerctl authorize-user *, /usr/local/bin/peerctl cors-origin *, /usr/local/bin/peerctl proxy *, /usr/local/bin/peerctl migrate *, /usr/local/bin/peerctl revoke *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl list *, /usr/local/bin/vmbackupctl create *, /usr/local/bin/vmbackupctl start *, /usr/local/bin/vmbackupctl job *, /usr/local/bin/vmbackupctl download *, /usr/local/bin/vmbackupctl delete *, /usr/local/bin/vmbackupctl schedule *, /usr/local/bin/vmbackupctl unschedule *, /usr/local/bin/vmbackupctl schedules
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl receive *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/filectl list *, /usr/local/bin/filectl upload *, /usr/local/bin/filectl download *, /usr/local/bin/filectl mkdir *, /usr/local/bin/filectl move *, /usr/local/bin/filectl delete *, /usr/local/bin/filectl archive *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/storagectl status, /usr/local/bin/storagectl relocate *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/dockerexecctl start *, /usr/local/bin/dockerexecctl info *, /usr/local/bin/dockerexecctl touch *, /usr/local/bin/dockerexecctl stop *, /usr/local/bin/dockerexecctl gc
vmapi ALL=(root) NOPASSWD: /usr/local/bin/hostexecctl start, /usr/local/bin/hostexecctl stop
vmapi ALL=(root) NOPASSWD: /usr/local/bin/logctl *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmctl delete *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/overlayctl list, /usr/local/bin/overlayctl show *, /usr/local/bin/overlayctl health *, /usr/local/bin/overlayctl stage *, /usr/local/bin/overlayctl validate *, /usr/local/bin/overlayctl activate *, /usr/local/bin/overlayctl create *, /usr/local/bin/overlayctl delete *, /usr/local/bin/overlayctl reset
SUDOERS
chmod 0440 /etc/sudoers.d/vmapi-netctl

install -d -m 0755 /usr/share/vmapi/www /usr/share/vmapi/www/vendor/bootstrap
install -m 0644 "$BASE/www/index.html" /usr/share/vmapi/www/index.html
install -m 0644 "$BASE/www/app.css" /usr/share/vmapi/www/app.css
install -m 0644 "$BASE/www/app.js" /usr/share/vmapi/www/app.js
install -m 0644 "$BASE/www/console.html" /usr/share/vmapi/www/console.html
install -m 0644 "$BASE/www/console.js" /usr/share/vmapi/www/console.js
install -m 0644 "$BASE/www/files.html" /usr/share/vmapi/www/files.html
install -m 0644 "$BASE/www/files.js" /usr/share/vmapi/www/files.js
install -m 0644 "$BASE/www/vendor/bootstrap/bootstrap.min.css" /usr/share/vmapi/www/vendor/bootstrap/bootstrap.min.css
install -m 0644 "$BASE/www/vendor/bootstrap/bootstrap.bundle.min.js" /usr/share/vmapi/www/vendor/bootstrap/bootstrap.bundle.min.js

for spec in \
  'vm-list list' 'vm-show show' 'vm-status status' 'vm-create create' 'vm-set set' \
  'vm-start start' 'vm-stop stop' 'vm-reboot reboot' 'vm-delete delete' \
  'vm-disk-add disk-add' 'vm-disk-remove disk-remove' 'vm-disk-resize disk-resize' 'vm-disk-set disk-set' 'vm-nic-add nic-add' 'vm-nic-remove nic-remove' 'vm-nic-set nic-set' \
  'vm-pci-add pci-add' 'vm-pci-remove pci-remove' 'vm-console-info console-info' 'vm-command command'; do
  set -- $spec; wrapper=$1; sub=$2
  cat > "/usr/local/bin/$wrapper" <<WRAP
#!/usr/bin/env bash
exec /usr/local/bin/vmctl $sub "\$@"
WRAP
  chmod 0755 "/usr/local/bin/$wrapper"
done

cat > /usr/local/bin/metrics-host <<'WRAP'
#!/usr/bin/env bash
exec /usr/local/bin/metricsctl host "$@"
WRAP
cat > /usr/local/bin/vm-metrics <<'WRAP'
#!/usr/bin/env bash
exec /usr/local/bin/metricsctl vm "$@"
WRAP
cat > /usr/local/bin/docker-metrics <<'WRAP'
#!/usr/bin/env bash
exec /usr/local/bin/metricsctl container "$@"
WRAP
chmod 0755 /usr/local/bin/metrics-host /usr/local/bin/vm-metrics /usr/local/bin/docker-metrics

for spec in \
  'docker-list list' 'docker-show show' 'docker-status status' 'docker-create create' 'docker-update update' \
  'docker-start start' 'docker-stop stop' 'docker-restart restart' 'docker-delete delete'; do
  set -- $spec; wrapper=$1; sub=$2
  cat > "/usr/local/bin/$wrapper" <<WRAP
#!/usr/bin/env bash
exec /usr/local/bin/dockerctl $sub "\$@"
WRAP
  chmod 0755 "/usr/local/bin/$wrapper"
done

install -m 0755 "$BASE/openrc/fcgiwrap-vmapi" /etc/init.d/fcgiwrap-vmapi
install -m 0755 "$BASE/openrc/vmapi-autostart" /etc/init.d/vmapi-autostart
install -m 0755 "$BASE/openrc/vmapi-console-gc" /etc/init.d/vmapi-console-gc
install -m 0755 "$BASE/openrc/websockify-vmapi" /etc/init.d/websockify-vmapi
  install -m 0755 "$BASE/openrc/ttyd-vmapi" /etc/init.d/ttyd-vmapi
  install -m 0755 "$BASE/openrc/ttyd-host-vmapi" /etc/init.d/ttyd-host-vmapi
install -m 0755 "$BASE/openrc/vmapi-overlay" /etc/init.d/vmapi-overlay
  sed -i 's/\r$//' /etc/init.d/fcgiwrap-vmapi /etc/init.d/vmapi-autostart /etc/init.d/vmapi-console-gc /etc/init.d/websockify-vmapi /etc/init.d/ttyd-vmapi /etc/init.d/ttyd-host-vmapi /etc/init.d/vmapi-overlay

if [[ -n $BRIDGE ]]; then
  [[ $BRIDGE =~ ^[A-Za-z0-9_.:-]{1,31}$ ]] || { echo 'Invalid bridge name' >&2; exit 1; }
  install -d -m 0755 /etc/qemu
  touch /etc/qemu/bridge.conf
  grep -Fxq "allow $BRIDGE" /etc/qemu/bridge.conf || echo "allow $BRIDGE" >> /etc/qemu/bridge.conf
  getent group qemu >/dev/null && chown root:qemu /etc/qemu/bridge.conf
  chmod 0640 /etc/qemu/bridge.conf
fi

if $ENABLE_LIGHTTPD; then
  apk add --no-cache lighttpd lighttpd-openrc lighttpd-mod_auth apache2-utils
  /usr/local/bin/peerctl sync-auth
  install -d -m 0755 /etc/lighttpd/conf.d
  if [[ -n ${VMAPI_HTTP_USER:-} && -n ${VMAPI_HTTP_PASSWORD:-} ]]; then
    hash=$(openssl passwd -apr1 "$VMAPI_HTTP_PASSWORD")
    printf '%s:%s\n' "$VMAPI_HTTP_USER" "$hash" > /etc/lighttpd/vmapi.htpasswd
    chmod 0640 /etc/lighttpd/vmapi.htpasswd
    chown root:lighttpd /etc/lighttpd/vmapi.htpasswd
  fi
  [[ -s /etc/lighttpd/vmapi.htpasswd ]] || { echo 'Set VMAPI_HTTP_USER and VMAPI_HTTP_PASSWORD, or create /etc/lighttpd/vmapi.htpasswd before enabling lighttpd' >&2; exit 1; }
  install -m 0644 "$BASE/lighttpd/vmapi.conf" /etc/lighttpd/conf.d/vmapi.conf
  install -d -m 0755 /run/vmapi/consoles
  chown vmapi:vmapi /run/vmapi /run/vmapi/consoles
  rm -f /etc/lighttpd/conf.d/vmapi-consoles.conf
  rm -f /etc/lighttpd/conf.d/zz-vmapi-consoles.conf
  : > /run/vmapi/console.tokens
  chmod 0640 /run/vmapi/console.tokens
  chown vmapi:vmapi /run/vmapi/console.tokens
  install -d -m 0755 /run/vmapi/docker-exec
  chown vmapi:vmapi /run/vmapi/docker-exec
  novnc_root=''
  for p in /usr/share/novnc /usr/share/webapps/novnc /usr/share/noVNC; do [[ -d $p ]] && { novnc_root=$p; break; }; done
  [[ -n $novnc_root ]] || { echo 'noVNC web root not found' >&2; exit 1; }
  sed -i "s|@NOVNC_ROOT@|$novnc_root|g" /etc/lighttpd/conf.d/vmapi.conf
  sed -i -E 's|^[#[:space:]]*server\.document-root[[:space:]]*=.*|server.document-root = "/usr/share/vmapi/www"|' /etc/lighttpd/lighttpd.conf
  sed -i -E 's|^[#[:space:]]*server\.port[[:space:]]*=.*|server.port = 8080|' /etc/lighttpd/lighttpd.conf
  grep -Eq '^[[:space:]]*include_shell[[:space:]]+"cat /etc/lighttpd/conf.d/\*\.conf"' /etc/lighttpd/lighttpd.conf || \
    printf '\ninclude_shell "cat /etc/lighttpd/conf.d/*.conf"\n' >> /etc/lighttpd/lighttpd.conf
fi

rc-update add docker default >/dev/null 2>&1 || true
rc-service docker start || true
rc-update add sudo default >/dev/null 2>&1 || true
rc-service sudo start >/dev/null 2>&1 || true
rc-update add fcgiwrap-vmapi default
pids=$(pgrep fcgiwrap 2>/dev/null || true); [[ -z $pids ]] || kill -KILL $pids 2>/dev/null || true
rc-service fcgiwrap-vmapi restart
rc-update add vmapi-autostart default
rc-update add websockify-vmapi default
pids=$(pgrep websockify 2>/dev/null || true); [[ -z $pids ]] || kill -KILL $pids 2>/dev/null || true
rc-service websockify-vmapi restart
  rc-update add ttyd-vmapi default
  rc-service ttyd-vmapi restart
  rc-update add ttyd-host-vmapi default
  rc-service ttyd-host-vmapi restart
rc-update add vmapi-console-gc default
if $ENABLE_LIGHTTPD; then
  rc-service nginx stop >/dev/null 2>&1 || true
  rc-update del nginx default >/dev/null 2>&1 || true
  rc-update add lighttpd default >/dev/null 2>&1 || true
  restart_lighttpd
fi
rc-service vmapi-console-gc restart
/usr/local/bin/overlayctl migrate-config
/usr/local/bin/overlayctl render
rc-update add vmapi-overlay default
rc-service vmapi-overlay restart

echo 'VMAPI installed on Alpine.'
echo 'Docker API: enabled through the local Docker daemon'
echo 'Config root: /var/lib/vmapi/vms'
echo 'Disk root:   /var/lib/vmapi/disks'
echo 'ISO root:    /var/lib/vmapi/isos'
[[ -n $ADMIN_USER ]] && echo "API admin:   $ADMIN_USER"
[[ -n $BRIDGE ]] && echo "Allowed QEMU bridge: $BRIDGE"
echo 'Web console: http://0.0.0.0:8080/'
echo 'API root:    http://0.0.0.0:8080/api/'
