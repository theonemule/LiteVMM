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

run_a() {
  PATH="$T/bin:$PATH" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/a/peers" VMAPI_IDENTITY_ROOT="$T/a/identity" VMAPI_NODE_ID_FILE="$T/a/node-id" VMAPI_PEER_NONCE_ROOT="$T/a/nonces" VMAPI_PEER_PASSWD_FILE="$T/a/passwd" VMAPI_OVERLAYCTL=/nonexistent VMCTL=true BACKUPCTL=true "$ROOT/bin/peerctl" "$@"
}
run_b() {
  PATH="$T/bin:$PATH" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/b/peers" VMAPI_IDENTITY_ROOT="$T/b/identity" VMAPI_NODE_ID_FILE="$T/b/node-id" VMAPI_PEER_NONCE_ROOT="$T/b/nonces" VMAPI_PEER_PASSWD_FILE="$T/b/passwd" VMAPI_OVERLAYCTL=/nonexistent VMCTL=true BACKUPCTL=true "$ROOT/bin/peerctl" "$@"
}

request=$(run_a request node-a https://node-a.example)
# Exporting again before a response arrives must preserve the original bundle.
# Otherwise a user can accidentally invalidate the file already moved to node B.
[[ $(run_a request renamed-node-a https://node-a.example) == "$request" ]]
response=$(run_b accept "$request" node-b https://node-b.example)
complete=$(run_a complete "$response")
grep -q '"trusted":true' <<< "$complete"

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

# Both hosts hash the identical paired HTTP credential; no signature headers.
source "$T/a/peers/$b_id.conf"
htpasswd -vb "$T/a/passwd" "$RELAY_USER" "$RELAY_PASSWORD" >/dev/null 2>&1
htpasswd -vb "$T/b/passwd" "$RELAY_USER" "$RELAY_PASSWORD" >/dev/null 2>&1
run_b authorize-user "$RELAY_USER"
if run_b authorize-user not-paired >/dev/null 2>&1; then exit 1; fi
cat > "$T/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
credential='' target=''
while (($#)); do
  case "$1" in
    --user) credential=$2; shift 2;;
    --header) [[ $2 != X-VMAPI-* ]] || exit 1; shift 2;;
    --request|--connect-timeout|--max-time|--data-binary) shift 2;;
    --fail-with-body|--show-error|--silent|--basic) shift;;
    *) target=$1; shift;;
  esac
done
[[ $target == https://node-b.example/peer-api/* ]]
htpasswd -vb "$VMAPI_TEST_TMP/b/passwd" "${credential%%:*}" "${credential#*:}" >/dev/null 2>&1
printf '{"ok":true}\n'
MOCK
chmod +x "$T/curl"

result=$(PATH="$T/bin:$PATH" VMAPI_TEST_ROOT="$ROOT" VMAPI_TEST_TMP="$T" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/a/peers" VMAPI_IDENTITY_ROOT="$T/a/identity" VMAPI_NODE_ID_FILE="$T/a/node-id" VMAPI_PEER_NONCE_ROOT="$T/a/nonces" CURL_BIN="$T/curl" "$ROOT/bin/peerctl" proxy "$b_id" GET /vms)
[[ $result == '{"ok":true}' ]]
result=$(PATH="$T/bin:$PATH" VMAPI_TEST_ROOT="$ROOT" VMAPI_TEST_TMP="$T" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_PEER_ROOT="$T/a/peers" VMAPI_IDENTITY_ROOT="$T/a/identity" VMAPI_NODE_ID_FILE="$T/a/node-id" VMAPI_PEER_NONCE_ROOT="$T/a/nonces" CURL_BIN="$T/curl" "$ROOT/bin/peerctl" proxy "$b_id" GET '/docker/networks?name=overlay-net')
[[ $result == '{"ok":true}' ]]

# Revocation removes API/upgrade credentials from the shared database.
run_b revoke "$a_id"
[[ ! -s $T/b/passwd ]]
if run_b authorize-user "$RELAY_USER" >/dev/null 2>&1; then exit 1; fi
# A second pairing from the same host gets a distinct username.
request2=$(run_a request node-a https://node-a.example)
[[ $request2 != "$request" ]]
echo 'peer smoke: PASS' 
