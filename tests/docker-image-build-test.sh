#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/state"
cat > "$T/bin/docker" <<'SH'
#!/usr/bin/env bash
set -e
printf '%s\n' "$*" > "$FAKE_DOCKER_STATE/args"
if [[ "$1 $2" == 'image build' ]]; then cat > "$FAKE_DOCKER_STATE/context"; echo sha256:deadbeef; exit 0; fi
exit 2
SH
chmod +x "$T/bin/docker"
out=$(printf 'fake-tar-context' | env VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" DOCKER_BIN="$T/bin/docker" FAKE_DOCKER_STATE="$T/state" bash "$ROOT/bin/docker-imagectl" build-stdin team/app:latest --file Dockerfile)
[[ $out == *'"image":"team/app:latest"'* && $out == *'"id":"sha256:deadbeef"'* ]]
grep -Fxq 'image build --quiet --tag team/app:latest --file Dockerfile -' "$T/state/args"
grep -Fxq 'fake-tar-context' "$T/state/context"
if printf x | env VMAPI_CONFIG=/dev/null VMAPI_LIB="$ROOT/lib/common.sh" DOCKER_BIN="$T/bin/docker" FAKE_DOCKER_STATE="$T/state" bash "$ROOT/bin/docker-imagectl" build-stdin bad:latest --file ../Dockerfile >/dev/null 2>&1; then echo 'expected traversing Dockerfile path to be rejected' >&2; exit 1; fi
echo 'docker image streamed build: PASS'
