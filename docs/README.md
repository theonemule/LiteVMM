# LiteVMM documentation

LiteVMM is a minimalist hypervisor and container host. It manages QEMU/KVM
virtual machines and Docker workloads from one small web console and HTTP API,
and it links hosts together into a peer cluster for backups, replication,
shared storage and Layer-2 networking.

It is deliberately small. There is **no database**, no application server, no
Python or Node backend and no libvirt. The control plane is a set of Bash
scripts behind a stock web server, state lives in plain files, and each
feature is delegated to a native Linux tool (QEMU, Docker, the kernel NFS
server, `ip`, `openssl`). On Alpine Linux the whole LiteVMM code base installs
into **under 1 MB**, and the full VM + Docker control plane runs in roughly
**100 MB of RAM**, leaving the host's memory and disk for workloads.

## The three guides

| Guide | For | Start here |
|---|---|---|
| **User guide** | Operators using the web console: installing, creating VMs and containers, networking, backups, pairing hosts. | [user-guide/README.md](user-guide/README.md) |
| **API reference** | Automation and integration: every HTTP endpoint, its parameters, responses and errors. | [api/README.md](api/README.md) |
| **Technical guide** | Administrators and contributors: daemons, data paths, the peer trust model, the storage backplane, overlays, replication, and the assumptions baked into all of them. | [technical/README.md](technical/README.md) |

## Suggested reading paths

- **First install:** [Installation](user-guide/01-installation.md) →
  [Console basics](user-guide/02-console-basics.md) → the chapter for your
  workload ([VMs](user-guide/03-virtual-machines.md) or
  [containers](user-guide/04-containers.md)).
- **Building a two-host cluster:** [Cluster and pairing](user-guide/07-cluster.md)
  → [Backups and replication](user-guide/06-backups-and-replication.md) →
  [Peering internals](technical/peering.md) →
  [Storage backplane](technical/storage-backplane.md).
- **Scripting LiteVMM:** [API conventions](api/README.md) →
  [Endpoint reference](api/endpoints.md).
- **Debugging a host:** [Troubleshooting](user-guide/09-troubleshooting.md) →
  [Architecture](technical/architecture.md) →
  [Security model and assumptions](technical/security-and-assumptions.md).

## Conventions used in these guides

- Examples use a host at `http://10.0.1.185:5186`; substitute your own.
  `5186` is LiteVMM's default management port.
- Shell commands prefixed with `sudo` run on the LiteVMM host itself.
- Screenshots were taken from a two-host lab (10.0.1.184 and 10.0.1.185)
  running Alpine Linux 3.24 with the `virtualization-docker` profile.
- A **host**, **node** and **peer** are the same thing seen from different
  angles: a machine running LiteVMM. Every host has a 32-character hex
  **node ID**.

These guides describe LiteVMM 0.12. The source of truth for API behaviour is
`cgi/api.cgi`; if a guide and the code disagree, the code wins and the guide
has a bug.
