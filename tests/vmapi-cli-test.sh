#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

cat >"$T/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
: >"$FAKE_ARGS"
out=''
writeout=''
while (($#)); do
  printf '%s\n' "$1" >>"$FAKE_ARGS"
  case $1 in
    -o) out=$2; printf '%s\n' "$2" >>"$FAKE_ARGS"; shift 2;;
    -w) writeout=$2; printf '%s\n' "$2" >>"$FAKE_ARGS"; shift 2;;
    --config|-X|-H|--data|--data-urlencode|--data-binary|--connect-timeout)
      printf '%s\n' "$2" >>"$FAKE_ARGS"; shift 2;;
    *) shift;;
  esac
done
[[ -z $out ]] || printf '{"ok":true}\n' >"$out"
[[ -z $writeout ]] || printf '200'
MOCK
chmod +x "$T/curl"
export FAKE_ARGS="$T/args"
export VMAPI_CURL="$T/curl" VMAPI_URL='http://host.test:5186' VMAPI_USER=alice VMAPI_PASSWORD=secret

out=$(bash "$ROOT/bin/vmapi" get system)
[[ $out == *'"ok": true'* ]]
grep -Fxq 'GET' "$FAKE_ARGS"
grep -Fxq 'http://host.test:5186/api/system' "$FAKE_ARGS"

bash "$ROOT/bin/vmapi" post docker/containers name=web image=nginx:latest publish_0=8080:80 >/dev/null
grep -Fxq 'POST' "$FAKE_ARGS"
grep -Fxq 'name=web' "$FAKE_ARGS"
grep -Fxq 'image=nginx:latest' "$FAKE_ARGS"
grep -Fxq 'publish_0=8080:80' "$FAKE_ARGS"
grep -Fxq 'http://host.test:5186/api/docker/containers' "$FAKE_ARGS"

bash "$ROOT/bin/vmapi" --peer abc123 get docker/images image=alpine:latest >/dev/null
grep -Fxq 'GET' "$FAKE_ARGS"
grep -Fq 'http://host.test:5186/api/cluster/peers/abc123/proxy?path=%2Fdocker%2Fimages%3Fimage%3Dalpine%253Alatest' "$FAKE_ARGS"

printf 'hello\n' >"$T/input"
bash "$ROOT/bin/vmapi" put files/content --query path=/tmp/x --file "$T/input" --content-type application/octet-stream >/dev/null
grep -Fxq 'PUT' "$FAKE_ARGS"
grep -Fxq 'Content-Type: application/octet-stream' "$FAKE_ARGS"
grep -Fxq "@$T/input" "$FAKE_ARGS"
grep -Fq 'http://host.test:5186/api/files/content?path=%2Ftmp%2Fx' "$FAKE_ARGS"

echo 'VMAPI CLI wrapper: PASS'
