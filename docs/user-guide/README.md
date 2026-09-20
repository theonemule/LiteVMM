# User guide

This guide walks through the LiteVMM web console page by page and system by
system. Each chapter is self-contained.

1. [Installation](01-installation.md): profiles, supported platforms, first login.
2. [Console basics](02-console-basics.md): layout, the Overview page, host
   diagnostics, the file browser, host terminal and HTTPS certificates.
3. [Virtual machines](03-virtual-machines.md): creating, editing and running
   VMs; disks, NICs, PCI passthrough, cloud-init, consoles, ISO media and
   storage locations.
4. [Containers](04-containers.md): Docker containers, the federated image
   library, the optional OCI registry and Compose projects.
5. [Networks](05-networks.md): host adapters, Linux bridges, VLANs, Docker
   networks and GOST TAP overlays.
6. [Backups and replication](06-backups-and-replication.md): archives,
   schedules, restore, live disk replication and hosted peer volumes.
7. [Cluster and pairing](07-cluster.md): pairing hosts, managing peers,
   operating a remote host from one console, VM migration.
8. [Profiles and capabilities](08-profiles-and-capabilities.md): why some
   pages or buttons appear on one host and not another.
9. [Troubleshooting](09-troubleshooting.md): common errors and what they mean.

## What LiteVMM is, and is not

LiteVMM gives you one lightweight management plane over two native backends:

- **the filesystem plus QEMU/KVM** for virtual machines, and
- **the Docker daemon** for containers, images, networks and volumes.

It is intentionally **not** libvirt, Proxmox, Kubernetes or Portainer. It does
not schedule workloads across hosts, does not fail VMs over automatically,
does not replicate guest RAM, and does not keep its own copy of Docker's
metadata. Where it links hosts together, it does so with ordinary Linux
building blocks (NFSv4, WebSockets, Linux bridges) that you can inspect with
normal tools.
