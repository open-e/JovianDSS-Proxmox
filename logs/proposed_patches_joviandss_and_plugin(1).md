# Proposed Patches to JovianDSS-Proxmox Plugin — PL-1 through PL-10 (with JD-2, JD-3)

**Date:** 2026-04-30 (PL-1–PL-5, original submission); updated 2026-05-04 (added JD-2, JD-3, PL-6–PL-10)
**Applied dates:** JD-2/JD-3: 2026-04-28 · PL-6/PL-7/PL-8: 2026-04-29 · PL-9/PL-10: 2026-05-04
**Prepared by:** Open-E QA Team
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

During functional testing of the JovianDSS-Proxmox plugin we identified bugs in
`OpenEJovianDSSPlugin.pm`, `OpenEJovianDSS/Common.pm`, and `jdssc/jovian_common/driver.py`.
All were reproduced reliably and have been patched in our test environment. This document
describes each bug in detail — the triggering test, the observed failure, the root cause,
and the proposed code change with before/after diffs.

This document has been extended beyond the original PL-1–PL-5 submission to include:

- **JD-2 and JD-3** — two provisional fixes applied directly to the JovianDSS REST server
  (`scstadmin.py`) on both storage nodes. These were necessary to unblock further testing
  after BUG-005 (SCST race condition). **See the important disclaimer in the JD section.**
- **PL-6 through PL-10** — five additional plugin patches applied after JD-2/JD-3.
  Several of them (PL-6, PL-7, PL-10) are direct consequences of JD-2's global flock
  serializing SCST calls and exposing queue-depth timeout issues.

**Note on PL-1:** This fix was developed by us during testing of v0.11.3 and subsequently
incorporated into v0.11.4. The v0.11.4 implementation is structurally identical to our patch
(same retry loop, same `find_free_diskname` re-query, same error message text) with `max_retries`
increased from 5 to 10. It does not need to be applied manually on systems already running
v0.11.4. We include it here as context for PL-2 through PL-5, which address related problems
in neighbouring code paths that v0.11.4 does not yet fix.

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
| **JD-2** ⚠️ | `scstadmin.py` **(JovianDSS)** | `_scstadmin()`, `_scstadmin_output()` | 17 gunicorn workers call scstadmin concurrently → DB↔SCST state divergence (BUG-005) | Wrap every scstadmin subprocess call with `fcntl.flock(LOCK_EX)` on a global lockfile | `disk_move_local_to_jdss_par` (10 VMs) |
| **JD-3** ⚠️ | `scstadmin.py` **(JovianDSS)** | `release_device()`, `release_device_from_group()` | `scstadmin -rem_lun` exits non-zero when LUN already absent → jdssc 50-retry × 3s ≈ 2.5 min stall per disk | Catch `ScstAdminError("No such LUN exists")` and return `''` (idempotent) | `disk_delete_via_unused_par` with orphaned LUNs |
| PL-6 | `Common.pm` | `volume_stage_iscsi` | 30s block device discovery timeout too short after JD-2 serializes SCST calls — last-queued VM consistently times out | Loop bound 30 → 60 (one-integer change) | `disk_add_scsi1_par` (VM 327) |
| PL-7 | `Common.pm` | `volume_unpublish`, `volume_deactivate` | Default 40s `joviandss_cmd` timeout insufficient when jdssc queue depth grows under JD-2 flock + orphaned staging LUNs | `timeout=120, retries=2` on 4 affected `joviandss_cmd` calls | `migrate_ubuntu_to_pve2_par` (BUG-009) |
| PL-8 | `OpenEJovianDSSPlugin.pm` | `_deactivate_volume` | `volume_unpublish` called unconditionally for vmstate volumes on source node after migration — source never registered the LUN → HTTP 500 → stuck LUN in DB | Guard: check `lun_record_local_get_info_list` before calling `volume_unpublish` (same pattern as PL-3) | Live migration with vmstate snapshots |
| PL-9 | `Common.pm` | `volume_stage_iscsi` | `rescan-scsi-bus.sh -a` called by all N VMs simultaneously → thundering herd → SCSI hosts disappear for sibling processes → "Unable to identify multipath name" (BUG-006) | Replace with targeted per-host sysfs write: read `/sys/class/iscsi_session/sessionN/targetname` → write to `/sys/class/scsi_host/hostH/scan` | `disk_add_scsi1_par` (BUG-006) |
| PL-10 | `OpenEJovianDSSPlugin.pm` | `_volume_resize` | Default 40s timeout too short when JD-2 flock queues resize operations — last VM in parallel wave times out even though JovianDSS completed the resize | `timeout=90, retries=0` | `disk_resize_scsi3_par` (VM 123) |


---

## JovianDSS-Side Provisional Fixes (JD-2, JD-3)

> ⚠️ **IMPORTANT — READ BEFORE ACTING ON THIS SECTION**
>
> The changes described below were applied **directly to JovianDSS production files**
> in our test environment by the QA automation tooling (AI-assisted, not by the
> Open-E development team). They have **not been reviewed, tested, or approved by
> the JovianDSS developers**.
>
> These are **provisional workarounds** intended to unblock further plugin testing.
> The JovianDSS development team should:
> 1. Review whether these changes are correct and safe.
> 2. Either absorb them into the official JovianDSS codebase with proper review,
>    or implement a better solution.
> 3. Never ship these changes as-is without a proper code review and regression
>    test.
>
> **These changes must be applied before PL-6 through PL-10** — several of those
> patches explicitly address side effects that JD-2 introduces.

---

### JD-2 — `scstadmin.py`: Serialize concurrent calls with `fcntl.flock()` (2026-04-28)

#### Triggering test

`disk_move_local_to_jdss_par` — moving 10 VM disks in parallel from local LVM to
JovianDSS storage. Every disk move triggers a call chain that ends in
`scstadmin -add_lun` on the JovianDSS side.

#### Observed failure

When 10 VMs move disks in parallel, up to 10 concurrent `scstadmin` processes
spawn on the JovianDSS node. `scstadmin` is not concurrency-safe: it reads the
current SCST configuration, modifies it, and writes it back. When two processes
read the same state and each writes their version, one overwrites the other's
changes. This produces **DB↔SCST runtime divergence** (BUG-005):

- The JovianDSS REST database records all LUNs as registered.
- SCST kernel runtime only has a subset — the last writer wins.
- The "missing" LUN is not accessible via iSCSI.
- Proxmox side eventually sees: `JDSSCommunicationFailure: None of interfaces responded`
  (after the 50-retry × 3s loop in `rest_proxy.py` exhausts itself — approximately
  16 minutes of stall before the final error).

After the failure, VM 327's `disk-3` existed in the Proxmox config and in the
JovianDSS REST DB, but had no corresponding LUN in SCST runtime — the block device
was inaccessible.

The root cause: the JovianDSS REST server (gunicorn) runs as **17 independent OS
processes**. Each process has its own Python memory space. A `threading.Lock()`
(our first attempt, JD-1) is ineffective because it only serializes calls within
a single process — the other 16 processes ignore it entirely.

`fcntl.flock(LOCK_EX)` is a **kernel-level advisory lock** visible across all
processes on the same host. It serializes `scstadmin` invocations system-wide.

#### File: `/mnt/hda3/prodexec/ps/opene/tools/scstadmin.py`

**Change 1 — add `import fcntl`:**

```python
# Before (line 3)
import os.path
import subprocess

# After
import os.path
import fcntl
import subprocess
```

**Change 2 — add lockfile constant (after line 11):**

```python
# After (new constant, added between __revision__ and ISCSI_DRIVER)
_SCST_LOCKFILE = '/var/run/scstadmin.lock'
```

**Change 3 — wrap `_scstadmin()` with flock (line ~48):**

```python
# Before
    spp = subprocess.Popen(
        cmdlist, shell=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    ret = spp.communicate()

# After
    with open(_SCST_LOCKFILE, 'w') as _lf:
        fcntl.flock(_lf, fcntl.LOCK_EX)
        spp = subprocess.Popen(
            cmdlist, shell=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        ret = spp.communicate()
```

**Change 4 — identical wrap in `_scstadmin_output()` (line ~67):**

```python
# Before
    spp = subprocess.Popen(
        cmdlist, shell=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True
    )
    std_out, _ = spp.communicate()

# After
    with open(_SCST_LOCKFILE, 'w') as _lf:
        fcntl.flock(_lf, fcntl.LOCK_EX)
        spp = subprocess.Popen(
            cmdlist, shell=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )
        std_out, _ = spp.communicate()
```

#### Known side effect — increased queue depth

Serialization works, but it means that under parallel load all SCST operations
queue behind the lock. With 10 VMs performing disk operations simultaneously, the
last VM in the queue must wait for 9 preceding calls to complete before its own
`scstadmin` runs. This **extends the total wall-clock time** for the last VM's
operation and causes timeout failures in several plugin code paths that assume
a ~40s upper bound (addressed by PL-6, PL-7, PL-10).

**Backup files created:** `scstadmin.py.bak.nodeA.20260428_215649`,
`scstadmin.py.bak.nodeB.20260428_215649`

---

### JD-3 — `scstadmin.py`: Make `rem_lun` idempotent on "No such LUN exists" (2026-04-28)

#### Triggering scenario

During `disk_delete_via_unused_par` (and other delete paths), the plugin may clean
up a LUN from SCST runtime during error recovery. When the same LUN is subsequently
deleted via the normal path, `scstadmin -rem_lun N` finds it is already gone from
SCST runtime and prints:

```
Collecting current configuration: done.
-> Making requested changes.
    -> Removing LUN N from driver/target '...': done.
FATAL: Received the following error:
    No such LUN exists.
```

Note: the line `→ Removing LUN N ... done.` confirms the removal succeeded. The
`FATAL` is a **post-removal verification artifact** — scstadmin checks whether the
LUN still exists after removing it, and reports failure when it correctly does not.
All subsequent retry attempts also get `FATAL` because the LUN was already removed
on the first call.

`scstadmin` exits non-zero → `ScstAdminError` raised in `scstadmin.py` → JovianDSS
REST returns **HTTP 500** → `jdssc` on the Proxmox side enters its **50-retry × 3s
loop ≈ 2.5 minutes of stall per disk**.

#### File: `/mnt/hda3/prodexec/ps/opene/tools/scstadmin.py`

**Change 1 — `release_device()` (line ~371):**

```python
# Before
    return _scstadmin(*cmdlist)

# After
    try:
        return _scstadmin(*cmdlist)
    except ScstAdminError as e:
        if 'No such LUN exists' in str(e):
            return ''
        raise
```

**Change 2 — `release_device_from_group()` (line ~391) — identical change:**

```python
# Before
    return _scstadmin(*cmdlist)

# After
    try:
        return _scstadmin(*cmdlist)
    except ScstAdminError as e:
        if 'No such LUN exists' in str(e):
            return ''
        raise
```

#### Why this fix is correct

"Remove something that is already absent" achieves the desired state. The operation
is idempotent: the desired post-condition (LUN does not exist in SCST) is already
satisfied. Returning `''` instead of raising means the REST server returns HTTP 200,
the `jdssc` retry loop does not trigger, and the disk delete completes in seconds
rather than minutes.

**Backup files:** `scstadmin.py.bak.nodeA.20260428_234553`,
`scstadmin.py.bak.nodeB.20260428_234553`

---

## PL-6: `volume_stage_iscsi` — Extend block device activation timeout 30s → 60s

**Applied:** 2026-04-29 · File: `/usr/share/perl5/OpenEJovianDSS/Common.pm`

### Triggering test

`disk_add_scsi1_par` — 10 Windows VMs adding a second iSCSI disk simultaneously.

### Observed failure

VM 327 (the last VM processed under JD-2 flock serialization) consistently failed
with:

```
Volume vm-327-disk-3 activation failed:
Unable to locate target iqn.2026-03.proxmox.pool-1:vm-327-0 block device location.
```

The `volume_stage_iscsi` function polls `/dev/disk/by-path/` for the new LUN to
appear, running 30 iterations of 1 second each. Every 3rd iteration it triggers a
SCSI rescan. With JD-2 flock serializing the preceding SCST LUN registrations,
VM 327's LUN only became visible in SCST after all 9 preceding VMs had been
processed — by which point fewer than 5 polling seconds remained before the 30s
timeout.

Disk-3 ended up in `[PENDING]` state: the Proxmox config change was saved but the
hotplug failed. The ZVOL existed on JovianDSS but the LUN was cleaned up from SCST
by the plugin's error handler.

### Code before the fix

```perl
# /usr/share/perl5/OpenEJovianDSS/Common.pm — volume_stage_iscsi

    for ( my $i = 1 ; $i <= 30 ; $i++ ) {
```

### Code after the fix

```perl
    for ( my $i = 1 ; $i <= 60 ; $i++ ) {
```

### Why this fix is correct

This is a one-integer change. The loop is unique — it covers only block device
discovery after iSCSI login. The rescan frequency (every 3rd attempt) is unchanged.
The 2× increase gives the last-queued VM sufficient margin when JD-2 flock drains
sequentially.

The proper long-term fix is PL-9 (targeted sysfs rescan) + a JovianDSS-side
improvement to reduce LUN registration time under parallel load.

---

## PL-7: `volume_unpublish` / `volume_deactivate` — Extend `joviandss_cmd` timeout 40s → 120s

**Applied:** 2026-04-29 · File: `/usr/share/perl5/OpenEJovianDSS/Common.pm`

### Triggering test

`migrate_ubuntu_to_pve2_par` and `migrate_windows_to_pve1_par` — 10 VMs migrating
in parallel when orphaned staging LUNs (`se_s1_*` / `se_r1_*`) were present from
a previous test run.

### Observed failure

Two distinct failure modes, both sharing the same root cause:

**Mode 1 — volume_unpublish timeout:**
```
unpublish_volume failed: JovianDSS command timed out after 0 retries
```

**Mode 2 — volume_deactivate timeout (vmstate ZVOLs):**
```
JovianDSS command timed out after 0 retries
Cleanup after stopping VM failed - volume deactivation failed:
  jdss-Pool-0:vm-120-state-r1.raw jdss-Pool-0:vm-120-state-r2.raw
ERROR: migration finished with problems
```

In both cases, `joviandss_cmd` uses the default timeout of 40 seconds. Under
parallel migration with orphaned staging LUNs present (BUG-002), each migration
triggers cleanup of multiple jdssc calls. Behind JD-2 flock, these calls queue
up — the last call in the queue must wait for all preceding ones. With 10 VMs
and ~6 calls each, the last call can wait 120–300 seconds, far exceeding the 40s
default.

### Code before the fix (4 affected calls in `volume_unpublish` and `volume_deactivate`)

```perl
# Call 1 — volume_unpublish, unless ( defined($snapname) ) branch
        my $delitablesnaps = joviandss_cmd(
            $ctx,
            [
                "pool",   $pool,
                "volume", $volname,
                "delete", "-c",  "-p",
                '--target-prefix', $prefix,
                '--target-group-name', $tgname
            ]
        );

# Call 2 — volume_unpublish, targets delete (whole volume)
        joviandss_cmd(
            $ctx,
            [
                'pool', $pool,
                'targets', 'delete',
                '--target-prefix', $prefix,
                '--target-group-name', $tgname,
                '-v', $volname
            ]
        );

# Call 3 — volume_unpublish, targets delete (specific snapshot)
        joviandss_cmd(
            $ctx,
            [
                'pool', $pool,
                'targets', 'delete',
                '--target-prefix', $prefix,
                '--target-group-name', $tgname,
                '-v', $volname,
                '--snapshot', $snapname]);

# Call 4 — volume_deactivate, unless( $snapname ) branch
        my $delitablesnaps = joviandss_cmd(
            $ctx,
            [
                "pool",   $pool,
                "volume", $volname,
                "delete", "-c",  "-p",
                '--target-prefix', $prefix,
                '--target-group-name', $tgname
            ]
        );
```

### Code after the fix

All four calls gain `, 120, 2` (timeout=120s, retries=2) as additional parameters:

```perl
# Example — Call 1 (others identical in structure)
        my $delitablesnaps = joviandss_cmd(
            $ctx,
            [
                "pool",   $pool,
                "volume", $volname,
                "delete", "-c",  "-p",
                '--target-prefix', $prefix,
                '--target-group-name', $tgname
            ],
            120, 2
        );
```

### Why 120s and retries=2

- **120s**: 3× the default. Under parallel load with orphaned staging LUNs the
  queue depth reached ~60 calls; at 2–5s per call the last one waited up to 5
  minutes. 120s provides a realistic upper bound without hanging indefinitely.
- **retries=2**: These operations (unpublish / deactivate) are idempotent from
  the plugin's perspective. A retry after a transient timeout is safe and helps
  absorb short JD-2 flock contention spikes.
- **Note**: The true fix is BUG-002 (remove orphaned staging LUNs after clone
  operations) — that reduces queue depth at the source.

---

## PL-8: `_deactivate_volume` — Skip `volume_unpublish` for vmstate when no local LUN record

**Applied:** 2026-04-29 · File: `/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm`

### Triggering test

`migrate_ubuntu_to_pve2_par` — parallel live migration of 10 Ubuntu VMs that each
had vmstate snapshots (r1, r2, r3, r4 created by `qm snapshot --vmstate`).

### Observed failure

During live migration, Proxmox calls `volume_activate` on the **destination node
(pve2)** for all volumes of the VM — including every vmstate ZVOL. After migration
completes, the **source node (pve1)** calls `_deactivate_volume` to clean up.

The source node never activated the vmstate volumes (the destination did), so it
has no `lun_record` for them. `volume_deactivate` returns early correctly due to
the missing record. But then `volume_unpublish` is called **unconditionally**:

```
→ calls scstadmin -close_dev {scsi_id}
→ device is NOT in SCST vdisk_blockio handler on source (never registered)
→ JovianDSS REST API returns HTTP 500
→ jdssc enters retry loop
→ "Cleanup after stopping VM failed - volume deactivation failed:
    jdss-Pool-0:vm-120-state-r1.raw jdss-Pool-0:vm-120-state-r2.raw"
```

After the error the LUN entry remains stuck in the JovianDSS REST DB (not in SCST
runtime). It accumulates with each migration — every round-trip adds one more stuck
entry per vmstate ZVOL per VM.

### Code before the fix (v0.11.4, `_deactivate_volume`)

```perl
    return 0 if ( 'images' ne "$vtype" );

    volume_deactivate( $ctx, $vmid,
        $volname, $snapname, undef );

    # Unpublish if that is a state of VM
    if ( $volname =~ m!^vm-(\d+)-state-(.+)$! ) {
        volume_unpublish( $ctx,
            $vmid, $volname, $snapname, undef );
    }
```

### Code after the fix

```perl
    return 0 if ( 'images' ne "$vtype" );

    my $lunrecs = lun_record_local_get_info_list( $ctx, $volname, $snapname );
    my $had_lun_record = scalar(@$lunrecs) > 0;

    volume_deactivate( $ctx, $vmid,
        $volname, $snapname, undef );

    # Unpublish if that is a state of VM and this node owns the LUN record.
    # If no local LUN record exists (e.g. source node cleanup after migration),
    # skip unpublish to avoid SCST 500 errors causing jdssc to retry in a loop.
    if ( $volname =~ m!^vm-(\d+)-state-(.+)$! && $had_lun_record ) {
        volume_unpublish( $ctx,
            $vmid, $volname, $snapname, undef );
    }
```

### Why this fix is correct

This follows the identical pattern already applied in PL-3 (`_rename_volume`): call
`lun_record_local_get_info_list` **before** `volume_deactivate` to capture whether
this node owns the LUN, then use that flag to guard `volume_unpublish`.

The source node should only call `volume_unpublish` for volumes it registered in
SCST. The destination node, which holds the LUN record after migration, will clean
up correctly when the VM is stopped there or migrated back.

**Status:** Deployed 2026-04-29. Requires verification: full cycle with vmstate
snapshots + round-trip migration.

---

## PL-9: `volume_stage_iscsi` — Replace `rescan-scsi-bus.sh -a` with targeted per-host sysfs rescan

**Applied:** 2026-05-04 · File: `/usr/share/perl5/OpenEJovianDSS/Common.pm`

### Triggering test

`disk_add_scsi1_par` — 10 VMs adding a disk in parallel. Session 2026-05-01-2,
step 28. VM 127 failed.

### Observed failure

```
Volume vm-127-disk-1 activation failed:
Unable to identify the multipath name for scsiid 26161346636346335
```

Inside the block device activation loop in `volume_stage_iscsi`, every 3rd
iteration runs:

```bash
/usr/bin/rescan-scsi-bus.sh --sparselun --reportlun2 --largelun --luns=N -a
```

The `-a` flag scans **all SCSI hosts** on the system. Under parallel load, all
10 VMs reach this rescan point at nearly the same time — particularly after JD-2
flock causes them to process in a synchronized burst. The result is **10 concurrent
global SCSI rescans** that interfere with each other: a rescan by process A briefly
removes SCSI host devices from the sysfs tree, causing sibling process B to fail
its `block_device_iscsi_paths` lookup with "Unable to identify the multipath name".

Root cause chain:
```
disk_add_scsi1_par (10 VMs parallel)
  └─ volume_activate → volume_stage_iscsi (each VM)
       └─ loop i % 3 == 0 → rescan-scsi-bus.sh -a   ← 10 simultaneous
            └─ global rescan causes SCSI host to vanish for sibling processes
                 └─ block_device_iscsi_paths fails → "Unable to identify multipath"
```

### Code before the fix

```perl
        if ( $i % 3 == 0 && $lunid =~ /^\A\d+\z$/ ) {
            eval {
                my $cmd = [
                    '/usr/bin/rescan-scsi-bus.sh',
                    '--sparselun', '--reportlun2', '--largelun',
                    "--luns=${lunid}", '-a'
                ];
                run_command(
                    $cmd,
                    outfunc  => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                    errfunc  => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                    timeout  => 60,
                    noerr    => 1
                );
            };
        } elsif ( $lunid !~ /^\A\d+\z$/ ) {
            debugmsg( $ctx, "warn", "Lun id ${lunid} contains non digit symbols" );
        }
```

### Code after the fix

The rescan call is replaced with a call to a new helper `_rescan_target_hosts()`,
which writes directly to the sysfs scan interface of only the SCSI host(s) that
carry an iSCSI session for the current target:

```perl
        # Targeted per-host rescan — replaces rescan-scsi-bus.sh -a.
        # Scans only the SCSI hosts that carry sessions for $targetname,
        # avoiding cross-VM interference when N VMs hotplug disks in parallel.
        if ( $i % 3 == 0 && $lunid =~ /^\A\d+\z$/ ) {
            _rescan_target_hosts( $ctx, $targetname, $lunid );
        } elsif ( $lunid !~ /^\A\d+\z$/ ) {
            debugmsg( $ctx, "warn", "Lun id ${lunid} contains non digit symbols" );
        }
```

New helper inserted immediately before `sub volume_stage_iscsi`:

```perl
# _rescan_target_hosts($ctx, $targetname, $lunid)
#
# Trigger a SCSI LUN rescan only on the hosts that carry an iSCSI session
# for $targetname.  Reads the mapping from sysfs:
#   /sys/class/iscsi_session/session{N}/targetname  -> IQN
#   /sys/class/iscsi_session/session{N}/device      -> symlink -> host{H}
#   /sys/class/scsi_host/host{H}/scan               -> write "- - {lun}"
#
# Safe to call from multiple parallel processes: each touches only its own
# session hosts, so there is no cross-VM interference.
sub _rescan_target_hosts {
    my ( $ctx, $targetname, $lunid ) = @_;

    my $sessdir = '/sys/class/iscsi_session';
    opendir( my $dh, $sessdir ) or do {
        debugmsg( $ctx, 'warn', "Cannot open $sessdir: $!\n" );
        return;
    };
    my @sessions = grep { /^session\d+$/ } readdir($dh);
    closedir($dh);

    for my $sess (@sessions) {
        my $tgt_file = "$sessdir/$sess/targetname";
        next unless -f $tgt_file;
        open( my $fh, '<', $tgt_file ) or next;
        my $tgt = <$fh>;
        close $fh;
        chomp $tgt;
        next unless defined $tgt && $tgt eq $targetname;

        my $dev_link = "$sessdir/$sess/device";
        next unless -l $dev_link;
        my $real = Cwd::realpath($dev_link);
        next unless defined $real;

        my ($hostN) = ( $real =~ m{/(host\d+)/} );
        next unless defined $hostN;

        my $scan = "/sys/class/scsi_host/$hostN/scan";
        if ( open( my $sf, '>', $scan ) ) {
            print $sf "- - $lunid\n";
            close $sf;
            debugmsg( $ctx, 'debug',
                "Targeted rescan: $hostN for target $targetname lun $lunid\n" );
        } else {
            debugmsg( $ctx, 'warn', "Cannot write to $scan: $!\n" );
        }
    }
}
```

### Why this fix is correct

Each iSCSI session in `/sys/class/iscsi_session/` exposes its target IQN. We match
only the sessions for the VM's specific target, find their backing SCSI host
numbers, and write `"- - $lunid"` to the host's sysfs `scan` interface. This is
the standard kernel mechanism for targeted LUN discovery. Multiple parallel
processes can each write to their own host's `scan` file simultaneously — there is
no global lock and no interference.

In our test configuration (2 `data_addresses` per storage pool), each VM has
exactly 2 iSCSI sessions and thus 2 SCSI hosts to rescan. The operation is
non-blocking and completes in microseconds.

---

## PL-10: `_volume_resize` — Extend `joviandss_cmd` timeout 40s → 90s

**Applied:** 2026-05-04 · File: `/usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm`

### Triggering test

`disk_resize_scsi3_par` — resizing a 3rd disk on 10 Ubuntu VMs in parallel.
VM 123, session 2026-05-04.

### Observed failure

```
TASK ERROR: JovianDSS command timed out after 0 retries
```

The `joviandss_cmd` call in `_volume_resize` uses the default timeout of 40
seconds. Under parallel `disk_resize_par`, all resize operations compete for the
JD-2 global flock on the JovianDSS node. With 10 VMs each resizing 3 disks in
sequence (scsi1, scsi2, scsi3), the third round of resizes (3rd disk, 10 VMs) runs
when the flock queue is longest — the last VM's request must wait for all 9
preceding ones to complete before JovianDSS even receives it.

JovianDSS completed the resize of VM 123's disk at 15:35:24, but `joviandss_cmd`
had already timed out at the default 40s. The result: JovianDSS has the larger
ZVOL, but the Proxmox side thinks the resize failed. On the next `qm resize` the
plugin would attempt to resize an already-resized volume, which produces an error.

This is the same pattern as PL-4 (`_rename_volume` timeout) — the operation
succeeds on JovianDSS but the plugin gives up before receiving the confirmation.

### Code before the fix (v0.11.4, `_volume_resize`)

```perl
    joviandss_cmd( $ctx,
        [ "pool", "${pool}", "volume", "${volname}", "resize", "${size}" ] );
```

### Code after the fix

```perl
    # Use an extended timeout (90s) for resize: under parallel load the preceding
    # JD-2 global flock may queue this call for >40s before it even reaches
    # JovianDSS.  retries=0 avoids re-extending an already-resized ZVOL.
    joviandss_cmd( $ctx,
        [ "pool", "${pool}", "volume", "${volname}", "resize", "${size}" ],
        90, 0
    );
```

### Why retries=0 is essential

If a retry were attempted after a timeout, the plugin would issue a second `resize`
command for the same volume. But JovianDSS may have already completed the resize
during the first attempt (exactly the observed case: resize finished at 15:35:24,
timeout at ~15:34:54). The retry would try to extend a ZVOL that is already at
the target size — behaviour is undefined (double-extension or error depending on
JovianDSS semantics).

### Why 90 seconds

The same reasoning as PL-4: observed maximum flock wait + operation time under
load was less than 90s. The 90s value is consistent with PL-4 (`_rename_volume`)
and provides a ~2× safety margin over the worst case observed.

The proper long-term fix is to reduce flock scope in JD-2 (serialize only SCST
writes, not reads) or move LUN registration out of the synchronous request path
on the JovianDSS side.
