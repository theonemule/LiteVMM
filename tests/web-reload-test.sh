#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: starts a private Lighttpd + fcgiwrap on a loopback port under a temp
# directory; it does not modify repository files or any system service.
#
# Regression: overlay/cert/registry changes rewrite Lighttpd routes from inside
# the API request that asked for them. Restarting Lighttpd there dropped that
# request's connection, so the change succeeded but the browser showed
# "Failed to fetch". vmapi-web-reload must let the request finish first.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
for cmd in lighttpd spawn-fcgi fcgiwrap curl flock setsid; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "web reload: SKIP (missing $cmd)"; exit 0; }
done
T=$(mktemp -d)
cleanup() {
  local f p
  for f in "$T/lighttpd.pid" "$T/fcgi.pid"; do
    [[ -r $f ]] && p=$(cat "$f") && kill "$p" 2>/dev/null || true
  done
  pkill -f "$ROOT/bin/vmapi-web-reload --after" 2>/dev/null || true
  rm -rf -- "$T"
}
trap cleanup EXIT
fail() { echo "web reload: FAIL - $*" >&2; [[ -r $T/error.log ]] && tail -5 "$T/error.log" >&2; exit 1; }

PORT=$((20000 + RANDOM % 20000))
mkdir -p "$T/www" "$T/conf.d"
echo old-route > "$T/www/old.txt"; echo new-route > "$T/www/new.txt"
echo '# no overlay routes yet' > "$T/conf.d/10-overlay.conf"
cat > "$T/lighttpd.conf" <<EOF
server.document-root = "$T/www"
server.bind = "127.0.0.1"
server.port = $PORT
server.pid-file = "$T/lighttpd.pid"
server.errorlog = "$T/error.log"
server.modules += ( "mod_fastcgi", "mod_alias" )
fastcgi.server = ( ".cgi" => (( "socket" => "$T/fcgi.sock", "check-local" => "disable" )) )
include_shell "cat $T/conf.d/*.conf"
EOF

# Stand-in for api.cgi -> sudo overlayctl create: hold overlayctl's fd-8
# mutation lock, publish a new route, reload, keep working, then answer.
cat > "$T/www/create.cgi" <<EOF
#!/usr/bin/env bash
set -euo pipefail
route=\$(sed -n 's/^QUERY=//p' <<< "QUERY=\${QUERY_STRING:-}")
out=\$(
  exec 8>"$T/overlay.lock"; flock -x 8
  if [[ \$route == invalid ]]; then echo 'this is not lighttpd syntax' > "$T/conf.d/10-overlay.conf"
  else echo 'alias.url += ( "/overlay/test" => "$T/www/new.txt" )' > "$T/conf.d/10-overlay.conf"; fi
  VMAPI_LIGHTTPD_CONF="$T/lighttpd.conf" VMAPI_WEB_RELOAD_SETTLE=2 "$ROOT/bin/vmapi-web-reload" 2>&1 || { echo RELOAD_REJECTED; exit 0; }
  sleep 0.5   # overlayctl continues: restart vmapi-overlay, wait_ready, show
  echo '{"name":"test"}'
)
printf 'Status: 201 Created\r\nContent-Type: application/json\r\n\r\n%s\n' "\$out"
EOF
chmod +x "$T/www/create.cgi"

spawn-fcgi -s "$T/fcgi.sock" -M 0600 -F 1 -P "$T/fcgi.pid" -- "$(command -v fcgiwrap)" -c 2 >/dev/null
lighttpd -f "$T/lighttpd.conf"
for _ in {1..50}; do curl -sf "http://127.0.0.1:$PORT/old.txt" >/dev/null 2>&1 && break; sleep .1; done
master=$(cat "$T/lighttpd.pid")
[[ $(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/overlay/test") == 404 ]] || fail 'route existed before creation'

# 1. The request that triggers the reload receives its complete response.
start=$(date +%s%N)
body=$(curl -sS -m 20 -w '\n%{http_code}' -d x "http://127.0.0.1:$PORT/create.cgi") || fail "request was cut off: $body"
elapsed_ms=$(( ($(date +%s%N) - start) / 1000000 ))
[[ ${body##*$'\n'} == 201 ]] || fail "expected HTTP 201, got: $body"
grep -Fq '{"name":"test"}' <<< "$body" || fail "response body lost: $body"
grep -Fq 'vmapi-web-reload' <<< "$body" && fail "helper wrote to stderr on success, corrupting JSON: $body"
# The detached waiter must not hold the CGI's pipes (that would stall until reload).
((elapsed_ms < 3000)) || fail "response stalled ${elapsed_ms}ms waiting on the reload worker"

# 2. The waiter must not inherit overlayctl's fd-8 flock.
# The CGI releases it before answering, so it must be free right now.
flock -n -x "$T/overlay.lock" true || fail 'overlay mutation lock still held after the request finished'

# 3. The new route goes live, served by the same (gracefully reloaded) master.
live=false
for _ in {1..60}; do
  [[ $(curl -s -m 1 "http://127.0.0.1:$PORT/overlay/test" 2>/dev/null) == new-route ]] && { live=true; break; }
  sleep .25
done
$live || fail 'new route never became live'
[[ $(cat "$T/lighttpd.pid") == "$master" ]] && kill -0 "$master" 2>/dev/null || fail 'lighttpd master changed: a restart occurred instead of a graceful reload'

# 4. An invalid configuration is rejected and the running server keeps serving.
body=$(curl -sS -m 20 -d x "http://127.0.0.1:$PORT/create.cgi?invalid") || fail "request cut off on invalid config: $body"
grep -Fq RELOAD_REJECTED <<< "$body" || fail "invalid configuration was not rejected: $body"
sleep 1.5
[[ $(curl -s -m 2 "http://127.0.0.1:$PORT/overlay/test") == new-route ]] || fail 'server stopped serving after an invalid configuration'

echo 'web reload: PASS'
