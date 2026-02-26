# JovianDSS Proxmox Plugin — Concurrency & Robustness Fixes

**Plugin version:** 0.10.15
**Problem:** Concurrent VM restore, destroy, and live migration failures under load.

---

## Background: What is TOCTOU?

**TOCTOU** stands for **Time-Of-Check To Time-Of-Use**. It is a class of race condition that occurs in three steps:

1. **Check** — you verify that a resource exists or is in a valid state
2. **Time passes** — another process runs concurrently
3. **Use** — you try to use the resource, but its state has changed since step 1

In this plugin, multiple Proxmox processes (restore, destroy, migration) all talk to the same JovianDSS appliance simultaneously. Any of them can create or delete iSCSI targets and volumes that others are depending on. If process A lists a target (check) and process B deletes it before process A configures it (use), process A gets an unexpected `JDSSResourceNotFoundException` and fails — even though neither process did anything wrong individually.

---

## Root Cause Summary

Two classes of failure were observed during concurrent VM restore tests:

1. **"disk DNE" failures** — `qm destroy --purge` or `qmrestore` failing with
   `JDSS resource v_vm-NNN-disk-0 DNE.` when the backend volume had already been deleted
   (or never existed on the JovianDSS side).

2. **"target DNE" failures** — `qmrestore` failing with
   `JDSS resource iqn.2025.com.open-e:vm-NNN-0 DNE.` due to TOCTOU races during concurrent
   iSCSI target creation/deletion.

---

## Fix 1 — Configurable Delete Timeout

**Files:** `OpenEJovianDSSPlugin.pm`, `OpenEJovianDSS/Common.pm`

**Problem:** The `joviandss_cmd` timeout for volume deletion was too short for cascade deletes
with many snapshots. The operation could time out and leave the system in an inconsistent state.

**Fix:** Added `delete_timeout` as a configurable storage property (default: 600 seconds).

```perl
# OpenEJovianDSSPlugin.pm — property declaration
delete_timeout => {
    description => "Timeout in seconds for volume delete operations (default 600). "
                 . "Increase for volumes with many snapshots.",
    type => 'integer',
    minimum => 60,
    default => 600,
    optional => 1,
},
```

```perl
# OpenEJovianDSS/Common.pm — getter function
sub get_delete_timeout {
    my ($scfg) = @_;
    return $scfg->{delete_timeout} // 600;
}
```

The timeout is passed to `joviandss_cmd` wherever volume deletion is invoked.

---

## Fix 2 — HTTP Request Timeout

**File:** `jdssc/jdssc/jovian_common/rest_proxy.py`

**Problem:** The `requests.Session.send()` call had no timeout configured, meaning REST API calls
could hang indefinitely if the JovianDSS appliance was slow or under load.

**Fix:** Added `request_timeout` configuration (default: 570 seconds) and pass it to `session.send()`.

```python
# rest_proxy.py — __init__
self.request_timeout = config.get('jovian_request_timeout', 570)

# rest_proxy.py — _send()
response_obj = self.session.send(pr, timeout=self.request_timeout)
```

---

## Fix 3 — Broad Exception Catch in `_delete_volume`

**File:** `jdssc/jdssc/jovian_common/driver.py`

**Problem:** `_detach_volume()` inside `_delete_volume()` only caught specific exceptions.
Under concurrent load, transient errors could propagate and abort the delete.

**Fix:** Broadened the exception catch in `_delete_volume` to catch all `JDSSException` subclasses
when detaching, so transient detach failures are logged as warnings rather than causing deletion to fail.

```python
if detach_target:
    try:
        self._detach_volume(vname)
    except jexc.JDSSException as jerr:
        LOG.warning('Could not detach volume %s from target: %s', vname, jerr)
```

---

## Fix 4 — Zombie Target Cleanup (`_delete_zombie_targets`)

**File:** `jdssc/jdssc/jovian_common/driver.py`

**Problem:** When a concurrent restore or delete operation was interrupted mid-way, orphaned
iSCSI targets ("zombies") could be left behind on JovianDSS. Subsequent operations on the
same VM would fail because the old target still existed.

**Fix:** Added `_delete_zombie_targets(target_prefix, target_group, vname)` method that scans
all targets with the given prefix/group and deletes any that reference the specified volume.
This method is called from `remove_export()` before any new target creation.

```python
def _delete_zombie_targets(self, target_prefix, target_group, vname):
    """Remove leftover targets referencing the given volume."""
    ...
    # Called in remove_export():
    self._delete_zombie_targets(target_prefix, target_group, vname)
```

---

## Fix 5 — TOCTOU Race in `_detach_volume`

**File:** `jdssc/jdssc/jovian_common/driver.py`

**Problem:** `_detach_volume` iterated over targets and tried to detach volumes from them.
Under concurrent load, a target could be deleted by another process between the list call
and the detach call, raising `JDSSResourceNotFoundException` and aborting the whole operation.

**Fix:** Added `except JDSSResourceNotFoundException: continue` inside the target iteration loop
so that a concurrently-deleted target is silently skipped.

```python
for target in targets:
    try:
        # ... detach logic ...
    except jexc.JDSSResourceNotFoundException:
        # Target was deleted concurrently — skip it
        continue
```

---

## Fix 6 — TOCTOU Race in `_acquire_taget_volume_lun`

**File:** `jdssc/jdssc/jovian_common/driver.py`

**Problem:** `_acquire_taget_volume_lun` searched for an available target slot and then tried
to use it. Between finding the slot and writing to it, another concurrent process could
claim or delete the target, causing `JDSSResourceNotFoundException`.

**Fix:** Added `except JDSSResourceNotFoundException: continue` inside the acquisition loop
so that a concurrently-modified target triggers a retry rather than a fatal error.

```python
for i in range(retries):
    try:
        # ... find and claim a target slot ...
    except jexc.JDSSResourceNotFoundException:
        # Slot was claimed or deleted concurrently — retry
        continue
```

---

## Fix 7 — TOCTOU Race in `_ensure_target_volume_lun` (post-`get_target`)

**File:** `jdssc/jdssc/jovian_common/driver.py`
**Lines:** ~1073–1124

**Problem:** `_ensure_target_volume_lun` called `get_target(tname)` to verify the target exists,
then proceeded to call `set_target_assigned_vips(tname, ...)` and `_attach_target_volume_lun()`.
If another concurrent process deleted the target between these calls, a `JDSSResourceNotFoundException`
was raised but not caught, propagating as a fatal error:

```
JDSS resource iqn.2025.com.open-e:vm-101-0 DNE.
```

**Fix:** Wrapped the entire post-`get_target` block in a `try/except JDSSResourceNotFoundException`
that calls `_create_target_volume_lun()` to recreate the target from scratch if it vanishes.

```python
try:
    volume_publication_info['target'] = tname
    expected_vips = self._get_conforming_vips()
    if ...:
        pass
    else:
        self.ra.set_target_assigned_vips(tname, ...)   # could raise if target deleted
    ...
    if not self.ra.is_target_lun(tname, vname, lid):
        self._attach_target_volume_lun(tname, vname, lid)
    ...
except jexc.JDSSResourceNotFoundException:
    LOG.debug("Target %s vanished during ensure, recreating", tname)
    return self._create_target_volume_lun(tname, vname, lid, provider_auth)
```

---

## Fix 8 — `get_volume_snapshots_page` Missing Error Class Check

**File:** `jdssc/jdssc/jovian_common/rest.py`
**Lines:** ~1172–1178

**Problem:** `get_volume_snapshots_page()` checked the error message against `resource_dne_msg`
(pattern: `^Zfs resource: .* not found in this collection.$`) but newer JovianDSS versions
return `opene.exceptions.ItemNotFoundError` (class) with message
`Resource Pool-N/v_vm-NNN-disk-0 not found.` — which does NOT match the old pattern.

As a result, `_general_error()` was called, raising `JDSSException` instead of the expected
`JDSSResourceNotFoundException`. Callers like `_list_all_volume_snapshots` only caught
`JDSSResourceNotFoundException`, so the wrong exception type propagated up and caused
`volume delete -c -p` to fail with:

```
JDSS resource v_vm-104-disk-0 DNE.
```

**Fix:** Added a second check for the `class` field using the existing `class_item_not_found_error`
pattern (`^opene.exceptions.ItemNotFoundError$`):

```python
if resp['error']:
    if 'message' in resp['error']:
        if self.resource_dne_msg.match(resp['error']['message']):
            raise jexc.JDSSResourceNotFoundException(res=vname)
    if 'class' in resp['error']:
        if self.class_item_not_found_error.match(resp['error']['class']):
            raise jexc.JDSSResourceNotFoundException(res=vname)
self._general_error(req, resp)
```

---

## Fix 9 — Wrong Regex in `path()` for Volume-Not-Found Handling

**File:** `OpenEJovianDSSPlugin.pm`
**Line:** 307

**Problem:** The `path()` function (which returns a volume's block device path) called
`block_device_path_from_rest()` inside an `eval {}` block, expecting that if the volume
doesn't exist it would get a `JDSS resource ... does not exist.` error and silently return `undef`.

However, the regex used to detect this condition was:
```perl
if ($clean_error =~ /^JDSS resource volume .+ DNE\.$/) {
```

The actual `JDSSResourceNotFoundException` message format is:
```
JDSS resource v_vm-104-disk-0 DNE.
```

The word `"volume"` is never present — the resource name comes directly after `"JDSS resource "`.
So the regex never matched, `die $error` was reached, and `qm destroy --purge` failed:

```
JDSS resource v_vm-104-disk-0 DNE.
Unable to identify expected block device path for volume activation error: ...
```

**Fix:** Removed the spurious `"volume "` from the regex:

```perl
# Before (wrong):
if ($clean_error =~ /^JDSS resource volume .+ does not exist\.$/) {

# After (correct):
if ($clean_error =~ /^JDSS resource .+ does not exist\.$/) {
```

---

## Fix 10 — Bare `multipath` Call Causes Live Migration Hang

**File:** `OpenEJovianDSS/Common.pm`
**Lines:** 1373, 2000, 2034

**Root cause:**

`volume_stage_multipath` calls bare `multipath` (no arguments) in a retry loop during
`activate_volume` on the destination node. The failure chain:

1. Bare `multipath` (no args) scans **all** paths on the system and holds the Linux IPC
   semaphore for the entire duration
2. Under concurrent migrations, multiple bare `multipath` calls compete for the same semaphore
3. When one gets SIGKILL'd (by a timeout) while holding it — the semaphore stays locked at
   value=1 forever, because SIGKILL bypasses signal handlers that would normally release it
4. All subsequent `multipath` calls block on `semtimedop(..., NULL)` — with no timeout —
   hanging forever
5. The `qm start --migratedfrom` on the destination never returns → migration hangs at
   `[pve2] OK`

**Why SIGKILL and not SIGTERM?** Proxmox's `joviandss_cmd` had a 40-second timeout that sent
SIGKILL directly to jdssc, which in turn left child processes (including `multipath`) getting
SIGKILL'd without cleanup.

**Fix:** Replace bare `multipath` with `multipath $id` (processes only the specific WWID,
much faster, holds semaphore briefly) and add `timeout => 30` to `run_command` so timeouts
send SIGTERM first — allowing `multipath`'s signal handler to release the semaphore before
dying.

```perl
# Before — scans all paths, holds semaphore indefinitely, no timeout:
my $cmd = [ $MULTIPATH ];
run_command($cmd, noerr => 1);

# After — only processes this WWID, 30s timeout allows clean semaphore release:
my $cmd = [ $MULTIPATH, $id ];
run_command($cmd, noerr => 1, timeout => 30);
```

---

## Fix 11 — Orphaned iSCSI Targets After VM Removal

**File:** `jdssc/jdssc/jovian_common/driver.py`

**Problem:** After deleting VMs via Proxmox GUI, iSCSI targets were left on JovianDSS with
one or two zvols still attached. Two code paths contributed:

**Cause A — `remove_export` skipped zombie cleanup on missing volume:**
`remove_export` checked `is_lun(vname)` before proceeding. If the ZFS volume was already
gone (e.g., deleted by a prior aborted operation), it returned early — but did *not* call
`_delete_zombie_targets`. Any empty or orphaned target for that VM's target group was left
behind.

**Cause B — `_delete_zombie_targets` only handled fully-empty targets:**
If a prior failed restore left an orphaned zvol attached as a LUN on the target, `_delete_zombie_targets`
would see `len(luns) > 0` and skip the target entirely — even if every LUN's backing ZFS
volume had since been deleted.

**Fix A:** Call `_delete_zombie_targets` unconditionally in `remove_export`, including on
the early-return path when the volume is already gone:

```python
# Before — early return without cleanup:
if not self.ra.is_lun(vname):
    LOG.warning(...)
    return                        # ← zombie targets left behind

# After — run cleanup before returning:
if not self.ra.is_lun(vname):
    LOG.warning(...)
    self._delete_zombie_targets(target_prefix, target_name)   # ← added
    return
```

Also removed the `if not new_target_flag:` guard on the final `_delete_zombie_targets`
call so it always runs (previously it was skipped when no related target existed at all).

**Fix B:** Extended `_delete_zombie_targets` to also detach LUNs whose backing ZFS
volume no longer exists before checking whether the target is empty:

```python
luns = self.ra.get_target_luns(target)

# Detach any LUNs whose backing ZFS volume no longer exists.
for lun in luns:
    lun_name = lun.get('name')
    if lun_name and not self.ra.is_lun(lun_name):
        LOG.warning("Detaching orphaned LUN %s from target %s"
                    " (volume no longer exists)", lun_name, target)
        try:
            self.ra.detach_target_vol(target, lun_name)
        except jexc.JDSSException as jerr:
            LOG.warning("Could not detach orphaned LUN %s "
                        "from target %s: %s", lun_name, target, jerr)

# Re-fetch after potential orphan cleanup.
luns = self.ra.get_target_luns(target)
if len(luns) == 0:
    LOG.warning("Deleting zombie empty target %s", target)
    self.ra.delete_target(target)
```

Together these two fixes ensure that after any volume is freed via `pvesm free` (or the
Proxmox GUI with disk purge), the entire VM target group is inspected and any lingering
targets — whether empty or holding orphaned LUNs — are cleaned up.

---

---

## Fix 12 — `pvesm free` Silently Succeeds for Non-Existent Volumes

**File:** `jdssc/jdssc/jovian_common/driver.py`

**Problem:** `pvesm free jdss-Pool-0:vm-100-disk-0` printed `Removed volume 'jdss-Pool-0:vm-100-disk-0'`
and exited 0 even when the volume did not exist on JovianDSS — either because the name was
wrong (e.g. `vm-357-0` instead of `vm-357-disk-0`) or because the volume had already been
deleted by a prior operation.

The cause was that `_delete_volume()` internally caught `JDSSResourceNotFoundException` and
returned `None` silently. The jdssc process exited 0, Proxmox saw success, and printed the
misleading "Removed volume" message.

**Fix:** Added an explicit `is_lun` pre-check at the start of `delete_volume()` (non-print
path). If the volume does not exist, `JDSSVolumeNotFoundException` is raised immediately:

```python
def delete_volume(self, volume_name, cascade=False, print_and_exit=False):
    vname = jcom.vname(volume_name)
    LOG.debug('deleting volume %s', vname)
    if print_and_exit:
        LOG.debug("Print only deletion")
        return self._list_resources_to_delete(vname, cascade=True)

    if not self.ra.is_lun(vname):
        raise jexc.JDSSVolumeNotFoundException(volume=volume_name)

    return self._delete_volume(vname, cascade=cascade)
```

This causes jdssc to log an error (`JDSS resource volume <name> does not exist.`) and exit 1. The Perl
layer (`joviandss_cmd`) detects the non-zero exit and calls `die`, which propagates through
the `fork_worker` child, preventing the "Removed volume" message from being printed.

**Note on exit code:** `pvesm free` submits deletion as a background worker via `fork_worker`
(scalar context — exit code discarded) and `run_cli_handler` always calls `exit 0`. This
means the shell exit code of `pvesm free` remains 0 even when the volume was not found.
This is a Proxmox architectural limitation that cannot be fixed without patching Proxmox
source files. The important user-visible behavior — suppressing the false "Removed volume"
message and displaying an error — is correct.

---

## Fix 13 — Slow Volume Deletion Due to Pool-Wide iSCSI Target Scan

**Files:** `jdssc/jdssc/volume.py`, `jdssc/jdssc/jovian_common/driver.py`

**Problem:** `pvesm free jdss-Pool-1:vm-NNN-disk-N` took ~15 seconds per volume on pools with
many iSCSI targets (~60). The bottleneck was `_detach_volume()`, which iterated over **all**
targets in the pool and called `GET /san/iscsi/targets/<name>/luns` for each one (~163 ms per
request × 60 targets ≈ **10 seconds** just for the scan).

With the Proxmox CFS lock acquisition timeout defaulting to **10 seconds** (`vdisk_free` passes
`undef` → `cfs_lock` uses 10 s), concurrent VM deletions from the Proxmox GUI failed:

- Each deletion held the `storage-jdss-Pool-1` lock for ~15 s (> 10 s timeout)
- All other concurrent deletions timed out waiting for the lock
- Result: orphaned volumes and iSCSI targets on JovianDSS

**Root cause:** The Perl plugin already passed `--target-group-name <vm-NNN>` to `jdssc volume
delete`, but `volume.py`'s `delete` argument parser did not define that option. Python's
`parse_known_args` silently discarded it, so `_detach_volume` always fell back to the
full pool-wide scan.

**Fix:** Three-part change:

1. **`volume.py`** — Add `--target-group-name` to the `delete` subparser and forward it to
   `delete_volume()` as `target_name`:

   ```python
   delete.add_argument('--target-group-name',
                       dest='target_group_name',
                       default=None,
                       help='Target group name hint (e.g. "vm-999"). ...')
   ```

2. **`driver.py`** — Thread `target_name` through `delete_volume()` → `_delete_volume()` →
   `_detach_volume()`.

3. **`driver.py` — `_detach_volume`** — When `target_name` is provided, build a regex and
   filter the target list **before** scanning LUNs:

   ```python
   if target_name is not None:
       tname = tprefix + ':' + target_name   # e.g. "iqn.2026-02.proxmox.pool-1:vm-999"
       target_re = re.compile(fr'^{re.escape(tname)}-\d+$')
       candidates = [t for t in all_targets if target_re.match(t['name'])]
       # typically 0–2 targets instead of 60+
   ```

**Result:** `_detach_volume` now scans 0–2 targets (the VM's own targets) instead of all 60+.
Total deletion time drops from **~15 s to ~6 s**, well below the 10 s CFS lock timeout.

---

## Fix 14 — Unnecessary `_detach_target_volume` Call in `remove_export`

**File:** `jdssc/jdssc/jovian_common/driver.py`

**Problem:** `remove_export` (called by `jdssc targets delete -v`) called
`_detach_target_volume(tname, vname)` even when `new_target_flag=True`, meaning no related
iSCSI target existed on the storage array. This resulted in ~1.3 s of wasted REST calls:

- `GET /san/iscsi/targets/<candidate>` → ~880 ms (target doesn't exist)
- `DELETE /san/iscsi/targets/<candidate>/luns/<vname>` → 404
- `GET /san/iscsi/targets/<candidate>/luns` → 404 (raises `JDSSResourceNotFoundException`)

All three calls fail because the target was never created. The exception was silently caught by
the `except jexc.JDSSException` wrapper in `remove_export`, so no error was surfaced — just
wasted time.

**Root cause:** The original condition:

```python
if (volume_attached_flag or (new_target_flag is True)):
    self._detach_target_volume(tname, vname)
```

The `new_target_flag is True` branch was intended as a safety net, but
`_acquire_taget_volume_lun` returns `new_target_flag=True` **only** when no related targets
exist. The volume therefore cannot be attached to any target, so `_detach_target_volume` is a
no-op that wastes ~1.3 s.

**Fix:** Remove the `new_target_flag` branch — only call `_detach_target_volume` when the
volume is actually attached:

```python
# Before:
if (volume_attached_flag or (new_target_flag is True)):
    self._detach_target_volume(tname, vname)

# After:
if volume_attached_flag:
    self._detach_target_volume(tname, vname)
```

**Result:** ~1.3 s saved per deletion when the volume has no associated iSCSI target
(the common path for newly allocated volumes that were never published). Combined with Fix 13,
total deletion time is now ~4–5 s, comfortably within the 10 s CFS lock timeout for 2 concurrent deletions.

---

## Test Results

### Fixes 1–9: Concurrent Restore and Destroy

Tests used the Proxmox API path (`pvesh create /nodes/pve/qemu --force 1`, `max_workers=4`),
which routes through the task worker pool and exposes plugin concurrency issues that direct
CLI `qmrestore` does not (see `ISSUES.md` for the distinction).

| Test | Result |
|------|--------|
| `qm destroy --purge` on VM whose backend volume was already deleted | ✅ OK |
| Concurrent API restore of 4 VMs (run 1) | ✅ All 4 OK |
| Sequential `qm destroy --purge` of 4 VMs | ✅ All 4 OK |
| Concurrent API restore of 4 VMs (run 2) | ✅ All 4 OK |

Previously, at least 1 of the 4 concurrent API restores would fail on every run.

### Fix 10: Live Migration Hang (multipath semaphore)

Tested with `multipath 1` storage on a multi-node cluster.

| Test | Result |
|------|--------|
| Live online migration of a running VM with multipath-enabled JovianDSS storage | ✅ OK |

Migration completed successfully. Previously this hung indefinitely after the destination node
acquired the VM lock, with the multipath IPC semaphore stuck at value=1.

### Fix 12: Silent success on non-existent volume free

| # | Command | Scenario | Output before fix | Output after fix |
|---|---------|----------|-------------------|-----------------|
| 1 | `pvesm free jdss-Pool-0:vm-999-disk-99` | Volume exists — **regression / positive case** | `Removed volume '...'` ✅ | `Removed volume '...'` ✅ |
| 2 | `pvesm free jdss-Pool-1:vm-357-0` | Target-group name used instead of disk name | `Removed volume '...'` ❌ | `JDSS resource volume vm-357-0 does not exist.` ✅ |
| 3 | `pvesm free jdss-Pool-1:vm-357-111` | Volume never existed on JovianDSS | `Removed volume '...'` ❌ | `JDSS resource volume vm-357-111 does not exist.` ✅ |
| 4 | `pvesm free jdss-Pool-0:vm-999-disk-99` | Volume already deleted (double-free) | `Removed volume '...'` ❌ | `JDSS resource volume vm-999-disk-99 does not exist.` ✅ |

Shell exit code is 0 in all cases — Proxmox `fork_worker` architectural limitation (documented above).

### Fix 13: Volume deletion performance (pool-wide target scan eliminated)

Test system: Pool-1, 42 active iSCSI targets, pve1 (10.15.0.141).

| # | Command | Scenario | Time before fix | Time after fix |
|---|---------|----------|-----------------|----------------|
| 1 | `pvesm free jdss-Pool-1:vm-888-disk-0` | Newly allocated volume, no target | ~15 s | ~11 s (old code deployed) |
| 2 | `pvesm free jdss-Pool-1:vm-777-disk-0` | Newly allocated volume, no target | — | **~6 s** ✅ |

Log confirmation for test 2:
```
driver - DEBUG - detach volume v_vm-777-disk-0 (target_name hint: vm-777)
driver - DEBUG - Filtered detach scan to 0/42 targets matching iqn.2026-02.proxmox.pool-1:vm-777
```
The 10-second pool-wide LUN scan is eliminated. Total time now fits within the 10 s CFS lock
acquisition timeout, allowing concurrent VM deletions to succeed without orphaning volumes.

---

## Fix 15 — Redundant `volume_unpublish` in `free_image` Causes CFS Lock Timeout

**File:** `OpenEJovianDSSPlugin.pm`
**Symptom:** Concurrent VM destructions (4+) on the same JovianDSS storage leave orphaned
volumes. The Proxmox GUI shows "Destroy OK" but volumes remain on JovianDSS, with task
logs reporting `cfs-lock 'storage-jdss-Pool-0' error: got lock request timeout`.

**Root cause:** `free_image()` held the CFS lock for ~22 seconds, far exceeding the 10 s
timeout. The time was spent on three phases, two of which were redundant:

| Phase | Duration | What it does |
|-------|----------|-------------|
| `volume_deactivate` | ~7.2 s | Host-local: multipath remove + iSCSI logout |
| `volume_unpublish` | ~5.6 s | REST: detach LUN + delete iSCSI target — **REDUNDANT** |
| `volume delete -c` | ~8.9 s | REST: scan all targets + ZFS destroy |
| **Total** | **~22 s** | CFS lock timeout is 10 s |

`volume_unpublish` detaches the volume's iSCSI target via REST API. But `volume delete -c`
does the exact same thing again via `_detach_volume()`. Worse, because `volume_unpublish`
already deleted the target, `_detach_volume()`'s target-group filter (Fix 13) finds no match
and falls through to scanning ALL targets (~20+ REST calls, ~7.6 s).

**Fix:** Remove the `volume_unpublish` call from `free_image`. The final `volume delete -c`
with `--target-group-name` already handles target detachment, and with the target still
present (not pre-deleted by `volume_unpublish`), the filter finds it directly.

```perl
# BEFORE (3 steps under CFS lock, ~22 s):
volume_deactivate(...)     # host-local cleanup
volume_unpublish(...)      # REST target detach (REDUNDANT)
jdssc volume delete -c     # REST target scan + ZFS destroy

# AFTER (2 steps under CFS lock, ~2 s):
volume_deactivate(...)     # host-local cleanup
jdssc volume delete -c     # REST filtered target detach + ZFS destroy
```

### Test results

**Environment:** pve1 (10.15.0.141), Pool-0, JovianDSS 10.15.20.142 (with r66567 fix).

**4 concurrent deletes** (user's scenario — 4 VMs destroyed simultaneously):

| VM | Time | CFS lock retries | Result |
|----|------|-------------------|--------|
| 203 | 2.3 s | 0 | OK |
| 201 | 4.3 s | 2 | OK |
| 204 | 6.3 s | 4 | OK |
| 202 | 8.3 s | 6 | OK |

All 4 succeeded. Zero orphaned volumes.

**8 concurrent deletes** (stress test):

5 of 8 succeeded within the 10 s CFS lock window. Each volume holds the lock for ~2 s,
so the theoretical maximum is ~5 concurrent deletes per 10 s window.

**Before vs After:**

| Metric | Before | After |
|--------|--------|-------|
| `free_image` lock hold time | ~22 s | ~2 s |
| Max concurrent deletes (10 s CFS) | 1 | ~5 |
| 4 concurrent VM destroy | 2 succeed, 2 orphan | All 4 succeed |

---

## Fix 16 — CFS Lock Acquisition Timeout Too Short for Concurrent Operations

**File:** `OpenEJovianDSSPlugin.pm`
**Symptom:** With 6+ concurrent VM deletions on the same JovianDSS storage, later
operations time out waiting for the CFS lock even though each `free_image` only holds
the lock for ~2 s (after Fix 15).

**Root cause:** `PVE::Storage::vdisk_free` calls `$plugin->cluster_lock_storage()` with
`undef` as timeout. Inside `PVE::Cluster::$cfs_lock`, `$timeout = 10 if !$timeout` sets
the default to 10 s. With 8 concurrent 2 s operations serializing on the lock, the last
one waits ~16 s and exceeds the 10 s limit.

**Fix:** Override `cluster_lock_storage` in `OpenEJovianDSSPlugin.pm` to dynamically
scale the CFS lock acquisition timeout based on the number of running storage workers.
The timeout adjusts to `10 + (N × 5)` seconds where N is the number of concurrent
`imgdel`/`qmrestore`/etc. workers targeting this storage (read from
`/var/log/pve/tasks/active`), capped at 120 s.

The per-worker multiplier of 5 s accounts for volumes with published snapshots, where
each published snapshot adds ~7 s of multipath unstage time during `volume_deactivate`.

The 120 s hard cap prevents runaway timeouts in pathological situations (e.g., hundreds
of queued tasks). At 120 s, the formula covers up to 22 concurrent workers. Beyond that
threshold, the system is likely overloaded and further extending timeouts would only
cause cascading delays; it is better to let excess tasks fail-fast and retry.

This means:
- 1 concurrent operation: 15 s timeout (barely over default — fast failure when stuck)
- 4 concurrent: 30 s (covers 4 × ~2-5 s serialized deletes)
- 8 concurrent: 50 s (covers 8 × ~2-5 s, with room for snapshot overhead)
- 22+ concurrent: 120 s (hard cap)
- Solo operations with no contention: 10 s (same as Proxmox default)

```perl
sub cluster_lock_storage {
    my ($class, $storeid, $shared, $timeout, $func, @param) = @_;
    if (!$timeout) {
        # Count running workers for this storage from PVE active tasks.
        # Running tasks: "UPID:…:storeid:… 0" (2 fields)
        # Completed:     "UPID:…:storeid:… 1 ts OK" (4+ fields)
        my $running = 0;
        if (open(my $fh, '<', '/var/log/pve/tasks/active')) {
            while (my $line = <$fh>) {
                next unless $line =~ /\Q$storeid\E/;
                my @f = split(/\s+/, $line);
                $running++ if @f <= 2;
            }
            close($fh);
        }
        # 10 s base + 5 s per concurrent worker, capped at 120 s.
        # Each delete holds the lock for ~2-9 s with zero snapshots;
        # published snapshots add ~7 s each (multipath unstage).
        $timeout = 10 + ($running * 5);
        $timeout = 120 if $timeout > 120;
    }
    return $class->SUPER::cluster_lock_storage(
        $storeid, $shared, $timeout, $func, @param);
}
```

### Test results

**8 concurrent deletes** (stress test, pve1, Pool-0):

| VM | Time | Result |
|----|------|--------|
| 242 | 2.4 s | OK |
| 246 | 4.4 s | OK |
| 244 | 6.5 s | OK |
| 247 | 8.4 s | OK |
| 245 | 10.4 s | OK |
| 241 | 12.4 s | OK |
| 243 | 14.4 s | OK |
| 240 | 16.4 s | OK |

All 8 succeeded. Dynamic timeout was `10 + (8 × 5) = 50 s`, sufficient for the 16.4 s
max wait. Zero orphaned volumes.

**Combined effect of Fixes 15 + 16:**

| Metric | Before | After Fix 15 | After Fix 15+16 |
|--------|--------|-------------|-----------------|
| `free_image` lock hold time | ~22 s | ~2 s | ~2 s |
| CFS lock acquisition timeout | 10 s (fixed) | 10 s (fixed) | 10 + N×5 s (dynamic, max 120 s) |
| Max concurrent deletes | 1 | ~5 | scales with N (up to ~22 before cap) |
| 8 concurrent VM destroy | 1-2 succeed | 5 succeed | All 8 succeed |
