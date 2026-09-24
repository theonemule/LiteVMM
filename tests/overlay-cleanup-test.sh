#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/root" "$T/run" "$T/peers" "$T/bin" "$T/sys"
peer=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa

cat > "$T/bin/ip" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if [[ "$*" == *"vmo-"* ]]; then exit 1; fi
exit 0
EOF

cat > "$T/bin/netctl" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> '$T/netctl.log'
exit 0
EOF

cat > "$T/bin/service" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$T/bin/"*

write_conf(){
  local name=$1 bridge=$2 owned=$3
  cat > "$T/root/$name.conf" <<CFG
SCHEMA=4
BRIDGE=$bridge
ROLE=spoke
PEERS_LIST=$peer
MTU=1400
STAGED=false
TAP_BRIDGE_LEARNING=off
OWN_BRIDGE=$owned
CFG
}

run_delete(){
  local name=$1
  PATH="$T/bin:/usr/bin:/bin" \
  VMAPI_OVERLAY_ROOT="$T/root" \
  VMAPI_OVERLAY_RUN="$T/run" \
  VMAPI_PEER_ROOT="$T/peers" \
  VMAPI_NETCTL="$T/bin/netctl" \
  VMAPI_RC_SERVICE="$T/bin/service" \
  VMAPI_LIGHTTPD_ROOT="$T/lighttpd" \
  VMAPI_SYS_CLASS_NET="$T/sys" \
  bash "$ROOT/bin/overlayctl" delete "$name"
}

# Overlay-owned empty bridge is removed.
mkdir -p "$T/sys/br-owned/brif"
write_conf clean1 br-owned true
run_delete clean1 >/dev/null
grep -Fq 'bridge-delete br-owned' "$T/netctl.log"
[[ ! -e "$T/root/clean1.conf" ]]

# Repeating the delete is harmless.
run_delete clean1 >/dev/null

# Explicitly pre-existing bridge is preserved even when empty.
: > "$T/netctl.log"
mkdir -p "$T/sys/br-shared/brif"
write_conf clean2 br-shared false
run_delete clean2 >/dev/null
! grep -Fq 'bridge-delete br-shared' "$T/netctl.log" || { echo "negative assertion failed: tests/overlay-cleanup-test.sh:70" >&2; exit 1; }

# Owned bridge with another member is preserved.
: > "$T/netctl.log"
mkdir -p "$T/sys/br-busy/brif" "$T/sys/member0"
ln -s "$T/sys/member0" "$T/sys/br-busy/brif/member0"
write_conf clean3 br-busy true
run_delete clean3 >/dev/null
! grep -Fq 'bridge-delete br-busy' "$T/netctl.log" || { echo "negative assertion failed: tests/overlay-cleanup-test.sh:78" >&2; exit 1; }

# Legacy empty overlay bridge is treated as stale overlay residue and removed.
: > "$T/netctl.log"
mkdir -p "$T/sys/br-legacy/brif"
cat > "$T/root/clean4.conf" <<CFG
SCHEMA=3
BRIDGE=br-legacy
ROLE=spoke
PEERS_LIST=$peer
MTU=1400
STAGED=false
TAP_BRIDGE_LEARNING=off
CFG
run_delete clean4 >/dev/null
grep -Fq 'bridge-delete br-legacy' "$T/netctl.log"

echo 'overlay destructive cleanup: PASS'
