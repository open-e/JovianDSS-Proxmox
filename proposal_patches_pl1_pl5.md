# Proposed Patches to JovianDSS-Proxmox Plugin — PL-1 through PL-5

**Date:** 2026-04-30
**Prepared by:** Open-E QA Team (marek.dikta@open-e.com)
**Plugin version tested:** v0.11.3 → v0.11.4
**Test environment:** 2-node Proxmox VE cluster (pve1: 10.15.0.141, pve2: 10.15.0.151),
Ubuntu VMs 120–129 on `jdss-Pool-0`, Windows VMs 320–329 on `jdss-Pool-1`

---

## Test List

| Test ID | Description |
|---------|-------------|
| `setup_create_vms_seq` | Clone many VMs from one VM (sequential) |
| `setup_create_vms_par` | Clone many VMs from one VM (parallel) |
| `start_seq` | Start VMs (sequential) |
| `start_par` | Start VMs (parallel) |
| `stop_seq` | Force stop VMs (sequential) |
| `stop_par` | Force stop VMs (parallel) |
| `shutdown_seq` | Graceful ACPI shutdown (sequential) |
| `shutdown_par` | Graceful ACPI shutdown (parallel) |
| `reboot_seq` | Reboot VMs (sequential) |
| `reboot_par` | Reboot VMs (parallel) |
| `reset_seq` | Hard reset VMs (sequential) |
| `reset_par` | Hard reset VMs (parallel) |
| `pause_seq` | Suspend VMs to RAM (sequential) |
| `pause_par` | Suspend VMs to RAM (parallel) |
| `resume_seq` | Resume VMs from suspend (sequential) |
| `resume_par` | Resume VMs from suspend (parallel) |
| `hibernate_seq` | Suspend VMs to disk (sequential) |
| `hibernate_par` | Suspend VMs to disk (parallel) |
| `ha_add_seq` | Add VMs to HA cluster (sequential) |
| `ha_add_par` | Add VMs to HA cluster (parallel) |
| `disk_add_seq` | Add iSCSI disk online (sequential) |
| `disk_add_par` | Add iSCSI disk online (parallel) |
| `disk_move_to_local_seq` | Move disk: JovianDSS → local LVM (sequential) |
| `disk_move_to_local_par` | Move disk: JovianDSS → local LVM (parallel) |
| `disk_move_to_jdss_seq` | Move disk: local LVM → JovianDSS (sequential) |
| `disk_move_to_jdss_par` | Move disk: local LVM → JovianDSS (parallel) |
| `disk_resize_seq` | Resize disk online (sequential) |
| `disk_resize_par` | Resize disk online (parallel) |
| `disk_delete_via_unused_seq` | Delete disk via unused entry, 2-step (sequential) |
| `disk_delete_via_unused_par` | Delete disk via unused entry, 2-step (parallel) |
| `disk_delete_force_seq` | Delete disk directly from storage (sequential) |
| `disk_delete_force_par` | Delete disk directly from storage (parallel) |
| `snapshots_create_no_ram_seq` | Create snapshots without RAM state (sequential) |
| `snapshots_create_no_ram_par` | Create snapshots without RAM state (parallel) |
| `snapshots_create_ram_seq` | Create snapshots with RAM state (sequential) |
| `snapshots_create_ram_par` | Create snapshots with RAM state (parallel) |
| `snapshot_clone_s1_seq` | Clone VM from non-RAM snapshot (sequential) |
| `snapshot_clone_s1_par` | Clone VM from non-RAM snapshot (parallel) |
| `snapshot_clone_r1_seq` | Clone VM from RAM snapshot (sequential) |
| `snapshot_clone_r1_par` | Clone VM from RAM snapshot (parallel) |
| `snapshot_clones_start_seq` | Start snapshot clone VMs (sequential) |
| `snapshot_clones_start_par` | Start snapshot clone VMs (parallel) |
| `snapshot_clones_delete_seq` | Delete snapshot clone VMs (sequential) |
| `snapshot_clones_delete_par` | Delete snapshot clone VMs (parallel) |
| `snapshot_rollback_to_last_seq` | Rollback VM to latest snapshot — RAM (sequential) |
| `snapshot_rollback_to_last_par` | Rollback VM to latest snapshot — RAM (parallel) |
| `snapshot_rollback_to_last_seq` | Rollback VM to latest snapshot — Non-RAM (sequential) |
| `snapshot_rollback_to_last_par` | Rollback VM to latest snapshot — Non-RAM (parallel) |
| `snapshots_delete_ram_seq` | Delete RAM snapshots (sequential) |
| `snapshots_delete_ram_par` | Delete RAM snapshots (parallel) |
| `snapshots_delete_no_ram_seq` | Delete non-RAM snapshots (sequential) |
| `snapshots_delete_no_ram_par` | Delete non-RAM snapshots (parallel) |
| `backup_seq` | Backup VMs to storage (sequential) |
| `backup_par` | Backup VMs to storage (parallel) |
| `restore_seq` | Restore VMs from backup (sequential) |
| `restore_par` | Restore VMs from backup (parallel) |
| `restored_vms_delete_seq` | Delete restored VMs (sequential) |
| `restored_vms_delete_par` | Delete restored VMs (parallel) |
| `backup_files_delete_seq` | Delete backup files from storage (sequential) |
| `backup_files_delete_par` | Delete backup files from storage (parallel) |
| `template_create_seq` | Convert VM to Proxmox template (sequential) |
| `template_create_par` | Convert VM to Proxmox template (parallel) |
| `linked_clone_create_seq` | Create linked clones from template (sequential) |
| `linked_clone_create_par` | Create linked clones from template (parallel) |
| `linked_clone_start_seq` | Start linked clone VMs (sequential) |
| `linked_clone_start_par` | Start linked clone VMs (parallel) |
| `linked_clone_delete_seq` | Delete linked clone VMs (sequential) |
| `linked_clone_delete_par` | Delete linked clone VMs (parallel) |
| `full_clone_from_tpl_create_seq` | Create full clone from template (sequential) |
| `full_clone_from_tpl_create_par` | Create full clone from template (parallel) |
| `full_clone_from_tpl_start_seq` | Start full clone VM (sequential) |
| `full_clone_from_tpl_start_par` | Start full clone VM (parallel) |
| `full_clone_from_tpl_delete_seq` | Delete full clone VM (sequential) |
| `full_clone_from_tpl_delete_par` | Delete full clone VM (parallel) |
| `multi_clone_from_tpl_create_seq` | Create multiple full clones from template (sequential) |
| `multi_clone_from_tpl_create_par` | Create multiple full clones from template (parallel) |
| `multi_clone_from_tpl_start_seq` | Start multiple template clones (sequential) |
| `multi_clone_from_tpl_start_par` | Start multiple template clones (parallel) |
| `multi_clone_from_tpl_delete_seq` | Delete multiple template clones (sequential) |
| `multi_clone_from_tpl_delete_par` | Delete multiple template clones (parallel) |
| `migration_ubuntu_to_pve2_seq` | Live migrate Ubuntu: pve1 → pve2 (sequential) |
| `migration_ubuntu_to_pve2_par` | Live migrate Ubuntu: pve1 → pve2 (parallel) |
| `migration_ubuntu_to_pve1_seq` | Live migrate Ubuntu: pve2 → pve1 (sequential) |
| `migration_ubuntu_to_pve1_par` | Live migrate Ubuntu: pve2 → pve1 (parallel) |
| `migration_windows_to_pve1_seq` | Live migrate Windows: pve2 → pve1 (sequential) |
| `migration_windows_to_pve1_par` | Live migrate Windows: pve2 → pve1 (parallel) |
| `migration_windows_to_pve2_seq` | Live migrate Windows: pve1 → pve2 (sequential) |
| `migration_windows_to_pve2_par` | Live migrate Windows: pve1 → pve2 (parallel) |
| `migration_all_to_pve1_seq` | Live migrate all VMs to pve1 (sequential) |
| `migration_all_to_pve1_par` | Live migrate all VMs to pve1 (parallel) |
| `migration_all_to_pve2_seq` | Live migrate all VMs to pve2 (sequential) |
| `migration_all_to_pve2_par` | Live migrate all VMs to pve2 (parallel) |
| `delete_seq` | Destroy all test VMs (sequential) |
| `delete_par` | Destroy all test VMs (parallel) |
| `node_operations_seq` | Restart / power off cluster node |

---

## Overview

During functional testing of the JovianDSS-Proxmox plugin we identified five bugs in
`OpenEJovianDSSPlugin.pm` and `jdssc/jovian_common/driver.py`. All five were reproduced
reliably and have been patched in our test environment. This document describes each bug
in detail — the triggering test, the observed failure, the root cause, and the proposed
code change with before/after diffs.

**Note on PL-1:** This patch was independently developed by us during testing of v0.11.3,
and we later found that v0.11.4 already contains an equivalent fix (10-retry loop with
random back-off in `_clone_image`). We include it here for completeness and as context
for PL-2 through PL-5, which address related problems in neighbouring code paths that
v0.11.4 does not yet fix.

---

## Root Cause Context: JovianDSS IDX Eventual Consistency

PL-1, PL-2, and PL-5 all share a common root cause that must be understood first.

The JovianDSS REST API exposes volume listing through an indexed endpoint:

```
GET /api/v3/pools/{pool}/volumes?page=0
```

This endpoint is served from an in-memory index (IDX) that has an **eventual-consistency
window of approximately 530–1150 ms** after a new volume is created. If a caller queries
this endpoint within that window, the newly created volume will not appear in the response.

Both `find_free_diskname` (in `OpenEJovianDSSPlugin.pm`) and `getfreename`
(in `jdssc`) query this endpoint to determine which disk name (e.g. `vm-120-disk-N`)
is free to use. If the IDX is stale, the function may return a name that was already
assigned to a volume created moments ago.

This causes `"already exists"` errors in code paths that create volumes sequentially
or concurrently for the same VM (e.g. when cloning a multi-disk VM, or converting
multiple VMs to templates in parallel).

---

## PL-1: `_clone_image` — Retry on "already exists" (already in v0.11.4)

### Triggering test

`linked_clones_from_tpl_create_par` — parallel linked clone creation from a Windows
template (VM 321, 3 disks: scsi0, tpmstate0, efidisk0). Ubuntu templates (1 disk) did
not exhibit this failure.

### Observed failure

When cloning a Windows VM with 3 disks, Proxmox calls `_clone_image` once per disk
in quick succession. Each call queries `find_free_diskname` → `GET /volumes?page=0`.
Because the IDX stale window is 530–1150 ms, two consecutive calls (e.g. for scsi0 and
tpmstate0) can receive the same name — for example both get `vm-5821-disk-0`.

The second `joviandss_cmd clone` then fails with:

```
JDSSVolumeExistsException: JDSS resource volume v_vm-5821-disk-0 already exists.
```

With no retry logic, this exception propagates to `qm clone`, which fails entirely.
The first disk was successfully cloned but Proxmox does not clean it up, leaving an
orphaned volume on JovianDSS.

### Fix already in v0.11.4

v0.11.4 adds a 10-attempt retry loop with random back-off and a fresh `find_free_diskname`
query on each attempt:

```perl
# v0.11.4 — _clone_image (lines 663–721)

    my $max_retries = 10;
    for my $attempt ( 1 .. $max_retries ) {
        if ( $attempt > 1 ) {
            $clone_name = $class->find_free_diskname( $storeid, $scfg, $vmid, $fmt );
            debugmsg( $ctx, "warn",
                "clone_image retry ${attempt}/${max_retries}: retrying with new "
              . "candidate name ${clone_name}\n" );
        }

        my $err;
        eval {
            if ($snap) {
                joviandss_cmd( $ctx,
                    [ "pool", $pool, "volume", $volname, "clone",
                      "--size", $size, "--snapshot", $snap, "-n", $clone_name ],
                    50, 3 );
            }
            else {
                joviandss_cmd( $ctx,
                    [ "pool", $pool, "volume", $volname, "clone",
                      "--size", $size, "-n", $clone_name ],
                    50, 3 );
            }
        };
        $err = $@;
        last unless $err;
        if ( $err =~ /already exists/i && $attempt < $max_retries ) {
            my $delay = 1 + rand(3);
            debugmsg( $ctx, "warn",
                "clone_image: volume ${clone_name} already exists "
              . "(JovianDSS stale list under load), "
              . sprintf( "retrying in %.1fs (attempt %d/%d)\n",
                         $delay, $attempt, $max_retries - 1 ) );
            select( undef, undef, undef, $delay );
            next;
        }
        die $err;
    }
    return $clone_name;
```

This is equivalent to the patch we applied during v0.11.3 testing (our version used
5 retries; v0.11.4 uses 10). **No further action is needed here.** We describe it
because PL-2 addresses the same IDX staleness problem in `_create_base`, which v0.11.4
does not yet fix.

---

## PL-2: `_create_base` — Retry on "already exists" in template conversion

### Triggering test

`convert_vms_to_templates_par` — parallel conversion of multiple VMs to templates
(`qm template`). With 2 or more VMs being converted simultaneously, one of them
consistently fails.

### Observed failure

`_create_base` is called during `qm template` to rename the VM's disk volume from
`vm-{vmid}-disk-0` to `base-{vmid}-disk-0`. The target name is determined by calling
`joviandss_cmd getfreename --prefix base-{vmid}-disk-`.

When two VMs are converted in parallel, both processes call `getfreename` within the
IDX stale window. Because neither conversion has finished yet, both processes receive
the same candidate name — for example both get `base-120-disk-0`. The first rename
succeeds; the second one fails with:

```
JDSSVolumeExistsException: JDSS resource volume v_base-120-disk-0 already exists.
```

Since v0.11.4 has no retry in `_create_base`, this exception propagates and the second
`qm template` call fails entirely. The VM's disk is left with its original name
(`vm-{vmid}-disk-0`) while the Proxmox config has already been updated to expect
`base-{vmid}-disk-0`, resulting in a permanently inconsistent state.

### Code before the fix (v0.11.4, `_create_base`, lines ~569–582)

```perl
# /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
# function _create_base (v0.11.4, before PL-2)

    _deactivate_volume( $class, $ctx, $volname, undef, undef );

    my $pool = get_pool($ctx);

    my $newnameprefix = join '', 'base-', $vmid, '-disk-';

    my $newname = joviandss_cmd( $ctx,
        [ "pool", $pool, "volumes", "getfreename", "--prefix", $newnameprefix ]
    );
    $newname = clean_word($newname);

    _rename_volume( $class, $ctx, $volname, $vmid, $newname );   # ← no retry

    return $newname;
```

### Code after the fix (lines 569–601)

```perl
# /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
# function _create_base (after PL-2)

    _deactivate_volume( $class, $ctx, $volname, undef, undef );   # line 569

    my $pool = get_pool($ctx);                                     # line 571

    my $newnameprefix = join '', 'base-', $vmid, '-disk-';        # line 573

    my $max_retries = 5;                                           # line 575
    my $newname;                                                   # line 576
    for my $attempt ( 1 .. $max_retries ) {                        # line 577
        $newname = joviandss_cmd( $ctx,                            # line 578
            [ "pool", $pool, "volumes", "getfreename",
              "--prefix", $newnameprefix ]
        );
        $newname = clean_word($newname);                           # line 581

        my $err;                                                   # line 583
        eval {
            _rename_volume( $class, $ctx, $volname, $vmid, $newname );
        };
        $err = $@;
        last unless $err;
        if ( $err =~ /already exists/i && $attempt < $max_retries ) {
            my $delay = 1 + rand(3);
            debugmsg( $ctx, "warn",
                "create_base: volume ${newname} already exists "
              . "(JovianDSS stale list under load), "
              . sprintf( "retrying in %.1fs (attempt %d/%d)\n",
                    $delay, $attempt, $max_retries - 1 ) );
            select( undef, undef, undef, $delay );
            next;
        }
        die $err;                                                   # line 599
    }                                                              # line 600
    return $newname;                                               # line 601
```

### Why this fix is correct

The logic is identical to what v0.11.4 already uses in `_clone_image` (PL-1). On each
retry:

1. A fresh `getfreename` query is issued, so the candidate name reflects the current
   (post-IDX-refresh) state.
2. A random 1–4 second delay is added before the retry, giving the IDX time to become
   consistent.
3. Only `"already exists"` errors are retried; all other errors are re-thrown immediately.

The `_deactivate_volume` call before the loop runs only once (not per retry), which is
correct — it deactivates the original volume name, and that name does not change across
retries.

**Log evidence (Pool-0, `convert_vms_to_templates_par`, session 16):**

```
# /var/log/joviandss/jdss-Pool-0.log

17:24:07.204  WARN [ded78220] Unable to identify lun record for volume vm-120-disk-0
17:24:07.876  INFO [ded78220] update volume vm-120-disk-0 → 'v_base-120-disk-0'

17:24:07.399  WARN [f7da8bba] Unable to identify lun record for volume vm-121-disk-0
17:24:08.403  INFO [f7da8bba] update volume vm-121-disk-0 → 'v_base-121-disk-0'
```

Both conversions completed in parallel (distinct request IDs `ded78220` and `f7da8bba`),
with no "already exists" errors and no retries needed in this run — because the
approximately 400 ms gap between getfreename calls was enough for the IDX to refresh.
The retry logic is a safety net for cases where both calls fall within the stale window.

---

## PL-3: `_rename_volume` — Skip `volume_unpublish` when LUN record is already gone

### Triggering test

`convert_vms_to_templates_seq` — sequential VM-to-template conversion when the VM was
already **stopped** before `qm template` was called. This is the normal, expected use
case: a user stops their VM and then converts it to a template.

### Observed failure

When `qm template` is called on a stopped VM, the call stack is:

```
qm template
  └─ _create_base
       ├─ _deactivate_volume(volname)       ← step A: removes LUN record
       └─ _rename_volume(volname, newname)   ← step B
              ├─ volume_deactivate(...)      ← step B1
              └─ volume_unpublish(...)       ← step B2: FAILS
```

**Step A — `_deactivate_volume`:** This function queries `lun_record_local_get_info_list`
to retrieve the local LUN record for the volume. For a stopped VM, no iSCSI session is
active and no LUN record exists. The function logs:

```
WARN: Unable to identify lun record for volume vm-120-disk-0
```

and returns early without calling `scstadmin`. The LUN record is now absent
(it was already absent).

**Step B2 — `volume_unpublish`:** Immediately afterward, `_rename_volume` calls
`volume_unpublish` unconditionally, without checking whether a LUN record ever existed.
`volume_unpublish` calls `jdssc targets delete`, which internally calls
`scstadmin -rem_lun`. Because the LUN was never registered in SCST (the VM was stopped),
`scstadmin` returns:

```
FATAL: No such LUN exists.
```

The JovianDSS REST server receives exit code 1 and returns **HTTP 500**. The `jdssc`
client on the Proxmox side enters a **retry loop: 50 attempts × 3 seconds ≈ 2.5
minutes** per disk. All 50 attempts fail identically. After the loop exhausts its
retries, `joviandss_cmd` raises a timeout exception, and `qm template` fails.

This bug also occurs in PL-2's retry scenario: because `_create_base` calls
`_deactivate_volume` before the retry loop, `_rename_volume` will always encounter
a missing LUN record on every attempt — including the very first one.

### Code before the fix (v0.11.4, `_rename_volume`, lines ~502–505)

```perl
# /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
# function _rename_volume (v0.11.4, before PL-3)

    volume_deactivate( $ctx,
        $original_vmid, $original_volname, undef, undef );
    volume_unpublish( $ctx,                              # ← unconditional call
        $original_vmid, $original_volname, undef, undef );
```

### Code after the fix (lines 502–516)

```perl
# /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
# function _rename_volume (after PL-3)

    my $lunrecs = lun_record_local_get_info_list( $ctx, $original_volname, undef );  # line 502
    my $had_lun_record = scalar(@$lunrecs) > 0;                                       # line 503

    volume_deactivate( $ctx,                                                           # line 505
        $original_vmid, $original_volname, undef, undef );

    # Only unpublish if a lun record existed before deactivate.
    # If the record is already gone (e.g. prior _deactivate_volume call from
    # _create_base), volume_unpublish hits stale SCST state: scstadmin returns
    # "No such LUN exists" but the REST API returns HTTP 500, causing jdssc to
    # retry in a loop until joviandss_cmd times out.
    if ( $had_lun_record ) {                                                           # line 513
        volume_unpublish( $ctx,
            $original_vmid, $original_volname, undef, undef );
    }                                                                                  # line 516
```

### Why this fix is correct

`volume_unpublish` should only be called when there is an actual iSCSI LUN record to
unpublish. The guard checks `lun_record_local_get_info_list` — the same source of
truth that `_deactivate_volume` uses — before the `volume_deactivate` call, so the
`$had_lun_record` flag reflects the state as seen by this node before any deactivation
takes place.

If no LUN record exists (stopped VM, or already deactivated by the preceding
`_deactivate_volume` call in `_create_base`), calling `volume_unpublish` would attempt
to remove a LUN from SCST that this node never registered. Skipping the call is both
correct (desired state is already achieved) and necessary (the call would trigger
the jdssc retry loop described above).

The `volume_deactivate` call (step B1) remains unconditional. It is idempotent — if
the LUN is not in SCST it silently succeeds — so it is safe to call regardless.

**Log evidence (Pool-0, `convert_vms_to_templates_par`, session 16):**

```
# /var/log/joviandss/jdss-Pool-0.log

17:24:07.723  WARN [ded78220] Unable to identify lun record for volume vm-120-disk-0
              ← lun_record_local_get_info_list: 0 records → had_lun_record = false
              → volume_unpublish SKIPPED → no HTTP 500, no retry loop
17:24:07.876  INFO [ded78220] update volume vm-120-disk-0 → 'v_base-120-disk-0'
              ← rename proceeded immediately (672ms total)
```

Notably, there is no `delete iSCSI target` log entry between the WARN and the INFO
lines — this confirms that `volume_unpublish` was not called. The iSCSI target
remains registered (to be cleaned up on `qm destroy`), which is the correct
behavior.

---

## PL-4: `_rename_volume` — Extended timeout for the rename command (40s → 90s)

### Triggering test

`convert_vms_to_templates_seq` — sequential VM-to-template conversion under load
(CPU load average 47 on the JovianDSS node during a stress test run).

### Observed failure

The `joviandss_cmd` call that performs the actual volume rename inside `_rename_volume`:

```perl
joviandss_cmd( $ctx,
    [ "pool", $pool, "volume", $original_volname, "rename", $new_volname ]
);
```

uses the default timeout of 40 seconds. Under high CPU load on the JovianDSS node,
the REST API for `rename` took **49 seconds** to respond — exceeding the timeout.

The plugin raised a timeout exception and `qm template` failed. However, examining
the JovianDSS side revealed that **the rename had actually completed successfully**:
`zfs list` showed `v_base-120-disk-0` already existed. This produced an inconsistent
state: Proxmox config still referred to `vm-120-disk-0`, while JovianDSS had already
renamed it to `base-120-disk-0`.

The root cause of the slowness is on the JovianDSS side: when the volume being
renamed has an active iSCSI target registered in SCST, the REST API must update
the SCST configuration (rename the target) in addition to performing the ZFS
dataset rename. The combined operation can significantly exceed 40 seconds under
load. This is a bug in the JovianDSS REST API (or jdssc) that we plan to report
separately; the patch below is a client-side workaround.

### Code before the fix (v0.11.4, `_rename_volume`, lines ~517–519)

```perl
# /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
# function _rename_volume (v0.11.4, before PL-4)

    joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $original_volname, "rename", $new_volname ]
    );    # ← default timeout 40s, default retries (non-zero)
```

### Code after the fix (lines 518–525)

```perl
# /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm
# function _rename_volume (after PL-4)

    # Use an extended timeout (90s) for rename: when the volume's iSCSI target
    # still exists in JovianDSS SCST, the REST API must update SCST configuration
    # along with the ZFS rename.  This can take significantly longer than the
    # default 40s.  retries=0 avoids renaming an already-renamed volume on retry.
    joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $original_volname, "rename", $new_volname ],
        90, 0    # timeout=90s, retries=0
    );
```

### Why retries=0 is essential

The `joviandss_cmd` `retries` parameter controls how many additional attempts are
made after a timeout. Setting `retries=0` is intentional and critical here.

If a retry were attempted after a timeout, the plugin would issue a second `rename`
command for the same `$original_volname`. But JovianDSS may have already completed
the rename during the first attempt (as observed in the test: rename took 49s, timeout
was 40s, but JovianDSS finished successfully). The retry would try to rename a volume
that no longer exists under its original name, resulting in a "not found" error — or
worse, if by coincidence a new volume was created with the same name in the meantime,
renaming the wrong object.

### Why 90 seconds

Observed maximum rename duration under CPU load 47: **49 seconds**. The 90-second
timeout provides an approximately 1.8× safety margin over the worst case we observed.
The proper long-term fix is to make the JovianDSS REST API respond immediately (with
the rename proceeding asynchronously), or to require the caller to deactivate the
target before renaming — both of which require changes on the JovianDSS side.

---

## PL-5: `_clone_object` — Pre-check before snapshot creation + cleanup in exception handler

### Triggering test

`linked_clones_from_tpl_create_par` — parallel creation of multiple linked clones
from a Windows template (VM 321, 3 disks: scsi0, tpmstate0, efidisk0). After running
this test and subsequently destroying the clones, **orphaned ZFS snapshots remained
permanently on the template volume** on JovianDSS Pool-1.

Verified directly on the JovianDSS node:

```
$ zfs list -t snapshot | grep base-321-disk-0
Pool-1/v_base-321-disk-0@v_vm-5821-disk-0    128K  —
Pool-1/v_base-321-disk-0@v_vm-6821-disk-0    128K  —
```

These snapshots are not referenced by any active clone. `qm destroy` does not remove
them because they were never registered as the origin of any ZVOL that Proxmox tracks.

### Root cause (detailed)

`_clone_object` in `jdssc/jovian_common/driver.py` creates linked clones as follows:

1. Pick candidate clone name `cvname` via `getfreename` (queries stale IDX).
2. Create a ZFS snapshot on the source volume: `create_snapshot(ovname, cvname)`.
3. Create a ZVOL from that snapshot: `create_volume_from_snapshot(cvname)`.

When cloning a Windows VM with 3 disks, steps 1–3 are executed by three separate
`jdssc` processes, invoked in quick succession from the Perl plugin. The second process
(for `scsi0`, which starts ~630 ms after the first) queries `getfreename` while the IDX
is still stale — it does not yet see the ZVOL created by the first process, and returns
the same candidate name (e.g. `vm-5821-disk-0`).

The second process now creates a **snapshot** on the source (base) volume using that
already-taken name. It then calls `create_volume_from_snapshot`, which fails with
`JDSSVolumeExistsException` because the ZVOL already exists. The Perl retry logic
assigns a new name (`vm-5821-disk-1`) and the clone succeeds.

However, the snapshot that was created in step 2 — `base-321-disk-0@v_vm-5821-disk-0`
— is **never cleaned up**. It is not the origin of any active ZVOL (the successful
clone uses `v_vm-5821-disk-1`), so `qm destroy` leaves it behind. The snapshot
accumulates with each `qm clone` call.

**Observed in JovianDSS logs (Pool-1, session 8, 2026-04-27 13:57):**

```
# /var/log/joviandss/jdss-Pool-1.log (before PL-5)

13:57:23.785  INFO  create volume vm-5821-disk-0 from snapshot vm-5821-disk-0
              ← efidisk0 clone OK (jdssc process #1)

13:57:24.938  INFO  create snapshot vm-5821-disk-0 for volume base-321-disk-0
              ← scsi0, jdssc process #2: IDX still stale at T+1.153s
              ← snapshot created BEFORE the volume existence check ← LEAK

13:57:25.103  ERROR: JDSS resource volume v_vm-5821-disk-0 already exists.
              ← create_volume_from_snapshot fails

13:57:26.991  INFO  create snapshot vm-5821-disk-1 for volume base-321-disk-0
              ← Perl retry with new name: succeeds
```

The snapshot `base-321-disk-0@v_vm-5821-disk-0` (line 2) is never followed by a
matching `delete snapshot` line.

### Fix 1 — Pre-check with direct volume lookup before `create_snapshot`

The fix adds a direct `GET /volumes/{cvname}` lookup before calling `create_snapshot`.
Unlike `GET /volumes?page=0`, a direct lookup by name is not served from the stale IDX
— it queries the volume's existence authoritatively and returns a 404 if it does not
exist.

**Code before the fix (v0.11.4, `_clone_object`, lines ~572–574):**

```python
# /usr/lib/python3/dist-packages/jdssc/jovian_common/driver.py
# function _clone_object (v0.11.4, before PL-5)

        if create_snapshot:
            try:
                self.ra.create_snapshot(ovname, sname)    # ← snapshot created without
                                                          #   checking cvname existence
```

**Code after Fix 1 (lines 572–579):**

```python
# /usr/lib/python3/dist-packages/jdssc/jovian_common/driver.py
# function _clone_object (after PL-5, Fix 1)

        if create_snapshot:                                           # line 572
            try:
                self.ra.get_lun(cvname)                              # line 574
                # Direct GET /volumes/<cvname> — authoritative, not through stale IDX.
                # If the volume exists, get_lun returns its data → raise below.
                raise jexc.JDSSVolumeExistsException(cvname)         # line 575
            except jexc.JDSSResourceNotFoundException:               # line 576
                pass    # volume does not exist → OK, proceed to create_snapshot
            try:                                                      # line 578
                self.ra.create_snapshot(ovname, sname)               # line 579
```

If `cvname` already exists (detected authoritatively), `JDSSVolumeExistsException` is
raised immediately — **before any snapshot is created** — so there is nothing to clean
up. The Perl retry logic receives the exception, picks a new name, and calls
`_clone_object` again cleanly.

### Fix 2 — Cleanup of leaked snapshot in the `JDSSVolumeExistsException` handler

Fix 1 eliminates the leak in the common case. Fix 2 addresses the narrow
time-of-check-to-time-of-use (TOCTOU) window: if two `jdssc` processes pass the
pre-check at exactly the same time, the snapshot may be created by one process just
before the other calls `create_volume_from_snapshot`. In this scenario the exception
handler now removes the snapshot before re-raising the exception.

**Code before the fix (v0.11.4, `_clone_object`, lines ~603–607):**

```python
# /usr/lib/python3/dist-packages/jdssc/jovian_common/driver.py
# function _clone_object (v0.11.4, before PL-5)

        except jexc.JDSSVolumeExistsException as jerr:
            if jcom.is_snapshot(cvname):
                LOG.debug(("Got Volume Exists exception, but do nothing as "
                           "%s is a snapshot"), cvname)
            else:
                raise jerr    # ← raises without cleaning up snapshot
```

**Code after Fix 2 (lines 603–620):**

```python
# /usr/lib/python3/dist-packages/jdssc/jovian_common/driver.py
# function _clone_object (after PL-5, Fix 2)

        except jexc.JDSSVolumeExistsException as jerr:               # line 603
            if jcom.is_snapshot(cvname):
                LOG.debug(("Got Volume Exists exception, but do nothing as "
                           "%s is a snapshot"), cvname)
            else:
                if create_snapshot:                                    # line 608
                    try:
                        self.ra.delete_snapshot(                       # line 610
                            ovname,
                            cvname,
                            recursively_children=True,
                            force_umount=True)
                    except jexc.JDSSException as jerrd:
                        LOG.warning(
                            "Because of %s physical snapshot %s of volume"
                            " %s have to be removed manually",
                            jerrd, sname, ovname)
                raise jerr                                             # line 620
```

The cleanup uses the same `delete_snapshot` call that the rest of the codebase uses
for removing JovianDSS snapshots. If the cleanup itself fails (e.g. due to a network
error), the exception is logged as a warning and the original `JDSSVolumeExistsException`
is still re-raised — so the Perl retry logic is not disrupted.

### Why these two fixes together eliminate the orphaned snapshot problem

The snapshot leak requires two conditions to occur simultaneously:
1. `getfreename` returns a name that is already taken (IDX stale).
2. `create_snapshot` runs before the conflict is detected.

Fix 1 eliminates condition 2 in nearly all cases by detecting the conflict via direct
lookup before `create_snapshot` is called. Fix 2 handles the residual TOCTOU window
where condition 2 still occurs.

**Log evidence (Pool-1, session 11, after PL-5, 2026-04-27 15:43):**

```
# /var/log/joviandss/jdss-Pool-1.log (after PL-5)

15:43:57.634  ERROR [ded78220] JDSS resource volume v_vm-6821-disk-0 already exists.
              ← pre-check GET /volumes/vm-6821-disk-0 returned 200 OK
              ← JDSSVolumeExistsException raised WITHOUT a preceding 'create snapshot' line
              ← no snapshot was created → no leak
```

The critical observation is that there is **no** `create snapshot vm-6821-disk-0 for
volume base-321-disk-0` line before the ERROR entry. In the pre-patch logs, that line
always appeared. After the patch, it does not.

A subsequent full clone cycle (session 16, 2026-04-27 17:23–18:22) processed over 60
linked, full, and multi-clones on pve1 and pve2 combined, with no orphaned snapshots
found on either Pool-0 or Pool-1.

---

## Summary Table

| ID | File | Function | Problem | Fix | Test |
|----|------|----------|---------|-----|------|
| PL-1 | `OpenEJovianDSSPlugin.pm` | `_clone_image` | No retry on "already exists" → clone fails | 10-retry loop with fresh `find_free_diskname` | Already in v0.11.4 |
| PL-2 | `OpenEJovianDSSPlugin.pm` | `_create_base` | No retry on "already exists" → template conversion fails in parallel | 5-retry loop with fresh `getfreename` | `convert_vms_to_templates_par` |
| PL-3 | `OpenEJovianDSSPlugin.pm` | `_rename_volume` | `volume_unpublish` called when LUN record already gone → HTTP 500 → 2.5-min jdssc retry loop | Guard: check `had_lun_record` before calling `volume_unpublish` | `convert_vms_to_templates_seq` (stopped VM) |
| PL-4 | `OpenEJovianDSSPlugin.pm` | `_rename_volume` | Default 40s timeout too short when SCST target is active → timeout while rename succeeds → inconsistent state | Extended timeout 90s, retries=0 | `convert_vms_to_templates_seq` (under CPU load) |
| PL-5 | `jdssc/jovian_common/driver.py` | `_clone_object` | Snapshot created before checking if target volume exists → leaked snapshot on template | Pre-check `get_lun(cvname)` before `create_snapshot`; cleanup snapshot in exception handler | `linked_clones_from_tpl_create_par` (multi-disk Windows VM) |

