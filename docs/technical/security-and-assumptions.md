# Security model and assumptions

LiteVMM is built for a small number of administrator-operated hosts. It favours
simple, inspectable trust relationships over fine-grained access control. This
page states those relationships and the assumptions behind them, so you can
decide whether they fit your environment.

## Trust boundaries

| Principal | Can do | Why |
|---|---|---|
| **Console user** (any account that can log in) | Everything on that host, including as root: file browser, host terminal, Docker (root-equivalent), bridges, VMs | There are no roles. Every console user is a host administrator |
| **Paired host** | Almost everything a console user can do on this host, through `/peer-api/` | The peer API is the full API, minus a few local-administration routes. Pairing is **mutual administrative trust** |
| **Paired storage client** | Read and write the storage host's entire backplane export as root | Loopback NFS export with `no_root_squash` ([details](storage-backplane.md#security-properties-and-assumptions)) |
| **Overlay member** | Send and receive frames on that overlay's segment | Per-overlay route restricted to member credentials |
| **Registry user** | Push and pull images at `/v2/` | Separate credential |
| **Local users on the host** | Potentially reach loopback services (NFS, VNC, terminals' ttyd, registry) | Loopback is not an authentication boundary |

Peer routes refused with `403` (local administration only):
`/backplane/*`, `/docker/images/federated`, `/docker/images/prepare`,
`/docker/images/pull`.

## Controls that are in place

- **One exposed port.** Every helper binds to `127.0.0.1`. The web server
  authenticates before proxying anything, including WebSocket upgrades. The
  backplane server verifies its real listeners and reports
  `external_exposure`.
- **No credentials in the browser.** The console uses the browser's HTTP Basic
  session; peer operations go through the local proxy so peer credentials never
  reach JavaScript.
- **Revocation is immediate.** Peer API calls re-check the live peer list after
  the web server's check; revocation also closes overlay sockets and
  unmounts storage.
- **Least privilege where practical.** API requests run as `vmapi`;
  privileged steps use per-profile, per-subcommand `sudo -n` rules.
- **Input validation before side effects.** Names, IDs, paths, ports and
  enumerations are checked by regex in both the router and the tools; peer
  proxy paths cannot escape the API root.
- **Validated configuration changes.** Web server fragments are tested with the
  server's own checker and rolled back on failure.
- **Secrets on disk** are root-only (`0600`): identity key, node ID, peer
  records, TLS keys, registry state. Web server credential files are
  `root:<web group> 0640` and hold APR1 hashes.
- **Pinned downloads.** GOST is fetched over HTTPS at a pinned version and checked
  against the SHA-256 value in `install.sh`.
  against SHA-256 values in `install.sh`.

## Assumptions baked into the design

**People and access**

1. Everyone who can log in to the console is a trusted administrator.
2. Hosts are single-tenant: no untrusted local users or untrusted processes on
   the host itself (they could reach loopback services).
3. Operators verify public-key fingerprints when pairing, and move pairing
   bundles over a private channel (the request bundle contains the pair
   credential).

**Network**

4. Either the management network is trusted, or HTTPS is enabled. With
   `http://` endpoints, credentials, NFS traffic and overlay frames cross the
   network unencrypted.
5. Each pair of hosts can reach each other's recorded API endpoint, in both
   directions for most features. (Overlay spokes and backplane clients only
   dial out.)
6. The management port is not exposed to the Internet without HTTPS and
   additional filtering.

**Peers**

7. Paired hosts trust each other fully, and all clients of a storage host trust
   each other with their backups and replicas.
8. Trust is not transitive; each pair is created deliberately.
9. Storage hosts have enough space: there are no per-peer quotas on the
   backplane, so one peer can fill a storage host's disk.

**Operations**

10. Failover is manual. Replication gives crash-consistent disks, with no
    fencing; starting a standby while the source still runs would split the
    VM in two.
11. Hard-mounted peer storage blocks rather than failing when a peer is down.
    Workloads on peer-backed disks or images pause with it.
12. `/etc/vmapi` stays readable (`0755`) by the `vmapi` user; otherwise
    settings silently revert to defaults.
13. Clocks are roughly correct (pairing expiry, cron, TLS).
14. Overlay hubs and browser VM consoles run on Alpine/lighttpd.
15. KVM is available for real workloads; software emulation must be allowed
    explicitly per VM.

## Hardening checklist

- Enable HTTPS (Let's Encrypt, CSR or import) before pairing across any
  network you do not control, and re-point peer endpoints to `https://`.
- Keep console accounts few; on Debian restrict the PAM service, on Alpine
  manage `/etc/lighttpd/vmapi.htpasswd`.
- Restrict the management port with a host or network firewall to admin
  networks and peer addresses.
- Pair only hosts that belong to the same administrative domain; use separate
  storage hosts for groups that must not see each other's data.
- Confine the file browser with `VMAPI_FILE_ROOT` if the full filesystem is
  not needed.
- Check `GET /api/backplane/status` for `"external_exposure": false` after
  changing any backplane setting.
- Revoke peers you no longer use, on both sides.
