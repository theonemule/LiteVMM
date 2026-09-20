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
| GOST | pinned upstream binary (v3.2.6, SHA-256 checked) | pinned upstream binary (v3.2.6, SHA-256 checked) |
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
| `backup` | `nfs-utils` + GOST |
| `virtualization` | `qemu-system-x86_64 qemu-img ovmf novnc ttyd xorriso nfs-utils iptables nftables socat kmod tcpdump` + GOST |
| `docker` | `docker docker-cli-compose ttyd nfs-utils` + GOST |
| `virtualization-docker` | union of the two |

GOST v3 (3.2.6) is downloaded from its GitHub release and SHA-256 checked for
all profiles.

Debian installs the equivalents (`qemu-system-x86`, `qemu-utils`, `docker.io`,
`nfs-kernel-server`, `nginx`, …).

## Footprint after GOST consolidation

LiteVMM now ships one native GOST binary for the WebSocket transport roles used
by storage, VM consoles, and TAP overlays. The previous lab RSS table measured
the removed Python console/storage brokers and the former storage client bridge,
so those process totals are no longer representative and are intentionally not
carried forward.

The GOST v3.2.6 binary is about 9.7 MB on the measured x86_64 lab host. Runtime
RSS depends on how many overlays, mounted peers, and active VM consoles are
running because each of those may own a GOST process. Re-measure the full
control-plane RSS on a deployed host before using a memory total for sizing.

LiteVMM scripts, CGI, libraries, and static UI remain under roughly 1 MB in the
previous lab measurement; QEMU and Docker remain the dominant disk consumers.

## Hardware assumptions

- x86_64 (QEMU is `qemu-system-x86_64`; GOST is fetched for
  x86_64 or aarch64).
- Intel VT-x or AMD-V exposed as `/dev/kvm` for VMs. Nested virtualization
  works (the lab hosts are Hyper-V guests) but needs MAC spoofing on the outer
  switch for bridged guests.
- IOMMU and VFIO configured by the administrator for PCI passthrough.
