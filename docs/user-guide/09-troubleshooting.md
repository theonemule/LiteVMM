# 9. Troubleshooting

Start with **Overview → Full system information** (service state and
component versions) and **View service logs**. Most failures show up there.
Error banners in the console quote the API's JSON error, which usually names
the command that failed.

## Capability is not installed or available on this host

```
GET /api/cluster/peers/<id>/proxy?path=/replications/replicas failed with HTTP 502
{"error":"Capability is not installed or available on this host: storage-backplane"}
```

A host was asked for a feature it does not offer. Two very different causes:

1. **Expected**: the host genuinely does not run that feature (for example a
   Docker-only host has no VMs). Current consoles skip such hosts in
   cross-host lists; update both hosts if you still see this.
2. **A setting is not being read**: the host is configured for the feature
   but the web API cannot see the configuration. The classic case is
   `storage-backplane` disappearing although `/etc/vmapi/vmapi.conf` says
   `VMAPI_BACKPLANE_SERVER=true`. The API runs as the unprivileged `vmapi`
   user, so if `/etc/vmapi` has been made unreadable to it, the API silently
   falls back to defaults. Check:

   ```sh
   ls -ld /etc/vmapi            # must be drwxr-xr-x (0755)
   su -s /bin/sh vmapi -c 'grep BACKPLANE_SERVER /etc/vmapi/vmapi.conf'
   sudo chmod 0755 /etc/vmapi   # fix
   ```

   Older versions of `registryctl` caused this when the OCI registry was
   enabled.

## Enabling the OCI registry fails with "unexpected key for proxy.header: host"

Older `registryctl` versions generated a lighttpd rule that lighttpd rejects.
Update LiteVMM. If a failed attempt left
`/etc/lighttpd/conf.d/zz-vmapi-registry.conf` behind, lighttpd will refuse to
start on its next restart. Check with:

```sh
sudo lighttpd -tt -f /etc/lighttpd/lighttpd.conf
```

Then re-enable the registry with a current version, or empty that file.

## Peer backups, replicas or ISOs are unavailable

The peer's storage backplane is not mounted. Check, on the host that is
**using** the peer:

```sh
backplanectl list          # mounted / tunnel_running per peer
backplanectl connect NODE_ID
```

and on the **storage** host: `GET /api/backplane/status` must show
`nfs_listening` and `websocket_listening` true and `external_exposure` false.

The `vmapi-backplane` service retries unreachable peers with a back-off that
starts at 30 seconds and doubles up to 15 minutes, so a peer that has just come
back can take a few minutes to remount. An explicit action (a backup, a
`backplanectl connect`) retries immediately.

The backplane and replication services log to
`/var/log/vmapi-backplane.log`, `/var/log/vmapi-backplane-server.log` and
`/var/log/vmapi-replication.log`. These are not shown in the console's log
viewer, so read them on the host.

## Pairing errors

| Message | Fix |
|---|---|
| *Invalid or expired pairing request* | Requests expire after 15 minutes. Export a new one |
| *Peer already exists; revoke it before pairing again* | Revoke the stale pair on both hosts first |
| *Pairing response does not match the pending request* | The response was generated from a different request. Restart from step 1 |
| *A node cannot pair with itself* | You imported a bundle into the host that created it |

## VMs will not start

- *KVM acceleration is unavailable*: enable VT-x/AMD-V in firmware, or for a
  nested host enable nested virtualization in the outer hypervisor. As a last
  resort allow software emulation for that VM (very slow).
- *Hardware settings can only be changed while the VM is stopped*: shut the VM
  down first.
- PCI passthrough fails: the host needs IOMMU enabled and the device bound to
  `vfio-pci` before LiteVMM can use it.

## Nested VMs get no DHCP address on a bridge

If LiteVMM itself runs inside Hyper-V, enable MAC address spoofing on the
outer VM's adapter
([details](05-networks.md#running-litevmm-inside-hyper-v)).

## Overlay: ping works, downloads stall

An MTU below 1500 on the overlay. Set it to 1500 on every member host with
`overlayctl set-mtu NAME 1500` ([details](05-networks.md#mtu)).

## "Failed to fetch" right after changing networking or TLS

The web server briefly reloads when routes or certificates change. The console
retries reads automatically; refresh the page if a view stays blank. Changes
are validated before reload, so the change itself has normally been applied.

## Every host is called "localhost"

The pairing name defaults to the hostname. Give hosts distinct hostnames, then
re-pair, or pick distinct names in the pairing dialog.

## Collecting details for a bug report

- `GET /api/` (profile, version, capabilities)
- `GET /api/system` (versions and service state)
- the service log excerpt around the failure
- the failing request and its JSON error
