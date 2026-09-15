#!/usr/bin/env bash
# Purpose: VMAPI installation or runtime maintenance script.
# Run on the target host with the documented privileges and arguments; it manages system-level VMAPI resources.
set -Eeuo pipefail

ADMIN_USER=''
BRIDGE=''
ENABLE_NGINX=true
while (($#)); do
  case "$1" in
    --admin) ADMIN_USER=${2:?}; shift 2;;
    --bridge) BRIDGE=${2:?}; shift 2;;
    --no-nginx) ENABLE_NGINX=false; shift;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ $EUID -eq 0 ]] || { echo 'Run install.sh as root' >&2; exit 1; }
BASE=$(cd "$(dirname "$0")" && pwd)

getent group kvm >/dev/null || groupadd --system kvm
getent group vmapi-admin >/dev/null || groupadd --system vmapi-admin
getent group docker >/dev/null || groupadd --system docker
id vmapi >/dev/null 2>&1 || useradd --system --home /var/lib/vmapi --create-home --shell /usr/sbin/nologin --groups kvm vmapi
usermod -aG kvm,docker vmapi
if [[ -n $ADMIN_USER ]]; then
  id "$ADMIN_USER" >/dev/null 2>&1 || { echo "Admin user does not exist: $ADMIN_USER" >&2; exit 1; }
  usermod -aG vmapi-admin "$ADMIN_USER"
fi

install -d -m 0755 /etc/vmapi /usr/local/lib/vmapi /usr/local/bin /usr/lib/vmapi/cgi
install -d -o root -g vmapi -m 0750 /etc/vmapi/overlays
install -d -o vmapi -g vmapi -m 0750 /var/lib/vmapi /var/lib/vmapi/vms /var/lib/vmapi/disks /var/lib/vmapi/isos /var/lib/vmapi/backup-jobs
install -d -o vmapi -g vmapi -m 0750 /var/log/vmapi/backups
install -m 0644 "$BASE/etc/vmapi.conf" /etc/vmapi/vmapi.conf
install -m 0644 "$BASE/lib/common.sh" /usr/local/lib/vmapi/common.sh
install -m 0755 "$BASE/bin/vmctl" /usr/local/bin/vmctl
install -m 0755 "$BASE/bin/imagectl" /usr/local/bin/imagectl
install -m 0755 "$BASE/bin/netctl" /usr/local/bin/netctl
install -m 0755 "$BASE/bin/dockerctl" /usr/local/bin/dockerctl
install -m 0755 "$BASE/bin/dockercompoectl" /usr/local/bin/dockercompoectl
install -m 0755 "$BASE/bin/docker-imagectl" /usr/local/bin/docker-imagectl
install -m 0755 "$BASE/bin/docker-netctl" /usr/local/bin/docker-netctl
install -m 0755 "$BASE/bin/docker-volumectl" /usr/local/bin/docker-volumectl
install -m 0755 "$BASE/bin/metricsctl" /usr/local/bin/metricsctl
install -m 0755 "$BASE/bin/peerctl" /usr/local/bin/peerctl
install -m 0755 "$BASE/bin/vmbackupctl" /usr/local/bin/vmbackupctl
install -m 0755 "$BASE/bin/filectl" /usr/local/bin/filectl
install -m 0755 "$BASE/bin/storagectl" /usr/local/bin/storagectl
install -m 0755 "$BASE/bin/overlayctl" /usr/local/bin/overlayctl
install -m 0755 "$BASE/bin/vmapi-autostart" /usr/local/bin/vmapi-autostart
install -m 0755 "$BASE/bin/vmapi-stopall" /usr/local/bin/vmapi-stopall
install -m 0755 "$BASE/tests/api-regression-curl.sh" /usr/local/bin/vmapi-api-regression
install -m 0755 "$BASE/tests/overlay-pair-curl.sh" /usr/local/bin/vmapi-overlay-pair-test
install -m 0755 "$BASE/tests/backup-pair-curl.sh" /usr/local/bin/vmapi-backup-pair-test
install -m 0755 "$BASE/cgi/api.cgi" /usr/lib/vmapi/cgi/api.cgi

# Static Bootstrap single-page management console. No Node/build runtime is required.
install -d -m 0755 /usr/share/vmapi/www /usr/share/vmapi/www/vendor/bootstrap
install -m 0644 "$BASE/www/index.html" /usr/share/vmapi/www/index.html
install -m 0644 "$BASE/www/app.css" /usr/share/vmapi/www/app.css
install -m 0644 "$BASE/www/app.js" /usr/share/vmapi/www/app.js
install -m 0644 "$BASE/www/files.html" /usr/share/vmapi/www/files.html
install -m 0644 "$BASE/www/files.js" /usr/share/vmapi/www/files.js
install -m 0644 "$BASE/www/vendor/bootstrap/bootstrap.min.css" /usr/share/vmapi/www/vendor/bootstrap/bootstrap.min.css
install -m 0644 "$BASE/www/vendor/bootstrap/bootstrap.bundle.min.js" /usr/share/vmapi/www/vendor/bootstrap/bootstrap.bundle.min.js

# Convenience command wrappers: each is still a shell-level API over vmctl.
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

# Resource metric convenience wrappers. These emit JSON and keep no metric database.
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

# Docker convenience wrappers. Docker remains the state authority; these only wrap its CLI.
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

install -m 0644 "$BASE/systemd/fcgiwrap-vmapi.socket" /etc/systemd/system/fcgiwrap-vmapi.socket
install -m 0644 "$BASE/systemd/fcgiwrap-vmapi.service" /etc/systemd/system/fcgiwrap-vmapi.service
install -m 0644 "$BASE/systemd/vmapi-autostart.service" /etc/systemd/system/vmapi-autostart.service
install -m 0644 "$BASE/systemd/vmapi-overlay.service" /etc/systemd/system/vmapi-overlay.service

install -d -m 0750 /etc/sudoers.d
cat > /etc/sudoers.d/vmapi-overlay <<'SUDOERS'
vmapi ALL=(root) NOPASSWD: /usr/local/bin/consolectl start *, /usr/local/bin/consolectl info *, /usr/local/bin/consolectl touch *, /usr/local/bin/consolectl stop *, /usr/local/bin/consolectl gc
vmapi ALL=(root) NOPASSWD: /usr/local/bin/dockerexecctl start *, /usr/local/bin/dockerexecctl info *, /usr/local/bin/dockerexecctl touch *, /usr/local/bin/dockerexecctl stop *, /usr/local/bin/dockerexecctl gc
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl list, /usr/local/bin/vmbackupctl create *, /usr/local/bin/vmbackupctl start *, /usr/local/bin/vmbackupctl job *, /usr/local/bin/vmbackupctl download *, /usr/local/bin/vmbackupctl delete *, /usr/local/bin/vmbackupctl schedule *, /usr/local/bin/vmbackupctl unschedule *, /usr/local/bin/vmbackupctl schedules
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl receive *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/filectl list *, /usr/local/bin/filectl upload *, /usr/local/bin/filectl download *, /usr/local/bin/filectl mkdir *, /usr/local/bin/filectl move *, /usr/local/bin/filectl delete *, /usr/local/bin/filectl archive *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/storagectl status, /usr/local/bin/storagectl relocate *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/hostexecctl start, /usr/local/bin/hostexecctl stop
vmapi ALL=(root) NOPASSWD: /usr/local/bin/logctl *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmctl delete *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/overlayctl list, /usr/local/bin/overlayctl show *, /usr/local/bin/overlayctl create *, /usr/local/bin/overlayctl delete *, /usr/local/bin/overlayctl orphans, /usr/local/bin/overlayctl cleanup-orphan *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl identity, /usr/local/bin/peerctl request, /usr/local/bin/peerctl request *, /usr/local/bin/peerctl pending, /usr/local/bin/peerctl cancel-pending, /usr/local/bin/peerctl accept *, /usr/local/bin/peerctl complete *, /usr/local/bin/peerctl list, /usr/local/bin/peerctl set-url *, /usr/local/bin/peerctl overlay-credentials *, /usr/local/bin/peerctl overlay-profile *, /usr/local/bin/peerctl authorize-user *, /usr/local/bin/peerctl cors-origin *, /usr/local/bin/peerctl proxy *, /usr/local/bin/peerctl migrate *, /usr/local/bin/peerctl revoke *
SUDOERS
chmod 0440 /etc/sudoers.d/vmapi-overlay

if [[ -n $BRIDGE ]]; then
  [[ $BRIDGE =~ ^[A-Za-z0-9_.:-]{1,31}$ ]] || { echo 'Invalid bridge name' >&2; exit 1; }
  install -d -m 0755 /etc/qemu
  touch /etc/qemu/bridge.conf
  grep -Fxq "allow $BRIDGE" /etc/qemu/bridge.conf || echo "allow $BRIDGE" >> /etc/qemu/bridge.conf
  chmod 0644 /etc/qemu/bridge.conf
fi

if $ENABLE_NGINX; then
  install -m 0644 "$BASE/pam/nginx-vmapi" /etc/pam.d/nginx-vmapi
  if [[ -d /etc/nginx/sites-available ]]; then
    install -m 0644 "$BASE/nginx/vmapi.conf" /etc/nginx/sites-available/vmapi
    ln -sfn /etc/nginx/sites-available/vmapi /etc/nginx/sites-enabled/vmapi
  fi
fi

systemctl daemon-reload
if command -v docker >/dev/null 2>&1 && systemctl list-unit-files docker.service >/dev/null 2>&1; then
  systemctl enable --now docker.service || true
fi
systemctl enable --now fcgiwrap-vmapi.socket
# Ensure an upgrade picks up changed supplementary groups (notably docker).
systemctl try-restart fcgiwrap-vmapi.service >/dev/null 2>&1 || true
systemctl enable vmapi-autostart.service
if $ENABLE_NGINX && command -v nginx >/dev/null 2>&1; then nginx -t && systemctl reload nginx || true; fi

echo 'VMAPI installed.'
echo 'Docker API: enabled through the local Docker daemon'
echo 'Config root: /var/lib/vmapi/vms'
echo 'Disk root:   /var/lib/vmapi/disks'
echo 'ISO root:    /var/lib/vmapi/isos'
[[ -n $ADMIN_USER ]] && echo "PAM API admin: $ADMIN_USER (group vmapi-admin)"
[[ -n $BRIDGE ]] && echo "Allowed QEMU bridge: $BRIDGE"
echo 'Web console: http://127.0.0.1:8080/'
echo 'API root:    http://127.0.0.1:8080/api/'

/usr/local/bin/peerctl sync-auth
