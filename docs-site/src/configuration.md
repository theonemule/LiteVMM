---
layout: layout.njk
title: Configuration reference
---
# Configuration reference

`/etc/vmapi/vmapi.conf` is sourced by `lib/common.sh`. Use shell-safe `NAME=value` lines; do not put secrets or untrusted shell syntax in this file.

| Setting | Default | Meaning |
|---|---|---|
| `VM_ROOT` | `/var/lib/vmapi/vms` | Parent directory for VM configuration, NVRAM, and transient runtime files. |
| `DISK_ROOT` | `/var/lib/vmapi/disks` | Parent directory for per-VM virtual-disk folders. |
| `ISO_ROOT` | `/var/lib/vmapi/isos` | Shared, read-only ISO and installer-image library. |
| `IMAGE_ROOT` | compatibility alias | Legacy fallback for `ISO_ROOT` on upgraded installations. |
| `QEMU_BIN` | `/usr/bin/qemu-system-x86_64` | QEMU executable used to start VMs. |
| `QEMU_IMG` | `/usr/bin/qemu-img` | Image utility used for disk creation and inspection. |
| `DEFAULT_MACHINE` | `q35` | QEMU machine model for newly created VMs. |
| `DEFAULT_CPU` | `host` | QEMU CPU model. `host` exposes host capabilities; use a compatible fixed model for portability. |
| `DEFAULT_MEMORY_MB` | `2048` | RAM assigned to a newly created VM, in MiB. |
| `DEFAULT_VCPUS` | `2` | vCPU count for a newly created VM. |
| `DEFAULT_DISK_FORMAT` | `qcow2` | Default virtual disk format. qcow2 supports sparse allocation and snapshots at the image layer. |
| `DEFAULT_DISK_BUS` | `virtio` | Default guest disk bus; generally the best choice for current guests. |
| `DEFAULT_NIC_MODEL` | `virtio-net-pci` | Default virtual NIC model. |
| `DEFAULT_VNC_BIND` | `127.0.0.1` | VNC bind address. Keep loopback-only; use VMAPI's proxied console path. |
| `STOP_TIMEOUT` | `20` | Seconds to wait for a graceful VM stop before forced handling. |
| `OVMF_CODE` | empty | Optional explicit UEFI firmware code image. Leave empty to use built-in common-path detection. |
| `OVMF_VARS_TEMPLATE` | empty | Optional explicit writable UEFI variable-store template. |
| `DOCKER_BIN` | `/usr/bin/docker` | Docker CLI path used by every Docker shell tool. |

## Runtime environment overrides

Tests and nonstandard deployments can override tool paths without editing the host config. Common examples are `VMAPI_LIB`, `VMAPI_CONFIG`, `VMAPI_FILE_ROOT`, `VMAPI_PEER_ROOT`, `VMAPI_BACKUP_ROOT`, `VMAPI_OVERLAY_ROOT`, and `DOCKER_BIN`. They are intentionally primarily for controlled deployments and tests; document any persistent override in your service unit.

## Per-VM settings

Each VM has `VM_ROOT/NAME/vm.conf` and its attached disks live in `DISK_ROOT/NAME`. VMAPI creates and edits the configuration through `vmctl`; avoid manual edits while a VM is running. Backups and migrations combine the configuration with every attached disk automatically; do not copy only `vm.conf`.
