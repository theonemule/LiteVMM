---
layout: layout.njk
title: VM storage, ISO media, and container images
---
# VM storage, ISO media, and container images

## Virtual disks and ISO media

Open **Virtual machines** and choose **Disk storage** to see every attached virtual disk and its per-VM storage location. Uploading a QCOW2, RAW, or VMDK selects a stopped VM, stores the file in that VM's disk folder, and attaches it as a data disk. Each attached disk also has a **Download** action.

Choose **ISO media** from the same VM overview to manage the shared, read-only installer library. An ISO is bootable installation media, not a guest-writable disk; its filename appears in the **Install image** selector when you create or edit a VM. Each media item can be uploaded or downloaded, and deletion is refused while it remains referenced by a VM.

**Storage locations** shows the separate configuration, virtual-disk, and ISO roots. Moving one transfers its existing contents and updates the host configuration; stop every VM first and use an unused absolute destination path.

## Docker images

Open **Containers** and choose **Image library** to list local Docker images. Enter a standard reference such as `nginx:stable` or `alpine:latest` to pull it; the modal keeps Docker's console output for the pull or removal.

Use images from publishers you trust and pin production workloads to a deliberate tag or digest. **Delete** removes the local image. It does not normally remove a running container, but it can prevent later starts or new containers if no usable local copy remains.

## Volumes

**Volumes** lists Docker-managed persistent volumes. **Create volume** asks for a name and driver; `local` is the normal driver. **Inspect** displays Docker's stored metadata, including its mountpoint and labels. **Delete** asks Docker to remove the volume and may remove persistent application data. Stop dependent containers and make an independent backup first.
