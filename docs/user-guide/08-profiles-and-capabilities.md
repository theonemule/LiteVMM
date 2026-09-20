# 8. Profiles and capabilities

Hosts in one cluster can run different profiles, so the console decides what
to show from each host's **capabilities**, not from its profile name. The
capability list is reported by `GET /api/` and shown on the Certificate
management page.

## Where capabilities come from

Most capabilities are detected from what is actually installed, not just from
the configured profile. If you install Docker on a `virtualization` host, the
Docker capabilities appear.

| Capability | Present when | Enables |
|---|---|---|
| `api`, `system`, `metrics`, `cluster`, `admin`, `backup`, `backup-storage` | Always | Overview, System information, Cluster, certificates, backup listing/storage |
| `qemu-kvm`, `backup-create`, `vm-network`, `vm-console`, `storage`, `cloud-init`, `replication-source` | QEMU is installed | Virtual machines and Networks pages, VM backups, replication source |
| `docker`, `compose`, `container-terminal`, `registry`, `peer-volume-client` | Docker is available | Containers and Compose pages, terminals, OCI registry, paired-storage volumes |
| `backplane-client` | QEMU or Docker available | Mounting peers' storage backplanes |
| `storage-backplane` | `VMAPI_BACKPLANE_SERVER=true` in `/etc/vmapi/vmapi.conf` | Being a destination for peer backups, replicas, peer volumes and shared ISOs |
| `files`, `host-terminal` | QEMU or Docker available | File browser and host terminal |

`backup`-profile hosts are the exception: their profile is always reported as
`backup`, and backup creation, scheduling and restore are refused there
(nothing to back up).

## How the console uses them

- Sidebar pages whose capability is missing on the **selected** host are
  hidden, and navigating to them falls back to the Overview.
- Buttons for optional features (Replication, Console, paired-storage volumes)
  appear only when the relevant capability is present.
- Cross-host inventories (backups, ISO media, disks, replicas, images) skip
  peers that lack the capability for that list, instead of reporting an error.

## How the API enforces them

Capabilities are an API boundary, not just a display hint. A request to a route
whose capability is missing returns:

```http
HTTP/1.1 404 Not Found
{"error":"Capability is not installed or available on this host: storage-backplane"}
```

Through the peer proxy, that becomes a `502 Bad Gateway` wrapping the peer's
404. See [Troubleshooting](09-troubleshooting.md#capability-is-not-installed-or-available-on-this-host).
