#!/usr/bin/env bash
set -Eeuo pipefail
port=${VMAPI_HTTP_PORT:-5186}
user=${VMAPI_HTTP_USER:-admin}
password=${VMAPI_HTTP_PASSWORD:-}
[[ $port =~ ^[0-9]{1,5}$ ]] && ((10#$port >= 1024 && 10#$port <= 65535)) || { echo 'VMAPI_HTTP_PORT must be 1024-65535' >&2; exit 2; }
[[ $user =~ ^[A-Za-z0-9._-]{1,64}$ ]] || { echo 'Invalid VMAPI_HTTP_USER' >&2; exit 2; }
[[ -n $password ]] || { echo 'VMAPI_HTTP_PASSWORD is required' >&2; exit 2; }

mkdir -p /var/lib/vmapi/{backups,replicas,replication-jobs,replication-receivers,remote-volumes,remote-volume-shares,peers,identity,backup-jobs} /var/log/vmapi/backups /var/log/vmapi /run/vmapi /run/vmapi/conf.d /run/vmapi-replication /etc/lighttpd
touch /run/vmapi/conf.d/00-empty.conf
chown -R vmapi:vmapi /var/lib/vmapi/backups /var/lib/vmapi/backup-jobs /var/log/vmapi /run/vmapi
chown root:lighttpd /var/lib/vmapi/remote-volumes /var/lib/vmapi/remote-volume-shares
chmod 0750 /var/lib/vmapi/remote-volumes /var/lib/vmapi/remote-volume-shares
sed -i -E "s/^VMAPI_HTTP_PORT=.*/VMAPI_HTTP_PORT=$port/" /etc/vmapi/vmapi.conf
hash=$(printf '%s\n' "$password" | openssl passwd -apr1 -stdin)
printf '%s:%s\n' "$user" "$hash" > /etc/lighttpd/vmapi.htpasswd
chmod 0640 /etc/lighttpd/vmapi.htpasswd
chown root:lighttpd /etc/lighttpd/vmapi.htpasswd

cat > /etc/sudoers.d/vmapi <<'SUDOERS'
vmapi ALL=(root) NOPASSWD: /usr/local/bin/peerctl identity, /usr/local/bin/peerctl request, /usr/local/bin/peerctl request *, /usr/local/bin/peerctl pending, /usr/local/bin/peerctl cancel-pending, /usr/local/bin/peerctl accept *, /usr/local/bin/peerctl complete *, /usr/local/bin/peerctl list, /usr/local/bin/peerctl set-url *, /usr/local/bin/peerctl authorize-user *, /usr/local/bin/peerctl cors-origin *, /usr/local/bin/peerctl proxy *, /usr/local/bin/peerctl revoke *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/vmbackupctl list, /usr/local/bin/vmbackupctl list *, /usr/local/bin/vmbackupctl download *, /usr/local/bin/vmbackupctl receive *, /usr/local/bin/vmbackupctl delete *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/replicationctl receiver-create *, /usr/local/bin/replicationctl receiver-delete *, /usr/local/bin/replicationctl receiver-purge *, /usr/local/bin/replicationctl receiver-start *, /usr/local/bin/replicationctl receiver-show *, /usr/local/bin/replicationctl receiver-list, /usr/local/bin/replicationctl render-web
vmapi ALL=(root) NOPASSWD: /usr/local/bin/remote-volumectl share-create *, /usr/local/bin/remote-volumectl share-start *, /usr/local/bin/remote-volumectl share-stop *, /usr/local/bin/remote-volumectl share-stop-admin *, /usr/local/bin/remote-volumectl share-show *, /usr/local/bin/remote-volumectl share-list, /usr/local/bin/remote-volumectl share-list *, /usr/local/bin/remote-volumectl share-purge *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/logctl *
vmapi ALL=(root) NOPASSWD: /usr/local/bin/certctl status
SUDOERS
chmod 0440 /etc/sudoers.d/vmapi

/usr/local/bin/peerctl sync-auth
sed "s/@PORT@/$port/g" /etc/lighttpd/vmapi-container.conf > /run/vmapi/lighttpd.conf
VMAPI_REPLICATION_SKIP_RELOAD=true /usr/local/bin/replicationctl daemon >>/var/log/vmapi/replication.log 2>&1 &
spawn-fcgi -s /run/vmapi/fcgi.sock -M 0660 -U lighttpd -G lighttpd -u vmapi -g vmapi -- /usr/bin/env HOME=/var/lib/vmapi PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin /usr/bin/fcgiwrap -f -c 8
exec lighttpd -D -f /run/vmapi/lighttpd.conf
