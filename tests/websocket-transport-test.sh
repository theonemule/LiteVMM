#!/usr/bin/env bash
# Real byte-stream tests for LiteVMM's websocat backplane and console bridges.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WEBSOCAT=${VMAPI_TEST_WEBSOCAT:-$(command -v websocat 2>/dev/null || true)}
[[ -n $WEBSOCAT && -x $WEBSOCAT ]] || { echo 'websocket transport: SKIP (set VMAPI_TEST_WEBSOCAT)'; exit 0; }
command -v socat >/dev/null 2>&1 || { echo 'websocket transport: SKIP (socat unavailable)'; exit 0; }
T=$(mktemp -d)
BP_LOCAL=$((24000 + RANDOM % 1000)); BP_WS=$((25000 + RANDOM % 1000)); BP_ECHO=$((26000 + RANDOM % 1000))
CON_WS=$((27000 + RANDOM % 1000)); CON_ECHO=$((28000 + RANDOM % 1000))
peer=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
pids=()
cleanup(){ set +e; for p in "${pids[@]}"; do kill "$p" 2>/dev/null || true; done; rm -rf -- "$T"; }
trap cleanup EXIT

cat >"$T/peerctl" <<PEERCTL
#!/usr/bin/env bash
case "\${1:-}" in
  transport-profile) printf '%s\n' '{"endpoint":"ws://127.0.0.1:$BP_WS","username":"probe","password":"0123456789abcdef0123456789abcdef0123456789abcdef","ca_file":""}';;
  *) exit 2;;
esac
PEERCTL
chmod +x "$T/peerctl"

socat "TCP-LISTEN:$BP_ECHO,bind=127.0.0.1,reuseaddr,fork" EXEC:/bin/cat >/dev/null 2>&1 & pids+=("$!")
"$WEBSOCAT" --binary --exit-on-eof "ws-l:127.0.0.1:$BP_WS" "tcp:127.0.0.1:$BP_ECHO" >/dev/null 2>"$T/bp-server.log" & pids+=("$!")
sleep .2
export VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEERCTL="$T/peerctl" VMAPI_WEBSOCAT="$WEBSOCAT"
export VMAPI_BACKPLANE_RUN_ROOT="$T/bp-run" VMAPI_BACKPLANE_STATE_ROOT="$T/bp-state" VMAPI_BACKPLANE_ROOT="$T/backplane" VMAPI_BACKPLANE_MOUNT_ROOT="$T/mounts"
source <(sed '/^case ${1:-help} in/,$d' "$ROOT/bin/backplanectl")
ensure_dirs
start_tunnel "$peer" "$BP_LOCAL"
pids+=("$(cat "$(pid_file "$peer")")")
python3 - "$BP_LOCAL" <<'PY'
import socket,sys
port=int(sys.argv[1]); payload=b'litevmm-backplane-websocket-probe'
s=socket.create_connection(('127.0.0.1',port),timeout=3); s.sendall(payload)
buf=b''
while len(buf)<len(payload):
    part=s.recv(4096)
    if not part: break
    buf+=part
assert buf==payload,(buf,payload)
PY
echo 'backplane TCP-WebSocket-TCP: PASS'

# The paired credential must never be visible on the process command line.
bp_cmdline=$(tr '\0' '\n' < "/proc/$(cat "$(pid_file "$peer")")/cmdline")
! grep -qx -- '--basic-auth' <<< "$bp_cmdline" || { echo 'backplane credential passed on the command line' >&2; exit 1; }
! grep -Fq '0123456789abcdef0123456789abcdef0123456789abcdef' <<< "$bp_cmdline" || { echo 'backplane password visible on the command line' >&2; exit 1; }
echo 'backplane credential not on command line: PASS'

# Real Lighttpd peer-realm authentication in front of the backplane bridge, as
# on a deployed host. This is the path that rejects a mis-encoded credential.
if command -v lighttpd >/dev/null 2>&1 && command -v openssl >/dev/null 2>&1; then
  LT_PORT=$((29000 + RANDOM % 1000)); BP_LOCAL2=$((30000 + RANDOM % 1000)); mkdir -p "$T/lt"
  printf 'probe:%s\n' "$(printf '%s\n' 0123456789abcdef0123456789abcdef0123456789abcdef | openssl passwd -apr1 -stdin)" > "$T/lt/peers.htpasswd"
  cat > "$T/lt/lighttpd.conf" <<LIGHTY
server.document-root = "$T/lt"
server.bind = "127.0.0.1"
server.port = $LT_PORT
server.errorlog = "$T/lt/error.log"
server.modules += ( "mod_auth", "mod_authn_file", "mod_proxy" )
\$HTTP["url"] =~ "^/backplane/storage(?:/|\$)" {
  auth.backend = "htpasswd"
  auth.backend.htpasswd.userfile = "$T/lt/peers.htpasswd"
  auth.require = ( "" => ( "method" => "basic", "realm" => "VMAPI peers", "require" => "valid-user" ) )
  proxy.server = ( "" => (( "host" => "127.0.0.1", "port" => $BP_WS )) )
  proxy.header = ( "upgrade" => "enable" )
}
LIGHTY
  lighttpd -D -f "$T/lt/lighttpd.conf" </dev/null >/dev/null 2>&1 & pids+=("$!")
  for _ in {1..50}; do (exec 3<>"/dev/tcp/127.0.0.1/$LT_PORT") 2>/dev/null && break; sleep .1; done
  lt_probe(){ python3 - "$1" <<'PY2'
import socket,sys
port=int(sys.argv[1]); payload=b'litevmm-backplane-through-lighttpd'
s=socket.create_connection(('127.0.0.1',port),timeout=5); s.sendall(payload); buf=b''
try:
    while len(buf)<len(payload):
        part=s.recv(4096)
        if not part: break
        buf+=part
except (socket.timeout, ConnectionError): pass
sys.exit(0 if buf==payload else 1)
PY2
  }
  cat >"$T/peerctl" <<PEERCTL
#!/usr/bin/env bash
printf '%s\n' '{"endpoint":"ws://127.0.0.1:$LT_PORT","username":"probe","password":"0123456789abcdef0123456789abcdef0123456789abcdef","ca_file":""}'
PEERCTL
  start_tunnel "$peer" "$BP_LOCAL2"; pids+=("$(cat "$(pid_file "$peer")")")
  lt_probe "$BP_LOCAL2" || { echo 'backplane through Lighttpd Basic auth: FAIL'; tail -n 5 "$T/lt/error.log" "$(log_file "$peer")"; exit 1; }
  echo 'backplane through Lighttpd Basic auth: PASS'
  BP_LOCAL3=$((31000 + RANDOM % 1000))
  sed -i 's/0123456789abcdef0123456789abcdef0123456789abcdef/fedcba9876543210fedcba9876543210fedcba9876543210/' "$T/peerctl"
  start_tunnel "$peer" "$BP_LOCAL3"; pids+=("$(cat "$(pid_file "$peer")")")
  ! lt_probe "$BP_LOCAL3" || { echo "negative assertion failed: tests/websocket-transport-test.sh:97" >&2; exit 1; }
  echo 'backplane wrong credential rejected by Lighttpd: PASS'
else
  echo 'backplane through Lighttpd: SKIP (lighttpd unavailable)'
fi

socat "TCP-LISTEN:$CON_ECHO,bind=127.0.0.1,reuseaddr,fork" EXEC:/bin/cat >/dev/null 2>&1 & pids+=("$!")
export VMAPI_CONSOLE_STATE_DIR="$T/console" VMAPI_WEBSOCAT="$WEBSOCAT"
source <(sed '/^case "${1:-help}" in/,$d' "$ROOT/bin/consolectl")
init_state
start_forwarder testvm tok123 127.0.0.1 "$CON_ECHO" "$CON_WS"
pids+=("$(cat "$(pid_file testvm)")")
printf 'litevmm-console-websocket-probe' | timeout 5 "$WEBSOCAT" --binary -1 "ws://127.0.0.1:$CON_WS/console/ws/tok123" >"$T/console.out"
[[ $(cat "$T/console.out") == litevmm-console-websocket-probe ]]
echo 'console WebSocket-TCP: PASS'
echo 'websocket transports: PASS'
