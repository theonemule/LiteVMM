#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
# Black-box VMAPI regression tests. Every operation goes through HTTP using the
# same Basic authentication as the web portal. Run this from a remote machine.
set -Eeuo pipefail

usage() {
  echo 'Usage: api-regression-curl.sh BASE_URL USERNAME [--insecure] [--destructive]'
  echo 'Example: api-regression-curl.sh http://10.0.4.62:8080 blaize'
  echo '  --destructive also creates and removes a host bridge and paired overlay.'
  exit 2
}

[[ $# -ge 2 ]] || usage
base=${1%/}; username=$2; shift 2
insecure=(); destructive=false
while (($#)); do
  case "$1" in
    --insecure) insecure=(-k);;
    --destructive) destructive=true;;
    *) usage;;
  esac
  shift
done
command -v curl >/dev/null || { echo 'curl is required' >&2; exit 2; }
command -v python3 >/dev/null || { echo 'python3 is required for JSON response validation' >&2; exit 2; }
[[ $base == */api ]] || base="$base/api"

if [[ -z ${VMAPI_PASSWORD:-} ]]; then
  read -r -s -p "Password for $username: " VMAPI_PASSWORD
  echo
fi

tmp=$(mktemp -d); body="$tmp/body"; suffix=$(printf '%x%x' "$(date +%s)" "$$" | tail -c 9)
vm="rg-vm-$suffix"; bridge="rgbr$suffix"; dnet="rg-net-$suffix"; volume="rg-vol-$suffix"; container="rg-box-$suffix"; overlay="ov${suffix:0:8}"; project="rg-compose-$suffix"; tagged="rg-img-$suffix:latest"; snapshot="rg-snapshot-$suffix:latest"; files_dir="/tmp/vmapi-files-$suffix"
vm_created=false; bridge_created=false; dnet_created=false; volume_created=false; container_created=false; overlay_created=false

curl_api() {
  curl -sS "${insecure[@]}" --connect-timeout 10 --max-time 180 --user "$username:$VMAPI_PASSWORD" "$@"
}
cleanup() {
  set +e
  curl_api -X DELETE "$base/docker/containers/$container" --data 'force=true&volumes=true' >/dev/null
  curl_api -X POST "$base/compose/projects/$project/down" --data '' >/dev/null
  curl_api -X DELETE "$base/compose/projects/$project" >/dev/null
  curl_api -X DELETE "$base/docker/images" --data-urlencode "image=$tagged" --data 'force=true' >/dev/null
  curl_api -X DELETE "$base/docker/images" --data-urlencode "image=$snapshot" --data 'force=true' >/dev/null
  curl_api -X POST "$base/vms/$vm/stop" --data 'force=true' >/dev/null
  curl_api -X DELETE "$base/vms/$vm" >/dev/null
  curl_api -X DELETE "$base/overlays/$overlay" >/dev/null
  curl_api -X DELETE "$base/docker/volumes/$volume" --data 'force=true' >/dev/null
  curl_api -X DELETE "$base/docker/networks/$dnet" >/dev/null
  $bridge_created && curl_api -X DELETE "$base/networks" --data-urlencode "name=$bridge" >/dev/null
  curl_api -X DELETE "$base/files" --data-urlencode "path_0=$files_dir" >/dev/null
  rm -rf "$tmp"
}
trap cleanup EXIT INT TERM

step=0
request() {
  local method=$1 path=$2 expected=$3 filter=$4; shift 4
  step=$((step+1)); printf '[%02d] %-7s %-42s ' "$step" "$method" "$path"
  code=$(curl_api -o "$body" -w '%{http_code}' -X "$method" "$base$path" "$@") || { echo 'CURL FAILED'; return 1; }
  if [[ $code != "$expected" ]]; then echo "FAIL ($code, expected $expected)"; sed -n '1,20p' "$body" >&2; return 1; fi
  if [[ -n $filter ]] && ! python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); scope={"d":d,"any":any,"bool":bool,"isinstance":isinstance,"dict":dict,"list":list,"len":len}; assert eval(sys.argv[2], {"__builtins__":{}, **scope}, scope)' "$body" "$filter"; then echo 'FAIL (response validation)'; cat "$body" >&2; return 1; fi
  echo PASS
}

echo "VMAPI black-box regression target: $base"
request GET / 200 'd.get("service") == "tinyvisor"'
request POST /vms 400 'bool(d.get("error"))' --data ''
request POST /networks 400 'bool(d.get("error"))' --data ''
request GET /does-not-exist 404 'bool(d.get("error"))'
request GET /metrics 200 'isinstance(d, dict)'
request GET '/logs?limit=5' 200 'isinstance(d, list)'
request GET /cluster/identity 200 'isinstance(d, dict)'
request GET /cluster/peers 200 'isinstance(d, list)'
request PUT /backups/receive/not-a-backup.tar.gz 403 'bool(d.get("error"))' --data-binary 'not-a-backup'
request GET /networks 200 'isinstance(d.get("bridges"), list)'
request GET /images 200 'isinstance(d, list)'
request GET /vms 200 'isinstance(d, list)'
request GET /docker/containers 200 'isinstance(d, list)'
request GET /docker/images 200 'isinstance(d, list)'
request GET /docker/networks 200 'isinstance(d, list)'
request GET /docker/volumes 200 'isinstance(d, list)'
request GET /compose/projects 200 'isinstance(d, list)'
request GET /overlays 200 'isinstance(d, list)'
request GET /overlays/orphans 200 'isinstance(d, list)'
request POST /host/terminal/session 201 'isinstance(d, dict)' --data ''
request DELETE /host/terminal/session 200 'd.get("stopped") is True'

if $destructive; then
  # A Linux bridge can alter host routing. Exercise it only when the caller has
  # explicitly chosen the host-level tier; cleanup removes this unique bridge.
  request POST /networks 201 'bool(d.get("name"))' --data-urlencode "name=$bridge" --data 'manual=true'; bridge_created=true
  request GET "/networks?name=$bridge" 200 "d.get('name') == '$bridge'"
  request PATCH /networks 200 "d.get('name') == '$bridge'" --data-urlencode "name=$bridge" --data 'manual=true'
else
  echo '[--] HOST NETWORK SKIP: pass --destructive to create a temporary Linux bridge'
fi

request POST /docker/networks 201 "isinstance(d, list) and d and d[0].get('Name') == '$dnet'" --data-urlencode "name=$dnet" --data 'driver=bridge'; dnet_created=true
request GET "/docker/networks/$dnet" 200 'isinstance(d, list) and len(d) == 1'
request POST /docker/volumes 201 "isinstance(d, list) and d and d[0].get('Name') == '$volume'" --data-urlencode "name=$volume"; volume_created=true
request GET "/docker/volumes/$volume" 200 'isinstance(d, list) and len(d) == 1'

request POST /docker/images/pull 200 'isinstance(d, (dict, list))' --data-urlencode 'image=alpine:3.20'
request POST /docker/images/tag 200 'd.get("tagged") is True' --data-urlencode 'source=alpine:3.20' --data-urlencode "target=$tagged"
request GET "/docker/images?image=$tagged" 200 'isinstance(d, (dict, list))'
request POST /docker/containers 201 'isinstance(d, list) and len(d) == 1' --data-urlencode "name=$container" --data-urlencode 'image=alpine:3.20' --data-urlencode "network=$dnet" --data 'cmd_0=sleep' --data 'cmd_1=300'; container_created=true
request GET "/docker/containers/$container" 200 'isinstance(d, list) and len(d) == 1'
request PATCH "/docker/containers/$container" 200 'isinstance(d, list) and len(d) == 1' --data 'field=restart&value=no'
request POST "/docker/containers/$container/start" 200 'd.get("state") == "running"' --data ''
request POST "/docker/containers/$container/restart" 200 'd.get("restarted") is True' --data ''
request GET "/docker/containers/$container/metrics" 200 'isinstance(d, dict)'
request GET "/docker/containers/$container/logs?tail=10" 200 ''
request POST "/docker/containers/$container/commit" 201 "d.get('image') == '$snapshot'" --data-urlencode "image=$snapshot" --data 'message=regression&pause=true'
request POST "/docker/containers/$container/exec/session" 201 'isinstance(d, dict)' --data 'shell=/bin/sh'
request GET "/docker/containers/$container/exec/session" 200 'isinstance(d, dict)'
request PATCH "/docker/containers/$container/exec/session" 200 'isinstance(d, dict)' --data ''
request DELETE "/docker/containers/$container/exec/session" 200 'd.get("stopped") is True'
request POST "/docker/containers/$container/stop" 200 'd.get("state") == "stopped"' --data ''
request DELETE "/docker/containers/$container" 200 'd.get("deleted") is True' --data 'force=true&volumes=true'; container_created=false

request POST /vms 201 "d.get('name') == '$vm'" --data-urlencode "name=$vm" --data 'memory_mb=512' --data 'vcpus=1' --data 'disk_size=1G' --data 'network=nat'; vm_created=true
request GET "/vms/$vm" 200 "d.get('name') == '$vm' and d.get('state') == 'stopped'"
request PATCH "/vms/$vm" 200 'd.get("config", {}).get("MEMORY_MB") == 768' --data 'field=memory_mb' --data 'value=768'
request POST "/vms/$vm/disks" 201 'd.get("index", -1) >= 1' --data 'size=1G'; disk_index=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["index"])' "$body")
request PATCH "/vms/$vm/disks/$disk_index" 200 'd.get("updated") is True' --data 'field=bus' --data 'value=virtio'
request DELETE "/vms/$vm/disks/$disk_index" 200 'd.get("deleted") is True' --data 'delete_file=true'
# NAT attachment is self-contained within VMAPI and proves the NIC handler
# without modifying host networking. The bridge/overlay path is tested below
# only in the destructive tier.
request POST "/vms/$vm/nics" 201 'd.get("index", -1) >= 1' --data 'mode=nat'; nic_index=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["index"])' "$body")
request PATCH "/vms/$vm/nics/$nic_index" 200 'd.get("updated") is True' --data 'field=model' --data 'value=virtio-net-pci'
request DELETE "/vms/$vm/nics/$nic_index" 200 'd.get("deleted") is True'
request POST "/vms/$vm/start" 200 'd.get("state") == "running"' --data ''
request GET "/vms/$vm/metrics" 200 'isinstance(d, dict)'
request GET "/vms/$vm/console" 200 'isinstance(d, dict)'
request POST "/vms/$vm/console/session" 201 'isinstance(d, dict)' --data ''
request GET "/vms/$vm/console/session" 200 'isinstance(d, dict)'
request PATCH "/vms/$vm/console/session" 200 'isinstance(d, dict)' --data ''
request DELETE "/vms/$vm/console/session" 200 'd.get("stopped") is True'
request POST "/vms/$vm/reboot" 200 'd.get("rebooted") is True' --data 'force=true'
request POST "/vms/$vm/stop" 200 'd.get("state") == "stopped"' --data 'force=true'
request POST /backups/create 201 "d.get('vm') == '$vm' and bool(d.get('archive'))" --data-urlencode "name=$vm" --data-urlencode "label=regression-$suffix"; archive=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["archive"])' "$body")
request GET /backups 200 "any(x.get('archive') == '$archive' for x in d)"
request DELETE "/backups/$vm/$archive" 200 'd.get("deleted") is True'
request POST /backups/schedule 201 'd.get("scheduled") is True' --data-urlencode "name=$vm" --data-urlencode 'cron=17 3 * * *' --data-urlencode "label=regression-$suffix" --data-urlencode 'destination=/var/lib/vmapi/backups' --data 'keep=2'
request GET /backups/schedules 200 "any(x.get('vm') == '$vm' and x.get('label') == 'regression-$suffix' and not x.get('peer_id') for x in d)"
request DELETE /backups/unschedule 200 'd.get("unscheduled") is True' --data-urlencode "name=$vm" --data-urlencode "label=regression-$suffix"
request POST /backups/create 400 'bool(d.get("error"))' --data-urlencode "name=$vm" --data 'transport=scp' --data 'ssh=obsolete@example'
request DELETE "/vms/$vm" 200 'd.get("deleted") is True'; vm_created=false
request GET "/vms/$vm" 404 'bool(d.get("error"))'

peer_id=$(curl_api "$base/cluster/peers" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d[0].get("node_id", "") if d else "")')
if $destructive && [[ -n $peer_id ]]; then
  request POST /overlays 201 "d.get('name') == '$overlay'" --data-urlencode "name=$overlay" --data-urlencode "bridge=$bridge" --data 'role=hub' --data-urlencode "peer_0=$peer_id"; overlay_created=true
  request GET "/overlays/$overlay" 200 "d.get('name') == '$overlay' and d.get('bridge') == '$bridge'"
  request DELETE "/overlays/$overlay" 200 'd.get("deleted") is True'; overlay_created=false
  request GET "/overlays/$overlay" 400 'bool(d.get("error"))'
elif $destructive; then
  echo '[--] OVERLAY SKIP: no paired peer is configured'
else
  echo '[--] OVERLAY SKIP: pass --destructive to create a temporary paired overlay'
fi

printf '%s\n' 'services:' '  sleeper:' '    image: alpine:3.20' '    command: ["sleep", "300"]' > "$tmp/compose.yaml"
request PUT "/compose/projects/$project" 201 "d.get('name') == '$project'" --header 'Content-Type: application/yaml' --data-binary "@$tmp/compose.yaml"
request GET "/compose/projects/$project" 200 ''
request POST "/compose/projects/$project/deploy" 200 'd.get("deployed") is True' --data ''
request POST "/compose/projects/$project/down" 200 'd.get("stopped") is True' --data ''
request DELETE "/compose/projects/$project" 200 'd.get("deleted") is True'
request DELETE /docker/images 200 'd.get("deleted") is True' --data-urlencode "image=$tagged" --data 'force=true'

request DELETE "/docker/volumes/$volume" 200 'd.get("deleted") is True' --data 'force=true'; volume_created=false
request DELETE "/docker/networks/$dnet" 200 'd.get("deleted") is True'; dnet_created=false
if $bridge_created; then
  request DELETE /networks 200 'd.get("deleted") is True' --data-urlencode "name=$bridge"; bridge_created=false
  request GET /networks 200 "'$bridge' not in d.get('bridges', [])"
fi

printf 'VMAPI file browser regression %s\n' "$suffix" > "$tmp/upload.txt"
request GET '/files?path=/' 200 'isinstance(d.get("entries"), list)'
request POST /files/directories 201 'd.get("created") is True' --data-urlencode "path=$files_dir"
file_upload_path=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$files_dir/original.txt")
request PUT "/files/content?path=$file_upload_path" 201 'd.get("uploaded") is True' --header 'Content-Type: application/octet-stream' --data-binary "@$tmp/upload.txt"
files_list_path=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$files_dir")
request GET "/files?path=$files_list_path" 200 "any(x.get('name') == 'original.txt' for x in d.get('entries', []))"
file_download_path=$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1]))' "$files_dir/original.txt")
curl_api -f -o "$tmp/download.txt" "$base/files/content?path=$file_download_path"
cmp "$tmp/upload.txt" "$tmp/download.txt"; step=$((step+1)); printf '[%02d] %-7s %-42s PASS\n' "$step" GET /files/content
request PATCH /files/move 200 'd.get("moved") is True' --data-urlencode "source=$files_dir/original.txt" --data-urlencode "destination=$files_dir/moved.txt"
curl_api -f -o "$tmp/files.zip" -X POST "$base/files/archive" --data-urlencode "path_0=$files_dir/moved.txt"
python3 -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); n=next(n for n in z.namelist() if n.endswith("moved.txt")); assert b"VMAPI file browser regression" in z.read(n)' "$tmp/files.zip"; step=$((step+1)); printf '[%02d] %-7s %-42s PASS\n' "$step" POST /files/archive
request DELETE /files 200 'd.get("deleted") is True and d.get("count") == 1' --data-urlencode "path_0=$files_dir"
request DELETE /files 400 'bool(d.get("error"))' --data-urlencode 'path_0=/'
echo "PASS: $step authenticated HTTP regression checks completed and all test resources were removed."
