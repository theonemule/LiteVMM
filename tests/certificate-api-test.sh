#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/seen"
cat > "$T/vmapi.conf" <<CFG
VMAPI_PROFILE=virtualization
VMAPI_HTTP_PORT=5186
VMAPI_TLS_ENABLED=false
VMAPI_BACKPLANE_SERVER=false
VM_ROOT=$T/vms
DISK_ROOT=$T/disks
ISO_ROOT=$T/isos
CFG
cat > "$T/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
set -e
[[ ${1:-} == -n ]] && shift
exec "$@"
MOCK
cat > "$T/bin/certctl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
  import-pair)
    cp "$2" "$FAKE_CERT_DIR/cert.pem"
    cp "$3" "$FAKE_CERT_DIR/key.pem"
    printf '%s' "$4" > "$FAKE_CERT_DIR/domain"
    printf '{"imported":true}\n'
    ;;
  import-signed)
    cp "$2" "$FAKE_CERT_DIR/signed.pem"
    printf '{"imported":true}\n'
    ;;
  status) printf '{"tls_enabled":false,"mode":"none","certbot_available":false}\n';;
  *) printf '{"ok":true}\n';;
esac
MOCK
chmod +x "$T/bin/sudo" "$T/bin/certctl"

cert=$'-----BEGIN CERTIFICATE-----\nA+B/C==\n-----END CERTIFICATE-----'
key=$'-----BEGIN PRIVATE KEY-----\nZ+Y/X==\n-----END PRIVATE KEY-----'
body=$(python3 - "$cert" "$key" <<'PY'
import sys, urllib.parse
print(urllib.parse.urlencode({
    "domain":"api.example.com",
    "certificate":sys.argv[1],
    "private_key":sys.argv[2],
}))
PY
)
out=$(printf '%s' "$body" | \
  PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" \
  FAKE_CERT_DIR="$T/seen" \
  REQUEST_METHOD=POST \
  PATH_INFO=/api/admin/certificates/import \
  CONTENT_TYPE='application/x-www-form-urlencoded;charset=UTF-8' \
  CONTENT_LENGTH=${#body} \
  VMAPI_CONFIG="$T/vmapi.conf" \
  VMAPI_LIB="$ROOT/lib/common.sh" \
  CERTCTL="$T/bin/certctl" \
  bash "$ROOT/cgi/api.cgi")
grep -Fq 'Status: 200 OK' <<< "$out"
cmp -s <(printf '%s\n' "$cert") "$T/seen/cert.pem"
cmp -s <(printf '%s\n' "$key") "$T/seen/key.pem"
[[ $(cat "$T/seen/domain") == api.example.com ]]

body=$(python3 - "$cert" <<'PY'
import sys, urllib.parse
print(urllib.parse.urlencode({"certificate":sys.argv[1]}))
PY
)
out=$(printf '%s' "$body" | \
  PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" \
  FAKE_CERT_DIR="$T/seen" \
  REQUEST_METHOD=POST \
  PATH_INFO=/api/admin/certificates/signed \
  CONTENT_TYPE='application/x-www-form-urlencoded;charset=UTF-8' \
  CONTENT_LENGTH=${#body} \
  VMAPI_CONFIG="$T/vmapi.conf" \
  VMAPI_LIB="$ROOT/lib/common.sh" \
  CERTCTL="$T/bin/certctl" \
  bash "$ROOT/cgi/api.cgi")
grep -Fq 'Status: 200 OK' <<< "$out"
cmp -s <(printf '%s\n' "$cert") "$T/seen/signed.pem"


out=$(printf '' | \
  PATH="$T/bin:/usr/local/bin:/usr/bin:/bin" \
  FAKE_CERT_DIR="$T/seen" \
  REQUEST_METHOD=POST \
  PATH_INFO=/api/admin/certificates/remove \
  CONTENT_TYPE='application/x-www-form-urlencoded;charset=UTF-8' \
  CONTENT_LENGTH=0 \
  VMAPI_CONFIG="$T/vmapi.conf" \
  VMAPI_LIB="$ROOT/lib/common.sh" \
  CERTCTL="$T/bin/certctl" \
  bash "$ROOT/cgi/api.cgi")
grep -Fq 'Status: 200 OK' <<< "$out"
grep -Fq '"ok":true' <<< "$out"

echo 'certificate API PEM transport: PASS'
