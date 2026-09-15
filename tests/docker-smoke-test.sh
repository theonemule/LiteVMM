#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
set -Eeuo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/state/containers" "$T/state/images" "$T/state/networks" "$T/state/volumes"
LOG="$T/docker.log"

cat > "$T/docker" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
STATE=${FAKE_DOCKER_STATE:?}
LOG=${FAKE_DOCKER_LOG:?}
printf '%q ' "$@" >> "$LOG"; printf '\n' >> "$LOG"
obj=${1:-}; act=${2:-}
case "$obj:$act" in
  container:inspect)
    if [[ ${3:-} == --format ]]; then name=${5:?}; [[ -f "$STATE/containers/$name" ]] || exit 1; echo running; exit 0; fi
    name=${3:?}; [[ -f "$STATE/containers/$name" ]] || exit 1
    printf '[{"Name":"/%s","State":{"Status":"running"},"Config":{"Image":"alpine:latest"}}]\n' "$name";;
  container:ls)
    if [[ "$*" == *'{{json .}}'* ]]; then
      for f in "$STATE"/containers/*; do [[ -f $f ]] || continue; n=$(basename "$f"); printf '{"Names":"%s","State":"running","Image":"alpine:latest","Status":"Up"}\n' "$n"; done
    else
      for f in "$STATE"/containers/*; do [[ -f $f ]] || continue; n=$(basename "$f"); printf '%s\trunning\talpine:latest\tUp\n' "$n"; done
    fi;;
  container:create)
    name=''; prev=''; for a in "$@"; do [[ $prev == --name ]] && name=$a; prev=$a; done
    [[ -n $name ]] || exit 2; touch "$STATE/containers/$name"; echo deadbeef;;
  container:start|container:stop|container:restart|container:update|container:kill)
    exit 0;;
  container:rm)
    name=${@: -1}; rm -f "$STATE/containers/$name";;
  image:ls)
    if [[ "$*" == *'{{json .}}'* ]]; then echo '{"Repository":"alpine","Tag":"latest","ID":"sha256:1","Size":"8MB"}';
    else echo $'alpine:latest\tsha256:1\t8MB\t1 day ago'; fi;;
  image:inspect) printf '[{"RepoTags":["%s"]}]\n' "${3:?}";;
  image:pull) touch "$STATE/images/pulled"; echo "Pulled ${3:?}";;
  image:tag) exit 0;;
  image:rm) exit 0;;
  network:ls)
    if [[ "$*" == *'{{json .}}'* ]]; then echo '{"Name":"bridge","Driver":"bridge","Scope":"local","ID":"n1"}'; else echo $'bridge\tbridge\tlocal\tn1'; fi;;
  network:create) name=${@: -1}; touch "$STATE/networks/$name"; echo netid;;
  network:inspect) printf '[{"Name":"%s","Driver":"bridge"}]\n' "${3:?}";;
  network:rm) rm -f "$STATE/networks/${3:?}";;
  volume:ls)
    if [[ "$*" == *'{{json .}}'* ]]; then echo '{"Name":"data","Driver":"local","Scope":"local"}'; else echo $'data\tlocal\tlocal'; fi;;
  volume:create) name=${@: -1}; touch "$STATE/volumes/$name"; echo "$name";;
  volume:inspect) printf '[{"Name":"%s","Driver":"local"}]\n' "${3:?}";;
  volume:rm) name=${@: -1}; rm -f "$STATE/volumes/$name";;
  *) echo "unhandled fake docker call: $*" >&2; exit 9;;
esac
MOCK
chmod +x "$T/docker"
export DOCKER_BIN="$T/docker" FAKE_DOCKER_STATE="$T/state" FAKE_DOCKER_LOG="$LOG" VMAPI_LIB="$ROOT/lib/common.sh" VMAPI_CONFIG=/dev/null

"$ROOT/bin/dockerctl" create web alpine:latest --cpus 1.5 --memory 512m --restart unless-stopped --network bridge --env MODE=prod --publish 8080:80 --volume data:/data --label app=web -- -- sleep 60 >/dev/null
[[ -f "$T/state/containers/web" ]]
"$ROOT/bin/dockerctl" status web | grep -qx running
"$ROOT/bin/dockerctl" update web cpus 2
"$ROOT/bin/dockerctl" stop web --time 3
"$ROOT/bin/dockerctl" start web >/dev/null
"$ROOT/bin/dockerctl" restart web
"$ROOT/bin/docker-imagectl" pull alpine:latest >/dev/null
"$ROOT/bin/docker-netctl" create appnet --subnet 172.30.0.0/24 >/dev/null
"$ROOT/bin/docker-volumectl" create appdata >/dev/null
"$ROOT/bin/dockerctl" delete web
[[ ! -e "$T/state/containers/web" ]]

grep -q -- '--publish 8080:80' "$LOG"
grep -q -- '--env MODE=prod' "$LOG"
grep -q -- 'container update --cpus 2 web' "$LOG"
grep -q -- 'network create --subnet 172.30.0.0/24 --driver bridge appnet' "$LOG"

# Exercise the CGI router against the same fake daemon.
body='name=cgiweb&image=alpine%3Alatest&restart=unless-stopped&publish_0=8081%3A80&env_0=MODE%3Dtest&cmd_0=sleep&cmd_1=30'
out=$(printf '%s' "$body" | \
  REQUEST_METHOD=POST PATH_INFO=/api/docker/containers CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH=${#body} \
  DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" \
  VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" \
  "$ROOT/cgi/api.cgi")
grep -q 'Status: 201 Created' <<< "$out"
grep -q '"Name":"/cgiweb"' <<< "$out"

out=$(REQUEST_METHOD=GET PATH_INFO=/api/docker/containers \
  DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" \
  VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" \
  "$ROOT/cgi/api.cgi")
grep -q '"Names":"cgiweb"' <<< "$out"

# Image/network/volume CGI paths.
body='image=alpine%3Alatest'
out=$(printf '%s' "$body" | REQUEST_METHOD=POST PATH_INFO=/api/docker/images/pull CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH=${#body} \
  DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" \
  VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" "$ROOT/cgi/api.cgi")
grep -q 'Status: 200 OK' <<< "$out"
grep -q '"output":"Pulled alpine:latest"' <<< "$out"

body='name=webnet&subnet=172.31.0.0%2F24'
out=$(printf '%s' "$body" | REQUEST_METHOD=POST PATH_INFO=/api/docker/networks CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH=${#body} \
  DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" \
  VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" "$ROOT/cgi/api.cgi")
grep -q '"Name":"webnet"' <<< "$out"

body='name=webdata'
out=$(printf '%s' "$body" | REQUEST_METHOD=POST PATH_INFO=/api/docker/volumes CONTENT_TYPE=application/x-www-form-urlencoded CONTENT_LENGTH=${#body} \
  DOCKERCTL="$ROOT/bin/dockerctl" DOCKER_IMAGECTL="$ROOT/bin/docker-imagectl" DOCKER_NETCTL="$ROOT/bin/docker-netctl" DOCKER_VOLUMECTL="$ROOT/bin/docker-volumectl" \
  VMCTL="$ROOT/bin/vmctl" IMAGECTL="$ROOT/bin/imagectl" NETCTL="$ROOT/bin/netctl" "$ROOT/cgi/api.cgi")
grep -q '"Name":"webdata"' <<< "$out"

echo 'docker smoke: PASS'
