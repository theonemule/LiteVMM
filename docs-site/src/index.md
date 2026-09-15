---
layout: layout.njk
title: Overview
---
# TinyVisor documentation

TinyVisor is a minimalist QEMU/KVM hypervisor console with optional Docker management. Its purpose is to make a small set of host virtualization operations understandable, inspectable, and directly operable without a heavyweight control plane. The host filesystem stores VM state; Docker remains authoritative for its own objects. A static Bootstrap console calls a Bash CGI API through Nginx/fcgiwrap on Debian or lighttpd/fcgiwrap on Alpine.

## Start here

1. Follow the [Quick start](/quick-start/) to install on a development host.
2. Read [Configuration](/configuration/) before changing default storage, QEMU, or Docker paths.
3. Use [Console & screenshots](/interface/) to orient yourself in the UI.
4. Read [Operations](/operations/) before exposing the service or using pairing, backups, or destructive tests.

## Architecture

```text
Browser or curl → Nginx/lighttpd → fcgiwrap → cgi/api.cgi
                                         ├─ vmctl / qemu-system
                                         ├─ docker*ctl / Docker daemon
                                         ├─ filectl / vmbackupctl / peerctl
                                         └─ overlayctl / GOST TAP-over-WebSocket
```

The CGI router validates HTTP input and delegates work to narrowly focused shell tools. Those tools are also usable directly over SSH. There is no database, libvirt dependency, application server, or frontend build step in the runtime product.

<div class="callout">Treat access to TinyVisor as host-administrator access. In particular, Docker socket access is effectively root-equivalent. Internal commands, paths, and API routes retain the <code>vmapi</code> name for compatibility.</div>
