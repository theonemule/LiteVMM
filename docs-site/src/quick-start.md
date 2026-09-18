---
layout: layout.njk
title: Quick start
---
# Quick start

## 1. Prepare the host for SSH installation

LiteVMM is installed by connecting to the target Linux host over SSH and running the installer on that host.

For Debian or Ubuntu:

```bash
sudo apt-get update
sudo apt-get install -y openssh-server git
sudo systemctl enable --now ssh
```

For Alpine:

```bash
sudo apk add openssh git
sudo rc-update add sshd default
sudo rc-service sshd start
```

VM profiles require hardware virtualization. Docker profiles require a host capable of running Docker.

## 2. Connect over SSH and get LiteVMM

From the workstation:

```bash
ssh YOUR_LOGIN@HOST
```

On the remote host:

```bash
git clone https://github.com/theonemule/LiteVMM.git
cd LiteVMM
```

For an existing checkout:

```bash
cd LiteVMM
git pull --ff-only
```

## 3. Choose one install profile

Every installation includes the LiteVMM API, console, and backup-storage backplane.

```bash
# Backup only
sudo ./install.sh --profile backup --port 5186

# VM + backup
sudo ./install.sh --profile virtualization --port 5186

# Docker + backup
sudo ./install.sh --profile docker --port 5186

# VM + Docker + backup
sudo ./install.sh --profile virtualization-docker --port 5186
```

Run `sudo ./install.sh` without `--profile` to use the interactive menu. It presents those four choices in the same order, with **Backup only** as the default. Add `--certbot` if the host should manage a Let's Encrypt certificate. CSR and certificate/key import do not require Certbot.

## 4. Connect to the console

Debian and Ubuntu bind the management endpoint to loopback by default. Until HTTPS is configured, open a local SSH tunnel from the workstation:

```bash
ssh -L 5186:127.0.0.1:5186 YOUR_LOGIN@HOST
```

Then open `http://127.0.0.1:5186/` and complete the HTTP Basic authentication challenge.

Alpine serves the configured management port through Lighttpd. Restrict network/firewall exposure until HTTPS is configured.

## 5. Upgrade or reconcile a host

SSH to the host, update the repository, and rerun the same profile:

```bash
cd LiteVMM
git pull --ff-only
sudo ./install.sh --profile virtualization-docker --port 5186
```

Re-running the installer is the supported upgrade path. It reconciles dependencies, runtime files, services, authentication policy, and the selected profile without requiring a separate deployment script.

## 6. Verify safely

```bash
VMAPI_PASSWORD='...' ./tests/api-regression-curl.sh http://127.0.0.1:5186 YOUR_LOGIN
```

This creates uniquely named, recoverable LiteVMM/Docker/Compose/file fixtures and removes them. Add `--destructive` only on a disposable development host to test temporary host bridge and paired-overlay operations.
