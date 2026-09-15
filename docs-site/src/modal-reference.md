---
layout: layout.njk
title: Console modal reference
---
# Console modal reference

This is the field-by-field reference for every operator modal in TinyVisor. The main task guides explain *when* to use a workflow; this page explains precisely what is in each dialog, what buttons are available, and what saving it changes.

## General modal controls

Every modal has a close **X**. Closing it discards unsaved values. A modal with a primary button submits the form: **Create**, **Save settings**, **Deploy**, and similar labels perform the operation named by the label. Confirmation dialogs appear before destructive removal; read them as the final warning, because confirming is the point at which the host change occurs.

## Overview modals

### Service logs

Open **Overview → View service logs**. Choose a source from **All sources**, **System**, **Overlay / GOST**, **Docker**, **API / fcgiwrap**, **Terminal broker**, or **VM console broker**. Select **Refresh** to reload the selected source. This modal only reads logs; it neither restarts nor clears services. Start with the narrowest source when troubleshooting.

**Launch host terminal** is not a modal: it creates a short-lived terminal session in a new browser tab. **File browser** opens the file-management page in a new tab. Both are host-level tools.

## Virtual-machine modals

### Create virtual machine

**Virtual machines → Create VM** opens five form sections.

| Section and field | What to enter or select | What it changes |
| --- | --- | --- |
| **Name** | A unique short VM name. | VM identity and its host directory name. |
| **vCPUs** | 1–16 virtual CPUs. | QEMU CPU topology exposed to the guest. |
| **Memory MB** | 256 MB through 16 GB from the menu. | Guest RAM configured for QEMU. |
| **Initial disk** | Capacity such as `40G`. | Creates the initial virtual disk. |
| **Disk format** | `qcow2` or `raw`. | Disk file type. |
| **Disk bus** | `virtio`, `sata`, or `scsi`. | Guest-visible disk controller. |
| **Install image** | A file from VM images, or None. | Media presented for installation/boot. |
| **Firmware** | BIOS or UEFI. | Firmware used at the next VM boot. |
| **Network** | NAT, Bridge, Overlay, or None. | NIC connectivity model. Bridge and Overlay reveal their own selectors. |
| **Bridge** | An existing Linux bridge. | Only used with Bridge mode. |
| **Overlay network** | An existing paired-host overlay. | Only used with Overlay mode. |
| **NIC model** | virtio-net-pci, e1000e, e1000, or rtl8139. | Guest NIC hardware emulation. |
| **Display** | VNC or None. | Whether a graphical browser console can be opened. |
| **VNC bind** | Normally `127.0.0.1`. | VNC listener address; keep it local unless deliberately securing remote access. |
| **Start at host boot** | On or off. | Enables VM autostart. |

**Advanced options** expands **Machine** (`q35` or `pc`), **CPU model** (`host`, `max`, `kvm64`, `qemu64`), **Boot order** (`c`, `d`, `dc`, `cd`, `n`), and optional **VNC display**. `c` means disk first; `d` means optical media first. The **Create command** panel is read-only: it previews the QEMU launch settings. Select **Create VM** to create the disk and configuration.

### Edit VM

Select **Edit** on a VM row. The resource graphs update every five seconds. CPU is QEMU process use; memory is QEMU resident memory; disk allocation is host image allocation versus virtual capacity; network is host-observed traffic. None of these is a guest-agent report.

The **Hardware** fields are **vCPUs**, **Memory MB**, **CPU model**, **Machine**, **ISO**, **Boot order**, **Display**, and **Autostart**. **Save settings** writes all of those settings. When the VM is running, the dialog explicitly warns that hardware settings can only be changed when stopped—stop it before saving hardware changes.

The device sections have their own buttons:

| Section | Button / modal | Fields and effect |
| --- | --- | --- |
| **Disks** | **Add disk** | **Size**, `qcow2`/`raw` **Format**, and `virtio`/`sata`/`scsi` **Bus**. **Add disk** creates and attaches it. |
| **Disks** | **Remove** | Removes that indexed disk and deletes its backing file. This is destructive. |
| **Network adapters** | **Add NIC** | **Mode** is NAT or Bridge; Bridge reveals the bridge selector. **NIC model** selects the emulated adapter. |
| **Network adapters** | **Edit** | Changes the selected NIC's mode, bridge where applicable, and model. The MAC is shown in the VM list but is not edited by this modal. |
| **Network adapters** | **Remove** | Removes the selected NIC from the VM. |
| **PCI passthrough** | **Add device** | Enter a PCI **BDF**, for example `01:00.0`, then select **Add device**. VFIO/IOMMU host preparation is required beforehand. |
| **PCI passthrough** | **Remove** | Removes the passthrough entry; it does not undo host driver configuration. |
| **Console** | **Open noVNC** | Appears only for a running VM with VNC enabled and opens the browser console in a new tab. |

### Migrate VM

The **Migrate** button appears on a stopped VM. Choose a **Destination peer** from paired hosts that have an endpoint configured, then select **Migrate VM**. It copies and imports the stopped guest remotely; the local VM is removed only if remote import succeeds. There is no live-migration option in this dialog.

### VM backups and backup plan

Select **Backups** on a VM row. In **Backup now**, set **Backup name**, **Keep copies** (1–9999), then choose **Store backup**:

| Destination choice | Remaining field | Result |
| --- | --- | --- |
| Local or mounted folder | **Storage folder** | Writes the archive to that local path; a mounted network share is valid if the host can write it. |
| Authenticated paired host | **Destination peer** | Streams the archive to the paired host; it is retained there rather than locally. |

Turn on **Live backup** only for a running VM with virtio qcow2 disks; it uses a QMP full-disk copy. Select **Backup now** to queue a tracked job. The progress bar shows the completed backup phases (rather than a byte estimate, which QMP does not reliably expose for every disk mode). Under **Local backups**, **Download** retrieves an archive, **Restore** imports it only if a VM with that name does not already exist, and **Delete** removes the archive. **Backups on paired hosts** queries every trusted peer and provides a download action for archives that were stored remotely.

**Configure plan** opens the backup-plan modal. Enable or disable **Daily backups**, **Weekly backups**, and **Monthly backups** independently and set their corresponding **Keep** counts. Set the time, weekly day, and monthly day (1–28), choose the storage destination, and optionally enable **Live backup**. **Save backup plan** writes one schedule for every enabled tier. **Remove** beside a listed plan only removes future scheduling, not archives already created.

## Container and Compose modals

### Create container

**Containers → Create container** contains the following fields.

| Group | Fields | Meaning |
| --- | --- | --- |
| **Identity** | Name, Image | The Docker container name and an installed or pullable image reference. |
| **Resources and lifecycle** | CPUs, Memory, Restart, Network, Start at host boot | Docker resource limits, restart behavior, selected Docker network. Start at host boot uses `unless-stopped`. |
| **Runtime options** | Environment, Published ports, Volumes / bind mounts, Labels, Command arguments | One item per line. Examples: `MODE=production`, `8080:80`, `appdata:/data`, `role=frontend`, `sleep` then `3600`. |
| **Runtime options** | Hostname, User, Working directory, Entrypoint, Read-only root filesystem | Standard Docker create options. A read-only root needs writable volumes for applications that write data. |

The **Create command** panel is read-only and previews the planned Docker invocation. Select **Create container** to create it. A new container may be stopped initially depending on its image/command; use the row **Start** button if necessary.

### Inspect / Update resources

**Inspect** opens a container modal. It has live CPU, memory, writable-layer, and network measurements; writable-layer size is not the size of named volumes. The editable fields are **CPUs**, **Memory**, and **Restart policy**. Select **Update resources** to apply nonblank values. The **Summary** displays image, status, restart policy, and network mode. **Logs**, **Snapshot**, and a running-only **Terminal** button launch their respective dialogs. The final **Docker inspect** block is read-only raw metadata.

### Logs, terminal, and snapshot

In **Logs**, set the **Tail** count, select **Refresh** for a fixed log read, or select **Stream logs** to follow new output. **Stop stream** ends only the browser log stream. Closing the modal also stops it.

In **Terminal**, replace **Command** only if `/bin/sh` is not available in the image, then select **Open terminal**. This creates a short-lived Docker exec terminal in a new tab.

In **Snapshot**, set an **Image tag**, optional **Message**, and decide whether to keep **Pause container while committing** enabled. Select **Create image** to commit the container's writable layer. It does not capture named volumes or bind-mounted paths.

### Deploy Compose project

Set a unique **Project name**. Choose a Compose file to copy its contents into the editor, or paste YAML into **Compose YAML**. Select **Deploy** to save the YAML and apply it. In the project list, **View** is read-only, **Deploy** reapplies saved YAML, **Stop** runs the project down operation, and **Delete** stops it and removes the saved TinyVisor project definition.

## Image, volume, and network modals

### VM images and Docker images

The **VM images** upload panel accepts `.iso`, `.img`, `.qcow2`, `.raw`, `.vmdk`, `.vhd`, and `.vhdx`. Select one file, then **Upload**. The confirmation toast names the uploaded file. Each image row has **Delete**, which removes the shared file.

**Docker images → Pull image** has one **Image reference** field. Enter a Docker reference such as `nginx:stable`, then select **Pull**. **Remove** on an image row removes that local image after confirmation.

### Docker volumes

**Create volume** has **Name** and **Driver**; leave the driver as `local` for normal host-managed persistent data. **Inspect** is read-only Docker metadata. **Delete** removes the volume when Docker permits it, which can remove application data.

### Network chooser and Linux bridge

**Create network** first presents **Network type**: Linux bridge, Docker network, or GOST TAP overlay. Select **Continue** to open only the relevant configuration modal.

The Linux bridge modal has **Bridge name**, **Address mode**, **Bridge address**, **Gateway**, **Member interfaces**, **Persist across reboot**, and the required acknowledgement checkbox. **Manual** means no host address; **Static** reveals the address field; **DHCP** obtains an address. Select one or more member interfaces carefully. You must tick “I understand this may disrupt host connectivity” before **Create bridge** or **Save bridge** is allowed. Edit has the same fields; its name is read-only.

### Docker network

The Docker-network modal has **Name**, **Driver**, **Subnet**, **Gateway**, and **Internal-only network**. Select **Create network** to create it. Editing an existing network labels the action **Recreate network** because Docker IP addressing is immutable: saving deletes and recreates the unused network. Do not do this with containers attached.

### GOST TAP overlay

The overlay modal has **Network name**, **Linux bridge**, **Topology role**, **MTU**, and a multi-select **Paired hosts** list. The network name has an 11-character limit. Choose **Hub** to accept several peers or **Spoke** to connect to one hub; the dialog rejects a spoke with anything other than exactly one selected peer. Use an MTU between 1200 and 1499; 1400 is the default to leave room for encapsulation. **Create overlay** creates it. Editing labels the action **Recreate overlay** and deletes/recreates the transport, so disconnect workloads first. **Validate** checks that GOST is running, its local adapter is TAP rather than TUN, and that the adapter is up and connected to the intended Linux bridge.

## Cluster modals

### Export pairing request

Set **This host's pairing name** and verify **This host's API endpoint**, which is prefilled from the browser URL. Select **Create request**. The result panel offers **Copy**, **Download**, and **Revoke pending request**. Copy/download transfers a credential; revoke permanently invalidates that pending request.

### Import pairing request and response

Both import dialogs offer a **Pairing file** picker and **Or paste pairing bundle** text area. Selecting a file loads it into the text area. As you paste, the dialog displays parsed identity details so you can check the host before submission.

When accepting a request, the dialog additionally asks for *this* host's **pairing name** and **API endpoint** because they are signed into the response. Select **Accept request**, then copy or download the generated response. On the original host, open **Import pairing response**, load that response, check its details, and select **Complete pairing**.

### Peer endpoint and relay credential

**Endpoint** opens a one-field modal: **Peer base URL**. Enter only the public origin, such as `https://host-b.example`; do not include `/api`. Select **Save endpoint**. **Relay** shows a read-only username and password for that host pair; it is displayed for copying into an overlay setup and is separate from management pairing trust. **Revoke** is a confirmation action that permanently removes the peer.
