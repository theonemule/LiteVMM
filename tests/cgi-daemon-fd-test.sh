#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/daemon-vmctl" <<'EOF'
#!/usr/bin/env bash
# Simulate qemu -daemonize: close normal stdio, retain any inherited extras,
# and return the PID immediately.  Holding FastCGI's saved response stream
# would otherwise keep the HTTP request open.
( exec 1>&- 2>&-; sleep 2 ) &
printf '%s\n' "$!"
EOF
chmod 0755 "$tmp/daemon-vmctl"

mkdir -p "$tmp/vms/demo/runtime"
cat > "$tmp/vms/demo/vm.conf" <<'EOF'
NAME=demo
EOF

response=$(timeout 1 bash -c 'REQUEST_METHOD=POST PATH_INFO=/vms/demo/start VMAPI_LIB="$1/lib/common.sh" VMCTL="$2/daemon-vmctl" VM_ROOT="$2/vms" IMAGE_ROOT="$2/images" "$1/cgi/api.cgi"' _ "$ROOT" "$tmp")
[[ $response == *'Status: 200 OK'* ]]
[[ $response == *'"state":"running"'* ]]
echo 'cgi daemon FD: PASS'
