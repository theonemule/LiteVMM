---
layout: layout.njk
title: Console and screenshots
---
# Console and screenshots

The console is a static single-page application. The left navigation selects Overview, Virtual machines, Containers, Compose, Networks, and Cluster. Disk storage and ISO media are managed from Virtual machines; the Docker image library is managed from Containers. Docker volumes remain available when creating containers or Compose projects. The top host selector changes between the local host and a paired host through the signed peer proxy.

## Page guide

| Page | What it does | Important modal fields |
|---|---|---|
| Overview | Counts resources, shows metrics and logs, opens host file browser. | Log source and line limit. |
| Virtual machines | Creates/edits lifecycle, disks, NICs, PCI, console, and backups. | VM name, memory, vCPUs, disk size, firmware, display, network. |
| Containers | Creates and manages Docker containers and exec sessions. | Image, command, ports, volumes, environment, restart, CPU/memory. |
| Compose | Stores, validates, deploys, stops, and deletes Compose YAML. | Project name and YAML. |
| Networks | Lists host bridges, Docker networks, and GOST overlays. | Bridge members/address; overlay name, role, peers, MTU. |
| Cluster | Performs pairing, endpoint configuration, relay credential display, and revocation. | Peer name, public HTTPS endpoint, pairing bundle. |

## Screenshot gallery

Screenshots are intentionally not fabricated. Capture them from a sanitized development host—never include passwords, pairing bundles, API tokens, IP addresses, VM disk contents, or customer names.

<div class="shot">Add <code>assets/screenshots/overview.png</code><br>Overview page with no sensitive host data</div>

<div class="shot">Add <code>assets/screenshots/create-vm-modal.png</code><br>Create virtual machine modal</div>

<div class="shot">Add <code>assets/screenshots/create-container-modal.png</code><br>Create container modal</div>

<div class="shot">Add <code>assets/screenshots/networks-overlay-modal.png</code><br>Network / overlay configuration modal</div>

<div class="shot">Add <code>assets/screenshots/cluster-pairing.png</code><br>Cluster pairing screen with all bundles redacted</div>

When an image is added, replace its placeholder with `<img src="/assets/screenshots/FILENAME" alt="Describe the visible controls and state">`. Keep the alt text specific enough for someone who cannot view the image.
