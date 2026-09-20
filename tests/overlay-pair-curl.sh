#!/usr/bin/env bash
# Purpose: focused VMAPI regression test.
# Scope: creates isolated fixtures or uses the supplied HTTP endpoint; it does not modify repository files.
# Run directly with Bash; a non-zero exit status identifies the failed assertion.
# Two-host GOST TAP data-plane test. All setup and cleanup uses authenticated HTTP.
set -Eeuo pipefail
[[ $# -eq 4 ]] || { echo 'Usage: overlay-pair-curl.sh HUB_URL HUB_USER SPOKE_URL SPOKE_USER'; exit 2; }
hub=${1%/}; hub_user=$2; spoke=${3%/}; spoke_user=$4
[[ $hub == */api ]] || hub="$hub/api"; [[ $spoke == */api ]] || spoke="$spoke/api"
command -v curl >/dev/null && command -v python3 >/dev/null || { echo 'curl and python3 are required'; exit 2; }
[[ -n ${HUB_PASSWORD:-} ]] || { read -rsp "Password for $hub_user@$hub: " HUB_PASSWORD; echo; }
[[ -n ${SPOKE_PASSWORD:-} ]] || { read -rsp "Password for $spoke_user@$spoke: " SPOKE_PASSWORD; echo; }
suffix=$(printf '%x' "$(date +%s)" | tail -c 8); overlay="dp${suffix:0:7}"; hub_br="dph${suffix:0:7}"; spoke_br="$hub_br"; hub_box="dp-hub-$suffix"; spoke_box="dp-spoke-$suffix"; hub_net="dpn-hub-$suffix"; spoke_net="dpn-spoke-$suffix"; tmp=$(mktemp -d)
hcurl(){ curl -sS --user "$hub_user:$HUB_PASSWORD" --connect-timeout 10 --max-time 180 "$@"; }
scurl(){ curl -sS --user "$spoke_user:$SPOKE_PASSWORD" --connect-timeout 10 --max-time 180 "$@"; }
cleanup(){ set +e; [[ ${KEEP_ON_FAILURE:-false} == true ]] && { echo "Preserved failed overlay $overlay for diagnostics"; return; }; scurl -X DELETE "$spoke/docker/containers/$spoke_box" --data 'force=true' >/dev/null; hcurl -X DELETE "$hub/docker/containers/$hub_box" --data 'force=true' >/dev/null; scurl -X DELETE "$spoke/docker/networks/$spoke_net" >/dev/null; hcurl -X DELETE "$hub/docker/networks/$hub_net" >/dev/null; scurl -X DELETE "$spoke/overlays/$overlay" >/dev/null; hcurl -X DELETE "$hub/overlays/$overlay" >/dev/null; rm -rf "$tmp"; }
trap cleanup EXIT INT TERM
json_field(){ python3 -c "import json,sys; d=json.load(sys.stdin); print($1)"; }
hub_peer=$(hcurl "$hub/cluster/peers" | json_field 'd[0]["node_id"] if d else ""'); spoke_peer=$(scurl "$spoke/cluster/peers" | json_field 'd[0]["node_id"] if d else ""')
[[ -n $hub_peer && -n $spoke_peer ]] || { echo 'Both hosts must already be paired'; exit 1; }
echo "Creating coordinated overlay $overlay from the hub"
hcurl -f -X POST "$hub/overlays" --data-urlencode "name=$overlay" --data-urlencode "bridge=$hub_br" --data 'role=hub' --data-urlencode "peer_0=$hub_peer" > "$tmp/hub-overlay.json"
sleep 5
hub_running=$(hcurl -f "$hub/overlays/$overlay" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(bool(d.get("running") and d.get("tap_type")=="tap" and d.get("tap_process") and d.get("tap_up") and d.get("tap_bridged"))).lower())')
spoke_running=$(scurl -f "$spoke/overlays/$overlay" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(bool(d.get("running") and d.get("tap_type")=="tap" and d.get("tap_process") and d.get("tap_up") and d.get("tap_bridged"))).lower())')
if [[ $hub_running != true || $spoke_running != true ]]; then
  echo "Overlay adapters did not start (hub=$hub_running, spoke=$spoke_running)"
  echo 'Hub overlay log:'; hcurl "$hub/logs?source=overlay&limit=80" || true
  echo 'Spoke overlay log:'; scurl "$spoke/logs?source=overlay&limit=80" || true
  exit 1
fi
# Overlayctl intentionally does not create Docker networks: host-local Docker
# IPAM would duplicate gateway addresses across one Layer-2 segment.  The test
# creates disposable networks only to attach fixed, non-overlapping endpoints.
octet=$(python3 -c 'import sys; print(20 + (int(sys.argv[1],16) % 200))' "$suffix")
subnet="10.251.$octet.0/24"; gateway="10.251.$octet.1"; hub_ip="10.251.$octet.10"; spoke_ip="10.251.$octet.20"; lease_start="10.251.$octet.100"; lease_end="10.251.$octet.110"
hcurl -f -X POST "$hub/docker/networks" --data-urlencode "name=$hub_net" --data 'driver=bridge' --data-urlencode "subnet=$subnet" --data-urlencode "gateway=$gateway" --data-urlencode "opt_0=com.docker.network.bridge.name=$hub_br" --data 'opt_1=com.docker.network.bridge.enable_ip_masquerade=false' >/dev/null
scurl -f -X POST "$spoke/docker/networks" --data-urlencode "name=$spoke_net" --data 'driver=bridge' --data-urlencode "subnet=$subnet" --data-urlencode "gateway=$gateway" --data-urlencode "opt_0=com.docker.network.bridge.name=$spoke_br" --data 'opt_1=com.docker.network.bridge.enable_ip_masquerade=false' >/dev/null
dhcp_image='jpillora/dnsmasq:latest'
hcurl -f -X POST "$hub/docker/images/pull" --data-urlencode "image=$dhcp_image" >/dev/null
scurl -f -X POST "$spoke/docker/images/pull" --data-urlencode 'image=alpine:3.20' >/dev/null
# Alpine's stock BusyBox includes udhcpc but not the udhcpd server. Use a
# dnsmasq image, override its web-UI entrypoint, and run only DHCP here.
hcurl -f -X POST "$hub/docker/containers" --data-urlencode "name=$hub_box" --data-urlencode "image=$dhcp_image" --data-urlencode "network=$hub_net" --data-urlencode "ip=$hub_ip" --data 'entrypoint=dnsmasq' --data 'cmd_0=--no-daemon' --data 'cmd_1=--interface=eth0' --data 'cmd_2=--bind-interfaces' --data-urlencode "cmd_3=--dhcp-range=$lease_start,$lease_end,255.255.255.0,1h" --data-urlencode "cmd_4=--dhcp-option=3,$hub_ip" --data 'cmd_5=--log-dhcp' >/dev/null
hcurl -f -X POST "$hub/docker/containers/$hub_box/start" --data '' >/dev/null
# Docker can clear NetworkSettings.IPAddress after a short-lived command exits,
# even though it was launched with --ip.  The test's DHCP exchange and ICMP
# below are the authoritative proof that the requested endpoint is attached to
# this bridge.  Fail early only if the DHCP server did not remain running.
hub_state=$(hcurl -f "$hub/docker/containers/$hub_box" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0]["State"]["Status"])')
[[ $hub_state == running ]] || { echo "Hub DHCP endpoint is not running (state=$hub_state)"; hcurl "$hub/docker/containers/$hub_box/logs?tail=50" || true; exit 1; }
scmd="udhcpc -n -q -s /bin/true -i eth0 -t 2 -T 2; ping -c 3 $hub_ip"
scurl -f -X POST "$spoke/docker/containers" --data-urlencode "name=$spoke_box" --data-urlencode 'image=alpine:3.20' --data-urlencode "network=$spoke_net" --data-urlencode "ip=$spoke_ip" --data 'cmd_0=sh' --data 'cmd_1=-ec' --data-urlencode "cmd_2=$scmd" >/dev/null
scurl -f -X POST "$spoke/docker/containers/$spoke_box/start" --data '' >/dev/null
sleep 8
scurl -f "$spoke/docker/containers/$spoke_box/logs?tail=50" > "$tmp/ping.log"
grep -Eq '0% packet loss|3 packets received|3 received' "$tmp/ping.log" || { echo "Overlay ping failed ($spoke -> $hub_ip)"; cat "$tmp/ping.log"; echo 'Hub overlay log:'; hcurl "$hub/logs?source=overlay&limit=80" || true; echo 'Spoke overlay log:'; scurl "$spoke/logs?source=overlay&limit=80" || true; exit 1; }
grep -Eq "lease of $lease_start obtained|lease of $lease_start" "$tmp/ping.log" || { echo "Overlay DHCP broadcast failed (expected a lease of $lease_start)"; cat "$tmp/ping.log"; echo 'Hub DHCP log:'; hcurl "$hub/docker/containers/$hub_box/logs?tail=50" || true; exit 1; }
echo "PASS: authenticated hub/spoke TAP carried DHCP broadcast, ARP resolution, and ICMP from $spoke_ip to distinct peer endpoint $hub_ip"
