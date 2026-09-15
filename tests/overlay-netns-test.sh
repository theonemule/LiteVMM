#!/usr/bin/env bash
# Real GOST + Lighttpd test in two disposable Linux network namespaces.
# Run as root with VMAPI_TEST_GOST=/path/to/gost (v3), lighttpd and iproute2.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
GOST=${VMAPI_TEST_GOST:?Set VMAPI_TEST_GOST to a GOST v3 binary}
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

# Stand in for OpenRC only; use the actual foreground GOST/controller/Lighttpd.
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
  local which=$1; shift; local ns=$H; [[ $which == hub ]] || ns=$S
  ip netns exec "$ns" env NODE="$T/$which" VMAPI_CTL="$ROOT/bin/overlayctl" \
    VMAPI_CONFIG=/nonexistent VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_NETCTL="$ROOT/bin/netctl" \
    VMAPI_PEERCTL="$ROOT/bin/peerctl" VMAPI_OVERLAYCTL="$ROOT/bin/overlayctl" \
    VMAPI_PEER_ROOT="$T/$which/peers" VMAPI_IDENTITY_ROOT="$T/$which/identity" VMAPI_NODE_ID_FILE="$T/$which/node-id" \
    VMAPI_PEER_PASSWD_FILE="$T/$which/passwd" VMAPI_PEER_AUTH_GROUP=root \
    VMAPI_OVERLAY_ROOT="$T/$which/overlays" VMAPI_OVERLAY_RUN="$T/$which/run" \
    VMAPI_GOST="$GOST" VMAPI_LIGHTTPD_ROOT="$T/$which/lighttpd" VMAPI_RC_SERVICE="$T/service" "$@"
}
request=$(node spoke "$ROOT/bin/peerctl" request spoke http://192.0.2.2:8080)
response=$(node hub "$ROOT/bin/peerctl" accept "$request" hub http://192.0.2.1:8080)
node spoke "$ROOT/bin/peerctl" complete "$response" >/dev/null
hid=$(cat "$T/hub/node-id"); sid=$(cat "$T/spoke/node-id")
mkdir -p "$T/hub/lighttpd/conf.d" "$T/hub/www"
sed -e "s|@NOVNC_ROOT@|$T/hub/www|g" -e "s|/etc/vmapi-peer.htpasswd|$T/hub/passwd|g" "$ROOT/lighttpd/vmapi.conf" > "$T/hub/lighttpd/conf.d/vmapi.conf"
cat > "$T/hub/lighttpd/lighttpd.conf" <<CONF
server.document-root = "$T/hub/www"
server.bind = "192.0.2.1"
server.port = 8080
include "$T/hub/lighttpd/conf.d/*.conf"
CONF
node hub "$ROOT/bin/overlayctl" create demo --bridge br-demo --role hub --peer "$sid" --staged > "$T/hub-created.json"
node spoke "$ROOT/bin/overlayctl" create demo --bridge br-demo --role spoke --peer "$hid" --staged > "$T/spoke-created.json"
[[ ! -e $T/spoke/lighttpd ]]
! grep -q lighttpd "$T/spoke/service.log"
python3 - "$T" <<'PY'
import json,sys,yaml,base64
from pathlib import Path
t=Path(sys.argv[1]); c=yaml.safe_load((t/'spoke/run/demo.yaml').read_text())
d=c['chains'][0]['hops'][0]['nodes'][0]
assert d['addr']=='192.0.2.1:8080'
assert d['dialer']['metadata']['path']=='/overlay/demo'
assert 'auth' not in d['connector']
for n in ('hub','spoke'):
    assert json.loads((t/f'{n}-created.json').read_text())['running']
PY
source "$T/spoke/peers/$hid.conf"
curl_spoke() { ip netns exec "$S" curl -sS --noproxy '*' "$@"; }
[[ $(curl_spoke -o /dev/null -w '%{http_code}' http://192.0.2.1:8080/overlay/demo) == 401 ]]
[[ $(curl_spoke --user "$RELAY_USER:wrong" -o /dev/null -w '%{http_code}' http://192.0.2.1:8080/overlay/demo) == 401 ]]
for path in /peer-api /peer-api.cgi /peer-api/cluster/identity; do
  [[ $(curl_spoke -o /dev/null -w '%{http_code}' "http://192.0.2.1:8080$path") == 401 ]]
  code=$(curl_spoke --user "$RELAY_USER:$RELAY_PASSWORD" -o /dev/null -w '%{http_code}' "http://192.0.2.1:8080$path")
  [[ $code != 401 ]]
done
sleep 2
node spoke "$ROOT/bin/overlayctl" validate demo
# The hub UDP TAP endpoint and relay must be unreachable from the underlay.
ip netns exec "$H" ss -lntu > "$T/listeners"
! grep -E '0.0.0.0:(18[0-9]{3}|[23][0-9]{4}|[34][0-9]{4})' "$T/listeners"
node hub "$ROOT/bin/overlayctl" activate demo >/dev/null
node spoke "$ROOT/bin/overlayctl" activate demo >/dev/null
# Workload-like addresses on opposite bridges prove the active Ethernet path.
ip -n "$H" addr add 198.18.0.1/24 dev br-demo
ip -n "$S" addr add 198.18.0.2/24 dev br-demo
sleep 2
ip netns exec "$S" ping -c 3 -W 2 198.18.0.1
node hub "$ROOT/bin/overlayctl" list | python3 -c 'import json,sys; x=json.load(sys.stdin); assert len(x)==1 and x[0]["tap_bridged"]'
# Killing GOST must take down the supervisor, allowing OpenRC to respawn it.
gpid=$(cat "$T/spoke/run/demo.pid"); kill "$gpid"; sleep 1
[[ ! -e $T/spoke/run/demo.pid ]]
node spoke "$ROOT/bin/overlayctl" restart-service
sleep 2
ip netns exec "$S" ping -c 1 -W 2 198.18.0.1
# Revocation closes established transport and removes the API credential.
node hub "$ROOT/bin/peerctl" revoke "$sid"
[[ ! -s $T/hub/passwd && ! -f $T/hub/overlays/demo.conf && ! -f $T/hub/run/demo.pid ]]
[[ $(curl_spoke --user "$RELAY_USER:$RELAY_PASSWORD" -o /dev/null -w '%{http_code}' http://192.0.2.1:8080/peer-api) == 401 ]]
! ip -n "$H" link show vmo-demo >/dev/null 2>&1
echo 'overlay netns: PASS (Basic auth, TAP ARP/ICMP, activation, child cleanup, revocation, no spoke Lighttpd)'
