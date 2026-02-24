# JovianDSS Proxmox Plugin — Concurrency & Robustness Fixes

**Date:** 2026-02-23
**Plugin version:** 0.10.15
**Problem:** Concurrent VM restore (`qmrestore`) and VM destroy (`qm destroy --purge`) failures under load.

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

## Test Results

### Fixes 1–9: Concurrent Restore and Destroy

Deployed to Proxmox VE 9.1.1 with JovianDSS storage `jdss1` (Pool-4).

Tests used the Proxmox API path (`pvesh create /nodes/pve/qemu --force 1`, `max_workers=4`),
which routes through the task worker pool and exposes plugin concurrency issues that direct
CLI `qmrestore` does not (see `ISSUES.md` for the distinction).

| Test | Result |
|------|--------|
| `qm destroy --purge` on VM whose backend volume was already deleted | ✅ OK |
| Concurrent API restore of VMs 101, 102, 103, 104 (run 1) | ✅ All 4 OK |
| Sequential `qm destroy --purge` of VMs 101–104 | ✅ All 4 OK |
| Concurrent API restore of VMs 101, 102, 103, 104 (run 2) | ✅ All 4 OK |

Previously, at least 1 of the 4 concurrent API restores would fail on every run.

### Fix 10: Live Migration Hang (multipath semaphore)

Deployed to Proxmox VE 9.1.1, 3-node cluster (pve1/pve2/pve3), JovianDSS storage
`jdss-Pool-1` with `multipath 1`.

| Test | Result |
|------|--------|
| Live migration of VM 305 (Windows, 8 GiB RAM, jdss-Pool-1 multipath) pve1 → pve2 | ✅ OK |

Migration completed in 37 seconds, 2.0 GiB/s average transfer speed, 56 ms downtime.
Previously this migration hung indefinitely after `[pve2] OK` with the multipath semaphore
stuck at value=1.
