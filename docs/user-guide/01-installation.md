# 1. Installation

## Supported platforms

| Platform | Init system | Web server | Notes |
|---|---|---|---|
| **Alpine Linux** (primary target) | OpenRC | lighttpd | Smallest footprint. Required for overlay **hubs** and the in-browser VM console (noVNC). |
| Debian, Ubuntu and derivatives | systemd | nginx (PAM authentication) | Listens on `127.0.0.1` by default; reach it through an SSH tunnel or configure HTTPS. |

Alpine is the recommended platform. LiteVMM is designed for small hosts, and
Alpine keeps the base system to a few hundred megabytes on disk.

Hardware virtualization (Intel VT-x / AMD-V with `/dev/kvm`) is required for
usable VM performance. LiteVMM can fall back to software emulation (TCG) per VM,
but only when you explicitly allow it.

## Choose a profile

The API and console are always installed. The **profile** decides which
workload features and host packages are added.

| Profile | Adds | Typical use |
|---|---|---|
| `backup` | Backup storage and the storage backplane server only | A storage node that receives backups, replicas and peer volumes |
| `virtualization` | QEMU/KVM, VM networking and consoles, cloud-init, overlays, VM backups, live replication | A VM host |
| `docker` | Docker and Compose, container terminals, peer volumes, federated images, optional OCI registry | A container host |
| `virtualization-docker` | Everything above | A combined host (the screenshots in this guide) |

Every profile can also act as backup storage for its peers.

## Install

Log in to the target host over SSH, fetch the source, and run the installer as
root:

```sh
# Alpine
apk add git bash
# Debian / Ubuntu
apt-get install -y git

git clone https://github.com/theonemule/LiteVMM.git
cd LiteVMM
sudo ./install.sh --profile virtualization-docker --port 5186
```

Run `sudo ./install.sh` without arguments for an interactive menu. For
unattended installs, set these environment variables:

| Variable | Meaning |
|---|---|
| `VMAPI_INSTALL_PROFILE` | One of the four profile names |
| `VMAPI_HTTP_PORT` | Management port (default `5186`) |
| `VMAPI_HTTP_USER` / `VMAPI_HTTP_PASSWORD` | Console login (Alpine/lighttpd) |

On Debian the console authenticates against local system accounts through PAM,
so log in with an existing Linux user.

### Upgrading

Re-running the installer is the supported upgrade path. It updates packages,
scripts, services and configuration while preserving VMs, disks, backups,
peers, bridges and overlays:

```sh
cd LiteVMM
git pull --ff-only
sudo ./install.sh --profile virtualization-docker --port 5186
```

Upgrade paired hosts together. Peers talk to each other through the same API,
so mismatched versions can disagree about endpoints.

## First login

Browse to `http://HOST:5186/`. The browser shows its normal HTTP Basic login
prompt; LiteVMM itself never sees or stores your password in JavaScript.

On Debian the listener is bound to loopback. Tunnel it from your workstation:

```sh
ssh -L 5186:127.0.0.1:5186 you@host
# then browse to http://127.0.0.1:5186/
```

> **Use HTTPS before exposing the console to a network.** HTTP Basic
> credentials are only base64-encoded. See
> [Certificates](02-console-basics.md#certificate-management) to enable
> Let's Encrypt, a CSR workflow, or an imported certificate.

## Run a storage node in a container

The repository's `Dockerfile` builds a `backup`-profile node. It starts the
kernel NFS server inside the container, so it must run privileged:

```sh
docker build -t litevmm-backup .
docker run -d --privileged --name litevmm-backup -p 5186:5186 \
  -e VMAPI_HTTP_USER=admin -e VMAPI_HTTP_PASSWORD='choose-a-strong-password' \
  -v litevmm-backup-data:/var/lib/vmapi litevmm-backup
```

Only the management port is published. NFS stays on `127.0.0.1:2049` inside
the container and peers reach it through the WebSocket backplane.
