# Known Issues — Open-E JovianDSS Proxmox Plugin

This file documents known concurrency and reliability issues discovered during testing.
For the fixes applied, see `FIXES.md`.

---

## Issue 1: Concurrent VM Restore Failure

### Summary

When restoring multiple VMs simultaneously (3+) through the Proxmox task system to JovianDSS
iSCSI storage, restore operations fail due to race conditions in volume allocation and iSCSI
target management. The previous workaround was setting `max_workers=1` in the cluster options,
which serializes all operations but significantly limits throughput.

**Status: Fixed** — see Fixes 1–9 in `FIXES.md`. The `max_workers=1` workaround is no longer needed.

### Environment

- **Proxmox VE**: 9.1.1 (kernel 6.17.2-1-pve, Debian Trixie)
- **Plugin**: open-e-joviandss-proxmox-plugin 0.10.15
- **JovianDSS**: HA cluster (2 nodes), Pool-4 (mirror)
- **Storage API version**: v3, port 82
- **iSCSI data path**: VIP on port 3260

### Steps to Reproduce

1. Configure JovianDSS storage plugin (`joviandss: jdss1`) with `max_workers > 1`
2. Create 4 test VMs with disks on jdss1 storage:
   ```
   for vmid in 101 102 103 104; do
     qm create $vmid --name test-vm-$vmid --memory 256 --cores 1 \
       --scsi0 jdss1:1 --scsihw virtio-scsi-pci --ostype l26
   done
   ```
3. Back up all VMs:
   ```
   vzdump 101 102 103 104 --storage local --compress zstd --mode stop
   ```
4. Destroy VMs:
   ```
   for vmid in 101 102 103 104; do qm destroy $vmid --purge; done
   ```
5. Set `max_workers` to allow concurrency:
   ```
   pvesh set /cluster/options --max_workers 4
   ```
6. Submit all restores simultaneously via the Proxmox API:
   ```
   for vmid in 101 102 103 104; do
     pvesh create /nodes/pve/qemu \
       --vmid $vmid \
       --archive "local:backup/vzdump-qemu-${vmid}-....vma.zst" \
       --storage jdss1 --force 1
   done
   ```

> **Note:** Must use the API path (`pvesh`), not direct CLI `qmrestore`. Direct CLI bypasses
> the Proxmox task worker and shows different symptoms (disks attached as `unused0` instead
> of hard failures) — see Test Results below.

### Observed Behavior

#### Failure Mode 1: "disk-1 DNE" — Orphaned Volumes

When `qm destroy --purge` silently fails to delete a volume (due to hung REST call, no timeout),
the volume survives on JovianDSS. The next restore sees `disk-0` still exists and allocates
`disk-1`. VMA restore expects `disk-0`. Fails with:

```
command '... vma extract ...' failed: JDSS resource v_vm-10X-disk-1 DNE.
```

Root cause chain:
1. `DELETE /san/iscsi/targets/<name>` hangs in JovianDSS (SCST teardown) — no HTTP timeout → jdssc killed
2. Orphaned empty iSCSI target survives, holding SCST device handler
3. `DELETE /volumes/<name>` with `force_umount: true` also hangs — SCST still registered
4. Volume survives; `find_free_diskname` returns `disk-1` on next restore

#### Failure Mode 2: "target DNE" — TOCTOU Race

Between checking that an iSCSI target exists (`get_target`) and using it
(`set_target_assigned_vips`), a concurrent process deletes it:

```
command '... vma extract ...' failed: JDSS resource iqn.2025.com.open-e:vm-101-0 DNE.
```

#### Aftermath

Failed restores leave orphaned state:
- Partially created volumes on JovianDSS (zvols exist but no valid VM config)
- `no lock found trying to remove 'create' lock` warnings
- Manual cleanup required on both Proxmox and JovianDSS sides

### Test Results (before fix)

| Test | max_workers | Method | Result |
|------|-------------|--------|--------|
| Concurrent restore (CLI `qmrestore &`) | N/A | Shell backgrounding | All 4 completed, but disks attached as `unused0` instead of `scsi0` |
| API restore, max_workers=4 (run 1) | 4 | `pvesh create /nodes/pve/qemu` | 1 OK, 3 FAILED (disk-1 DNE) |
| API restore, max_workers=4 (run 2) | 4 | `pvesh create /nodes/pve/qemu` | 3 OK, 1 FAILED (target DNE) |
| API restore, max_workers=1 | 1 | `pvesh create /nodes/pve/qemu` | All 4 OK (serialized) |

### Test Results (after fix)

| Test | Result |
|------|--------|
| Concurrent API restore of VMs 101–104 (run 1) | ✅ All 4 OK |
| Sequential `qm destroy --purge` of VMs 101–104 | ✅ All 4 OK |
| Concurrent API restore of VMs 101–104 (run 2) | ✅ All 4 OK |

---

## Issue 2: Live Migration Hangs at "[pve2] OK"

### Summary

Live migration of a VM to another node hangs indefinitely after the destination node acquires
the VM lock. The migration task log cuts off at:

```
2026-02-23 18:01:50 starting VM 302 on remote node 'pve2'
2026-02-23 18:01:51 [pve2] trying to acquire lock...
2026-02-23 18:01:51 [pve2]  OK
```

No further progress. The source VM remains running on the original node. The `qmigrate` task
stays in the active list indefinitely (status `0`).

**Status: Fixed** — see Fix 10 in `FIXES.md`.

### Environment

- **Proxmox VE**: 9.1.1, 3-node cluster (pve1/pve2/pve3)
- **Plugin**: open-e-joviandss-proxmox-plugin 0.10.15
- **Trigger**: HA resource agent migration under concurrent load (multiple VMs migrating)

### Root Cause

After the destination node (pve2) acquires the lock, `qm start --migratedfrom` runs
`activate_volume` for the VM's disk, which calls `volume_stage_multipath` in `Common.pm`.

`volume_stage_multipath` runs bare `multipath` (no arguments) in a 10-attempt retry loop.
Bare `multipath` scans **all paths on the system** (48+ with many VMs) and holds the Linux
IPC semaphore for the entire duration.

Under concurrent migration load:
1. Multiple bare `multipath` calls compete for the IPC semaphore (`semtimedop`)
2. When one call is SIGKILL'd (by a timeout) while holding the semaphore → semaphore stuck at value=1 forever
3. All subsequent `multipath` calls block on `semtimedop(..., NULL)` — no timeout → hang forever

Confirmed by inspection:
```
# On pve2, stuck process tree:
qm(209360) → task(209365) → multipath(214319)

# Stuck semaphore:
semnum  value  ncount  zcount  pid
0       1      0       1       214319   ← stuck at 1 since 18:02:15, never signaled

# multipath blocked in kernel:
strace -p 214319: semtimedop(131128, [{sem_num=0, sem_op=0, sem_flg=0}], 1, NULL)
#                                                                              ^^^^ no timeout
```

### Fix Applied

In `Common.pm`, replaced all three bare `multipath` calls with per-device calls and added
a 30-second timeout:

```perl
# Before — scans all 48 paths, holds semaphore indefinitely:
my $cmd = [ $MULTIPATH ];
run_command($cmd, noerr => 1);

# After — only processes this specific WWID, 30s timeout:
my $cmd = [ $MULTIPATH, $id ];
run_command($cmd, noerr => 1, timeout => 30);
```

Files changed: `OpenEJovianDSS/Common.pm` lines 1373, 2000, 2034.

The `timeout => 30` ensures `run_command` sends SIGTERM (not SIGKILL) to `multipath` on
timeout. SIGTERM triggers `multipath`'s signal handler which releases the semaphore before
exiting. Only SIGKILL bypasses this, which is what caused the original stuck semaphore.

---

## Issue 3: iSCSI Targets Not Deleted After VM Removal

### Summary

After deleting VMs via Proxmox GUI, iSCSI targets remained on JovianDSS with one or two
zvols still attached. The expected behavior is that removing a VM (with disk purge) removes
all iSCSI targets and volumes for that VM from JovianDSS.

**Status: Fixed** — see Fix 11 in `FIXES.md`.

### Observed Behavior

After removing VMs via Proxmox GUI with "purge disk images":

```
iqn.2026-02.proxmox.pool-1:vm-357-0  ← 2 zvols attached
iqn.2026-02.proxmox.pool-1:vm-356-0  ← 1 zvol attached
iqn.2026-02.proxmox.pool-1:vm-355-0  ← 1 zvol attached
...
```

### Root Cause

Two bugs in `remove_export` / `_delete_zombie_targets` in `driver.py`:

1. **Early return skipped zombie cleanup**: `remove_export` returned early when the ZFS
   volume was already gone (`is_lun` returned False) without calling `_delete_zombie_targets`.
   If a prior aborted operation had already deleted the volume but left the target alive,
   the target was never cleaned up by subsequent `free_image` calls.

2. **Orphaned LUNs not cleaned up**: `_delete_zombie_targets` only deleted *empty* targets
   (`len(luns) == 0`). If a target still had LUNs referencing volumes that no longer existed
   on ZFS (e.g., from an aborted restore), the target was silently skipped and left behind
   indefinitely.

### Note on Removal Procedure

All Proxmox VE-managed volumes must be removed using Proxmox VE tools (GUI with "purge disk
images" checked, or CLI `pvesm free <storeid>:<volname>`). Volumes or targets left behind
by failed operations can also be cleaned up by running `pvesm free` for each orphaned
volume — this now triggers the extended zombie cleanup which also detaches orphaned LUNs
and deletes the empty target.

---

## Issue 4: Offline Cross-Cluster Migration Between ZFS and JovianDSS Fails

### Summary

Offline (VM stopped) cross-cluster migration between local ZFS storage and JovianDSS
iSCSI storage fails in both directions, while live migration of the same VMs succeeds.
Reported against 0.11.6-pre.

- ZFS → JovianDSS:
  `failed to handle 'disk-import' command - unable to parse joviandss volume name '103/vm-103-disk-0.raw'`
- JovianDSS → ZFS:
  `failed to handle 'disk-import' command - no matching import/export format found for storage 'local-zfs'`

### Root Causes

The report decomposes into three independent facts:

1. **Plugin bug (fixed)** — the storage config defines a `path` property, so PVE's
   generic import code (`PVE/Storage.pm`, `$volname_for_storage`) composes the target
   volname in directory style, `"$vmid/$name.$format"`, before calling into the plugin.
   The plugin's `parse_volname` rejected that form, killing *any* import into JovianDSS
   storage — including jdss→jdss, which is otherwise fully feasible.

2. **PVE limitation, not fixable in the plugin** — `PVE::Storage::ZFSPoolPlugin`
   implements only the `zfs` (send/recv) stream format for both export and import;
   `raw` support is an upstream TODO (`ZFSPoolPlugin.pm`). JovianDSS can only offer
   `raw+size` (the REST API exposes no zfs-send-style stream), so the format
   intersection with a `zfspool` storage is empty in both directions. This is not
   JovianDSS-specific: offline LVM↔ZFS migration fails identically on stock PVE.

3. **Format limitation** — a `raw+size` stream carries a single point-in-time state,
   so a volume cannot be transferred *together with its snapshot history*
   (`with_snapshots`). The plugin refuses those requests by returning an empty format
   list and PVE reports "no matching import/export format".

### Status

**Fixed for the feasible cases** (2026-07-28): `OpenEJovianDSSPlugin.pm`
implements `volume_export`/`volume_import` (+`_formats`) with `raw+size` streams.
Verified live on the pve-91 cluster: export/import round-trip with identical checksums,
import via the PVE-composed dir-style volname, `--allow-rename` collision handling, and
export from a named snapshot (via the snapshot-clone activation path).

Works after the fix:
- Offline cross-cluster (and `--targetstorage`) migration JovianDSS → JovianDSS
- Offline migration between JovianDSS and any storage speaking `raw+size`
  (dir, LVM, ...), in both directions, for volumes without snapshot history
- `pvesm export --snapshot <name>` point-in-time exports

Still not possible (use live migration as the workaround — QEMU's NBD block mirror
bypasses the storage import/export format system entirely):
- Offline migration between JovianDSS and `zfspool` storage in either direction
  (blocked by PVE's ZFS plugin until upstream implements raw streams)
- Offline migration of VMs whose disks carry snapshots (`with_snapshots`)

---

## Issue 5: Intra-Cluster Same-VMID Concurrent Export|Import Deadlocks

### Summary

Offline migration between two JovianDSS storages **within one cluster**
(`qm migrate --targetstorage`, or any manual same-vmid
`pvesm export ... | pvesm import ...` pipeline) deadlocks: the migration
hangs ~20 minutes, then aborts with "got lock request timeout".
**Status: Resolved — see Resolution below.**

Discovered 2026-07-30 while designing the long-transfer verification of the
sliced-dd copy (the test had to import under a different vmid to avoid it).

### Root Cause

`volume_export` and `volume_import` each hold the per-VM method lock for
their entire runtime. The lock is keyed cluster-wide by vmid only —
`joviandss-lock-vm-<vmid>` (`Lock.pm`, `_lock_resolve`), with no storage id
in the key — and on `shared 1` storages it is a single pmxcfs object.

PVE's `storage_migrate` runs export and import as a concurrent pipeline
(`PVE/Storage.pm`: the import command is appended to the export command list
and both run under one `run_command`). Export acquires `vm-<vmid>` and
starts streaming; import blocks acquiring the same lock; the pipe fills and
export's write stalls. Nothing detects the cycle — it ends only when
import's acquire timeout (vm class: 1200 s) expires.

### Scope

| Scenario | Affected? |
|---|---|
| Cross-cluster `qm remote-migrate` (separate pmxcfs per cluster) | No — works, verified live 2026-07-30 (12 GiB, md5-verified) |
| Sequential export to file, then import, same vmid | No — locks taken one after the other |
| Same cluster, concurrent, different vmids | No |
| Same cluster, concurrent, same vmid (incl. `--targetstorage` offline migration between two jdss storages) | **Yes — deadlock** |

### Workarounds

- Use live migration for intra-cluster storage moves (QEMU NBD mirror, no
  import/export path).
- Or export to an intermediate file, then import (sequential locking).

### Resolution

**Resolved 2026-07-30** by restructuring `volume_export`/`volume_import` to
per-step locking: no method-level vm lock is held across the operation; each
serialized step (activate, alloc, deactivate, free) takes its own short
`_*_lock`, and the copy itself runs with no lock held.  Concurrent same-vmid
export|import now interleave instead of deadlocking.

Verified live: same-vmid cross-node pipeline (export on node1, import on
node2 — the real intra-cluster migration shape) moved 2 GiB in 28 s with a
matching md5, where the previous design hung for 1200 s.

Residual, pre-existing constraint (not a lock issue): same-vmid concurrent
export|import **on one node** across two storages sharing a `target_prefix`
fails fast (~19 s) at the target-collision guard with the documented
"different storages MUST use different target_prefix" error — configure
distinct `target_prefix` values per storage for that case.

## Issue 6: Online Container Mountpoint Resize Fails (loop-over-block + stale host device)

**Status:** Open — found 2026-08-02 on pve-92-1 (pve-manager 9.2.5, plugin
build of 2026-08-02) by testcase `iscsi-resize-ct-load-001`
(pve-testing/testcases/iscsi-plugin/resize/pct-resize-under-load-container.yaml).

### Symptom

`pct resize <ctid> mp0 2G` on a RUNNING container with a JovianDSS-backed
mountpoint grows the zvol on the appliance (REST volsize and pct config both
report the new size) but the filesystem inside the container stays at the
old size, and pct prints:

    internal error: CT running but mount point not attached to a loop device
    at /usr/share/perl5/PVE/API2/LXC.pm line 2438.

### Root cause chain

1. The storage entry declares a `path` property (`path /mnt/pve/<storeid>`).
   `PVE::LXC::mountpoint_mount` decides how to mount raw CT volumes solely
   on `$scfg->{path}`: when present, the volume is attached through a LOOP
   device (`run_with_loopdev`) even though the plugin hands back a real
   block device. Container start therefore loop-mounts the iSCSI device —
   functional, but an extra layer PVE only expects for file-backed images.
2. On resize of a running CT, `PVE::API2::LXC` re-resolves the volume path
   and calls `PVE::LXC::query_loopdev($path)` to find that loop device.
   The lookup fails (the path string used at attach time and the one
   returned at resize time do not match), so the code dies with the
   "internal error" above before `losetup --set-capacity`/`resize2fs` run.
3. Independently, the host-side device does not reflect the grown zvol
   after `volume_resize` returns (blockdev --getsize64 still reports the
   pre-resize size): without a SCSI rescan + multipath map resize the
   loop capacity update and resize2fs would read the stale size even if
   step 2 were fixed. VM disks mask this because QEMU's `block_resize`
   informs the guest directly.

### Impact

- Online mountpoint grow for containers is broken end to end.
- Offline (stopped CT) resize path also depends on the host seeing the new
  device size (e2fsck + resize2fs on the mapped device) and needs
  verification once the online path is addressed.

### Candidate directions (undecided)

- Teach `volume_resize` to refresh the host block stack synchronously
  (iSCSI rescan + `multipathd resize map`) before returning, so the mapped
  device reports the new size — required for every non-QEMU consumer.
- Revisit the `path` property declaration (it also drives the composed
  `$vmid/$name.raw` volnames of Issue 4); dropping it would make PVE::LXC
  mount the block device directly, but has wide side effects and needs a
  design pass.
- Alternatively implement `map_volume`/`unmap_volume` semantics that PVE's
  LXC layer can match consistently at attach and resize time.

### Reproduction

    pct create <id> <tmpl> --rootfs jdss-X:2 --mp0 jdss-X:1,mp=/mnt/testdata --net0 ...
    pct start <id>
    pct resize <id> mp0 2G       # zvol grows, fs does not, internal error printed

## Issue 7: Property Deletion Bypasses on_update_hook Validation

**Status:** Open — found 2026-08-02 on pve-92-1 (pve-manager 9.2.5, plugin
build of 2026-08-02) while reviewing storage API v13 compatibility.

### Symptom

With a chap-enabled storage, deleting the chap user name is accepted:

    pvesm set <storeid> --delete chap_user_name     # exits 0

leaving `chap_enabled 1` without a `chap_user_name` in storage.cfg — the
exact invalid state the plugin's own on_update_hook validation
("chap_user_name is required when chap_enabled is set") exists to refuse.
Verified live: the deletion succeeded and the section kept `chap_enabled 1`
with no chap user name.

### Root cause

`on_update_hook` receives only the UPDATED properties; property DELETIONS
are processed by PVE separately and never reach the hook, and the `$scfg`
passed in still carries the pre-deletion values — so the chap
cross-validation sees a consistent (stale) picture. This is the exact
limitation storage API v13 addresses with `on_update_hook_full()`, which
additionally receives the current configuration and the list of properties
to be deleted (Proxmox bug #6669 was the upstream motivation). The plugin
does not implement `on_update_hook_full` yet.

### Impact

An administrator can `--delete chap_user_name` (or conceivably other
cross-validated properties) and only discover the broken chap setup when
iSCSI logins start failing.

### Direction

Implement `on_update_hook_full()` (v13) and move the chap cross-validation
there, evaluating the post-update effective configuration including
deletions; keep `on_update_hook` delegating for older PVE versions. The
desired contract is captured by testcase
`iscsi-api-v13-update-delete-validation-001`
(pve-testing/testcases/iscsi-plugin/api-compatibility/v13), which FAILS on
current builds by design until the hook is implemented. The pinned absence
in tests/api_compat_test.pl must be flipped alongside.

## Issue 8: alloc_image Accepts Unsupported qcow2 Format

**Status: Fixed** — found 2026-08-02 on pve-92-1 by testcase
`iscsi-api-v12-get-formats-001`
(pve-testing/testcases/iscsi-plugin/api-compatibility/v12), fixed the
same day.

### Symptom

    pvesm alloc jdss-Pool-2 990032 vm-990032-disk-0.qcow2 131072 --format qcow2

succeeds (exit 0) although the plugin's format declaration is raw-only.
A raw zvol is created under a name ending in .qcow2; any consumer trusting
the requested format (e.g. a VM config referencing the volume as qcow2)
would misinterpret the raw device.

### Root cause

The plugin's alloc path does not validate the requested format. Upstream
block plugins refuse explicitly (ZFSPoolPlugin::alloc_image:
`die "unsupported format '$fmt'" if $fmt ne 'raw';`); the JovianDSS
plugin has no equivalent guard, and PVE core does not enforce the
storage's format list at allocation time.

### Resolution

**Resolved 2026-08-02**: `alloc_image` refuses any format other than raw
before taking a lock or touching the appliance, mirroring
ZFSPoolPlugin::alloc_image:

    unsupported format 'qcow2' - storage 'jdss-Pool-2' only supports raw

Verified live on pve-92-1: the qcow2 allocation is now rejected and
leaves no volume behind, while default and explicit raw allocations still
succeed — testcase `iscsi-api-v12-get-formats-001` passes 8/8. Unit
coverage in tests/api_compat_test.pl pins the guard (refusal, no storage
call on refusal, raw and unspecified formats pass).
