---
layout: layout.njk
title: Quick start
---
# Quick start

## 1. Choose a disposable development host

Use a Linux host with hardware virtualization available for VMs. Docker features require a running local Docker daemon. TinyVisor's default listener is local-only on Debian; use an SSH tunnel until TLS is configured.

## 2. Install

Alpine, Debian, Ubuntu, and Debian derivatives all use the same installer:

```bash
sudo ./install.sh
```

The installer detects the platform and installs the required packages, CA certificates, GOST v3, web server, service definitions, and VMAPI runtime. It uses the account that invoked `sudo` as the local administrator. On Alpine it prompts for the HTTP Basic password on a new installation; supply `VMAPI_HTTP_USER` and `VMAPI_HTTP_PASSWORD` only for noninteractive automation.

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
