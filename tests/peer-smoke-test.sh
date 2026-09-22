#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT

# Git Bash's temporary mount cannot chmod nested directories. The production
# commands still set 0700/0600; this tiny test shim only makes the smoke test
# portable to that mount.
mkdir -p "$T/bin"
cat > "$T/bin/install" <<'MOCK'
#!/usr/bin/env bash
if [[ ${1:-} == -d ]]; then
  target=${!#}
  mkdir -p "$target"
  exit 0
fi
exec /usr/bin/install "$@"
MOCK
chmod +x "$T/bin/install"
cat > "$T/bin/chown" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK
chmod +x "$T/bin/chown"
cat > "$T/bin/htpasswd" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == -vb ]] || exit 2
file=$2 user=$3 password=$4
hash=$(awk -F: -v u="$user" '$1==u{print $2}' "$file")
[[ -n $hash ]] || exit 1
IFS='$' read -r _ scheme salt rest <<< "$hash"
calc=$(printf '%s\n' "$password" | openssl passwd -apr1 -salt "$salt" -stdin)
[[ $calc == "$hash" ]]
MOCK
chmod +x "$T/bin/htpasswd"

openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=LiteVMM A Root' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -keyout "$T/a-ca.key" -out "$T/a-ca.crt" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -days 30 -subj '/CN=LiteVMM B Root' -addext 'basicConstraints=critical,CA:TRUE,pathlen:0' -keyout "$T/b-ca.key" -out "$T/b-ca.crt" >/dev/null 2>&1

run_a() {
  PATH="$T/bin:$PATH" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/a/peers" VMAPI_IDENTITY_ROOT="$T/a/identity" VMAPI_NODE_ID_FILE="$T/a/node-id" VMAPI_PEER_NONCE_ROOT="$T/a/nonces" VMAPI_PEER_PASSWD_FILE="$T/a/passwd" VMAPI_OVERLAYCTL=/nonexistent VMAPI_TLS_ENABLED=true VMAPI_TLS_MODE=local-ca VMAPI_TLS_CA_CERT_FILE="$T/a-ca.crt" VMCTL=true BACKUPCTL=true bash "$ROOT/bin/peerctl" "$@"
}
run_b() {
  PATH="$T/bin:$PATH" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/b/peers" VMAPI_IDENTITY_ROOT="$T/b/identity" VMAPI_NODE_ID_FILE="$T/b/node-id" VMAPI_PEER_NONCE_ROOT="$T/b/nonces" VMAPI_PEER_PASSWD_FILE="$T/b/passwd" VMAPI_OVERLAYCTL=/nonexistent VMAPI_TLS_ENABLED=true VMAPI_TLS_MODE=local-ca VMAPI_TLS_CA_CERT_FILE="$T/b-ca.crt" VMCTL=true BACKUPCTL=true bash "$ROOT/bin/peerctl" "$@"
}

request=$(run_a request node-a https://node-a.example)
# Exporting again before a response arrives must preserve the original bundle.
# Otherwise a user can accidentally invalidate the file already moved to node B.
[[ $(run_a request renamed-node-a https://node-a.example) == "$request" ]]
response=$(run_b accept "$request" node-b https://node-b.example)
complete=$(run_a complete "$response")
grep -q '"trusted":true' <<< "$complete"
grep -q '"tls_ca":true' <<< "$complete"

a_id=$(run_a identity | sed -nE 's/.*"node_id":"([^"]+)".*/\1/p')
b_id=$(run_b identity | sed -nE 's/.*"node_id":"([^"]+)".*/\1/p')
grep -q "$b_id" <<< "$(run_a list)"
grep -q "$a_id" <<< "$(run_b list)"

run_a set-url "$b_id" https://node-b.example
[[ $(run_a cors-origin https://node-b.example) == https://node-b.example ]]
credential=$(run_a overlay-credentials "$b_id")
grep -q '"username":"relay_' <<< "$credential"
grep -q '"password":"[0-9a-f]' <<< "$credential"
profile=$(run_a overlay-profile "$b_id")
grep -q '"endpoint":"wss://node-b.example/overlay"' <<< "$profile"
grep -q '"username":"relay_' <<< "$profile"
transport=$(run_a transport-profile "$b_id")
grep -q '"endpoint":"wss://node-b.example"' <<< "$transport"
grep -q '"username":"relay_' <<< "$transport"
grep -q '"ca_file":"' <<< "$transport"
source "$T/a/peers/$b_id.conf"
[[ -r $TLS_CA_FILE ]]
openssl verify -CAfile "$T/b-ca.crt" "$TLS_CA_FILE" >/dev/null
[[ $(openssl x509 -in "$T/b-ca.crt" -noout -fingerprint -sha256) == "$(openssl x509 -in "$TLS_CA_FILE" -noout -fingerprint -sha256)" ]]

# Both hosts hash the identical paired HTTP credential; no signature headers.
source "$T/a/peers/$b_id.conf"
"$T/bin/htpasswd" -vb "$T/a/passwd" "$RELAY_USER" "$RELAY_PASSWORD" >/dev/null 2>&1
"$T/bin/htpasswd" -vb "$T/b/passwd" "$RELAY_USER" "$RELAY_PASSWORD" >/dev/null 2>&1
run_b authorize-user "$RELAY_USER"
if run_b authorize-user not-paired >/dev/null 2>&1; then exit 1; fi
cat > "$T/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
credential='' target=''
while (($#)); do
  case "$1" in
    --user) credential=$2; shift 2;;
    --cacert) [[ -r $2 ]] || exit 1; grep -Fq 'BEGIN CERTIFICATE' "$2" || exit 1; shift 2;;
    --header) [[ $2 != X-VMAPI-* ]] || exit 1; shift 2;;
    --request|--connect-timeout|--max-time|--data-binary) shift 2;;
    --fail-with-body|--show-error|--silent|--basic) shift;;
    *) target=$1; shift;;
  esac
done
[[ $target == https://node-b.example/peer-api/* ]]
"$VMAPI_TEST_TMP/bin/htpasswd" -vb "$VMAPI_TEST_TMP/b/passwd" "${credential%%:*}" "${credential#*:}" >/dev/null 2>&1
printf '{"ok":true}\n'
MOCK
chmod +x "$T/curl"

result=$(PATH="$T/bin:$PATH" VMAPI_TEST_ROOT="$ROOT" VMAPI_TEST_TMP="$T" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/a/peers" VMAPI_IDENTITY_ROOT="$T/a/identity" VMAPI_NODE_ID_FILE="$T/a/node-id" VMAPI_PEER_NONCE_ROOT="$T/a/nonces" CURL_BIN="$T/curl" bash "$ROOT/bin/peerctl" proxy "$b_id" GET /vms)
[[ $result == '{"ok":true}' ]]
result=$(PATH="$T/bin:$PATH" VMAPI_TEST_ROOT="$ROOT" VMAPI_TEST_TMP="$T" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/a/peers" VMAPI_IDENTITY_ROOT="$T/a/identity" VMAPI_NODE_ID_FILE="$T/a/node-id" VMAPI_PEER_NONCE_ROOT="$T/a/nonces" CURL_BIN="$T/curl" bash "$ROOT/bin/peerctl" proxy "$b_id" GET '/docker/networks?name=overlay-net')
[[ $result == '{"ok":true}' ]]

# Migration uses a transient archive, streams it to the paired API, and only
# deletes the source VM after the peer import succeeds.
cat > "$T/migrate-vmctl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
case "$1" in
  status) printf 'stopped\n';;
  delete) printf '%s\n' "$2" >> "$VMAPI_MIGRATE_DELETE_LOG";;
  *) exit 2;;
esac
MOCK
cat > "$T/migrate-backupctl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == create ]] || exit 2
vm=$2; shift 2; destination=''
while (($#)); do case "$1" in --destination) destination=$2; shift 2;; *) shift;; esac; done
[[ -n $destination ]] || exit 3
mkdir -p "$destination/$vm"
archive="$vm-migration-test.tar.gz"
printf 'migration-payload' > "$destination/$vm/$archive"
printf '%s\n' "$destination" > "$VMAPI_MIGRATE_SCRATCH_LOG"
printf '{"vm":"%s","archive":"%s","path":"%s/%s/%s"}\n' "$vm" "$archive" "$destination" "$vm" "$archive"
MOCK
cat > "$T/migrate-curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
method=GET; target=''
while (($#)); do
  case "$1" in
    --request) method=$2; shift 2;;
    --user|--connect-timeout|--max-time|--header|--data-binary|--cacert) shift 2;;
    --fail-with-body|--show-error|--silent|--basic) shift;;
    *) target=$1; shift;;
  esac
done
case "$method:$target" in
  GET:*/peer-api/vms) printf '[]\n';;
  POST:*/peer-api/migrations/import/*) cat > "$VMAPI_MIGRATE_BODY"; printf '{"imported":true}\n';;
  *) exit 22;;
esac
MOCK
chmod +x "$T/migrate-vmctl" "$T/migrate-backupctl" "$T/migrate-curl"
: > "$T/migrate-delete.log"
PATH="$T/bin:$PATH" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/a/peers" VMAPI_IDENTITY_ROOT="$T/a/identity" VMAPI_NODE_ID_FILE="$T/a/node-id" VMAPI_PEER_NONCE_ROOT="$T/a/nonces" CURL_BIN="$T/migrate-curl" VMAPI_VMCTL="$T/migrate-vmctl" VMAPI_BACKUPCTL="$T/migrate-backupctl" VMAPI_MIGRATE_DELETE_LOG="$T/migrate-delete.log" VMAPI_MIGRATE_SCRATCH_LOG="$T/migrate-scratch.log" VMAPI_MIGRATE_BODY="$T/migrate-body" bash "$ROOT/bin/peerctl" migrate demo "$b_id" >/dev/null
grep -qx demo "$T/migrate-delete.log"
grep -qx 'migration-payload' "$T/migrate-body"
scratch=$(cat "$T/migrate-scratch.log")
[[ ! -e $scratch ]]

# Revocation removes API/upgrade credentials from the shared database.
run_b revoke "$a_id"
[[ ! -s $T/b/passwd ]]
if run_b authorize-user "$RELAY_USER" >/dev/null 2>&1; then exit 1; fi
# A second pairing from the same host gets a distinct username.
request2=$(run_a request node-a https://node-a.example)
[[ $request2 != "$request" ]]
echo 'peer smoke: PASS' 
