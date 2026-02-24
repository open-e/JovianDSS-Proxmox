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
doesn't exist it would get a `JDSS resource ... DNE.` error and silently return `undef`.

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
if ($clean_error =~ /^JDSS resource volume .+ DNE\.$/) {

# After (correct):
if ($clean_error =~ /^JDSS resource .+ DNE\.$/) {
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

This causes jdssc to log an error (`JDSS resource volume <name> DNE.`) and exit 1. The Perl
layer (`joviandss_cmd`) detects the non-zero exit and calls `die`, which propagates through
the `fork_worker` child, preventing the "Removed volume" message from being printed.

**Note on exit code:** `pvesm free` submits deletion as a background worker via `fork_worker`
(scalar context — exit code discarded) and `run_cli_handler` always calls `exit 0`. This
means the shell exit code of `pvesm free` remains 0 even when the volume was not found.
This is a Proxmox architectural limitation that cannot be fixed without patching Proxmox
source files. The important user-visible behavior — suppressing the false "Removed volume"
message and displaying an error — is correct.

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

| Test | Result |
|------|--------|
| `pvesm free jdss-Pool-1:vm-357-0` (target-group name, not a disk) | ✅ Shows error, no "Removed volume" |
| `pvesm free jdss-Pool-1:vm-357-111` (completely non-existent volume) | ✅ Shows error, no "Removed volume" |

Previously both commands printed `Removed volume 'jdss-Pool-1:vm-357-0'` with exit 0.
Now they print `JDSS resource volume vm-357-0 DNE.` (no "Removed volume").
Exit code remains 0 due to Proxmox `fork_worker` architecture (documented in fix above).
