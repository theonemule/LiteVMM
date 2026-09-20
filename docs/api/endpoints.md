# Endpoint reference

All paths are relative to `/api`. Parameters are form fields (query string or
`application/x-www-form-urlencoded` body) unless marked *raw body*. The
**Cap** column names the required [capability](README.md#service-discovery-and-capabilities).
Success status is `200 OK` unless noted.

Contents: [Host](#host-and-diagnostics) · [Files](#files) ·
[Certificates](#certificates) · [VMs](#virtual-machines) ·
[ISO media and storage](#iso-media-and-storage-roots) ·
[Networks](#host-networks) · [Overlays](#overlays) ·
[Backups](#backups-and-migration-import) · [Replication](#replication) ·
[Backplane](#storage-backplane) · [Containers](#docker-containers) ·
[Images](#docker-images) · [Registry](#oci-registry) ·
[Docker networks and volumes](#docker-networks-and-volumes) ·
[Compose](#compose) · [Cluster](#cluster-and-pairing)

---

## Host and diagnostics

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/` | none | Service description and capabilities ([example](README.md#service-discovery-and-capabilities)) |
| GET | `/metrics` | none | Host CPU, memory, disk, network and uptime snapshot |
| GET | `/system` | none | OS, kernel, hardware, interfaces, routes, filesystems, block devices, component versions, service state |
| GET | `/logs` | `source`: `all` (default), `system`, `overlay`, `docker`, `fcgi`, `ttyd`, `websockify`; `limit` (default `300` per source) | Array of log entries, newest first |
| POST | `/host/terminal/session` | none | `201`; starts a host shell session for `/host/terminal/` (cap `host-terminal`) |
| DELETE | `/host/terminal/session` | none | `{"stopped":true}` |

`GET /metrics` example:

```json
{"scope":"host","timestamp":1789863643,
 "cpu":{"utilization_percent":0.41,"logical_cpus":12,"load1":0.06,"load5":0.05,"load15":0.00},
 "virtualization":{"kvm_available":true,"note":"KVM acceleration available"},
 "memory":{"used_bytes":1604915200,"total_bytes":2321838080,"available_bytes":716922880,"utilization_percent":69.12},
 "disk":{"path":"/var/lib/vmapi/vms","used_bytes":4721803264,"total_bytes":29101182976,"available_bytes":22875148288,"utilization_percent":16.23},
 "network":{"rx_bytes":5328795491,"tx_bytes":838337210},"uptime_seconds":29170}
```

## Files

Cap `files`. Paths are absolute; the root is `/` unless `VMAPI_FILE_ROOT`
confines it.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/files` | `path` (default `/`) | Directory listing |
| GET | `/files/content` | `path` | File download |
| PUT | `/files/content` | `path` (query); *raw body* | `201` |
| POST | `/files/directories` | `path` | `201` |
| PATCH | `/files/move` | `source`, `destination` | Result JSON |
| POST | `/files/archive` | `path_0`…`path_255` | ZIP download |
| DELETE | `/files` | `path_0`…`path_255` | Result JSON (recursive) |

## Certificates

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/admin` or `/admin/certificates` | none | TLS status: mode, domain, subject, issuer, SANs, validity, fingerprint, pending CSR |
| POST | `/admin/certificates/letsencrypt` | `domain`, `email` | Status JSON (Certbot HTTP-01; port 80 must be reachable) |
| POST | `/admin/certificates/renew` | none | Status JSON |
| POST | `/admin/certificates/csr` | `domain` required; `sans`, `organization`, `organizational_unit`, `country`, `state`, `locality`, `key_type` (`rsa2048` default, `rsa4096`, `ec256`) | `201` |
| GET | `/admin/certificates/csr` | none | PEM CSR (`text/plain`) |
| POST | `/admin/certificates/signed` | `certificate` (PEM chain for the pending CSR) | Status JSON |
| POST | `/admin/certificates/import` | `certificate`, `private_key` (PEM), optional `domain` | Status JSON |
| DELETE | `/admin/certificates` | none | Returns the endpoint to HTTP; files retained |

`POST /admin/certificates` with `domain` and `email` is an alias for the Let's
Encrypt route.

## Virtual machines

Cap `qemu-kvm`. `{name}`: letters, digits, `.`, `_`, `-`, up to 64 characters.

### Collection and configuration

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/vms` | none | `[{"name","state"}]` |
| POST | `/vms` | see below | `201`, VM object |
| GET | `/vms/{name}` | none | VM object |
| PATCH | `/vms/{name}` | `field`, `value` (VM stopped) | VM object |
| DELETE | `/vms/{name}` | none | `{"deleted":true}` (VM stopped) |

`POST /vms` fields: `name` (required), `memory_mb`, `vcpus`, `disk_size`
(e.g. `40G`), `disk_format` (`qcow2`/`raw`), `disk_bus`
(`virtio`/`sata`/`scsi`), `disk_location` (`local` or `peer:NODE_ID`), `iso`,
`iso_peer`, `network` (`nat`/`bridge`/`overlay`/`none`), `bridge`, `overlay`,
`nic_model` (`virtio-net-pci`/`e1000`/`e1000e`/`rtl8139`), `vlan` (1–4094),
`autostart`, `firmware` (`bios`/`uefi`), `machine`, `cpu`, `emulation`
(allow TCG), `vnc_display`, `vnc_bind`, `display` (`vnc`/`none`), `boot`,
`cloud_init_user_data`, `cloud_init_hostname`. If cloud-init fails, the new VM
is removed and `400` is returned.

`PATCH` fields are `vm.conf` keys handled by `vmctl set` (e.g. `memory`,
`cpus`, `autostart`, `boot`); `field=iso` also accepts `peer_id`.

VM object:

```json
{"name":"alpine1","state":"running",
 "config":{"NAME":"alpine1","MEMORY_MB":512,"VCPUS":1,"MACHINE":"q35","CPU":"host","FIRMWARE":"bios",
   "AUTOSTART":false,"DISPLAY":"vnc","VNC_BIND":"127.0.0.1","VNC_DISPLAY":1,"BOOT_ORDER":"c",
   "DISK_0_FILE":"disk0.qcow2","DISK_0_FORMAT":"qcow2","DISK_0_BUS":"virtio",
   "NIC_0_MODE":"bridge","NIC_0_MODEL":"virtio-net-pci","NIC_0_MAC":"52:54:00:05:d4:1c","NIC_0_BRIDGE":"overlay1br0"},
 "storage":{"config_path":"/var/lib/vmapi/vms/alpine1","disk_path":"/var/lib/vmapi/disks/alpine1","iso_path":"/var/lib/vmapi/isos"}}
```

`config` is `vm.conf` verbatim: numbers and booleans are typed, and repeated
devices use `DISK_n_*`, `NIC_n_*` and `PCI_n_*` keys.

### Power

| Method | Path | Parameters | Response |
|---|---|---|---|
| POST | `/vms/{name}/start` | none | `{"state":"running","pid":N}` |
| POST | `/vms/{name}/shutdown` | `timeout`, `force` | Graceful ACPI power-down: `{"state":"stopped","graceful":true}` |
| POST | `/vms/{name}/restart` | `timeout`, `force` | Graceful shutdown then start |
| POST | `/vms/{name}/stop` | `force` | Immediate power off |
| POST | `/vms/{name}/reboot` | `force` | Immediate virtual reset |

### Devices

| Method | Path | Parameters | Response |
|---|---|---|---|
| POST | `/vms/{name}/disks` | `size` required; `file`, `format`, `bus`, `location` | `201 {"index":N}` |
| PUT | `/vms/{name}/disks/import/{filename}` | query `format` (`qcow2`/`raw`/`vmdk`), `bus`, `location`; *raw body* | `201 {"index":N}` |
| GET | `/vms/{name}/disks/{index}/download` | none | Disk file download |
| PATCH | `/vms/{name}/disks/{index}` | `field` (`size` resizes; also `bus`, …), `value` | `{"updated":true}` |
| DELETE | `/vms/{name}/disks/{index}` | `delete_file` | `{"deleted":true}` |
| POST | `/vms/{name}/nics` | `mode` (`nat`/`bridge`/`overlay`) required; `bridge`, `overlay`, `model`, `mac`, `vlan` | `201 {"index":N}` |
| PATCH | `/vms/{name}/nics/{index}` | `field`, `value` | `{"updated":true}` |
| DELETE | `/vms/{name}/nics/{index}` | none | `{"deleted":true}` |
| POST | `/vms/{name}/pci` | `bdf` (e.g. `01:00.0`) | `201 {"index":N}` |
| DELETE | `/vms/{name}/pci/{index}` | none | `{"deleted":true}` |

### Cloud-init, console and metrics

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/vms/{name}/cloud-init` | none | Seed status and user-data |
| PUT | `/vms/{name}/cloud-init` | `user_data` required; `hostname` (defaults to VM name) | Seed status (new instance ID) |
| DELETE | `/vms/{name}/cloud-init` | none | Seed status (removed) |
| GET | `/vms/{name}/console` | none | VNC details: bind, `vnc_port`, socket paths |
| GET | `/vms/{name}/console/session` | none | Session info |
| POST | `/vms/{name}/console/session` | none | `201`, token for `/console.html` / `/console/ws/?token=…` |
| PATCH | `/vms/{name}/console/session` | none | Heartbeat (send every 30 s) |
| DELETE | `/vms/{name}/console/session` | none | `{"stopped":true}` |
| GET | `/vms/{name}/metrics` | none | QEMU CPU, RSS vs configured RAM, per-disk allocation, NIC counters |

## ISO media and storage roots

Cap `qemu-kvm`.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/images` | none | `[{"name","bytes","modified"}]` |
| PUT | `/images/{filename}` | *raw body* (`.iso` or `.img`) | `201 {"name":…}` |
| GET | `/images/{filename}` | none | Download |
| DELETE | `/images/{filename}` | none | `{"deleted":true}` |
| GET | `/storage` | none | `{"config_path","disk_path","iso_path"}` |
| POST | `/storage` | `kind` (`config`/`disks`/`isos`), `path` (new absolute path) | Result JSON. All VMs must be stopped |

## Host networks

Cap `qemu-kvm`. Bridge changes run as root and can disrupt connectivity.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/networks` | none | `{"bridges":[…],"interfaces":[…]}` |
| GET | `/networks?name=BR` | none | Bridge details |
| POST | `/networks` | `name`; `address` (CIDR) or `dhcp=true` or `manual=true`; `gateway`; `member_0`…`member_15`; `persist` | `201 {"name":…}` |
| PATCH | `/networks` | as POST; members are replaced, `persist=false` removes persistence | Bridge details |
| DELETE | `/networks?name=BR` | none | `{"deleted":true}` |

## Overlays

Cap `qemu-kvm`. Overlay names: `^[a-z][a-z0-9-]{0,10}$`.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/overlays` | none | Array of overlay objects |
| GET | `/overlays/{name}` | none | Overlay object |
| GET | `/overlays/{name}/health` | none | `{"name","staged","peer_reachable","probe"}` |
| POST | `/overlays` | `name`, `bridge`, `role` (`hub`/`spoke`), `mtu` (1200–1500, default 1500), `staged`, `peer_0`…`peer_15` (node IDs; a spoke takes exactly one hub) | `201`, overlay object. Also creates each peer's endpoint; rolls back on failure (`502` naming the peer) |
| POST | `/overlays/{name}/stage` \| `/validate` \| `/activate` | none | Staged-test workflow |
| DELETE | `/overlays/{name}` | none | `{"deleted":true,"remote_cleanup":"complete"}`, or `"warning"` plus a `warning` string if a peer could not be cleaned |

Overlay object:

```json
{"name":"overlay1","bridge":"overlay1br0","role":"hub","mtu":1500,
 "peers":["1dc34747e9c4543aa61306787a444ed7"],"tap":"vmo-overlay1","tap_bridge_learning":"off",
 "state":"active","running":true,"tap_process":true,"tap_type":"tap","tap_up":true,"tap_bridged":true,
 "relay_path":"/overlay/overlay1","tap_cidr":"10.77.174.1/24","tap_peer":"10.77.174.2"}
```

Called through the peer API, `POST /overlays` creates only the local endpoint,
bound to the calling peer, and `DELETE` removes only the local endpoint.

## Backups and migration import

Cap `backup`. On `backup`-profile hosts only listing, download and delete are
available.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/backups` | none | `[{"vm","archive","bytes","modified","target","owner"}]` (`target`: `local` or `backplane`) |
| POST | `/backups/create` | `name`; `live`, `label`, `destination` (folder), `keep`, `peer_id` | `201`, result (synchronous) |
| POST | `/backups/start` | as `create` | `202`, job descriptor (asynchronous) |
| GET | `/backups/jobs/{id}` | none | Job progress |
| POST | `/backups/restore` | `name`, `archive`; `destination`, `peer_id` (where the archive is stored), `replace` | `201`, result |
| GET | `/backups/{vm}/{archive}` | none | `application/gzip` download |
| DELETE | `/backups/{vm}/{archive}` | none | `{"deleted":true}` |
| GET | `/backups/schedules` | none | `[{"vm","cron","label","destination","keep","live","target","peer_id","scheduler_active"}]` |
| POST | `/backups/schedule` | `name`, `cron`; `label`, `destination`, `keep`, `live`, `peer_id` | `201 {"scheduled":true}` |
| DELETE | `/backups/unschedule` | `name`; `label` | `{"unscheduled":true}` |
| POST | `/migrations/import/{archive}` | *raw body* (`.tar.gz`) | `201`; imports a VM archive (used by migration) |

SSH, SCP and SFTP destinations are rejected (`transport`, `ssh`, `remote_dir`
return `400`); use `peer_id`.

## Replication

| Method | Path | Cap | Parameters | Response |
|---|---|---|---|---|
| GET | `/replications` | `replication-source` | none | Array of replication status objects |
| POST | `/replications` | `replication-source` | `name`, `peer_id`; `speed` (bytes/s, `0` = unlimited) | `201`, status |
| GET | `/replications/{vm}` | `replication-source` | none | Status |
| DELETE | `/replications/{vm}` | `replication-source` | none | Stops replication; replica files are kept |
| GET | `/replications/replicas` | `storage-backplane` | none | Replicas hosted **on this host** |
| GET | `/replications/replicas/{id}` | `storage-backplane` | none | One hosted replica |
| DELETE | `/replications/replicas/{id}` | `storage-backplane` | `delete_file` | Purges a hosted replica |

Status object:

```json
{"vm":"alpine1","configured":true,"paused":false,"peer_id":"1dc34747e9c4543aa61306787a444ed7",
 "running":true,"transport":"nfs4-wss-backplane",
 "disks":[{"index":0,"job":"repl-0","ready":true,"offset":1179648,"length":1179648,
   "bytes":8589934592,"tunnel_running":true,"backplane_connected":true}]}
```

## Storage backplane

Cap `storage-backplane`. Local administration only (`403` via the peer API).

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/backplane/status` | none | Listener verification (below) |
| GET | `/backplane/docker-volumes` | none | Peer volumes hosted on this host |
| GET | `/backplane/docker-volumes/{id}` | none | One hosted volume |
| DELETE | `/backplane/docker-volumes/{id}` | `delete_data` | Removes the hosted volume record (and data if requested) |

```json
{"server_enabled":true,"nfs_bind":"127.0.0.1","nfs_export_client":"127.0.0.1","nfs_port":2049,
 "nfs_listening":true,"websocket_bind":"127.0.0.1","websocket_port":6091,
 "websocket_listening":true,"external_exposure":false}
```

`external_exposure` becomes `true` if NFS or its WebSocket bridge is listening
on anything other than loopback, or if NFS is listening on UDP.

## Docker containers

Cap `docker`.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/docker/containers` | none | Array of container summaries |
| POST | `/docker/containers` | see below | `201`, container details |
| GET | `/docker/containers/{name}` | none | Container details |
| PATCH | `/docker/containers/{name}` | `field` (`cpus`, `memory`, `restart`), `value` | Container details |
| DELETE | `/docker/containers/{name}` | `force`, `volumes` | `{"deleted":true}` |
| POST | `/docker/containers/{name}/start` | none | `{"state":"running"}` |
| POST | `/docker/containers/{name}/stop` | `time`, `force` | `{"state":"stopped"}` |
| POST | `/docker/containers/{name}/restart` | `time` | `{"restarted":true}` |
| GET | `/docker/containers/{name}/metrics` | none | CPU, memory, network, block I/O, PIDs, limits, sizes |
| GET | `/docker/containers/{name}/logs` | `tail`, `since`, `timestamps`, `follow` | `text/plain`; `follow=true` streams |
| POST | `/docker/containers/{name}/commit` | `image` required; `author`, `message`, `pause` | `201 {"image","id"}` |
| GET/POST/PATCH/DELETE | `/docker/containers/{name}/exec/session` | POST: `shell` (default `/bin/sh`) | Terminal session for `/docker/terminal/` (POST `201`, PATCH heartbeat) |

`POST /docker/containers` fields: `name`, `image` (required); `hostname`,
`restart`, `cpus`, `memory`, `network`, `ip`, `user`, `workdir`, `entrypoint`,
`read_only`; repeatable `env_N`, `publish_N`, `volume_N`, `label_N` (N up to
63) and `cmd_N` (command arguments, in order). If the image exists only on a
peer, the container is created with the zero-copy remote runtime.

## Docker images

Cap `docker`.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/docker/images` | none | Local images |
| GET | `/docker/images?image=REF` | none | `docker image inspect` |
| DELETE | `/docker/images?image=REF` | `force` | `{"deleted":true,"output":…}` |
| GET | `/docker/images/federated` | none | Catalog of this host and all peers (local only) |
| POST | `/docker/images/prepare` | `image` | Prepares zero-copy use of a peer image (local only) |
| POST | `/docker/images/expose` | `image` | Exposes a local image as a read-only rootfs on the backplane (called by peers) |
| POST | `/docker/images/pull` | `image` | Normal local pull (local only) |
| POST | `/docker/images/tag` | `source`, `target` | `{"tagged":true}` |
| PUT | `/docker/images/build` | query `tag` required, `dockerfile` (default `Dockerfile`); *raw body* tar or compressed tar build context | `201` |

The build context is streamed straight into `docker build`; it is never
extracted onto the host.

## OCI registry

Cap `docker`.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/docker/registry` | none | `{"enabled","running","username","image","loopback_port","path":"/v2/"}` |
| POST | `/docker/registry` | `username` (default `registry`) | `201`, status. Starts `registry:3` on `127.0.0.1:5000` and publishes `/v2/` |
| DELETE | `/docker/registry` | none | Status (disabled; data kept) |
| GET | `/docker/registry/credentials` | none | `{"username","password","path"}` |
| GET | `/docker/registry/catalog` | none | Registry `_catalog` |
| POST | `/docker/registry/push` | `source`, `repository` (`name[:tag]`) | `{"published":true,…}` |

The registry itself is at `/v2/` (not under `/api`) with its own credential.

## Docker networks and volumes

Cap `docker`.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/docker/networks` | none | Array |
| POST | `/docker/networks` | `name`; `driver`, `subnet`, `gateway`, `internal`, `ipv6`, `label_N`, `opt_N` | `201`, inspect |
| GET / DELETE | `/docker/networks/{name}` | none | Inspect / `{"deleted":true}` |
| GET | `/docker/volumes` | none | Array |
| POST | `/docker/volumes` | `name`; `driver`, `label_N`, `opt_N` (e.g. `type=nfs`, `o=addr=…`, `device=:/export`) | `201`, inspect |
| GET | `/docker/volumes/{name}` | none | Inspect |
| DELETE | `/docker/volumes/{name}` | `force` | `{"deleted":true}` |
| GET | `/docker/peer-volumes` | none | Peer-backed volumes attached here (cap `peer-volume-client`) |
| POST | `/docker/peer-volumes` | `peer_id`, `remote_name`; `name` (defaults to `remote_name`) | `201`. Creates/attaches a directory on the peer's backplane as a local named volume |
| GET / DELETE | `/docker/peer-volumes/{name}` | none | Show / detach (data stays on the peer) |

## Compose

Cap `docker`.

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/compose/projects` | none | Array of projects |
| PUT | `/compose/projects/{project}` | *raw body* (YAML) | `201`; validated with `docker compose config` and stored |
| GET | `/compose/projects/{project}` | none | Stored YAML (`text/plain`) |
| POST | `/compose/projects/{project}/deploy` | none | `up -d --remove-orphans` result |
| POST | `/compose/projects/{project}/down` | none | `down` result |
| DELETE | `/compose/projects/{project}` | none | `{"deleted":true}` |

## Cluster and pairing

| Method | Path | Parameters | Response |
|---|---|---|---|
| GET | `/cluster/identity` | none | `{"node_id","name","key_algorithm":"ed25519","public_key_fingerprint"}` |
| GET | `/cluster/peers` | none | `[{"node_id","name","url","api_auth","public_key_fingerprint","relay_configured"}]` |
| DELETE | `/cluster/peers/{id}` | none | `{"revoked":true}` |
| ANY | `/cluster/peers/{id}/proxy` | query `path` | Peer's response ([proxy](README.md#the-peer-proxy)) |
| GET | `/cluster/peers/{id}/overlay-credentials` | none | The pair's credential (cap `vm-network`). **Secret** |
| PATCH | `/cluster/peer-url` | `node_id`, `url` | `{"updated":true}` |
| POST | `/cluster/migrate` | `vm`, `node_id` | `{"migrated":true,"vm","peer","archive"}` (cap `qemu-kvm`) |
| POST | `/cluster/pair/request` | `name`, `endpoint` (this host's URL) | Request bundle (`text/plain`) |
| GET | `/cluster/pair/pending` | none | The pending request bundle, or an empty body |
| DELETE | `/cluster/pair/pending` | none | `{"revoked":true}` |
| POST | `/cluster/pair/accept` | `bundle`, `name`, `endpoint` | Response bundle (`text/plain`) |
| POST | `/cluster/pair/complete` | `bundle` | `{"trusted":true,"node_id","name","api_auth":"basic","public_key_fingerprint"}` |

Scripted pairing between hosts A and B:

```sh
REQ=$(curl -su admin -X POST --data 'name=hv-a&endpoint=https://a.example:5186' https://a.example:5186/api/cluster/pair/request)
RESP=$(curl -su admin -X POST --data-urlencode "bundle=$REQ" --data 'name=hv-b&endpoint=https://b.example:5186' https://b.example:5186/api/cluster/pair/accept)
curl -su admin -X POST --data-urlencode "bundle=$RESP" https://a.example:5186/api/cluster/pair/complete
```

Only automate this where you already trust both hosts; the manual exchange
exists so that a person verifies the fingerprints.

## Web paths outside `/api`

| Path | Purpose | Authentication |
|---|---|---|
| `/` | Console (static files) | User login |
| `/files.html`, `/console.html` | File browser, VM console page | User login |
| `/console/ws/?token=…` | noVNC WebSocket → `websockify` (Alpine) | User login + token |
| `/docker/terminal/`, `/host/terminal/` | `ttyd` terminals | User login + session |
| `/peer-api/…` | Peer API | Pair credential |
| `/backplane/storage` | Storage backplane WebSocket (NFSv4) | Pair credential |
| `/overlay/NAME` | Overlay WebSocket on hubs | Pair credential of that overlay's members only |
| `/v2/` | OCI registry (when enabled) | Registry credential |
