---
layout: layout.njk
title: Using the LiteVMM console
---
# Using the LiteVMM console

The **System information** page is the detailed host inventory. It shows operating-system and kernel identity, CPU/RAM, primary IP and gateway, every interface and route, mounted filesystems and block devices, service state, installed component versions, and the raw JSON inventory for troubleshooting.

This is the administrator's guide to the LiteVMM web console. It describes what you see after signing in, what each action changes, and when not to use an action. It does not require API knowledge. Use the dedicated pages for [virtual machines](/virtual-machines/), [containers and Compose](/containers-and-compose/), [images and storage](/images-and-storage/), [networks](/networking/), and [cluster pairing](/cluster/). For every field and submit button inside those dialogs, use the [console modal reference](/modal-reference/).

## Understand the screen before changing anything

<div class="shot"><strong>Console layout</strong><br><br><code>Left navigation</code> selects a resource area · <code>top bar</code> selects the active host, switches theme, and refreshes · <code>main panel</code> lists resources and provides actions · <code>toast</code> confirms success or reports an error.</div>

The status dot at the bottom of the navigation tells you whether the console can reach the selected host. The host selector starts at **Local host**. After pairing another host, selecting it changes the view to that host; actions are still initiated by this host and signed on your behalf. The mobile **Menu** button contains the same items as the left navigation: Overview, Virtual machines, Containers, VM images, Docker images, Networks, Volumes, and Cluster.

**Refresh** reloads the current page from the host. It does not restart workloads. **Theme** changes only your browser's visual theme and is remembered in that browser.

## Overview

The Overview page is a read-first landing page. It shows counts for virtual machines, containers, VM images, and Docker images plus current host CPU, memory, storage, and network activity. Charts are short in-browser history, not long-term monitoring.

| Control | What it does | What to know |
|---|---|---|
| **Refresh** | Reloads summary and live measurements. | Safe; no host change. |
| **Logs** | Opens a modal for system, overlay/GOST, Docker, CGI, terminal, or console-broker logs. | Use a smaller line limit first; logs may contain service details. |
| **Host terminal** | Creates a short-lived terminal session in a new tab. | This is an administrator shell on the host. Treat every command as host-level. Debian/Ubuntu and Alpine both proxy the loopback-only ttyd broker through the authenticated web endpoint. |
| **File browser** | Opens a separate file-management tab. | It operates within the configured file root; deletes are recursive. |

### The file browser

The file browser has a folder tree, breadcrumbs, an **Up** button, and a table of the current folder. Double-click a folder to open it; double-click a file to download it. Select rows with their checkboxes, then use **Download** to receive a ZIP archive or **Delete** to permanently remove the selected items. **Move** is enabled for exactly one selected item and asks for its complete destination path. **New folder** creates a child directory in the folder you are viewing. **Upload** uploads selected workstation files into that folder. **Refresh** reloads the listing. Confirm the path and selection before deleting or moving anything.

## Virtual machines

### Create virtual machine

Open **Virtual machines** and select **Create VM**. The name becomes part of the on-disk VM directory, so choose a short stable name such as `debian-dev` rather than a sentence.

| Field | Choose this when | Notes |
|---|---|---|
| **Name** | You need a unique VM identity. | Cannot contain arbitrary path characters. |
| **Memory / vCPUs** | Sizing a guest. | These are host resources reserved when QEMU starts. |
| **Disk size** | Creating the first guest disk. | qcow2 is sparse; virtual disk size is not immediate physical usage. |
| **Image / ISO** | Installing an operating system or attaching existing media. | Upload images first from **VM images**. |
| **Firmware** | Your guest needs UEFI. | UEFI requires OVMF support on the host. |
| **Network** | The guest needs connectivity. | NAT is the safe default; bridge connects the guest to a host bridge. |

After creation, use the row actions: **Start**, **Shutdown**, **Restart**, **Power off**, **Reset**, **Edit**, **Console**, **Backups**, **Migrate**, and **Delete**. **Shutdown** asks the guest to power down through ACPI, and **Restart** waits for that graceful shutdown before starting it again. **Power off** terminates QEMU from the host and **Reset** sends an immediate virtual hardware reset; use those two only when a graceful guest operation is inappropriate or has failed. Delete removes the VM configuration and disks, so back up first.

### VM details modal

The Details modal is the hardware editor. Save settings only while the VM is stopped unless the screen explicitly permits the operation.

| Section | Controls | Effect |
|---|---|---|
| General | memory, vCPUs, machine, CPU, boot order, autostart | Updates the next QEMU launch configuration. |
| Disks | add, edit bus/format, resize, remove | Removing with **delete file** permanently deletes the disk image. |
| Network adapters | add/edit/remove | NAT needs no bridge. Bridge mode needs a prepared Linux bridge. MAC is shown read-only. |
| PCI passthrough | PCI BDF and remove | Advanced: VFIO/IOMMU must already be configured on the host. |
| Console | VNC/serial/QMP information | Use **Open console** for the browser session rather than exposing VNC. |

**Add disk** asks for size, format, and bus. Prefer `qcow2` + `virtio` for ordinary Linux guests. **Add NIC** asks for NAT or Bridge and an adapter model. Prefer `virtio-net-pci` unless the guest needs a legacy e1000/rtl8139 driver.

### Console, backups, and migration

**Console** opens a short-lived noVNC session in a new tab. Close the tab when finished. **Backups** lets you create a one-off archive, set retention schedules, download an archive, and restore into a new VM name. A stopped-VM backup is safest; live backup uses QMP and is intended for guests that support the configured disk mode. **Migrate** is only offered for a stopped VM and a paired destination; the source is removed only after the destination import succeeds.

## Containers and Compose

### Containers page

**Create container** opens a form with name, image, optional hostname, restart policy, CPU/memory limits, network, user, working directory, entrypoint, read-only filesystem, environment entries, published ports, volumes, labels, and command arguments.

Use Docker syntax: a port is `8080:80`, an environment entry is `NAME=value`, and a volume is `volume-name:/path`. The **Command arguments** box is one argument per line. Avoid shell quoting there; LiteVMM passes each line as one argument.

Per-container actions are **Start**, **Stop**, **Restart**, **Inspect**, **Edit resources**, **Logs**, **Terminal**, **Snapshot**, and **Delete**. Snapshot creates a Docker image from the current container; choose a clear image tag and leave **pause while committing** enabled unless you have a reason not to. The terminal command defaults to `/bin/sh` and must exist inside the container.

### Compose page

**Deploy Compose project** accepts a project name plus pasted YAML or a `.yaml`/`.yml` file. LiteVMM validates it before deployment. Use the project name as a stable application identifier, for example `blog-stack`. **View** shows the stored YAML; **Deploy** applies it again; **Down** stops the stack; **Delete** stops it and removes LiteVMM's stored project file. Review YAML carefully: Compose can mount host files and expose ports.

## Images, networks, and volumes

**VM images** stores installation ISOs and disk images used by VM creation. Upload only trusted media; delete removes the shared file and can prevent future VM starts if a guest still references it.

**Docker images** lists images known to Docker. **Pull image** accepts the normal Docker image reference (`alpine:latest`). Removing an image does not remove a running container, but it can prevent future container creation.

**Networks** combines three different things in one table:

| Type | Meaning | Safe use |
|---|---|---|
| Linux bridge | A host Layer-2 bridge for VMs. | Create only when you have a host networking plan. |
| Docker network | Docker-managed network for containers. | Use a non-overlapping subnet and gateway. |
| GOST TAP overlay | Encrypted Layer-2 path between paired hosts. | Configure only after pairing and testing on development hosts. |

The **Create network** button first asks for the type, then shows only the relevant settings. A Linux bridge modal asks for name, address mode (static, DHCP, or manual), address, gateway, member interfaces, and persistence. Moving a physical management interface into a bridge can disconnect you—perform that change only with console access and a rollback plan.

A Docker network modal asks for name, driver, subnet, gateway, and **internal-only**. Docker addressing is immutable: editing an existing network removes and recreates an unused one. An overlay modal asks for a short name, existing Linux bridge, hub/spoke role, MTU, and paired hosts. Use **Validate** after creation to check the local GOST process, TAP type, link, and bridge attachment. Editing an overlay recreates it; attached workloads must be disconnected first.

**Volumes** lists Docker volumes. Create asks only for name and driver; inspect displays the Docker metadata; delete removes volume data when Docker permits it.

## Cluster page

Use Cluster only when connecting LiteVMM hosts you administer. The normal flow is **Export pairing request** on host A, **Import pairing request** on host B, then **Import pairing response** on host A. Pairing bundles are secrets: transfer them through a trusted channel and never paste them into tickets or chat logs. Compare the displayed host name and fingerprint before accepting.

After pairing, use **Endpoint** to set the peer's public HTTPS base address—not an `/api` suffix. **Manage** switches the active host. **Relay** displays the pair-specific overlay credential; use it only while configuring the matching overlay. **Revoke** permanently removes trust and should be used before decommissioning a peer.

## If something goes wrong

1. Read the error toast; it usually names the field or host command that failed.
2. Press **Refresh** to separate a failed action from stale display data.
3. Use Overview → **Logs** and select the relevant service: Docker for containers, CGI for console actions, GOST for overlays, and system for QEMU/host failures.
4. Stop before editing VM disks, NICs, or passthrough settings.
5. Do not retry a destructive action until you know whether it completed; inspect the resource first.
