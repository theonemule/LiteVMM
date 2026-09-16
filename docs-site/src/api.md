---
layout: layout.njk
title: API reference
---
# API reference

All browser API paths begin with `/api` and require the same HTTP Basic authentication as the console. Forms use `application/x-www-form-urlencoded`; image/file/Compose uploads stream raw request bodies. Responses are JSON unless downloading content, logs, archives, or pairing bundles. The service identity returned from `GET /api/` is `litevmm`; the established `vmapi` command and filesystem identifiers remain compatible.

| Resource | Operations |
|---|---|
| Service | `GET /` returns service metadata and capabilities. |
| System inventory | `GET /system` returns host, OS, hardware, network, storage, component-version, and service-state inventory. |
| Metrics/logs | `GET /metrics`, `GET /logs?source=&limit=`. |
| VMs | `GET, POST /vms`; `GET, PATCH, DELETE /vms/{name}`; lifecycle includes graceful `/shutdown` and `/restart` plus immediate `/stop` and `/reboot`; metrics, console, disks, NICs (including optional VLAN ID), and PCI subresources. |
| VM images | `GET /images`; `PUT, DELETE /images/{filename}`. |
| Docker | Containers, images, networks, and volumes under `/docker/...`; container subresources include lifecycle, metrics, logs, commit, and exec sessions. |
| Compose | `GET /compose/projects`; `PUT, GET, DELETE /compose/projects/{name}`; `POST .../deploy` and `.../down`. |
| Host networking | `GET, POST, PATCH, DELETE /networks`. |
| Files | List, upload/download, create directory, move, zip, and delete under `/files`. |
| Backups | List/create/restore/download/delete and schedule routes under `/backups`; `POST /backups/start` queues a tracked job and `GET /backups/jobs/{id}` returns its phase status. |
| Cluster | Identity, peer list/revocation, endpoint update, pairing, migration, and signed proxy routes under `/cluster`. |
| Overlays | List/create/show/delete and orphan cleanup under `/overlays`. |

The exact request fields are enforced in `cgi/api.cgi`; use the console for normal administration and the regression scripts as curl examples. The peer-only `/peer-api` is not a browser endpoint: it requires HTTP Basic authentication using the same paired credential as hub WebSocket upgrades.
