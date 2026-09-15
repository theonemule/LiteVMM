---
layout: layout.njk
title: Operations and safety
---
# Operations and safety

## Authentication and exposure

Nginx (Debian) uses PAM and the `vmapi-admin` group. lighttpd (Alpine) uses an htpasswd file created from `VMAPI_HTTP_USER` and `VMAPI_HTTP_PASSWORD`. HTTP Basic credentials are reusable by the browser but are not encrypted without TLS. Keep the listener private or configure TLS before LAN exposure.

## Backups, pairing, and overlays

Backups are tar archives of VM directories. Stopped VMs are the safe default; live copies use QMP. Pairing is a three-step, out-of-band Ed25519 exchange. Compare node names and public-key fingerprints independently. Pairing establishes one shared HTTP Basic credential for the peer API and hub WebSocket upgrades. Revoke a peer before replacing a host.

Named overlays use GOST TAP over a WebSocket routed by lighttpd. The relay binds to loopback; the existing HTTPS port carries the WebSocket. Overlay creation changes host bridges; use the Validate action and test it only with paired disposable hosts. Docker bridge IPAM is not attached automatically because it is host-local rather than distributed Layer-2 state.

## Regression testing tiers

| Tier | Command | Scope |
|---|---|---|
| Normal | `tests/api-regression-curl.sh URL USER` | Recoverable VM, Docker, Compose, backup, and file fixtures. |
| Host network | append `--destructive` | Also creates and removes a unique Linux bridge and paired overlay. |
| Two host | `tests/overlay-pair-curl.sh` | Verifies TAP data flow between already paired hosts. |
| Backup transfer | `tests/backup-pair-curl.sh` | Creates a temporary VM and verifies signed peer backup transfer. |

All test commands use unique names and cleanup traps. Still run destructive tiers only where temporary host-level networking is acceptable.
