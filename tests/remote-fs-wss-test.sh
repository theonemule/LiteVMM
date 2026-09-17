#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for cmd in lighttpd openssl python3 fusermount3; do command -v "$cmd" >/dev/null 2>&1 || { echo "remote FUSE/WSS integration: SKIP ($cmd unavailable)"; exit 0; }; done
python3 -c 'import pyfuse3,trio' >/dev/null 2>&1 || { echo 'remote FUSE/WSS integration: SKIP (pyfuse3 unavailable)'; exit 0; }
[[ -c /dev/fuse ]] || { echo 'remote FUSE/WSS integration: SKIP (/dev/fuse unavailable)'; exit 0; }
sudo -n true >/dev/null 2>&1 || { echo 'remote FUSE/WSS integration: SKIP (passwordless sudo unavailable)'; exit 0; }
T=$(mktemp -d)
cleanup(){
  sudo -n fusermount3 -uz "$T/mnt" 2>/dev/null || true
  [[ -f $T/fuse.pid ]] && kill "$(cat "$T/fuse.pid")" 2>/dev/null || true
  [[ -f $T/lighttpd.proc ]] && kill "$(cat "$T/lighttpd.proc")" 2>/dev/null || true
  rm -rf "$T" 2>/dev/null || true
}
trap cleanup EXIT
mkdir -p "$T"/{shares,data,mnt,www}
PORT=$(python3 - <<'PY'
import socket
s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()
PY
)
USER_NAME=peer-test; PASS=peer-test-password; TOKEN=$(openssl rand -hex 24); ID=$(openssl rand -hex 12)
cat > "$T/shares/$ID.json" <<JSON
{"id":"$ID","owner":"$USER_NAME","name":"appdata","token":"$TOKEN","data":"$T/data","active":true}
JSON
printf '%s:%s\n' "$USER_NAME" "$(printf '%s\n' "$PASS" | openssl passwd -apr1 -stdin)" > "$T/peer.htpasswd"
cat > "$T/openssl.cnf" <<'CONF'
[req]
distinguished_name=dn
x509_extensions=v3
prompt=no
[dn]
CN=127.0.0.1
[v3]
subjectAltName=IP:127.0.0.1
CONF
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -keyout "$T/key.pem" -out "$T/cert.pem" -config "$T/openssl.cnf" >/dev/null 2>&1
cat > "$T/lighttpd.conf" <<CFG
server.modules = ( "mod_openssl", "mod_auth", "mod_authn_file", "mod_alias", "mod_rewrite", "mod_cgi", "mod_setenv" )
server.document-root = "$T/www"
server.bind = "127.0.0.1"
server.port = $PORT
server.pid-file = "$T/lighttpd.pid"
server.errorlog = "$T/error.log"
ssl.engine = "enable"
ssl.pemfile = "$T/cert.pem"
ssl.privkey = "$T/key.pem"
auth.backend = "htpasswd"
auth.backend.htpasswd.userfile = "$T/peer.htpasswd"
setenv.add-environment = ( "VMAPI_REMOTE_VOLUME_SHARE_ROOT" => "$T/shares" )
\$HTTP["url"] =~ "^/(remote-fs(?:/|\$)|remote-fs-ws[.]py(?:/|\$))" {
  auth.require = ( "" => ( "method" => "basic", "realm" => "LiteVMM peers", "require" => "valid-user" ) )
}
alias.url = ( "/remote-fs-ws.py" => "$ROOT/cgi/remote-fs-ws.py" )
url.rewrite-once = ( "^/remote-fs/([a-f0-9]{48})/?\$" => "/remote-fs-ws.py/\$1" )
\$HTTP["url"] =~ "^/remote-fs-ws[.]py(?:/|\$)" {
  cgi.assign = ( ".py" => "/usr/bin/python3" )
  cgi.upgrade = "enable"
}
CFG
lighttpd -tt -f "$T/lighttpd.conf" >/dev/null
lighttpd -D -f "$T/lighttpd.conf" >"$T/lighttpd.out" 2>&1 & echo $! > "$T/lighttpd.proc"
sleep .2
sudo -n env LITEVMM_REMOTE_FS_CA_FILE="$T/cert.pem" \
  LITEVMM_REMOTE_FS_URL="wss://127.0.0.1:$PORT/remote-fs/$TOKEN" \
  LITEVMM_REMOTE_FS_USER="$USER_NAME" LITEVMM_REMOTE_FS_PASSWORD="$PASS" \
  python3 "$ROOT/bin/litevmm-remote-fuse.py" "$T/mnt" >"$T/fuse.log" 2>&1 & echo $! > "$T/fuse.pid"
for _ in {1..100}; do
  awk -v p="$T/mnt" '$2==p && $3 ~ /^fuse/ {found=1} END{exit !found}' /proc/mounts && break
  kill -0 "$(cat "$T/fuse.pid")" 2>/dev/null || { cat "$T/fuse.log" >&2; exit 1; }
  sleep .1
done
awk -v p="$T/mnt" '$2==p && $3 ~ /^fuse/ {found=1} END{exit !found}' /proc/mounts || { cat "$T/fuse.log" >&2; exit 1; }
printf 'hello over wss\n' | sudo -n tee "$T/mnt/hello.txt" >/dev/null
sudo -n mkdir "$T/mnt/subdir"
printf 'persistent remote data\n' | sudo -n tee "$T/mnt/subdir/data.txt" >/dev/null
[[ $(sudo -n cat "$T/mnt/hello.txt") == 'hello over wss' ]]
[[ $(cat "$T/data/hello.txt") == 'hello over wss' ]]
[[ $(cat "$T/data/subdir/data.txt") == 'persistent remote data' ]]
sudo -n mv "$T/mnt/hello.txt" "$T/mnt/renamed.txt"
sudo -n truncate -s 5 "$T/mnt/renamed.txt"
sudo -n sh -c "printf '!' >> '$T/mnt/renamed.txt'"
[[ $(cat "$T/data/renamed.txt") == 'hello!' ]]
sudo -n rm "$T/mnt/subdir/data.txt"; sudo -n rmdir "$T/mnt/subdir"
# Unmount the direct client and exercise the actual remote-volumectl attach/detach path.
sudo -n fusermount3 -u "$T/mnt"
kill "$(cat "$T/fuse.pid")" 2>/dev/null || true
rm -f "$T/fuse.pid"
mkdir -p "$T/controller"/{mounts,state,run,docker-state}
PEER_ID=0123456789abcdef0123456789abcdef
cat > "$T/fake-peerctl" <<SH
#!/usr/bin/env bash
set -e
case "\${1:-}" in
  overlay-profile)
    printf '%s\n' '{"node_id":"$PEER_ID","endpoint":"wss://127.0.0.1:$PORT/overlay","username":"$USER_NAME","password":"$PASS"}' ;;
  proxy)
    method=\${3:-}; path=\${4:-}
    if [[ \$method == POST && \$path == /remote-volumes/shares ]]; then
      cat >/dev/null || true
      printf '%s\n' '{"id":"$ID","name":"appdata","active":true,"bytes":0,"path":"/remote-fs/$TOKEN"}'
    elif [[ \$method == DELETE ]]; then
      cat >/dev/null || true; printf '%s\n' '{"stopped":true}'
    else
      echo "unexpected fake peerctl call: \$*" >&2; exit 2
    fi;;
  *) echo "unexpected fake peerctl command: \$*" >&2; exit 2;;
esac
SH
chmod +x "$T/fake-peerctl"
cat > "$T/fake-docker" <<SH
#!/usr/bin/env bash
set -e
root='$T/controller/docker-state'
if [[ \${1:-} == volume && \${2:-} == inspect ]]; then [[ -f \$root/\${3:-} ]]; exit; fi
if [[ \${1:-} == volume && \${2:-} == create ]]; then name=\${!#}; touch \$root/\$name; printf '%s\n' "\$name"; exit; fi
if [[ \${1:-} == volume && \${2:-} == rm ]]; then rm -f \$root/\${3:-}; printf '%s\n' "\${3:-}"; exit; fi
echo "unexpected fake docker call: \$*" >&2; exit 2
SH
chmod +x "$T/fake-docker"
sudo -n env \
  VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" \
  VMAPI_PEERCTL="$T/fake-peerctl" DOCKER_BIN="$T/fake-docker" \
  VMAPI_REMOTE_FUSE_CLIENT="$ROOT/bin/litevmm-remote-fuse.py" \
  VMAPI_REMOTE_VOLUME_ROOT="$T/hosted-unused" VMAPI_REMOTE_VOLUME_SHARE_ROOT="$T/shares" \
  VMAPI_REMOTE_MOUNT_ROOT="$T/controller/mounts" VMAPI_REMOTE_MOUNT_STATE_ROOT="$T/controller/state" \
  VMAPI_REMOTE_VOLUME_RUN_ROOT="$T/controller/run" LITEVMM_REMOTE_FS_CA_FILE="$T/cert.pem" \
  bash "$ROOT/bin/remote-volumectl" attach "$PEER_ID" appdata peerdata >/dev/null
MP="$T/controller/mounts/peerdata"
awk -v p="$MP" '$2==p && $3 ~ /^fuse/ {found=1} END{exit !found}' /proc/mounts
printf 'controller-path\n' | sudo -n tee "$MP/controller.txt" >/dev/null
[[ $(cat "$T/data/controller.txt") == controller-path ]]
FUSE_PID=$(sudo -n awk -F= '$1=="PID_FILE"{gsub(/^[^=]*=/,"",$0); print $0}' "$T/controller/state/peerdata.conf" | xargs sudo -n cat)
! sudo -n ss -ltnp 2>/dev/null | grep -F "pid=$FUSE_PID," >/dev/null
sudo -n env \
  VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" \
  VMAPI_PEERCTL="$T/fake-peerctl" DOCKER_BIN="$T/fake-docker" \
  VMAPI_REMOTE_FUSE_CLIENT="$ROOT/bin/litevmm-remote-fuse.py" \
  VMAPI_REMOTE_VOLUME_ROOT="$T/hosted-unused" VMAPI_REMOTE_VOLUME_SHARE_ROOT="$T/shares" \
  VMAPI_REMOTE_MOUNT_ROOT="$T/controller/mounts" VMAPI_REMOTE_MOUNT_STATE_ROOT="$T/controller/state" \
  VMAPI_REMOTE_VOLUME_RUN_ROOT="$T/controller/run" LITEVMM_REMOTE_FS_CA_FILE="$T/cert.pem" \
  bash "$ROOT/bin/remote-volumectl" detach peerdata >/dev/null
[[ ! -f "$T/controller/docker-state/peerdata" ]]
[[ $(cat "$T/data/controller.txt") == controller-path ]]
echo 'remote FUSE/WSS integration: PASS'
