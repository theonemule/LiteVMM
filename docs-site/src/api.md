---
layout: layout.njk
title: API reference
---
# API reference

All browser API paths begin with `/api` and require the same HTTP Basic authentication as the console. Forms use `application/x-www-form-urlencoded`; image/file/Compose uploads stream raw request bodies. Responses are JSON unless downloading content, logs, archives, or pairing bundles. The service identity returned from `GET /api/` is `litevmm`; it also reports the active deployment `profile`, management `port`, TLS state, and authoritative capability list. The established `vmapi` command and core filesystem identifiers remain, while retired peer-storage transport endpoints are not carried forward in 0.10.

| Resource | Operations |
|---|---|
| Service | `GET /` returns service metadata, profile, management port, TLS state, and capabilities. |
| System inventory | `GET /system` returns host, OS, hardware, network, storage, component-version, and service-state inventory. |
| Metrics/logs | `GET /metrics`, `GET /logs?source=&limit=`. |
| VMs | `GET, POST /vms`; `GET, PATCH, DELETE /vms/{name}`; lifecycle includes graceful `/shutdown` and `/restart` plus immediate `/stop` and `/reboot`; metrics, console, disks, NICs (including optional VLAN ID), PCI, and `/vms/{name}/cloud-init` subresources. |
| VM images | `GET /images`; `PUT, DELETE /images/{filename}`. |
| Docker | Containers, images, networks, and volumes under `/docker/...`; container subresources include lifecycle, metrics, logs, commit, and exec sessions. |
| Compose | `GET /compose/projects`; `PUT, GET, DELETE /compose/projects/{name}`; `POST .../deploy` and `.../down`. |
| Host networking | `GET, POST, PATCH, DELETE /networks`. |
| Files | List, upload/download, create directory, move, zip, and delete under `/files`. |
| Backups | Virtualization nodes can create/schedule/restore/download/delete. Backup-profile nodes inventory/download/delete archives stored in the shared peer backplane; peer-targeted backups write through the mounted NFSv4/WSS backplane. |
| Storage backplane | `GET /backplane/status`; list/show/delete hosted Docker volume directories under `/backplane/docker-volumes`. The data path is `/backplane/storage`; NFS itself remains loopback-only. |
| Peer Docker volumes | `GET, POST /docker/peer-volumes`; `GET, DELETE /docker/peer-volumes/{name}`. |
| Replication | Source management under `/replications`; retained destination replica inventory under `/replications/replicas`. Replica files are written through the shared storage backplane. |
| Cluster | Identity, peer list/revocation, endpoint update, pairing, and signed proxy routes under `/cluster`; VM migration is virtualization-only. |
| Admin | `GET /admin` reports active TLS metadata and pending CSR state. Certificate operations under `/admin/certificates` support Let's Encrypt, CSR generation/download, signed-CSR import, direct certificate/private-key import, renewal, and HTTPS disable. |
| Overlays | List/create/show/delete and orphan cleanup under `/overlays`. |

The exact request fields are enforced in `cgi/api.cgi`; use the console for normal administration and the regression scripts as curl examples. The peer-only `/peer-api` is not a browser endpoint: it requires HTTP Basic authentication using the same paired credential as hub WebSocket upgrades.


Profile filtering is enforced by the CGI before platform tools are invoked. A hidden UI control is not the security boundary: direct calls to VM routes on a `backup` or `docker` node, or Docker routes on a `backup` or `virtualization` node, return `404 Not Found` for the unavailable capability.


## Cloud-init VM resource

Virtualization profiles expose `GET /vms/{name}/cloud-init`, `PUT /vms/{name}/cloud-init`, and `DELETE /vms/{name}/cloud-init`. `PUT` accepts URL-encoded `user_data` and optional `hostname`. User-data may be cloud-config YAML or a shell script. Updating it regenerates the NoCloud seed and rotates its instance ID; the VM must be stopped. VM creation also accepts `cloud_init_user_data` and optional `cloud_init_hostname`.
