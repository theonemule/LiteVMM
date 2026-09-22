#!/usr/bin/env bash
set -Eeuo pipefail
port=${VMAPI_HTTP_PORT:-5186}
user=${VMAPI_HTTP_USER:-admin}
password=${VMAPI_HTTP_PASSWORD:-}
[[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1024 && 10#$port <= 65535)) || { echo 'VMAPI_HTTP_PORT must be 1024-65535' >&2; exit 2; }
[[ $user =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo 'Invalid VMAPI_HTTP_USER' >&2; exit 2; }
[[ -n $password ]] || { echo 'VMAPI_HTTP_PASSWORD is required' >&2; exit 2; }

mkdir -p /var/lib/vmapi/{backups,backplane/peers,peers,identity,backup-jobs,config,tls} /var/log/vmapi/backups /var/log/vmapi /run/vmapi /run/vmapi/conf.d /run/vmapi-backplane /etc/lighttpd /etc/vmapi

# The container image is replaceable; all mutable LiteVMM configuration lives
# with the mounted data at /var/lib/vmapi. This preserves TLS activation state,
# peer/storage settings, and future runtime settings across image upgrades.
defaults=/usr/share/vmapi/vmapi-container-defaults.conf
persistent_config=/var/lib/vmapi/config/vmapi.conf
if [[ ! -s $persistent_config ]]; then
  install -m 0644 "$defaults" "$persistent_config"

  # Migration from storage images that persisted certificate files but kept the
  # active TLS flags in ephemeral /etc. Recover the common existing certificate
  # layouts so an image upgrade does not silently fall back to HTTP.
  tls_root=/var/lib/vmapi/tls
  recover_cert=''; recover_key=''; recover_mode=''; recover_domain=''
  if [[ -s $tls_root/local-endpoint.crt && -s $tls_root/local-endpoint.key ]]; then
    recover_cert=$tls_root/local-endpoint.crt; recover_key=$tls_root/local-endpoint.key; recover_mode=local-ca
  elif [[ -s $tls_root/imported.crt && -s $tls_root/imported.key ]]; then
    recover_cert=$tls_root/imported.crt; recover_key=$tls_root/imported.key; recover_mode=imported
  fi
  if [[ -n $recover_cert ]] && openssl x509 -in "$recover_cert" -noout >/dev/null 2>&1 && openssl pkey -in "$recover_key" -noout >/dev/null 2>&1; then
    cert_pub=$(openssl x509 -in "$recover_cert" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    key_pub=$(openssl pkey -in "$recover_key" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')
    if [[ -n $cert_pub && $cert_pub == "$key_pub" ]]; then
      recover_domain=$(openssl x509 -in "$recover_cert" -noout -subject -nameopt RFC2253 2>/dev/null | sed -n 's/^subject=.*CN=\([^,]*\).*$/\1/p' | head -n1)
      sed -i -E         -e 's#^VMAPI_TLS_ENABLED=.*#VMAPI_TLS_ENABLED=true#'         -e "s#^VMAPI_TLS_MODE=.*#VMAPI_TLS_MODE=$recover_mode#"         -e "s#^VMAPI_TLS_DOMAIN=.*#VMAPI_TLS_DOMAIN=$recover_domain#"         -e "s#^VMAPI_TLS_CERT_FILE=.*#VMAPI_TLS_CERT_FILE=$recover_cert#"         -e "s#^VMAPI_TLS_KEY_FILE=.*#VMAPI_TLS_KEY_FILE=$recover_key#"         "$persistent_config"
    fi
  fi
fi
rm -f /etc/vmapi/vmapi.conf
ln -s "$persistent_config" /etc/vmapi/vmapi.conf

touch /run/vmapi/conf.d/00-empty.conf
chmod 0770 /var/lib/vmapi/backplane/peers
chown -R vmapi:vmapi /var/lib/vmapi/backups /var/lib/vmapi/backup-jobs /var/log/vmapi /run/vmapi
touch /var/log/vmapi/lighttpd-error.log
chown lighttpd:lighttpd /var/log/vmapi/lighttpd-error.log

sed -i -E "s/^VMAPI_HTTP_PORT=.*/VMAPI_HTTP_PORT=$port/" "$persistent_config"
hash=$(printf '%s\n' "$password" | openssl passwd -apr1 -stdin)
printf '%s:%s\n' "$user" "$hash" > /etc/lighttpd/vmapi.htpasswd
chmod 0640 /etc/lighttpd/vmapi.htpasswd
chown root:lighttpd /etc/lighttpd/vmapi.htpasswd

cat > /etc/sudoers.d/vmapi <<'SUDOERS'
vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl identity, /usr/local/bin/peerctl request, /usr/local/bin/peerctl request *, /usr/local/bin/peerctl pending, /usr/local/bin/peerctl cancel-pending, /usr/local/bin/peerctl accept *, /usr/local/bin/peerctl complete *, /usr/local/bin/peerctl list, /usr/local/bin/peerctl set-url *, /usr/local/bin/peerctl authorize-user *, /usr/local/bin/peerctl cors-origin *, /usr/local/bin/peerctl proxy *, /usr/local/bin/peerctl revoke *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl list, /usr/local/bin/vmbackupctl list *, /usr/local/bin/vmbackupctl download *, /usr/local/bin/vmbackupctl delete *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/replicationctl replica-purge *, /usr/local/bin/replicationctl replica-show *, /usr/local/bin/replicationctl replica-list
vmapi ALL=(root) NOPASSWD: /usr/local/bin/peer-volumectl list-hosted, /usr/local/bin/peer-volumectl list-hosted *, /usr/local/bin/peer-volumectl show-hosted *, /usr/local/bin/peer-volumectl delete-hosted *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/backplanectl server-status
vmapi ALL=(root) NOPASSWD: /usr/local/bin/hostexecctl start, /usr/local/bin/hostexecctl stop
vmapi ALL=(root) NOPASSWD: /usr/local/bin/filectl *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/logctl *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/certctl status, /usr/local/bin/certctl issue *, /usr/local/bin/certctl renew, /usr/local/bin/certctl self-sign *, /usr/local/bin/certctl ca-show, /usr/local/bin/certctl csr-generate *, /usr/local/bin/certctl csr-show, /usr/local/bin/certctl import-signed *, /usr/local/bin/certctl import-pair *, /usr/local/bin/certctl disable
SUDOERS
chmod 0440 /etc/sudoers.d/vmapi

/usr/local/bin/peerctl sync-auth
sed "s/@PORT@/$port/g" /etc/lighttpd/vmapi-container.conf > /run/vmapi/lighttpd.conf

# /run is recreated with every container. Rebuild the active TLS fragment and
# combined PEM from the persistent config/certificate files before Lighttpd
# starts. Suppress reload because there is no running web server yet.
VMAPI_WEB_RELOAD=/bin/true /usr/local/bin/certctl apply >/dev/null

# The storage container uses the userspace NFS backend and does not require
# privileged mode or host mount capabilities. Native LiteVMM installs on a VM
# or physical host use the kernel NFS backend regardless of workload profile.
/usr/local/bin/backplanectl server-daemon >>/var/log/vmapi/backplane.log 2>&1 &
backplane_pid=$!
ready=false
for _ in {1..80}; do
  if /usr/local/bin/backplanectl server-status >/dev/null 2>&1; then ready=true; break; fi
  kill -0 "$backplane_pid" 2>/dev/null || break
  sleep .1
done
if [[ $ready != true ]]; then
  cat /var/log/vmapi/backplane.log >&2 2>/dev/null || true
  echo 'LiteVMM storage backplane failed to start.' >&2
  exit 1
fi

fcgiwrap_bin=$(command -v fcgiwrap 2>/dev/null || true)
[[ -n $fcgiwrap_bin ]] || { echo 'fcgiwrap is not installed' >&2; exit 1; }
spawn_fcgi_bin=$(command -v spawn-fcgi 2>/dev/null || true)
[[ -n $spawn_fcgi_bin ]] || { echo 'spawn-fcgi is not installed' >&2; exit 1; }
lighttpd_bin=$(command -v lighttpd 2>/dev/null || true)
[[ -n $lighttpd_bin ]] || { echo 'lighttpd is not installed' >&2; exit 1; }
ttyd_bin=$(command -v ttyd 2>/dev/null || true)
[[ -n $ttyd_bin ]] || { echo 'ttyd is not installed' >&2; exit 1; }
install -d -m 0700 /run/vmapi/host-exec
"$ttyd_bin" --interface 127.0.0.1 --port 7682 --writable --url-arg --base-path /host/terminal --client-option titleFixed=LiteVMM-Storage /usr/local/bin/hostexecctl attach >>/var/log/vmapi/ttyd-host.log 2>&1 &
ttyd_pid=$!

"$spawn_fcgi_bin" -s /run/vmapi/fcgi.sock -M 0660 -U lighttpd -G lighttpd -u vmapi -g vmapi -- /usr/bin/env HOME=/var/lib/vmapi PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin "$fcgiwrap_bin" -f -c 8
# PID 1 supervises Lighttpd. vmapi-web-reload sends SIGUSR1 after an API
# request finishes; Lighttpd then exits gracefully and this loop immediately
# starts a replacement using the updated configuration (for example HTTP->HTTPS).
stopping=false
lighttpd_pid=''
stop_container(){
  stopping=true
  [[ $lighttpd_pid =~ ^[0-9]+$ ]] && kill -TERM "$lighttpd_pid" 2>/dev/null || true
  [[ $backplane_pid =~ ^[0-9]+$ ]] && kill -TERM "$backplane_pid" 2>/dev/null || true
  [[ $ttyd_pid =~ ^[0-9]+$ ]] && kill -TERM "$ttyd_pid" 2>/dev/null || true
}
trap stop_container TERM INT

while [[ $stopping != true ]]; do
  "$lighttpd_bin" -D -f /run/vmapi/lighttpd.conf &
  lighttpd_pid=$!
  set +e
  wait "$lighttpd_pid"
  rc=$?
  set -e
  lighttpd_pid=''
  [[ $stopping == true ]] && break
  # A graceful config reload exits cleanly. Unexpected exits are also retried
  # after a short delay so PID 1 does not busy-loop on a persistent error.
  ((rc == 0)) || sleep 1
done

wait "$backplane_pid" 2>/dev/null || true
wait "$ttyd_pid" 2>/dev/null || true
exit 0
