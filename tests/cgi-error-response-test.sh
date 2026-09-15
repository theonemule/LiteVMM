#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/failing-vmctl" <<'EOF'
#!/usr/bin/env bash
echo 'qemu-img: failed to create disk image' >&2
exit 1
EOF
chmod 0755 "$tmp/failing-vmctl"

# The POST handler intentionally discards successful vmctl output.  A failure
# must nevertheless reach the client as JSON rather than disappearing and
# becoming a Lighttpd 502 due to a CGI process that emitted no headers.
response=$(printf 'name=testvm' | env \
  VMAPI_LIB="$ROOT/lib/common.sh" VMCTL="$tmp/failing-vmctl" \
  VM_ROOT="$tmp/vms" IMAGE_ROOT="$tmp/images" \
  REQUEST_METHOD=POST PATH_INFO=/vms CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH=11 \
  "$ROOT/cgi/api.cgi") || cgi_status=$?

[[ ${cgi_status:-0} -ne 0 ]]
[[ $response == *'Status: 400 Bad Request'* ]]
[[ $response == *'qemu-img: failed to create disk image'* ]]
echo 'cgi error response: PASS'
