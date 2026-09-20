# Replication and backups

Both features are thin orchestration over QEMU's block layer (driven through
QMP, the QEMU Machine Protocol, on each VM's `runtime/qmp.sock`) and plain
files. Neither has its own network protocol. Remote copies are written to the
[storage backplane](storage-backplane.md) mount as ordinary files.

## Live replication

### Starting

`replicationctl start VM PEER_ID [BYTES_PER_SEC]`:

1. Connects the peer's backplane and resolves
   `…/peer-storage/PEER/peers/ME/replicas/VM/`.
2. For each disk, creates (or reuses) `disk<N>.qcow2` of the same virtual size,
   with a `disk<N>.meta` sidecar describing source, VM and disk.
3. Issues QMP `drive-mirror` per disk (`job-id` `repl-<N>`, target format
   `qcow2`, optional `speed`). The mirror copies the whole disk (**initial
   sync**), then enters the **ready** state, in which every guest write is sent
   to both the source and the replica before completing.
4. Records the job in `/var/lib/vmapi/replication-jobs/VM/state.conf`.

The mirror is never "completed", so it keeps running as long as the VM runs.
QEMU writes straight to the NFS-backed replica file. There is no replication
receiver on the destination.

### The reconcile loop

`vmapi-replication` runs `replicationctl daemon`, which calls `resume-all`
every 10 seconds. For each configured VM it restarts mirrors that are missing,
for example after the VM restarts, the backplane reconnects or the host reboots.
It also keeps each replica's `.meta` current, so the destination can list its
hosted replicas (`GET /replications/replicas`).

### Change tracking instead of full resyncs

Some operations need the mirror out of the way. QEMU allows only one block job
per disk, so a live backup cannot run while `drive-mirror` owns it. LiteVMM
pauses replication without losing sync:

1. **Quiesce**: the guest is frozen briefly; each **ready** mirror is cancelled
   (leaving the replica exact) and a **dirty bitmap**
   (`block-dirty-bitmap-add`, `vmapi-repl-N`) is created in the same frozen
   window, so no write can fall between the two. Bitmaps are persistent for
   qcow2 sources and survive QEMU restarts, including hibernation.
2. The other job runs. Meanwhile the bitmap records exactly the blocks the
   replica is missing.
3. **Catch up**: the replica is opened as a block node and `blockdev-backup
   sync=bitmap` copies only the dirty blocks while the guest runs. Passes
   repeat until the remaining delta is small, then the guest is frozen for a
   final pass and a new `drive-mirror` with `sync=none, mode=existing` takes
   over forwarding new writes.

A disk still in its initial copy when paused gets no bitmap; it is
resynchronised in full on resume.

A pause is held by a marker file recording the holder's PID. If the holder dies
without releasing it, the marker is treated as stale, so a crashed backup cannot
leave replication stopped. Changes to one VM's replication are serialised with
`flock`.

### Stopping and purging

`DELETE /replications/VM` cancels the mirrors and removes the job. The replica
files stay on the destination. `DELETE /replications/replicas/ID?delete_file=true`
on the **destination** removes them (replica IDs are a hash of
owner/VM/disk).

### What replication is not

- No guest RAM or CPU state, so a replica is crash-consistent: like pulling the
  power, then starting from the disks.
- No fencing and no automatic failover. Starting a VM from a replica is a
  manual decision.
- One replica per VM, on one peer.

## Backups

### Archive format

```
VM-LABEL-YYYYMMDDTHHMMSSZ.tar.gz
├── vm.conf
├── nvram.fd                 (UEFI)
├── cloud-init/…             (if enabled)
└── disks/disk0.qcow2 …
```

Runtime sockets and PID files are never archived. Imports also accept the old
layout (disks beside `vm.conf`) and move them into the disk root.

### Creating

`vmbackupctl create VM [--live] [--label L] [--destination DIR] [--keep N] [--peer ID]`:

- **Stopped VM:** files are copied directly; the copy is consistent.
- **Running VM with `--live`:** each disk is copied by a QEMU block-copy job
  into a staging file while the guest runs (jobs are not auto-dismissed, so a
  failure stays visible instead of passing for success). Replication is paused
  around it as described above. Disks QEMU cannot copy are refused up front.
- The archive is assembled in staging. For `--peer`, it is then copied into
  `peers/ME/backups/VM/` on the peer's backplane, and the local staging copy is
  deleted only after that succeeds. Cleanup runs on every exit path, so a failed
  run does not strand full-size disk copies.
- `--keep N` then deletes all but the newest *N* archives matching
  `VM-LABEL-*` in that destination.

`POST /backups/start` runs the same thing asynchronously with a progress file;
`GET /backups/jobs/ID` reports it.

### Scheduling

Schedules are cron entries plus a small definition file per VM and label
(`NAME`, `LABEL`, `DESTINATION`, `KEEP`, `LIVE`, `PEER_ID`, `CRON`). The
system cron daemon runs `vmbackupctl`; LiteVMM adds no scheduler process.
Crontabs are rewritten atomically and **only when their content changes**,
because BusyBox `crond` reloads whenever its directory changes.

### Listing

`vmbackupctl list` merges local archives (`/var/lib/vmapi/backups/VM/`) and
archives other hosts stored **on this host's** backplane
(`backplane/peers/*/backups/VM/`, reported with `target: "backplane"` and the
`owner` node ID). The console then merges every paired host's list.

### Restoring

`vmbackupctl restore VM ARCHIVE [--peer ID] [--replace]` extracts onto **this**
host's local storage (disks that were peer-backed come back local). With
`--replace` on an existing, stopped VM, a rollback backup of the current VM is
taken first and restored automatically if the restore fails.

## Cold migration

`peerctl migrate VM PEER` (`POST /cluster/migrate`):

1. Requires the VM stopped and not replicating, and the destination not to
   have a VM of that name (checked through the peer API).
2. Builds a `migration`-labelled archive in a scratch directory.
3. Streams it to the peer's `POST /peer-api/migrations/import/ARCHIVE`, which
   restores it there.
4. Deletes the local VM only after the import succeeds.

The archive crosses the management endpoint as an HTTP body; migration does not
use the backplane.
