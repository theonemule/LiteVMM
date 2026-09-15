#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf -- "$T"' EXIT
mkdir -p "$T/bin"

cat > "$T/bin/sudo" <<'MOCK'
#!/usr/bin/env bash
[[ ${1:-} == -n ]] && shift
exec "$@"
MOCK
chmod +x "$T/bin/sudo"

cat > "$T/bin/peerctl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ $1 == authorize-user ]] || exit 1
printf '%s\n' "$2" >> "$VMAPI_VERIFY_LOG"
MOCK
chmod +x "$T/bin/peerctl"

verify_uri() {
  local request_uri=$1 path_info=$2
  : > "$T/verify.log"
  REQUEST_METHOD=GET REQUEST_URI="$request_uri" PATH_INFO="$path_info" QUERY_STRING='filter=ready&limit=10' \
    PATH="$T/bin:$PATH" VMAPI_PEER_API=true AUTH_TYPE=Basic REMOTE_USER=paired-user VMAPI_LIB="$ROOT/lib/common.sh" PEERCTL="$T/bin/peerctl" VMAPI_VERIFY_LOG="$T/verify.log" \
    "$ROOT/cgi/api.cgi" >/dev/null
  cat "$T/verify.log"
}

canonical=$(verify_uri '/peer-api/docker/images?filter=ready&limit=10' '/peer-api/docker/images')
rewritten=$(verify_uri '/peer-api.cgi/docker/images' '/peer-api.cgi/docker/images')
[[ $canonical == paired-user ]]
[[ $rewritten == "$canonical" ]]

canonical_base=$(verify_uri '/peer-api?filter=ready&limit=10' '/peer-api')
rewritten_base=$(verify_uri '/peer-api.cgi' '/peer-api.cgi')
[[ $canonical_base == paired-user ]]
[[ $rewritten_base == "$canonical_base" ]]

for uri in /peer-api /peer-api.cgi /peer-api.cgi/cluster/identity; do
  output=$(REQUEST_METHOD=GET REQUEST_URI="$uri" PATH_INFO="$uri" VMAPI_LIB="$ROOT/lib/common.sh" AUTH_TYPE='' REMOTE_USER='' "$ROOT/cgi/api.cgi")
  [[ $output == *'401 Unauthorized'* ]]
done
echo 'peer CGI authentication and URI: PASS' 
