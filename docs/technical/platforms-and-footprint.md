# Platforms and footprint

## Alpine versus Debian

| | Alpine (primary) | Debian / Ubuntu |
|---|---|---|
| Init | OpenRC + `supervise-daemon` | systemd |
| Web server | lighttpd (`mod_auth`, `mod_fastcgi`, `mod_proxy`) | nginx |
| Console login | htpasswd (`/etc/lighttpd/vmapi.htpasswd`) | PAM (`libnginx-mod-http-auth-pam`), local accounts |
| Default listen | configured port on all interfaces | `127.0.0.1:5186` |
| FastCGI | `spawn-fcgi` + `fcgiwrap` | `fcgiwrap` socket unit |
| NFS export helper | `rpc.mountd -N 2 -N 3 -u` | `nfsv4.exportd` |
| Cron | BusyBox `crond` | `cron` |
| `websocat` | distribution package | pinned upstream binary (v1.14.1, SHA-256 checked) |
| Overlay hub | yes | **no** (spoke only) |
| Browser VM console (noVNC) | yes | **no** (use an SSH tunnel to VNC) |
| Logs | `/var/log/<service>.log` | `journalctl -u <service>` |

Shell scripts target Bash and avoid GNU-only behaviour where BusyBox differs;
tools search `/usr/sbin`, `/sbin`, `/usr/bin` and `/bin` because service
managers may start them with a short `PATH`.

## Packages per profile (Alpine)

| Profile | Adds, beyond the base set |
|---|---|
| base (all) | `bash coreutils findutils gawk grep sed shadow util-linux iproute2 iputils curl openssl ca-certificates sudo tar gzip zip jq fcgiwrap spawn-fcgi lighttpd lighttpd-mod_auth apache2-utils openssh-client certbot` |
| `backup` | `nfs-utils websockify` |
| `virtualization` | `qemu-system-x86_64 qemu-img ovmf novnc websockify ttyd xorriso nfs-utils websocat iptables nftables socat kmod tcpdump` + GOST |
| `docker` | `docker docker-cli-compose ttyd nfs-utils websockify websocat` |
| `virtualization-docker` | union of the two |

GOST v3 (3.2.6) is downloaded from its GitHub release and SHA-256 checked for
the virtualization profiles.

Debian installs the equivalents (`qemu-system-x86`, `qemu-utils`, `docker.io`,
`nfs-kernel-server`, `nginx`, …).

## Measured footprint

Measured on the lab host 10.0.1.185: Alpine 3.24, kernel 6.18, 12 vCPU, 2.2 GB
RAM, `virtualization-docker` profile, one running VM, one active overlay hub,
the backplane server running and one peer mounted.

**Disk**

| Item | Size |
|---|---|
| LiteVMM scripts, CGI and libraries | ~360 KB |
| Console (HTML/JS/CSS incl. vendored Bootstrap) | ~600 KB |
| **LiteVMM total** | **< 1 MB** |
| lighttpd / fcgiwrap / websockify / ttyd | ~0.9 MB / 22 KB / 136 KB / 229 KB |
| GOST / websocat binaries | ~9.7 MB / ~2.1 MB |
| QEMU system emulator | ~33 MB |

The largest costs are the workload engines (QEMU, Docker), not LiteVMM.

**Memory (resident set size)**

| Process | RSS |
|---|---|
| `websockify` ×2 (NFS bridge, console broker; Python) | 42.6 MB |
| GOST (one overlay) | 20.7 MB |
| `fcgiwrap` pool (×25 processes) | 11.3 MB |
| `websocat` (one peer mount) | 6.1 MB |
| lighttpd | 4.1 MB |
| Bash service loops (backplane ×2, replication, overlay, console GC) | ~8.8 MB |
| `ttyd` ×2 | 3.2 MB |
| `rpc.mountd`, `supervise-daemon` ×9 | ~5 MB |
| **Control plane total** | **≈ 100 MB** |

RSS counts shared libraries in every process that maps them, so the true
unique total is lower. For comparison, the running 512 MB Alpine guest's QEMU process used
78 MB of RSS.

### Where the memory goes, and how to trim it

- The two **Python `websockify`** processes are the largest single item. A
  host without VMs does not need the console broker; a host that is not a
  storage server does not need the NFS bridge.
- **GOST** costs ~20 MB per overlay.
- `fcgiwrap` workers are small and pre-forked; the pool size bounds
  concurrent API requests.
- Idle Bash loops sleep between 10-second passes and use negligible CPU.

There is no database, no metrics store and no agent: memory use stays flat
over time rather than growing with history.

## Hardware assumptions

- x86_64 (QEMU is `qemu-system-x86_64`; `websocat` and GOST are fetched for
  x86_64 or aarch64).
- Intel VT-x or AMD-V exposed as `/dev/kvm` for VMs. Nested virtualization
  works (the lab hosts are Hyper-V guests) but needs MAC spoofing on the outer
  switch for bridged guests.
- IOMMU and VFIO configured by the administrator for PCI passthrough.
