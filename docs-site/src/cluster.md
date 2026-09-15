---
layout: layout.njk
title: Cluster pairing
---
# Cluster and pairing

The **Cluster** menu establishes trust between TinyVisor hosts you administer. Pairing allows a host to manage a selected peer, migrate stopped VMs, send backups to it, and create paired-host overlays. It does not turn unrelated machines into one shared filesystem or automatically expose their management interfaces.

## Pair two hosts

Pairing happens in three deliberate steps. The bundles are credentials: transfer them only through a trusted channel and compare host identity details before accepting.

1. On host A, select **Export pairing request**. Enter the name that host A should present and verify its public base endpoint. Select **Create request**.
2. Use **Copy** or **Download** to transfer the request bundle to host B. On host B, choose **Import pairing request**, paste the bundle or select its file, verify the host/fingerprint details, and choose **Accept request**.
3. Host B produces a pairing response. Copy or download it and transfer it back to host A. On host A, choose **Import pairing response**, paste or select it, verify the details, and choose **Complete pairing**.

The request export panel also provides **Revoke pending request**. Use it if the request was sent to the wrong place or is no longer needed; responses created from it can no longer be completed.

## Manage a paired host

| Button | What it does |
| --- | --- |
| **Manage** | Switches the console's active-host view to that paired node. Use the host selector or menu to return to Local. |
| **Endpoint** | Saves the peer's public HTTPS base URL. Enter the host root, for example `https://host-b.example`, not an `/api` path. |
| **Relay** | Shows the relay username/password for this host pair. Use the same credential on both ends only while configuring the matching GOST TAP overlay. |
| **Revoke** | Permanently removes trust in the peer. Use before decommissioning a host or when credentials may have been exposed. |

Pairing credentials for management and relay credentials for overlays are separate. A valid pairing alone does not create an overlay; create that under **Networks** after endpoint and relay configuration are working.
