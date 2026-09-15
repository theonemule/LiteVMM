#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$ROOT/apply-alpine-runtime.sh"
grep -Fq 'lighttpd/vmapi.conf' "$ROOT/apply-alpine-runtime.sh"
grep -Fq 'lighttpd -tt -f /etc/lighttpd/lighttpd.conf' "$ROOT/apply-alpine-runtime.sh"
grep -Fq 'peer-api(?:/|$)' "$ROOT/lighttpd/vmapi.conf"
grep -Fq 'overlay(?:/|$)' "$ROOT/lighttpd/vmapi.conf"
# Runtime updates must not replace the sudo policy with one that omits the
# paired-host control plane.  The console loads this at startup on every view.
grep -Fq '/usr/local/bin/peerctl identity' "$ROOT/apply-alpine-runtime.sh"
grep -Fq '/usr/local/bin/peerctl list' "$ROOT/apply-alpine-runtime.sh"
grep -Fq '/usr/local/bin/vmctl delete *' "$ROOT/apply-alpine-runtime.sh"
grep -Fq 'run_cmd vm_delete_cmd "$name"' "$ROOT/cgi/api.cgi"
find "$ROOT" -type f \( -name '*.sh' -o -name 'vmctl' -o -name 'imagectl' -o -name 'netctl' -o -name 'overlayctl' -o -name 'dockerctl' -o -name 'dockerexecctl' -o -name 'docker-imagectl' -o -name 'docker-netctl' -o -name 'docker-volumectl' -o -name 'metricsctl' -o -name 'consolectl' -o -name 'vmapi-console-gc' -o -name '*.cgi' \) -print0 |
  while IFS= read -r -d '' f; do bash -n "$f"; done
if command -v node >/dev/null 2>&1; then node --check "$ROOT/www/app.js"; fi
bash "$ROOT/tests/host-selector-test.sh"
bash "$ROOT/tests/cgi-error-response-test.sh"
bash "$ROOT/tests/cgi-daemon-fd-test.sh"
bash "$ROOT/tests/vmctl-cpu-fallback-test.sh"
bash -n "$ROOT/tests/api-regression-curl.sh"
bash -n "$ROOT/tests/overlay-pair-curl.sh"
[[ -s "$ROOT/www/index.html" && -s "$ROOT/www/app.css" && -s "$ROOT/www/vendor/bootstrap/bootstrap.min.css" && -s "$ROOT/www/vendor/bootstrap/bootstrap.bundle.min.js" ]]
echo 'syntax: PASS'
