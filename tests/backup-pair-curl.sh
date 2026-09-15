#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
# End-to-end paired-host backup test. Setup, transfer, validation, and cleanup all
# use the same HTTP credentials as the VMAPI portal.
set -Eeuo pipefail
[[ $# -eq 4 ]] || { echo 'Usage: backup-pair-curl.sh SOURCE_URL SOURCE_USER DESTINATION_URL DESTINATION_USER'; exit 2; }
source_url=${1%/}; source_user=$2; destination_url=${3%/}; destination_user=$4
[[ $source_url == */api ]] || source_url="$source_url/api"; [[ $destination_url == */api ]] || destination_url="$destination_url/api"
command -v curl >/dev/null && command -v python3 >/dev/null && command -v tar >/dev/null || { echo 'curl, python3, and tar are required'; exit 2; }
[[ -n ${SOURCE_PASSWORD:-} ]] || { read -rsp "Password for $source_user@$source_url: " SOURCE_PASSWORD; echo; }
[[ -n ${DESTINATION_PASSWORD:-} ]] || { read -rsp "Password for $destination_user@$destination_url: " DESTINATION_PASSWORD; echo; }
scurl(){ curl -sS --fail-with-body --user "$source_user:$SOURCE_PASSWORD" --connect-timeout 10 --max-time 3600 "$@"; }
dcurl(){ curl -sS --fail-with-body --user "$destination_user:$DESTINATION_PASSWORD" --connect-timeout 10 --max-time 3600 "$@"; }
json(){ python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
suffix=$(printf '%x%x' "$(date +%s)" "$$" | tail -c 9); vm="peer-backup-$suffix"; archive=''; vm_created=false; tmp=$(mktemp -d)
cleanup(){ set +e; [[ -z $archive ]] || dcurl -X DELETE "$destination_url/backups/$vm/$archive" >/dev/null 2>&1; $vm_created && { scurl -X POST "$source_url/vms/$vm/stop" --data 'force=true' >/dev/null 2>&1; scurl -X DELETE "$source_url/vms/$vm" >/dev/null 2>&1; }; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
destination_id=$(dcurl "$destination_url/cluster/identity" | json 'd["node_id"]')
peer_id=$(scurl "$source_url/cluster/peers" | python3 -c 'import json,sys; peers=json.load(sys.stdin); target=sys.argv[1].lower(); print(next((p["node_id"] for p in peers if p.get("node_id","").lower()==target and p.get("url")),""))' "$destination_id")
[[ -n $peer_id ]] || { echo 'The source does not have the destination configured as an authenticated peer'; exit 1; }
echo "Creating stopped test VM $vm on the source"
scurl -X POST "$source_url/vms" --data-urlencode "name=$vm" --data 'memory_mb=256' --data 'vcpus=1' --data 'disk_size=1G' --data 'network=nat' > "$tmp/vm.json"
vm_created=true
echo 'Streaming its backup through the signed peer API'
policy="pair-plan-$suffix"
scurl -X POST "$source_url/backups/schedule" --data-urlencode "name=$vm" --data-urlencode 'cron=23 4 * * *' --data-urlencode "label=$policy" --data-urlencode "peer_id=$peer_id" --data 'keep=2' >/dev/null
scurl "$source_url/backups/schedules" | python3 -c 'import json,sys; peer,label=sys.argv[1:]; assert any(x.get("peer_id")==peer and x.get("label")==label for x in json.load(sys.stdin))' "$peer_id" "$policy"
scurl -X DELETE "$source_url/backups/unschedule" --data-urlencode "name=$vm" --data-urlencode "label=$policy" >/dev/null
if ! scurl -X POST "$source_url/backups/create" --data-urlencode "name=$vm" --data-urlencode 'label=pair-regression' --data-urlencode "peer_id=$peer_id" --data 'keep=2' > "$tmp/result.json"; then
  cat "$tmp/result.json" >&2
  exit 1
fi
archive=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d.get("target")=="peer" and d.get("peer_id"); print(d["archive"])' "$tmp/result.json")
scurl "$source_url/backups" | python3 -c 'import json,sys; a=sys.argv[1]; assert all(x.get("archive")!=a for x in json.load(sys.stdin))' "$archive"
dcurl "$destination_url/backups" | python3 -c 'import json,sys; a=sys.argv[1]; assert any(x.get("archive")==a for x in json.load(sys.stdin))' "$archive"
dcurl -o "$tmp/backup.tar.gz" "$destination_url/backups/$vm/$archive"
tar -tzf "$tmp/backup.tar.gz" | grep -qx "$vm/vm.conf"
dcurl -X DELETE "$destination_url/backups/$vm/$archive" >/dev/null; archive=''
scurl -X DELETE "$source_url/vms/$vm" >/dev/null; vm_created=false
echo "PASS: $vm was backed up to its authenticated peer, validated, and fully removed"
