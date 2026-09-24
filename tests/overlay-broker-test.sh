#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
peer=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
caller=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

cat > "$T/vmapi.conf" <<CFG
VMAPI_PROFILE=virtualization
VMAPI_HTTP_PORT=5186
VMAPI_TLS_ENABLED=false
VMAPI_BACKPLANE_SERVER=true
QEMU_BIN=$T/bin/qemu-system-x86_64
CFG
cat > "$T/bin/qemu-system-x86_64" <<'EOF'
#!/bin/sh
exit 0
EOF
cat > "$T/bin/sudo" <<'EOF'
#!/bin/sh
[ "$1" = -n ] && shift
exec "$@"
EOF
cat > "$T/bin/peerctl" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
case "\$1" in
  authorize-user) exit 0;;
  peer-id-for-user) printf '%s\n' '$caller';;
  proxy)
    id=\$2 method=\$3 path=\$4
    body=\$(cat)
    printf '%s|%s|%s|%s\n' "\$id" "\$method" "\$path" "\$body" >> '$T/state/proxy.log'
    if [[ "\$method" == DELETE && "\${FAIL_REMOTE_DELETE:-false}" == true ]]; then
      printf '{"error":"remote overlay missing"}\n' >&2
      exit 22
    fi
    printf '{"remote":true}\n'
    ;;
  *) exit 2;;
esac
EOF
cat > "$T/bin/overlayctl" <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "\$*" >> '$T/state/overlay.log'
case "\$1" in
  create) printf '{"name":"%s","running":true}\n' "\$2";;
  show) printf '{"name":"%s","running":true}\n' "\$2";;
  peer-list) printf '%s\n' '$peer';;
  delete) ;;
  list) printf '[]\n';;
  *) exit 2;;
esac
EOF
chmod +x "$T/bin/"*

cgi(){
  local method=$1 path=$2 body=${3-}
  printf '%s' "$body" | \
    PATH="$T/bin:/usr/bin:/bin" \
    VMAPI_CONFIG="$T/vmapi.conf" \
    VMAPI_LIB="$ROOT/lib/common.sh" \
    PEERCTL="$T/bin/peerctl" \
    OVERLAYCTL="$T/bin/overlayctl" \
    REQUEST_METHOD="$method" \
    PATH_INFO="$path" \
    CONTENT_TYPE='application/x-www-form-urlencoded' \
    CONTENT_LENGTH=${#body} \
    FAIL_REMOTE_DELETE=${FAIL_REMOTE_DELETE:-false} \
    bash "$ROOT/cgi/api.cgi"
}

body="name=mesh1&bridge=brmesh&role=hub&peer_0=$peer&mtu=1400"
out=$(cgi POST /api/overlays "$body")
printf '%s\n' "$out" | grep -Fq 'Status: 201 Created'
grep -Fq "create mesh1 --bridge brmesh --role hub --peer $peer --mtu 1400" "$T/state/overlay.log"
grep -Fq "$peer|POST|/overlays|name=mesh1&bridge=brmesh&role=spoke&mtu=1400" "$T/state/proxy.log"

: > "$T/state/overlay.log"
remote_body='name=mesh2&bridge=brmesh2&role=spoke&mtu=1400&peer_0=cccccccccccccccccccccccccccccccc'
out=$(printf '%s' "$remote_body" | \
  PATH="$T/bin:/usr/bin:/bin" \
  VMAPI_CONFIG="$T/vmapi.conf" \
  VMAPI_LIB="$ROOT/lib/common.sh" \
  PEERCTL="$T/bin/peerctl" \
  OVERLAYCTL="$T/bin/overlayctl" \
  VMAPI_PEER_API=true \
  AUTH_TYPE=Basic \
  REMOTE_USER=relay_test \
  REQUEST_METHOD=POST \
  PATH_INFO=/overlays \
  CONTENT_TYPE='application/x-www-form-urlencoded' \
  CONTENT_LENGTH=${#remote_body} \
    FAIL_REMOTE_DELETE=${FAIL_REMOTE_DELETE:-false} \
  bash "$ROOT/cgi/api.cgi")
printf '%s\n' "$out" | grep -Fq 'Status: 201 Created'
grep -Fq "create mesh2 --bridge brmesh2 --role spoke --peer $caller --mtu 1400" "$T/state/overlay.log"
! grep -Fq 'cccccccccccccccccccccccccccccccc' "$T/state/overlay.log" || { echo "negative assertion failed: tests/overlay-broker-test.sh:101" >&2; exit 1; }

: > "$T/state/proxy.log"
out=$(cgi DELETE /api/overlays/mesh1 '')
printf '%s\n' "$out" | grep -Fq 'Status: 200 OK'
grep -Fq "$peer|DELETE|/overlays/mesh1|" "$T/state/proxy.log"
grep -Fq 'delete mesh1' "$T/state/overlay.log"


: > "$T/state/proxy.log"
: > "$T/state/overlay.log"
out=$(FAIL_REMOTE_DELETE=true cgi DELETE /api/overlays/mesh1 '')
printf '%s\n' "$out" | grep -Fq 'Status: 200 OK'
printf '%s\n' "$out" | grep -Fq '"remote_cleanup":"warning"'
grep -Fq 'delete mesh1' "$T/state/overlay.log"
grep -Fq "$peer|DELETE|/overlays/mesh1|" "$T/state/proxy.log"

# Repeated cleanup remains successful even when the local definition is already gone.
: > "$T/state/overlay.log"
out=$(FAIL_REMOTE_DELETE=true cgi DELETE /api/overlays/mesh1 '')
printf '%s\n' "$out" | grep -Fq 'Status: 200 OK'
grep -Fq 'delete mesh1' "$T/state/overlay.log"

echo 'overlay broker lifecycle: PASS'
