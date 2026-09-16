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
| **Stop** | Requests a graceful shutdown of a running guest. | Wait for the state to become stopped before hardware edits. |
| **Reboot** | Restarts a running guest. | Interrupts applications inside the guest. |
| **Console** | Opens a short-lived browser noVNC session. | Available only for a running VM with VNC display enabled. |
| **Migrate** | Copies a stopped VM to a paired host. | The source is removed only after the destination import succeeds. |
| **Delete** | Removes the VM configuration and per-VM disk folder. | This removes its disks; make a backup first. |

## Create a VM

1. Select **Create VM**.
2. Under **Identity and compute**, set a short, unique **Name**, then choose **vCPUs** and **Memory MB**. These are the guest's configured resources, not a reservation held while it is stopped.
3. Under **Storage and boot**, choose the initial virtual-disk size, format, bus, an optional install image, and firmware.
4. Under **Networking and display**, choose the connectivity model and display options.
5. Expand **Advanced options** only if you need a different machine type, CPU model, boot order, or fixed VNC display number. The live command preview is there to review the resulting QEMU settings.
6. Select **Create VM**, then use **Start** and **Console** to install the operating system.

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
