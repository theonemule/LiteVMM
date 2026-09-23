#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'sudo -n rm -rf "$T" >/dev/null 2>&1 || rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/nginx" "$T/le"
cat > "$T/vmapi.conf" <<CFG
VMAPI_PROFILE=virtualization
VMAPI_HTTP_PORT=5186
VMAPI_TLS_ENABLED=false
VMAPI_TLS_RELOAD_REQUIRED=false
VMAPI_TLS_MODE=none
VMAPI_TLS_DOMAIN=
VMAPI_TLS_CERT_FILE=
VMAPI_TLS_KEY_FILE=
VMAPI_TLS_CSR_FILE=
VMAPI_TLS_CSR_KEY_FILE=
VMAPI_TLS_CSR_DOMAIN=
VMAPI_TLS_ROOT=$T/tls
VMAPI_CERTBOT_CONFIG_DIR=$T/certbot
VMAPI_CERTBOT_WORK_DIR=$T/certbot-work
VMAPI_CERTBOT_LOGS_DIR=$T/certbot-logs
CFG
cat > "$T/nginx/vmapi" <<'NGINX'
server {
    listen 127.0.0.1:5186;
    server_name _;
}
NGINX
cat > "$T/bin/nginx" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$T/bin/systemctl" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$T/bin/certbot" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case ${1:-} in
  certonly)
    shift
    domain='' config=''
    while (($#)); do
      [[ $1 == -d ]] && { domain=$2; shift 2; continue; }
      [[ $1 == --config-dir ]] && { config=$2; shift 2; continue; }
      [[ $1 == --work-dir || $1 == --logs-dir ]] && { shift 2; continue; }
      shift
    done
    [[ -n $domain && -n $config ]]
    dir="$config/live/$domain"
    mkdir -p "$dir"
    openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj "/CN=$domain" \
      -addext "subjectAltName=DNS:$domain" -keyout "$dir/privkey.pem" -out "$dir/fullchain.pem" >/dev/null 2>&1
    ;;
  renew) exit 0;;
  *) exit 2;;
esac
MOCK
chmod +x "$T/bin/"*

run_certctl(){
  sudo -n env \
    PATH="$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    VMAPI_CONFIG="$T/vmapi.conf" \
    VMAPI_TLS_ROOT="$T/tls" \
    VMAPI_NGINX_SITE="$T/nginx/vmapi" \
    bash "$ROOT/bin/certctl" "$@"
}

out=$(run_certctl self-sign local.example.com '127.0.0.1,alt.local.example.com' 30)
[[ $out == *'"tls_enabled":true'* && $out == *'"mode":"local-ca"'* && $out == *'"local_ca_available":true'* ]]
[[ $out == *'"reload_required":true'* ]]
grep -Fqx 'VMAPI_TLS_RELOAD_REQUIRED=true' "$T/vmapi.conf"
out=$(run_certctl reload)
[[ $out == *'"reload_required":false'* ]]
grep -Fqx 'VMAPI_TLS_RELOAD_REQUIRED=false' "$T/vmapi.conf"
ca_cert=$(awk -F= '$1=="VMAPI_TLS_CA_CERT_FILE"{print $2}' "$T/vmapi.conf")
ca_key=$(awk -F= '$1=="VMAPI_TLS_CA_KEY_FILE"{print $2}' "$T/vmapi.conf")
local_cert=$(awk -F= '$1=="VMAPI_TLS_CERT_FILE"{print $2}' "$T/vmapi.conf")
local_key=$(awk -F= '$1=="VMAPI_TLS_KEY_FILE"{print $2}' "$T/vmapi.conf")
sudo -n test -s "$ca_cert" && sudo -n test -s "$ca_key" && sudo -n test -s "$local_cert" && sudo -n test -s "$local_key"
[[ $(sudo -n stat -c %a "$ca_key") == 600 ]]
sudo -n openssl x509 -in "$ca_cert" -noout -text | grep -Fq 'CA:TRUE'
sudo -n openssl verify -CAfile "$ca_cert" "$local_cert" | grep -Fq ': OK'
sudo -n openssl x509 -in "$local_cert" -noout -ext subjectAltName | grep -Fq 'DNS:local.example.com'
sudo -n openssl x509 -in "$local_cert" -noout -ext subjectAltName | grep -Fq 'IP Address:127.0.0.1'
sudo -n openssl x509 -in "$local_cert" -noout -ext subjectAltName | grep -Fq 'DNS:alt.local.example.com'
run_certctl ca-show | grep -Fq 'BEGIN CERTIFICATE'

out=$(run_certctl csr-generate demo.example.com alt.example.com 'Example Corp' Infrastructure US NC Charlotte rsa2048)
[[ $out == *'"generated":true'* ]]
sudo -n openssl req -in "$T/tls/demo.example.com.csr" -noout -text | grep -Fq 'DNS:demo.example.com, DNS:alt.example.com'
grep -Fq "VMAPI_TLS_CSR_DOMAIN=demo.example.com" "$T/vmapi.conf"
grep -Fq "VMAPI_TLS_ENABLED=true" "$T/vmapi.conf"

sudo -n openssl x509 -req -in "$T/tls/demo.example.com.csr" -signkey "$T/tls/demo.example.com.key" \
  -days 30 -copy_extensions copy -out "$T/signed.pem" >/dev/null 2>&1
out=$(run_certctl import-signed "$T/signed.pem")
[[ $out == *'"tls_enabled":true'* && $out == *'"mode":"imported-csr"'* && $out == *'"reload_required":true'* ]]
grep -Fqx 'VMAPI_TLS_CSR_FILE=' "$T/vmapi.conf"
grep -Fqx 'VMAPI_TLS_CSR_KEY_FILE=' "$T/vmapi.conf"
grep -Fqx 'VMAPI_TLS_CSR_DOMAIN=' "$T/vmapi.conf"
grep -Fq ' ssl;' "$T/nginx/vmapi"
grep -Fq 'ssl_certificate ' "$T/nginx/vmapi-tls.conf"
active_cert=$(awk -F= '$1=="VMAPI_TLS_CERT_FILE"{print $2}' "$T/vmapi.conf")
active_key=$(awk -F= '$1=="VMAPI_TLS_KEY_FILE"{print $2}' "$T/vmapi.conf")
[[ $active_cert == "$T/tls/demo.example.com.crt" ]]
[[ $active_key == "$T/tls/demo.example.com.key" ]]

run_certctl csr-generate replacement.example.com '' 'Example Corp' '' US NC Charlotte ec256 >/dev/null
[[ $(awk -F= '$1=="VMAPI_TLS_CERT_FILE"{print $2}' "$T/vmapi.conf") == "$active_cert" ]]
[[ $(awk -F= '$1=="VMAPI_TLS_KEY_FILE"{print $2}' "$T/vmapi.conf") == "$active_key" ]]
grep -Fq 'VMAPI_TLS_CSR_DOMAIN=replacement.example.com' "$T/vmapi.conf"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=direct.example.com' \
  -addext 'subjectAltName=DNS:direct.example.com' -keyout "$T/direct.key" -out "$T/direct.crt" >/dev/null 2>&1
out=$(run_certctl import-pair "$T/direct.crt" "$T/direct.key" direct.example.com)
[[ $out == *'"mode":"imported"'* && $out == *'"domain":"direct.example.com"'* && $out == *'"reload_required":true'* ]]
grep -Fq 'VMAPI_TLS_CSR_FILE=' "$T/vmapi.conf"

out=$(run_certctl reload dual 5443)
[[ $out == *'"tls_transport":"dual"'* && $out == *'"https_port":5443'* && $out == *'"reload_required":false'* ]]
grep -Fq 'listen 127.0.0.1:5186;' "$T/nginx/vmapi"
! grep -Fq 'listen 127.0.0.1:5186 ssl;' "$T/nginx/vmapi"
grep -Fq 'listen 127.0.0.1:5443 ssl;' "$T/nginx/vmapi-tls.conf"
! grep -Fq 'return 308 ' "$T/nginx/vmapi-tls.conf"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=wrong.example.com' \
  -keyout "$T/wrong.key" -out "$T/wrong.crt" >/dev/null 2>&1
if run_certctl import-pair "$T/direct.crt" "$T/wrong.key" wrong.example.com >/dev/null 2>&1; then
  echo 'mismatched certificate/key unexpectedly succeeded' >&2
  exit 1
fi

out=$(run_certctl issue le.example.com admin@example.com)
[[ $out == *'"mode":"certbot"'* && $out == *'"domain":"le.example.com"'* && $out == *'"reload_required":true'* ]]
[[ -f "$T/certbot/live/le.example.com/fullchain.pem" && -f "$T/certbot/live/le.example.com/privkey.pem" ]]
out=$(run_certctl reload redirect 5444)
[[ $out == *'"tls_transport":"redirect"'* && $out == *'"https_port":5444'* ]]
grep -Fq 'listen 127.0.0.1:5444 ssl;' "$T/nginx/vmapi-tls.conf"
grep -Fq 'return 308 https://le.example.com:5444$request_uri;' "$T/nginx/vmapi-tls.conf"
run_certctl renew >/dev/null

status=$(run_certctl status)
python3 - "$status" <<'PY'
import json,sys
x=json.loads(sys.argv[1])
assert x["tls_enabled"] is True
assert x["reload_required"] is True
assert x["mode"] == "certbot"
assert x["tls_transport"] == "redirect"
assert x["https_port"] == 5444
assert x["domain"] == "le.example.com"
assert x["certbot_available"] is True
assert x["fingerprint_sha256"]
assert x["expires"]
PY

out=$(run_certctl reload replace 5444)
[[ $out == *'"reload_required":false'* && $out == *'"tls_transport":"replace"'* ]]
grep -Fq 'listen 127.0.0.1:5186 ssl;' "$T/nginx/vmapi"
! grep -Fq 'listen 127.0.0.1:5444 ssl;' "$T/nginx/vmapi-tls.conf"

out=$(run_certctl disable)
[[ $out == *'"tls_enabled":false'* && $out == *'"tls_disabled_explicitly":true'* ]]
! grep -Fq 'listen 127.0.0.1:5186 ssl;' "$T/nginx/vmapi"
grep -Fqx 'VMAPI_TLS_DISABLED_EXPLICITLY=true' "$T/vmapi.conf"
[[ -s "$T/certbot/live/le.example.com/fullchain.pem" ]]

mkdir -p "$T/lightbin" "$T/light"
cat > "$T/lightbin/lighttpd" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
cat > "$T/lightbin/rc-service" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$T/lightbin/"*
: > "$T/light/lighttpd.conf"
run_light_certctl(){
  sudo -n env     PATH="$T/lightbin:/usr/local/bin:/usr/bin:/bin"     VMAPI_CONFIG="$T/vmapi.conf"     VMAPI_TLS_ROOT="$T/tls"     VMAPI_LIGHTTPD_TLS_CONF="$T/light/10-tls.conf"     VMAPI_LIGHTTPD_PEM="$T/light/server.pem"     VMAPI_LIGHTTPD_MAIN_CONF="$T/light/lighttpd.conf"     bash "$ROOT/bin/certctl" "$@"
}
out=$(run_light_certctl import-pair "$T/direct.crt" "$T/direct.key" direct.example.com)
[[ $out == *'"platform":"alpine"'* && $out == *'"tls_enabled":true'* && $out == *'"reload_required":true'* ]]
run_light_certctl reload | grep -Fq '"reload_required":false'
grep -Fq 'ssl.engine = "enable"' "$T/light/10-tls.conf"
sudo -n grep -Fq 'BEGIN PRIVATE KEY' "$T/light/server.pem"
sudo -n grep -Fq 'BEGIN CERTIFICATE' "$T/light/server.pem"
out=$(run_light_certctl disable)
[[ $out == *'"tls_enabled":false'* && $out == *'"tls_disabled_explicitly":true'* ]]
[[ ! -e "$T/light/10-tls.conf" && ! -e "$T/light/server.pem" ]]
grep -Fqx 'VMAPI_TLS_MODE=imported' "$T/vmapi.conf"
grep -Fqx 'VMAPI_TLS_DISABLED_EXPLICITLY=true' "$T/vmapi.conf"
sudo -n test -s "$T/tls/imported.crt"
sudo -n test -s "$T/tls/imported.key"

out=$(run_light_certctl remove)
[[ $out == *'"tls_enabled":false'* && $out == *'"tls_disabled_explicitly":true'* && $out == *'"mode":"none"'* ]]
grep -Fqx 'VMAPI_TLS_MODE=none' "$T/vmapi.conf"
grep -Fqx 'VMAPI_TLS_CERT_FILE=' "$T/vmapi.conf"
grep -Fqx 'VMAPI_TLS_KEY_FILE=' "$T/vmapi.conf"
[[ ! -e "$T/tls/imported.crt" && ! -e "$T/tls/imported.key" ]]
sudo -n test -s "$T/tls/litevmm-root-ca.crt"
sudo -n test -s "$T/tls/litevmm-root-ca.key"

# Container config is a symlink into persistent storage. Certificate updates
# must write through it without replacing the link.
mkdir -p "$T/persistent"
cp "$T/vmapi.conf" "$T/persistent/vmapi.conf"
ln -s "$T/persistent/vmapi.conf" "$T/vmapi-link.conf"
sudo -n env PATH="$T/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" VMAPI_CONFIG="$T/vmapi-link.conf" VMAPI_TLS_ROOT="$T/tls" VMAPI_NGINX_SITE="$T/nginx/vmapi" bash "$ROOT/bin/certctl" disable >/dev/null
[[ -L "$T/vmapi-link.conf" ]]
grep -Fqx 'VMAPI_TLS_ENABLED=false' "$T/persistent/vmapi.conf"

echo 'certificate lifecycle: PASS'
