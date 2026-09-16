---
layout: layout.njk
title: Quick start
---
# Quick start

## 1. Choose a disposable development host

Use a Linux host with hardware virtualization available for VMs. Docker features require a running local Docker daemon. LiteVMM's default listener is local-only on Debian; use an SSH tunnel until TLS is configured.

## 2. Install

Alpine, Debian, Ubuntu, and Debian derivatives all use the same installer:

Choose the workload profile at install time. The API and console are always installed.

```bash
sudo ./install.sh --profile virtualization --port 5186
# or: --profile docker
# or: --profile virtualization-docker
# or: --profile backup
```

With no `--profile`, an interactive install asks which profile to use. `virtualization` includes cloud-init seed support and the backup engine, `docker` installs Docker/Compose without KVM, `virtualization-docker` combines cloud-init, virtualization, backups, and Docker/Compose, and `backup` is a receive-only paired archive node. Add `--certbot` if this host should manage an ACME certificate from the Admin page.

## 3. Connect

For the default Debian loopback listener:

```bash
ssh -L 5186:127.0.0.1:5186 YOUR_LOGIN@HOST
```

Open <http://127.0.0.1:5186/> and complete the HTTP Basic challenge. The same authentication protects `/api/`.

## 4. Verify safely

```bash
VMAPI_PASSWORD='...' ./tests/api-regression-curl.sh http://127.0.0.1:5186 YOUR_LOGIN
```

This creates uniquely named, recoverable LiteVMM/Docker/Compose/file fixtures and removes them. Add `--destructive` only on a disposable development host to test temporary host bridge and paired-overlay operations.
