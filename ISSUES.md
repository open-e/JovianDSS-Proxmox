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
