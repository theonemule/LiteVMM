---
layout: layout.njk
title: Virtual machines
---
# Virtual machines

Open **Virtual machines** from the left menu to see one row per QEMU/KVM guest. A row shows its name, state, vCPU allocation, configured memory, and firmware. The row buttons are the normal day-to-day controls.

| Button | What it does | Important consequence |
| --- | --- | --- |
| **Create VM** | Opens the new-VM form. | Creates a configuration directory, a per-VM disk folder, and an initial virtual disk. |
| **Edit** | Opens the VM hardware and device editor. | Hardware fields are saved for the next boot; stop the VM first. |
| **Backups** | Opens backups and the backup schedule for this VM. | A backup archive may be local or sent to a paired host. |
| **Start** | Starts a stopped guest. | The guest consumes its configured CPU and memory on the host. |
| **Shutdown** | Requests an ACPI power-down and waits for the guest to stop. | Preferred for normal guest shutdown. |
| **Restart** | Gracefully shuts down and then starts the guest. | Preferred for an orderly restart. |
| **Power off** | Terminates QEMU from the host. | Immediate; use when graceful shutdown is unsuitable or fails. |
| **Reset** | Sends QMP `system_reset`. | Immediate virtual hardware reset; interrupts applications. |
| **Console** | Opens a short-lived browser noVNC session. | Available only for a running VM with VNC display enabled. |
| **Migrate** | Copies a stopped VM to a paired host. | The source is removed only after the destination import succeeds. |
| **Delete** | Removes the VM configuration and per-VM disk folder. | This removes its disks; make a backup first. |

## Create a VM

1. Select **Create VM**.
2. Under **Identity and compute**, set a short, unique **Name**, then choose **vCPUs** and **Memory MB**. These are the guest's configured resources, not a reservation held while it is stopped.
3. Under **Storage and boot**, choose the initial virtual-disk size, format, bus, an optional install image, and firmware.
4. Under **Networking and display**, choose the connectivity model and display options.
5. If the guest is a cloud-init-capable image, enable **Cloud-init provisioning**, optionally set its hostname, and paste `#cloud-config` YAML or a cloud-init shell script.
6. Expand **Advanced options** only if you need a different machine type, CPU model, boot order, or fixed VNC display number. The live command preview is there to review the resulting QEMU settings.
7. Select **Create VM**, then use **Start** and **Console** to boot or install the operating system.

### What each creation setting means

| Setting | Meaning and normal choice |
| --- | --- |
| **Initial disk** | The virtual capacity of the first disk, for example `40G`. It is not necessarily immediate physical disk use. |
| **Disk format** | `qcow2` is sparse and supports QEMU features such as snapshots/copies. `raw` is simpler and can be appropriate for direct-performance needs. |
| **Disk bus** | `virtio` is the usual fast choice for current Linux guests. Use `sata` or `scsi` only where guest-driver compatibility requires it. |
| **Install image** | An ISO or installer image managed from **Virtual machines → ISO media**. Choose None when attaching storage later. |
| **Firmware** | **BIOS** is broadly compatible. **UEFI** needs OVMF installed on the host and is common for current operating systems. |
| **Network: NAT** | The default. The guest can reach out through host-managed NAT without being a direct LAN member. |
| **Network: Bridge** | Attaches the VM to a selected Linux bridge, making it a peer on that bridge's Layer-2 network. |
| **Network: Overlay** | Attaches the VM to a paired-host Layer-2 overlay. Create and verify that overlay first. |
| **Network: None** | Gives the VM no NIC. Useful for isolated appliance work. |
| **NIC model** | `virtio-net-pci` is normal for modern guests. `e1000e`, `e1000`, and `rtl8139` are compatibility choices. |
| **Display / VNC bind** | **VNC** enables the browser console; the default bind address keeps VNC local to the host. **None** creates no graphical console. |
| **Start at host boot** | Starts the VM when the LiteVMM host starts. Use it only for guests that should recover automatically. |
| **Cloud-init provisioning** | Builds a per-VM NoCloud `cidata` ISO containing `user-data` and `meta-data`. The guest image must already include cloud-init. |

## Provision with cloud-init

Cloud-init support is available on the `virtualization` and `virtualization-docker` profiles. LiteVMM uses the NoCloud datasource model: it writes `user-data` plus `meta-data`, builds an ISO9660 image labeled `cidata`, and attaches that seed ISO to the VM as read-only CD-ROM media.

The **User-data** editor accepts either `#cloud-config` YAML or a script beginning with `#!`. A typical cloud-config can create users, install packages, write files, and run commands on the guest's first boot. The guest image itself must contain cloud-init and support NoCloud; attaching a seed ISO does not add cloud-init to an ordinary operating-system image.

The generated seed lives under `VM_ROOT/NAME/cloud-init`, so backups, restores, and migrations retain the exact provisioning source and seed. When you change user-data or the cloud-init hostname, LiteVMM generates a new `instance-id`. On a normal cloud image this causes cloud-init to treat the next boot as a new instance and run per-instance configuration again. For that reason, cloud-init changes are allowed only while the VM is stopped.

Example user-data:

```yaml
#cloud-config
package_update: true
packages:
  - curl
write_files:
  - path: /etc/litevmm-provisioned
    content: provisioned by LiteVMM
runcmd:
  - systemctl restart ssh
```

## Edit a VM safely

Select **Edit**. The dialog starts with live CPU, memory, disk-allocation, and network measurements. Those charts refresh every five seconds and are a quick health check, not guest monitoring.

The **Hardware** section edits vCPUs, memory, CPU model, machine type, ISO, boot order, display, and autostart. If the guest is running, LiteVMM warns that hardware values cannot be changed until it is stopped. Save after reviewing all fields.

The **Disks** section lists every disk. **Add disk** asks for capacity, format, and bus. The VM overview's **Disk storage** modal also uploads QCOW2, RAW, and VMDK files directly into the selected VM's disk folder and attaches them as data disks. The remove control deletes the disk image as well as disconnecting it, so back up data before using it.

The **Network adapters** section lists the NIC mode, bridge (where applicable), model, and MAC. **Add NIC** creates another adapter; **Edit** changes an existing one; **Remove** detaches it. NAT does not need a bridge. Bridge mode does.

The **PCI passthrough** section is for an already prepared VFIO/IOMMU host. **Add device** requires its PCI BDF. Do not treat this as plug-and-play: driver binding and IOMMU isolation must be configured on the host first.

The **Console** section shows VNC and serial/QMP information. Prefer **Open noVNC** instead of exposing a raw VNC port.

## Back up, restore, and migrate

Open **Backups** from the VM row. **Backup now** queues an archive job and shows progress through validation, configuration, disk copying, compression, and any peer transfer. Give it a meaningful label, choose how many copies to retain, then choose either a local/mounted folder or an authenticated paired host. A stopped-VM backup is the safest choice. **Live backup** uses QMP full-disk copies for a running VM with virtio qcow2 disks and can take several minutes. The percentage is phase-based because QMP does not expose reliable byte progress for every disk mode.

**Configure plan** creates daily, weekly, and monthly retention tiers. Each enabled tier has a keep count and schedule time. Removing a plan only stops future backups; it does not delete existing archives. Local archives can be **Download**ed, **Restore**d, or **Delete**d; peer-held archives appear in a separate paired-host inventory and can be downloaded from there. Restore requires that the VM name does not already exist.

For a host move, stop the VM, select **Migrate**, and choose a paired peer that has a configured endpoint. LiteVMM transfers and imports it remotely first. Only a successful import causes the source to be removed.

## VLAN-tagged VM adapters

A bridged NIC can optionally specify a **VLAN ID** from 1 through 4094. LiteVMM presents the VM-side TAP as an untagged access port in that VLAN and allows the VLAN on non-VM bridge ports. The upstream physical or virtual switch must carry that VLAN. Leave the field blank for an ordinary untagged bridged NIC. NAT adapters do not accept a VLAN ID.
