#!/usr/bin/env bash
# Verify the detailed system inventory is valid JSON with the expected top-level model.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
out=$(VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" bash "$ROOT/bin/metricsctl" system)
python3 -c 'import json,sys; d=json.load(sys.stdin); required={"host","os","hardware","network","storage","components","services"}; missing=required-set(d); assert not missing, missing; assert "hostname" in d["host"]; assert "memory_total_bytes" in d["hardware"]; assert "interfaces" in d["network"]' <<<"$out"
echo 'system information inventory: PASS'
