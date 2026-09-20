# Technical guide

How LiteVMM is built: which daemons run, how requests and data move, how hosts
trust each other, and which assumptions the design depends on. Read this
before changing LiteVMM, debugging a host below the console, or deciding
whether LiteVMM fits an environment.

1. [Architecture](architecture.md): layers, request path, privilege model,
   files, configuration, services and ports.
2. [Peering](peering.md): node identity, the pairing protocol, the shared pair
   credential, the peer API and proxy, revocation.
3. [Storage backplane](storage-backplane.md): NFSv4 carried over WebSockets,
   the per-peer namespace, and everything that uses it.
4. [Overlay networks](overlay-networks.md): GOST TAP over WebSocket, hub and
   spoke, MTU, validation.
5. [Replication and backups](replication-and-backups.md): QEMU block jobs,
   dirty bitmaps, archives, scheduling, migration.
6. [Docker federation](docker-federation.md): the federated catalog,
   zero-copy peer rootfs, the `litevmm-remote` runtime, the registry.
7. [Consoles and terminals](consoles-and-terminals.md): noVNC and ttyd behind
   one port.
8. [Security model and assumptions](security-and-assumptions.md): trust
   boundaries and the assumptions baked into the design.
9. [Platforms and footprint](platforms-and-footprint.md): Alpine vs Debian,
   packages per profile, measured resource use.

## Design principles

These principles explain most of LiteVMM's design decisions.

**No database.** State is files: `vm.conf` key/value files, peer records,
overlay definitions, cron entries. Docker's and QEMU's own state is
authoritative and never mirrored. A host can be understood with `ls`, `cat`
and `ps`.

**Delegate to native tools.** QEMU builds VMs, Docker runs containers, the
kernel NFS server shares storage, Linux bridges switch frames, OpenSSL signs
pairing bundles, cron schedules backups. LiteVMM is the glue: roughly 10,000
lines of Bash and one static web page.

**One port.** Everything a remote party needs, whether browser, API, peer API,
storage, overlays, consoles, terminals or registry, goes through the single
management HTTP(S) port. Every helper daemon listens on `127.0.0.1` only and is
reached through the web server with authentication applied first.

**Small hosts first.** Alpine, BusyBox, lighttpd and on-demand processes
keep the control plane near 100 MB of RAM and the installed code under 1 MB,
so the host's resources go to workloads. Designs that need a JVM, a database,
an agent per host or a message bus were rejected on principle.

**Explicit over automatic.** Pairing is manual. Failover is manual. Copies of
images are explicit (`docker pull`). Where automation could do the wrong thing
silently (split-brain, surprise data copies), LiteVMM makes the operator
decide.

**Validate before apply.** Web server changes are written, tested with the
server's own config check and rolled back on failure before a reload.
Multi-host operations (overlays) roll back partial work.
