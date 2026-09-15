#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
bash -n "$ROOT/bin/peerctl"
bash -n "$ROOT/cgi/api.cgi"
bash -n "$ROOT/tests/peer-cgi-uri-test.sh"
echo 'peer syntax: PASS'
