#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$ROOT/install.sh"
head -n 1 "$ROOT/install.sh" | grep -Fxq '#!/bin/sh'
grep -Fq 'VMAPI_INSTALL_BASH=1 bash "$0" "$@"' "$ROOT/install.sh"
grep -Fq 'detect_platform' "$ROOT/install.sh"
grep -Fq 'GOST_VERSION=3.2.6' "$ROOT/install.sh"
grep -Fq 'PROFILE=${VMAPI_INSTALL_PROFILE:-}' "$ROOT/install.sh"
grep -Fq 'HTTP_PORT=${VMAPI_HTTP_PORT:-5186}' "$ROOT/install.sh"
grep -Fq 'FROM alpine:3.24' "$ROOT/Dockerfile"
grep -Fq 'VMAPI_PROFILE=backup' "$ROOT/docker/backup/vmapi.conf"
grep -Fq 'lighttpd -tt -f /etc/lighttpd/lighttpd.conf' "$ROOT/install.sh"
grep -Fq 'vmapi-network.service' "$ROOT/install.sh"
grep -Fq 'report_nested_hyperv_requirement' "$ROOT/install.sh"
grep -Fq '/usr/local/bin/netctl restore' "$ROOT/openrc/vmapi-network"
grep -Fq '"ports":[' "$ROOT/bin/netctl"
grep -Fq 'configured_bridge_members "$name"' "$ROOT/bin/netctl"
grep -Fq 'function bridgeMemberOptions' "$ROOT/www/app.js"
grep -Fq '/^(tap|vnet)\d+$/.test(i)' "$ROOT/www/app.js"
grep -Fq 'netctl restore' "$ROOT/systemd/vmapi-network.service"
grep -Fq 'peer-api(?:/|$)' "$ROOT/lighttpd/vmapi.conf"
grep -Fq 'overlay(?:/|$)' "$ROOT/lighttpd/vmapi.conf"
# Runtime updates must not replace the sudo policy with one that omits the
# paired-host control plane.  The console loads this at startup on every view.
grep -Fq '/usr/local/bin/peerctl identity' "$ROOT/install.sh"
grep -Fq '/usr/local/bin/peerctl list' "$ROOT/install.sh"
grep -Fq '/usr/local/bin/vmctl delete *' "$ROOT/install.sh"
grep -Fq '/usr/local/bin/vmbackupctl *' "$ROOT/install.sh"

grep -Fq 'virtualization-docker)' "$ROOT/install.sh"
grep -Fq 'SupplementaryGroups=kvm docker' "$ROOT/install.sh"
grep -Fq 'vmapi ALL=(root) NOPASSWD: /usr/local/bin/dockerexecctl start *' "$ROOT/install.sh"
grep -Fq 'xorriso' "$ROOT/install.sh"
grep -Fq 'cloud-init-set' "$ROOT/bin/vmctl"
grep -Fq 'vmapi-replication.service' "$ROOT/install.sh"
grep -Fq 'replication-source' "$ROOT/cgi/api.cgi"
grep -Fq 'peer-pull' "$ROOT/bin/registryctl"
grep -Fq 'type=nfs' "$ROOT/www/app.js"
grep -Fq 'type=cifs' "$ROOT/www/app.js"
grep -Fq 'LiteVMM peer NFS backplane volume' "$ROOT/www/app.js"
grep -Fq '/backplane/storage' "$ROOT/lighttpd/vmapi.conf"
grep -Fq 'VMAPI_BACKPLANE_NFS_BIND=127.0.0.1' "$ROOT/etc/vmapi.conf"
grep -Fq 'websocat' "$ROOT/install.sh"
grep -Fq '1) backup                 Backup only' "$ROOT/install.sh"
grep -Fq "Docker profile verification failed: docker is not installed" "$ROOT/install.sh"
grep -Fq 'verify_profile_install' "$ROOT/install.sh"
grep -Fq 'verify_active_profile_config()' "$ROOT/install.sh"
grep -Fq 'activate_requested_profile()' "$ROOT/install.sh"
grep -Fq 'openssh-client-default' "$ROOT/install.sh"
grep -Fq 'docker) systemctl enable --now vmapi-backplane-server.service vmapi-backplane.service' "$ROOT/install.sh"
grep -Fq 'docker) apt-get install -y --no-install-recommends docker.io ttyd nfs-common nfs-kernel-server websockify' "$ROOT/install.sh"
grep -Fq 'docker) apk add --no-cache docker docker-openrc docker-cli-compose ttyd nfs-utils websockify websocat' "$ROOT/install.sh"
grep -Fq 'VMAPI_TLS_CSR_KEY_FILE=' "$ROOT/etc/vmapi.conf"
grep -Fq '/admin/certificates/import' "$ROOT/www/app.js"
grep -Fq 'csr-generate' "$ROOT/bin/certctl"
grep -Fq '/cloud-init' "$ROOT/www/app.js"
grep -Fq 'ttyd-host-vmapi.service' "$ROOT/install.sh"
grep -Fq 'location /host/terminal/' "$ROOT/nginx/vmapi.conf"
grep -Fq '"$METRICSCTL" system' "$ROOT/cgi/api.cgi"
grep -Fq 'BRIDGE_CONFIG_ROOT' "$ROOT/bin/netctl"
grep -Fq 'restore)' "$ROOT/bin/netctl"
grep -Fq 'run_cmd vm_delete_cmd "$name"' "$ROOT/cgi/api.cgi"
find "$ROOT" -type f \( -name '*.sh' -o -name 'vmctl' -o -name 'imagectl' -o -name 'netctl' -o -name 'overlayctl' -o -name 'dockerctl' -o -name 'dockerexecctl' -o -name 'docker-imagectl' -o -name 'docker-netctl' -o -name 'docker-volumectl' -o -name 'replicationctl' -o -name 'backplanectl' -o -name 'registryctl' -o -name 'metricsctl' -o -name 'certctl' -o -name 'consolectl' -o -name 'vmapi-console-gc' -o -name '*.cgi' \) -print0 |
  while IFS= read -r -d '' f; do bash -n "$f"; done
if command -v node >/dev/null 2>&1; then node --check "$ROOT/www/app.js"; fi
bash "$ROOT/tests/host-selector-test.sh"
bash "$ROOT/tests/cgi-error-response-test.sh"
bash "$ROOT/tests/cgi-daemon-fd-test.sh"
bash "$ROOT/tests/vmctl-cpu-fallback-test.sh"
bash "$ROOT/tests/vmctl-vlan-test.sh"
bash "$ROOT/tests/vmctl-cloud-init-test.sh"
bash "$ROOT/tests/vmctl-replication-guard-test.sh"
bash "$ROOT/tests/system-info-test.sh"
bash "$ROOT/tests/profile-api-test.sh"
bash "$ROOT/tests/runtime-capability-test.sh"
bash "$ROOT/tests/replicationctl-test.sh"
bash "$ROOT/tests/replication-json-test.sh"
bash "$ROOT/tests/registryctl-test.sh"
bash "$ROOT/tests/docker-image-build-test.sh"
bash "$ROOT/tests/peer-volumectl-test.sh"
bash "$ROOT/tests/backplanectl-test.sh"
bash "$ROOT/tests/certctl-test.sh"
bash "$ROOT/tests/certificate-api-test.sh"
bash -n "$ROOT/tests/api-regression-curl.sh"
bash -n "$ROOT/tests/overlay-pair-curl.sh"
[[ -s "$ROOT/www/index.html" && -s "$ROOT/www/app.css" && -s "$ROOT/www/vendor/bootstrap/bootstrap.min.css" && -s "$ROOT/www/vendor/bootstrap/bootstrap.bundle.min.js" ]]
echo 'syntax: PASS'

python3 - "$ROOT/install.sh" <<'PY'
from pathlib import Path
import sys
s=Path(sys.argv[1]).read_text()
a=s.index('install_packages\nactivate_requested_profile\nverify_active_profile_config\ndisable_native_nfs')
b=s.index('if [[ $PROFILE == virtualization || $PROFILE == virtualization-docker ]]; then install_gost; fi')
assert a < b
PY
