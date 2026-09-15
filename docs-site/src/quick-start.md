---
layout: layout.njk
title: Quick start
---
# Quick start

## 1. Choose a disposable development host

Use a Linux host with hardware virtualization available for VMs. Docker features require a running local Docker daemon. TinyVisor's default listener is local-only on Debian; use an SSH tunnel until TLS is configured.

## 2. Install

Debian/Ubuntu-style hosts:

```bash
sudo ./bootstrap-debian.sh --admin YOUR_LOGIN --bridge br0
```

Alpine hosts (run as root):

```bash
VMAPI_HTTP_USER=YOUR_LOGIN VMAPI_HTTP_PASSWORD='change-me' \
  ./bootstrap-alpine.sh --admin YOUR_LOGIN --bridge br0
```

`--admin` adds the named local account to `vmapi-admin`. `--bridge` allows an existing Linux bridge through QEMU's bridge helper; omit it when bridged VMs are not required.

## 3. Connect

For the default Debian loopback listener:

```bash
ssh -L 8080:127.0.0.1:8080 YOUR_LOGIN@HOST
```

Open <http://127.0.0.1:8080/> and complete the HTTP Basic challenge. The same authentication protects `/api/`.

## 4. Verify safely

```bash
VMAPI_PASSWORD='...' ./tests/api-regression-curl.sh http://127.0.0.1:8080 YOUR_LOGIN
```

This creates uniquely named, recoverable TinyVisor/Docker/Compose/file fixtures and removes them. Add `--destructive` only on a disposable development host to test temporary host bridge and paired-overlay operations.
