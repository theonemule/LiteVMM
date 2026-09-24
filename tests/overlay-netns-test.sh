#!/usr/bin/env bash
# Real WSVPN + Lighttpd test in two disposable Linux network namespaces.
# Run as root with VMAPI_TEST_WSVPN=/path/to/wsvpn, lighttpd and iproute2.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WSVPN=${VMAPI_TEST_WSVPN:?Set VMAPI_TEST_WSVPN to a WSVPN binary}
[[ $EUID == 0 ]] || { echo 'Network namespace test requires root'; exit 2; }
T=$(mktemp -d); H="vmoh-$$"; S="vmos-$$"
cleanup() {
  local result=$?
  set +e
  if ((result != 0)); then
    echo "Test failed ($result)"
    tail -60 "$T"/*/overlay.log "$T"/*/lighttpd.log "$T"/*/service.log 2>/dev/null || true
  fi
  for ns in "$H" "$S"; do
    pids=$(ip netns pids "$ns" 2>/dev/null)
    [[ -z $pids ]] || kill $pids 2>/dev/null
  done
  sleep .5
  for ns in "$H" "$S"; do
    pids=$(ip netns pids "$ns" 2>/dev/null)
    [[ -z $pids ]] || kill -KILL $pids 2>/dev/null
    ip netns del "$ns" 2>/dev/null
  done
  if [[ ${KEEP_TEST_FILES:-false} == true ]]; then echo "Test files: $T"; else rm -rf -- "$T"; fi
}
trap cleanup EXIT
trap 'echo "FAILED at line $LINENO"; tail -40 "$T"/*/overlay.log "$T"/*/lighttpd.log 2>/dev/null || true' ERR
ip netns add "$H"; ip netns add "$S"
ip link add vmoh-test type veth peer name vmos-test
ip link set vmoh-test netns "$H"; ip link set vmos-test netns "$S"
ip -n "$H" addr add 192.0.2.1/24 dev vmoh-test
ip -n "$S" addr add 192.0.2.2/24 dev vmos-test
ip -n "$H" link set vmoh-test up; ip -n "$S" link set vmos-test up
ip -n "$H" link set lo up; ip -n "$S" link set lo up
for node in hub spoke; do mkdir -p "$T/$node/overlays" "$T/$node/run" "$T/$node/peers"; done
chmod 755 "$T" "$T/hub"

# Real local-CA certificate for the hub. Lighttpd terminates TLS; WSVPN never
# receives the private key or certificate and sees only plaintext WebSocket on
# its loopback listener.
mkdir -p "$T/hub/tls"
openssl req -x509 -newkey rsa:2048 -nodes -sha256 -days 2   -subj '/CN=LiteVMM Overlay Test Root/O=LiteVMM'   -addext 'basicConstraints=critical,CA:TRUE' -addext 'keyUsage=critical,keyCertSign,cRLSign'   -keyout "$T/hub/tls/root.key" -out "$T/hub/tls/root.crt" >/dev/null 2>&1
openssl req -new -newkey rsa:2048 -nodes -sha256 -subj '/CN=192.0.2.1/O=LiteVMM'   -keyout "$T/hub/tls/server.key" -out "$T/hub/tls/server.csr" >/dev/null 2>&1
cat >"$T/hub/tls/server.ext" <<'TLS_EXT'
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
subjectAltName=IP:192.0.2.1
TLS_EXT
openssl x509 -req -in "$T/hub/tls/server.csr" -CA "$T/hub/tls/root.crt" -CAkey "$T/hub/tls/root.key"   -CAcreateserial -days 2 -sha256 -extfile "$T/hub/tls/server.ext" -out "$T/hub/tls/server.crt" >/dev/null 2>&1
cat "$T/hub/tls/server.key" "$T/hub/tls/server.crt" > "$T/hub/tls/server.pem"
chmod 0600 "$T/hub/tls/root.key" "$T/hub/tls/server.key" "$T/hub/tls/server.pem"

# Stand in for OpenRC only; use the actual foreground WSVPN/controller/Lighttpd.
cat > "$T/service" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$NODE/service.log"
name=$1; action=$2
if [[ -r $NODE/$name.pid ]]; then
  pid=$(cat "$NODE/$name.pid")
  kill "$pid" 2>/dev/null || true
  for _ in {1..50}; do kill -0 "$pid" 2>/dev/null || break; sleep .1; done
fi
[[ $action != stop ]] || exit 0
if [[ $name == lighttpd ]]; then
  lighttpd -D -f "$NODE/lighttpd/lighttpd.conf" </dev/null >"$NODE/lighttpd.log" 2>&1 8>&- 9>&- &
else
  bash "$VMAPI_CTL" run </dev/null >>"$NODE/overlay.log" 2>&1 8>&- 9>&- &
fi
echo $! > "$NODE/$name.pid"
SH
chmod +x "$T/service"
node() {
  local which=$1; shift; local ns=$H tls_enabled=false tls_mode=none tls_ca=/nonexistent
  if [[ $which == hub ]]; then
    tls_enabled=true; tls_mode=local-ca; tls_ca="$T/hub/tls/root.crt"
  else
    ns=$S
  fi
  ip netns exec "$ns" env NODE="$T/$which" VMAPI_CTL="$ROOT/bin/overlayctl"     VMAPI_TLS_ENABLED="$tls_enabled" VMAPI_TLS_MODE="$tls_mode" VMAPI_TLS_CA_CERT_FILE="$tls_ca" \
    VMAPI_CONFIG=/nonexistent VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_NETCTL="$ROOT/bin/netctl" \
    VMAPI_PEERCTL="$ROOT/bin/peerctl" VMAPI_OVERLAYCTL="$ROOT/bin/overlayctl" \
    VMAPI_PEER_ROOT="$T/$which/peers" VMAPI_IDENTITY_ROOT="$T/$which/identity" VMAPI_NODE_ID_FILE="$T/$which/node-id" \
    VMAPI_PEER_PASSWD_FILE="$T/$which/passwd" VMAPI_PEER_AUTH_GROUP=root \
    VMAPI_OVERLAY_ROOT="$T/$which/overlays" VMAPI_OVERLAY_RUN="$T/$which/run" \
    VMAPI_QEMU_BRIDGE_CONF="$T/$which/qemu/bridge.conf" VMAPI_WSVPN="$WSVPN" VMAPI_LIGHTTPD_ROOT="$T/$which/lighttpd" VMAPI_RC_SERVICE="$T/service" "$@"
}
request=$(node spoke "$ROOT/bin/peerctl" request spoke http://192.0.2.2:8080)
response=$(node hub "$ROOT/bin/peerctl" accept "$request" hub https://192.0.2.1:8443)
node spoke "$ROOT/bin/peerctl" complete "$response" >/dev/null
hid=$(cat "$T/hub/node-id"); sid=$(cat "$T/spoke/node-id")
mkdir -p "$T/hub/lighttpd/conf.d" "$T/hub/www"
sed -e "s|@NOVNC_ROOT@|$T/hub/www|g" -e "s|/etc/vmapi-peer.htpasswd|$T/hub/passwd|g" -e "s|/run/fcgiwrap-vmapi.sock|$T/hub/fcgi.sock|g" "$ROOT/lighttpd/vmapi.conf" > "$T/hub/lighttpd/conf.d/vmapi.conf"
cat > "$T/hub/lighttpd/lighttpd.conf" <<CONF
server.document-root = "$T/hub/www"
server.bind = "192.0.2.1"
server.port = 8443
server.modules += ( "mod_openssl" )
ssl.engine = "enable"
ssl.pemfile = "$T/hub/tls/server.pem"
include "$T/hub/lighttpd/conf.d/*.conf"
CONF
node hub "$ROOT/bin/overlayctl" create demo --bridge br-demo --role hub --peer "$sid" --staged > "$T/hub-created.json"
node spoke "$ROOT/bin/overlayctl" create demo --bridge br-demo --role spoke --peer "$hid" --staged > "$T/spoke-created.json"
[[ ! -e $T/spoke/lighttpd ]]
! grep -q lighttpd "$T/spoke/service.log" || { echo "negative assertion failed: tests/overlay-netns-test.sh:109" >&2; exit 1; }
python3 - "$T" <<'PY'
import json,sys,yaml
from pathlib import Path
t=Path(sys.argv[1])
h=yaml.safe_load((t/'hub/run/demo.yaml').read_text())
s=yaml.safe_load((t/'spoke/run/demo.yaml').read_text())
assert h['tunnel']['mode']=='TAP'
assert h['tunnel']['allow-client-to-client'] is True
assert h['tunnel']['allow-ip-spoofing'] is True
assert h['tunnel']['allow-unknown-ether-types'] is True
assert h['server']['listen'].startswith('127.0.0.1:')
assert h['server']['tls']['certificate']=='' and h['server']['tls']['key']==''
assert s['client']['server']=='wss://192.0.2.1:8443/overlay/demo'
assert s['client']['auth-file']==str(t/'spoke/run/demo.auth')
assert s['client']['tls']['config']['insecure'] is False
assert s['client']['tls']['ca']==str(t/'spoke/peers/ca'/((t/'hub/node-id').read_text().strip()+'.crt'))
for n in ('hub','spoke'):
    assert json.loads((t/f'{n}-created.json').read_text())['running']
PY
source "$T/spoke/peers/$hid.conf"
[[ -s $TLS_CA_FILE ]]
openssl verify -CAfile "$TLS_CA_FILE" "$T/hub/tls/server.crt" >/dev/null
curl_spoke() { ip netns exec "$S" curl -sS --noproxy '*' --cacert "$TLS_CA_FILE" "$@"; }
[[ $(curl_spoke -o /dev/null -w '%{http_code}' https://192.0.2.1:8443/overlay/demo) == 401 ]]
[[ $(curl_spoke --user "$RELAY_USER:wrong" -o /dev/null -w '%{http_code}' https://192.0.2.1:8443/overlay/demo) == 401 ]]
for path in /peer-api /peer-api.cgi /peer-api/cluster/identity; do
  [[ $(curl_spoke -o /dev/null -w '%{http_code}' "https://192.0.2.1:8443$path") == 401 ]]
  code=$(curl_spoke --user "$RELAY_USER:$RELAY_PASSWORD" -o /dev/null -w '%{http_code}' "https://192.0.2.1:8443$path")
  [[ $code != 401 ]]
done
sleep 2
node spoke "$ROOT/bin/overlayctl" validate demo
# WSVPN must expose only its loopback listener; Lighttpd is the only underlay-facing endpoint.
ip netns exec "$H" ss -lntu > "$T/listeners"
! grep -E '0.0.0.0:(18[0-9]{3}|[23][0-9]{4}|[34][0-9]{4})' "$T/listeners" || { echo "negative assertion failed: tests/overlay-netns-test.sh:144" >&2; exit 1; }
grep -Eq '127.0.0.1:(18[0-9]{3}|2[0-9]{4})' "$T/listeners"
node hub "$ROOT/bin/overlayctl" activate demo >/dev/null
node spoke "$ROOT/bin/overlayctl" activate demo >/dev/null
# Workload-like addresses on opposite bridges prove the active Ethernet path.
ip -n "$H" addr add 198.18.0.1/24 dev br-demo
ip -n "$S" addr add 198.18.0.2/24 dev br-demo
sleep 2
ip netns exec "$S" ping -c 3 -W 2 198.18.0.1
# Full-size frames must cross the overlay: guests default to a 1500-byte MTU,
# and a smaller overlay silently dropped their full-size (e.g. routed TCP) packets.
[[ $(ip netns exec "$H" cat /sys/class/net/br-demo/mtu) == 1500 && $(ip netns exec "$S" cat /sys/class/net/br-demo/mtu) == 1500 ]]
ip netns exec "$S" ping -c 2 -s 1472 -M do -W 3 198.18.0.1
# A hub Lighttpd restart (e.g. any route change or certificate reload) forces a
# WSVPN reconnect. The spoke must keep the same bridged TAP and recover by itself.
spoke_ifindex=$(ip netns exec "$S" cat /sys/class/net/vmo-demo/ifindex)
node hub "$T/service" lighttpd restart
recovered=false
for _ in {1..40}; do ip netns exec "$S" ping -c 1 -W 1 198.18.0.1 >/dev/null 2>&1 && { recovered=true; break; }; sleep .5; done
[[ $recovered == true ]] || { echo 'overlay did not recover after a hub Lighttpd restart' >&2; exit 1; }
[[ $(ip netns exec "$S" cat /sys/class/net/vmo-demo/ifindex) == "$spoke_ifindex" ]] || { echo 'spoke TAP was recreated on reconnect' >&2; exit 1; }
[[ $(basename "$(ip netns exec "$S" readlink /sys/class/net/vmo-demo/master)") == br-demo ]] || { echo 'spoke TAP lost its bridge on reconnect' >&2; exit 1; }
# set-mtu changes an existing overlay on each member host, bridge ports included.
node hub "$ROOT/bin/overlayctl" set-mtu demo 1400 >/dev/null; node spoke "$ROOT/bin/overlayctl" set-mtu demo 1400 >/dev/null
for _ in {1..30}; do ip netns exec "$S" ping -c 1 -W 1 198.18.0.1 >/dev/null 2>&1 && break; sleep .5; done
[[ $(ip netns exec "$H" cat /sys/class/net/br-demo/mtu) == 1400 && $(ip netns exec "$S" cat /sys/class/net/vmo-demo/mtu) == 1400 ]]
grep -q '^MTU=1400$' "$T/hub/overlays/demo.conf"
ip netns exec "$S" ping -c 2 -s 1372 -M do -W 3 198.18.0.1
node hub "$ROOT/bin/overlayctl" set-mtu demo 1500 >/dev/null; node spoke "$ROOT/bin/overlayctl" set-mtu demo 1500 >/dev/null
for _ in {1..30}; do ip netns exec "$S" ping -c 1 -W 1 198.18.0.1 >/dev/null 2>&1 && break; sleep .5; done
ip netns exec "$S" ping -c 2 -s 1472 -M do -W 3 198.18.0.1
# Verify a non-IP Ethernet frame survives the overlay. EtherType 0x8137 is
# historically used by IPX; WSVPN must not filter it.
ip -n "$H" link add hguest type veth peer name hport
ip -n "$S" link add sguest type veth peer name sport
ip -n "$H" link set hport master br-demo; ip -n "$H" link set hport up; ip -n "$H" link set hguest up
ip -n "$S" link set sport master br-demo; ip -n "$S" link set sport up; ip -n "$S" link set sguest up
ip netns exec "$S" python3 - <<'PYRX' >"$T/raw-frame.out" &
import socket,sys
s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW,socket.htons(0x8137)); s.bind(('sguest',0)); s.settimeout(5)
while True:
    frame=s.recv(2048)
    if frame[12:14] == b'\x81\x37' and b'LITEVMM-IPX-PROBE' in frame:
        print('raw-ethertype-8137=ok'); break
PYRX
raw_pid=$!
sleep .3
ip netns exec "$H" python3 - <<'PYTX'
import socket
s=socket.socket(socket.AF_PACKET,socket.SOCK_RAW); s.bind(('hguest',0))
src=s.getsockname()[4]
frame=b'\xff'*6+src+b'\x81\x37'+b'LITEVMM-IPX-PROBE'
s.send(frame)
PYTX
wait "$raw_pid"
grep -Fxq 'raw-ethertype-8137=ok' "$T/raw-frame.out"
node hub "$ROOT/bin/overlayctl" list | python3 -c 'import json,sys; x=json.load(sys.stdin); assert len(x)==1 and x[0]["tap_bridged"]'
# Killing WSVPN must take down the supervisor, allowing OpenRC to respawn it.
wpid=$(cat "$T/spoke/run/demo.pid"); kill "$wpid"; sleep 1
[[ ! -e $T/spoke/run/demo.pid ]]
node spoke "$ROOT/bin/overlayctl" restart-service
sleep 2
ip netns exec "$S" ping -c 1 -W 2 198.18.0.1
# Revocation closes established transport and removes the API credential.
node hub "$ROOT/bin/peerctl" revoke "$sid"
[[ ! -s $T/hub/passwd && ! -f $T/hub/overlays/demo.conf && ! -f $T/hub/run/demo.pid ]]
# The fake service manager starts Lighttpd in the background without waiting
# for it to bind, so give the restart triggered by revocation a moment.
code=000; for _ in {1..50}; do code=$(curl_spoke --user "$RELAY_USER:$RELAY_PASSWORD" -o /dev/null -w '%{http_code}' https://192.0.2.1:8443/peer-api 2>/dev/null || true); [[ $code == 000 ]] || break; sleep .1; done
[[ $code == 401 ]]
! ip -n "$H" link show vmo-demo >/dev/null 2>&1 || { echo "negative assertion failed: tests/overlay-netns-test.sh:205" >&2; exit 1; }
echo 'overlay netns: PASS (Lighttpd HTTPS/WSS TLS-offload/auth boundary, WSVPN TAP ARP/ICMP/raw EtherType 0x8137, 1500-byte frames, set-mtu, activation, child cleanup, revocation, no spoke Lighttpd)'
