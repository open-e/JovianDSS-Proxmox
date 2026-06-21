# Applied Plugin Patches — Open-E QA Team

**Date:** 2026-05-21
**Plugin version under test:** v0.11.4
**Test environment:** 2-node Proxmox VE cluster — pve1 (10.15.0.141), pve2 (10.15.0.151)
**VMs:** 10 Ubuntu (120–129) on `jdss-Pool-0` (pve1) · 10 Windows (320–329) on `jdss-Pool-1` (pve2)

---

## JovianDSS Patches — None Applied

**No patches have been applied to JovianDSS** on either node (10.15.0.142, 10.15.0.152).
Both nodes run the stock JovianDSS installation without any modifications to `scstadmin.py`,
`internal_configuration.py`, or any other file.

---

## Currently Applied Plugin Patches

### PL-4 — `_rename_volume` timeout extended from 40s to 90s

**File:** `OpenEJovianDSSPlugin.pm` · **Function:** `_rename_volume`


**Triggering test**

`convert_vms_to_templates_seq` — sequential VM-to-template conversion under load
(CPU load average 47 on the JovianDSS node during a stress test run).


**Observed failure**

The `joviandss_cmd` call that performs the actual volume rename inside `_rename_volume`
uses the default timeout of 40 seconds. Under high CPU load on the JovianDSS node,
the REST API for `rename` took **49 seconds** to respond — exceeding the timeout.

The plugin raised a timeout exception and `qm template` failed. However, examining
the JovianDSS side revealed that **the rename had actually completed successfully**.
This produced an inconsistent state: Proxmox config still referred to `vm-120-disk-0`,
while JovianDSS had already renamed it to `base-120-disk-0`.

The root cause of the slowness is on the JovianDSS side: when the volume being
renamed has an active iSCSI target registered in SCST, the REST API must update
the SCST configuration (rename the target) in addition to performing the ZFS
dataset rename. The combined operation can significantly exceed 40 seconds under
load.


**Why retries=0 is essential**

If a retry were attempted after a timeout, the plugin would issue a second `rename`
command for the same `$original_volname`. But JovianDSS may have already completed
the rename during the first attempt. The retry would try to rename a volume that no
longer exists under its original name, resulting in a "not found" error.


**Why 90 seconds**

Observed maximum rename duration under CPU load 47: **49 seconds**. The 90-second
timeout provides an approximately 1.8× safety margin over the worst case observed.

```perl
# Before
joviandss_cmd( $ctx,
    [ "pool", $pool, "volume", $original_volname, "rename", $new_volname ]
);

# After
joviandss_cmd( $ctx,
    [ "pool", $pool, "volume", $original_volname, "rename", $new_volname ],
    90, 0    # timeout=90s, retries=0
);
```

---

### PL-5 — Pre-check `get_lun(cvname)` before snapshot creation in `_clone_object`

**File:** `jdssc/jovian_common/driver.py` · **Function:** `_clone_object`


**Triggering test**

`linked_clones_from_tpl_create_par` — parallel creation of multiple linked clones
from a Windows template (VM 321, 3 disks: scsi0, tpmstate0, efidisk0). After running
this test and subsequently destroying the clones, **orphaned ZFS snapshots remained
permanently on the template volume** on JovianDSS Pool-1.


**Observed failure**

When cloning a Windows VM with 3 disks, three separate `jdssc` processes are invoked
in quick succession. The second process queries `getfreename` while the IDX is still
stale — it does not yet see the ZVOL created by the first process, and returns the
same candidate name (e.g. `vm-5821-disk-0`).

The second process creates a **snapshot** on the source (base) volume using that
already-taken name. It then calls `create_volume_from_snapshot`, which fails with
`JDSSVolumeExistsException`. The Perl retry logic assigns a new name and the clone
succeeds. However, the snapshot that was created — `base-321-disk-0@v_vm-5821-disk-0`
— is **never cleaned up** and accumulates with each `qm clone` call.


**Root cause**

`_clone_object` in `jdssc` creates linked clones as follows:
1. Pick candidate clone name `cvname` via `getfreename` (queries stale IDX).
2. Create a ZFS snapshot on the source volume: `create_snapshot(ovname, cvname)`.
3. Create a ZVOL from that snapshot: `create_volume_from_snapshot(cvname)`.

The IDX eventual-consistency window (530–1150 ms) causes step 1 to return a name
already taken, and the snapshot at step 2 is created before the conflict is detected.


**Why Fix 1 + Fix 2 together eliminate the orphaned snapshot problem**

Fix 1 adds a direct `GET /volumes/{cvname}` lookup (authoritative, not through stale
IDX) before calling `create_snapshot`. If the volume exists, the exception is raised
immediately before any snapshot is created. Fix 2 handles the residual TOCTOU window
by cleaning up any leaked snapshot in the `JDSSVolumeExistsException` handler before
re-raising the exception.

**Fix 1 — Pre-check before `create_snapshot`:**
```python
# Before
if create_snapshot:
    try:
        self.ra.create_snapshot(ovname, sname)

# After
if create_snapshot:
    try:
        self.ra.get_lun(cvname)
        raise jexc.JDSSVolumeExistsException(cvname)
    except jexc.JDSSResourceNotFoundException:
        pass
    try:
        self.ra.create_snapshot(ovname, sname)
```

**Fix 2 — Cleanup leaked snapshot in the exception handler:**
```python
# Before
except jexc.JDSSVolumeExistsException as jerr:
    if jcom.is_snapshot(cvname):
        LOG.debug(...)
    else:
        raise jerr

# After
except jexc.JDSSVolumeExistsException as jerr:
    if jcom.is_snapshot(cvname):
        LOG.debug(...)
    else:
        if create_snapshot:
            try:
                self.ra.delete_snapshot(ovname, cvname,
                                        recursively_children=True, force_umount=True)
            except jexc.JDSSException as jerrd:
                LOG.warning("snapshot %s of volume %s must be removed manually", sname, ovname)
        raise jerr
```

---

### PL-6 — Block device discovery loop extended from 30 to 60 iterations

**File:** `Common.pm` · **Function:** `volume_stage_iscsi`


**Triggering test**

`disk_add_scsi1_par` — 10 Windows VMs adding a second iSCSI disk simultaneously.


**Observed failure**

VM 327 (the last VM processed under JD-2 flock serialization) consistently failed with:

```
Volume vm-327-disk-3 activation failed:
Unable to locate target iqn.2026-03.proxmox.pool-1:vm-327-0 block device location.
```

The `volume_stage_iscsi` function polls `/dev/disk/by-path/` for the new LUN to
appear, running 30 iterations of 1 second each. With JD-2 flock serializing the
preceding SCST LUN registrations, VM 327's LUN only became visible in SCST after
all 9 preceding VMs had been processed — by which point fewer than 5 polling seconds
remained before the 30s timeout. Disk-3 ended up in `[PENDING]` state.


**Why this fix is correct**

This is a one-integer change. The loop is unique — it covers only block device
discovery after iSCSI login. The rescan frequency (every 3rd attempt) is unchanged.
The 2× increase gives the last-queued VM sufficient margin when JD-2 flock drains
sequentially.

```perl
# Before
for ( my $i = 1 ; $i <= 30 ; $i++ ) {

# After
for ( my $i = 1 ; $i <= 60 ; $i++ ) {
```

---

### PL-7 — `volume_unpublish` / `volume_deactivate` timeout extended from 40s to 120s

**File:** `Common.pm` · **Functions:** `volume_unpublish`, `volume_deactivate`


**Triggering test**

`migrate_ubuntu_to_pve2_par` and `migrate_windows_to_pve1_par` — 10 VMs migrating
in parallel when orphaned staging LUNs (`se_s1_*` / `se_r1_*`) were present from
a previous test run.


**Observed failure**

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

`joviandss_cmd` uses the default timeout of 40 seconds. Under parallel migration
with orphaned staging LUNs present, each migration triggers cleanup of multiple
jdssc calls. Behind JD-2 flock, these calls queue up — the last call in the queue
must wait for all preceding ones. With 10 VMs and ~6 calls each, the last call can
wait 120–300 seconds.


**Why 120s and retries=2**

- **120s**: 3× the default. Under parallel load with orphaned staging LUNs the
  queue depth reached ~60 calls; at 2–5s per call the last one waited up to 5
  minutes.
- **retries=2**: These operations (unpublish / deactivate) are idempotent from
  the plugin's perspective. A retry after a transient timeout is safe.

```perl
# Before (4 joviandss_cmd calls — example)
my $delitablesnaps = joviandss_cmd( $ctx,
    [ "pool", $pool, "volume", $volname, "delete", "-c", "-p",
      '--target-prefix', $prefix, '--target-group-name', $tgname ]
);

# After
my $delitablesnaps = joviandss_cmd( $ctx,
    [ "pool", $pool, "volume", $volname, "delete", "-c", "-p",
      '--target-prefix', $prefix, '--target-group-name', $tgname ],
    120, 2
);
```

---

### PL-8 — vmstate guard in `_deactivate_volume`

**File:** `OpenEJovianDSSPlugin.pm` · **Function:** `_deactivate_volume`


**Triggering test**

`migrate_ubuntu_to_pve2_par` — parallel live migration of 10 Ubuntu VMs that each
had vmstate snapshots (r1, r2, r3, r4 created by `qm snapshot --vmstate`).


**Observed failure**

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

After the error the LUN entry remains stuck in the SCST persistent config files.
It accumulates with each migration — every round-trip adds one more stuck entry
per vmstate ZVOL per VM.


**Why this fix is correct**

This follows the identical pattern already applied in PL-3 (`_rename_volume`): call
`lun_record_local_get_info_list` **before** `volume_deactivate` to capture whether
this node owns the LUN, then use that flag to guard `volume_unpublish`.

The source node should only call `volume_unpublish` for volumes it registered in
SCST. The destination node, which holds the LUN record after migration, will clean
up correctly when the VM is stopped there or migrated back.

```perl
# Before
    volume_deactivate( $ctx, $vmid, $volname, $snapname, undef );

    if ( $volname =~ m!^vm-(\d+)-state-(.+)$! ) {
        volume_unpublish( $ctx, $vmid, $volname, $snapname, undef );
    }

# After
    my $lunrecs = lun_record_local_get_info_list( $ctx, $volname, $snapname );
    my $had_lun_record = scalar(@$lunrecs) > 0;

    volume_deactivate( $ctx, $vmid, $volname, $snapname, undef );

    if ( $volname =~ m!^vm-(\d+)-state-(.+)$! && $had_lun_record ) {
        volume_unpublish( $ctx, $vmid, $volname, $snapname, undef );
    }
```

---

### PL-9 — Targeted per-host SCSI rescan replacing `rescan-scsi-bus.sh -a`

**File:** `Common.pm` · **Function:** `volume_stage_iscsi`


**Triggering test**

`disk_add_scsi1_par` — 10 VMs adding a disk in parallel. Session 2026-05-01-2,
step 28. VM 127 failed.


**Observed failure**

```
Volume vm-127-disk-1 activation failed:
Unable to identify the multipath name for scsiid 26161346636346335
```

Inside the block device activation loop in `volume_stage_iscsi`, every 3rd
iteration runs `rescan-scsi-bus.sh --sparselun --reportlun2 --largelun --luns=N -a`.
The `-a` flag scans **all SCSI hosts** on the system. Under parallel load, all
10 VMs reach this rescan point at nearly the same time — particularly after JD-2
flock causes them to process in a synchronized burst. The result is **10 concurrent
global SCSI rescans** that interfere with each other: a rescan by process A briefly
removes SCSI host devices from the sysfs tree, causing sibling process B to fail
its `block_device_iscsi_paths` lookup.

Root cause chain:
```
disk_add_scsi1_par (10 VMs parallel)
  └─ volume_activate → volume_stage_iscsi (each VM)
       └─ loop i % 3 == 0 → rescan-scsi-bus.sh -a   ← 10 simultaneous
            └─ global rescan causes SCSI host to vanish for sibling processes
                 └─ block_device_iscsi_paths fails → "Unable to identify multipath"
```


**Why this fix is correct**

Each iSCSI session in `/sys/class/iscsi_session/` exposes its target IQN. We match
only the sessions for the VM's specific target, find their backing SCSI host
numbers, and write `"- - $lunid"` to the host's sysfs `scan` interface. This is
the standard kernel mechanism for targeted LUN discovery. Multiple parallel
processes can each write to their own host's `scan` file simultaneously — there is
no global lock and no interference.

```perl
# Before
        if ( $i % 3 == 0 && $lunid =~ /^\A\d+\z$/ ) {
            eval {
                my $cmd = [ '/usr/bin/rescan-scsi-bus.sh',
                            '--sparselun', '--reportlun2', '--largelun',
                            "--luns=${lunid}", '-a' ];
                run_command( $cmd, timeout => 60, noerr => 1 );
            };
        }

# After
        if ( $i % 3 == 0 && $lunid =~ /^\A\d+\z$/ ) {
            _rescan_target_hosts( $ctx, $targetname, $lunid );
        }
```

New helper added before `sub volume_stage_iscsi`:
```perl
sub _rescan_target_hosts {
    my ( $ctx, $targetname, $lunid ) = @_;

    my $sessdir = '/sys/class/iscsi_session';
    opendir( my $dh, $sessdir ) or return;
    my @sessions = grep { /^session\d+$/ } readdir($dh);
    closedir($dh);

    for my $sess (@sessions) {
        my $tgt_file = "$sessdir/$sess/targetname";
        next unless -f $tgt_file;
        open( my $fh, '<', $tgt_file ) or next;
        my $tgt = <$fh>; close $fh; chomp $tgt;
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
        }
    }
}
```

---

### PL-10 — `_volume_resize` timeout extended from 40s to 90s

**File:** `OpenEJovianDSSPlugin.pm` · **Function:** `_volume_resize`


**Triggering test**

`disk_resize_scsi3_par` — resizing a 3rd disk on 10 Ubuntu VMs in parallel.
VM 123, session 2026-05-04.


**Observed failure**

```
TASK ERROR: JovianDSS command timed out after 0 retries
```

The `joviandss_cmd` call in `_volume_resize` uses the default timeout of 40
seconds. Under parallel `disk_resize_par`, all resize operations compete for the
JD-2 global flock on the JovianDSS node. With 10 VMs each resizing 3 disks in
sequence, the third round of resizes runs when the flock queue is longest — the
last VM's request must wait for all 9 preceding ones.

JovianDSS completed the resize of VM 123's disk at 15:35:24, but `joviandss_cmd`
had already timed out at the default 40s. The result: JovianDSS has the larger
ZVOL, but the Proxmox side thinks the resize failed. This is the same pattern as
PL-4 (`_rename_volume` timeout).


**Why retries=0 is essential**

If a retry were attempted after a timeout, the plugin would issue a second `resize`
command for the same volume. But JovianDSS may have already completed the resize
during the first attempt. The retry would try to extend a ZVOL that is already at
the target size — behaviour is undefined (double-extension or error).


**Why 90 seconds**

Same reasoning as PL-4: observed maximum flock wait + operation time under
load was less than 90s. Consistent with PL-4 and provides a ~2× safety margin.

```perl
# Before
joviandss_cmd( $ctx,
    [ "pool", "${pool}", "volume", "${volname}", "resize", "${size}" ] );

# After
joviandss_cmd( $ctx,
    [ "pool", "${pool}", "volume", "${volname}", "resize", "${size}" ],
    90, 0
);
```

---

### PL-11 — `multipathd del map` before and after `multipath -f`

**File:** `Common.pm` · **Function:** `_volume_unstage_multipath_remove_device`


**Triggering test**

`disk_delete_via_unused_par` — 10 Windows VMs deleting a disk in parallel (pve2,
`jdss-Pool-1`). Session 2026-05-05, approximately 20:55.


**Observed failure**

After parallel disk deletion completed, one dm device remained in a **zombie state**:
it had 0 paths but `queue_if_no_path` policy set. Any process that opened the device —
including `vgs` (called by LVM's udev rule) and `pvestatd` — entered an
**uninterruptible sleep (D-state)** with no timeout. The Proxmox GUI showed question
marks for the affected storage pool; `pvestatd` hung and could not be recovered without
a reboot.


**Root cause**

JD-2's global `fcntl.flock` on `scstadmin.py` serializes all SCST operations.
When 10 VMs delete disks in parallel, their SCST LUN removal calls queue behind
the flock and are released in rapid succession — a **thundering herd** effect.
At the moment the LUN is removed from SCST, the iSCSI paths are still briefly
present in the kernel. `multipathd` sees the paths, queues an `addmap` event,
and races with the plugin's cleanup:

```
plugin:     multipath -f <wwid>  →  dm device removed from kernel
multipathd: addmap               →  dm device recreated (0 paths, queue_if_no_path)
                                     ← zombie
```


**Why this fix is correct**

Step 1b instructs `multipathd` to stop managing the WWID **before** the flush —
when `multipathd del map` succeeds, `multipathd` will not re-add the map even if
it sees the iSCSI paths momentarily. Step 2b handles the narrow TOCTOU window
where `addmap` fires between Step 1b and `multipath -f`.

The `multipathd del map` command is idempotent: if the map was never known to
`multipathd`, the call returns `"device not found"` (exit 0 with `noerr => 1`).

```perl
# Step 1b — inserted before multipath -f
if ($MULTIPATHD) {
    eval {
        my $cmd = [ $MULTIPATHD, 'del', 'map', $clean_scsiid ];
        run_command( $cmd,
            outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
            errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
            timeout => 10, noerr => 1
        );
    };
    if ($@) { debugmsg( $ctx, 'warn', "multipathd del map failed for ${clean_scsiid}: $@" ); }
}

# Step 2b — inserted after multipath -f
if (_multipathd_map_exists($ctx, $clean_scsiid)) {
    if ($MULTIPATHD) {
        eval {
            my $cmd = [ $MULTIPATHD, 'del', 'map', $clean_scsiid ];
            run_command( $cmd, timeout => 10, noerr => 1 );
        };
    }
}
```

New helper:
```perl
sub _multipathd_map_exists {
    my ( $ctx, $wwid ) = @_;
    my $found = 0;
    eval {
        my $cmd = [ $MULTIPATH, '-ll', $wwid ];
        run_command( $cmd,
            outfunc => sub { my $line = shift; $found = 1 if $line =~ /\Q$wwid\E/;
                             cmd_log_output($ctx, 'debug', $cmd, $line); },
            errfunc => sub { },
            timeout => 15, noerr => 1
        );
    };
    return $found;
}
```

---

### PL-12 — Block device discovery loop extended from 60 to 160 iterations

**File:** `Common.pm` · **Function:** `volume_stage_iscsi`


**Triggering test**

`snapshot_clone_r1_par` — 10 Windows VMs (320–329) cloned from a RAM snapshot in
parallel. Session 2026-05-08-9, step `snapshot_clone_from_r1_par`.


**Observed failure**

VM 822 (`snap-clone-r1-322`) failed during disk activation for its second disk:

```
Volume vm-822-disk-1 activation failed:
Unable to locate target iqn.2026-03.proxmox.pool-1:vm-822-0 block device location.
```

The WARN fires at **15:22:32**, which is **160 seconds** after disk-1 was
created (15:19:52). The 60-iteration loop exhausted at 60 seconds — the block device
eventually became visible at ~160 seconds, well after the loop had given up.


**Root cause**

For a multi-disk clone, `volume_stage_iscsi` is called once per disk:

- **disk-0**: login loop runs → new session established → device found quickly.
- **disk-1** (LUN hot-add): the session from disk-0 already exists → **login loop
  exits immediately** → 60-iteration block device discovery loop runs.

Under JD-2, all scstadmin calls are serialized by a global `fcntl.flock`. When
10 Windows VMs simultaneously hot-add their disk-1 (LUN 1), all 10 scstadmin calls
queue behind the flock. With 10 concurrent add-LUN operations, vm-822 (last in
queue) waits approximately 100–130 seconds before JovianDSS even begins registering
LUN 1 in SCST. The 60-iteration loop (60 seconds) exhausts before the device appears.


**Why this fix is correct**

The loop is a polling loop with no side effects. Extending it from 60 to 160
iterations adds at most 100 extra seconds of waiting. In the success case the loop
returns immediately once the device is found, so the added iterations carry no cost
when registration is prompt.

```perl
# Before
    for ( my $i = 1 ; $i <= 60 ; $i++ ) {
        ...
        debugmsg( $ctx, "debug", "... (attempt ${i}/30)\n" );

# After
    for ( my $i = 1 ; $i <= 160 ; $i++ ) {
        ...
        debugmsg( $ctx, "debug", "... (attempt ${i}/160)\n" );
```

---

### PL-13 — `eval` guard in `_free_image`

**File:** `OpenEJovianDSSPlugin.pm` · **Function:** `_free_image`


**Triggering test**

`snapshots_create_with_ram_par` — 10 VMs creating snapshots with RAM state (`--vmstate`)
in parallel. Session 2026-05-08-9.


**Observed failure**

VM 320's snapshot `r3` with `--vmstate` did not complete. After the session ended,
direct inspection of JovianDSS Pool-1 confirmed an orphaned vmstate ZVOL:

```
Pool-1/vh_vm-320-state-r3_raw_<base32hash>-  1.6G  ...
```

No corresponding snapshot `r3` exists in the Proxmox VM config for VM 320.
The ZVOL is unreachable through normal Proxmox operations and occupies pool space
indefinitely until manually removed.


**Root cause**

The `qm snapshot --vmstate` command allocates a vmstate ZVOL, activates it over
iSCSI, dumps VM state via QMP, then deactivates and releases it. If the QMP command
times out (QEMU unresponsive due to heavy IO load from 10 concurrent ~1.6 GiB RAM
state dumps), Proxmox calls `free_image` on the vmstate ZVOL to clean up.

The cleanup call chain: `_free_image` calls `volume_deactivate(...)`. The LUN
record that was created by `activate_volumes` in the "before" hook is still present
(because `deactivate_volumes` in the "after" hook was skipped after `savevm-end`
threw). Under heavy IO load, `volume_deactivate`'s internal jdssc call times out —
the resulting exception propagates out of `_free_image` before the ZVOL delete step
is reached. **ZVOL is orphaned.**


**Why this fix is correct**

`volume_deactivate` in the `_free_image` context does two things: retrieves
associated snapshots and removes the local LUN record. If this call fails
transiently, the ZVOL itself is unaffected on JovianDSS — the subsequent
`joviandss_cmd delete -c` handles all cleanup on the JovianDSS side.

The `eval` guard does not suppress the error silently: it logs a `warn` message
for post-hoc diagnosis. The ZVOL deletion still runs. If the deletion itself fails,
the exception from `joviandss_cmd` propagates normally.

```perl
# Before
    volume_deactivate( $ctx, $vmid, $volname, undef, undef );

    joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $volname, "delete", "-c",
          '--target-prefix', $prefix, '--target-group-name', $tgname ],
        get_delete_timeout($ctx)
    );

# After
    eval {
        volume_deactivate( $ctx, $vmid, $volname, undef, undef );
    };
    if ( $@ ) {
        debugmsg( $ctx, "warn",
            "free_image: volume_deactivate failed for ${volname}, "
            . "proceeding with delete: $@\n" );
    }

    joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $volname, "delete", "-c",
          '--target-prefix', $prefix, '--target-group-name', $tgname ],
        get_delete_timeout($ctx)
    );
```

---

### PL-14 — Targeted rescan in `lun_record_update_device`

**File:** `Common.pm` · **Function:** `lun_record_update_device`


**Triggering test**

`snapshot_clone_from_r1_par` — 10 parallel `qm clone --full --snapname r1` on the
same Proxmox node (Ubuntu VMs 120..129 cloning to 2020..2029 on `jdss-Pool-0`).
Also triggered by `volume_update_size` (disk resize) and offline migration
return-path under parallel load.


**Observed failure**

```
Cannot open /sys/class/scsi_host/host70/scan for writing:
    No such file or directory at /usr/share/perl5/OpenEJovianDSS/Common.pm line 3646.
...
Volume vm-2020-disk-0 activation failed: Unable to locate target
    iqn.2026-03.proxmox.pool-0:vm-2020-0 block device location.
```

`sub lun_record_update_device` iterates over the SCSI host directory tree with
`glob '/sys/class/scsi_host/host*'` and writes `"- - -\n"` to each `scan` file.
Under parallel load (10 simultaneous `qm clone --full`), the `glob` returns hostNN
directories that udev has registered but whose `scan` attribute is not yet created.
`open` fails with `No such file or directory`, no `scan` write succeeds for the new
hosts, so the freshly-attached LUN never appears as a block device.


**Root cause**

This is the same anti-pattern PL-9 removed from `volume_stage_iscsi`, but in a
different function. The global `glob`+write block races with udev under parallel load.


**Why this fix is correct**

Replace the global `glob`+write block with a single call to the targeted helper
`_rescan_target_hosts()` introduced by PL-9. Each VM then writes only to the
`scan` files of the SCSI hosts that already carry a session to its target —
hosts that are fully populated in sysfs by the time `lun_record_update_device`
is called (the session was established earlier in the flow). Sets are disjoint
between processes → no cross-VM interference.

```perl
# Before
foreach (@update_device_try) {
    for my $iscsihost (glob '/sys/class/scsi_host/host*') {
        my $scan_file = "$iscsihost/scan";
        if ( $scan_file =~ /^([\:\-\@\w.\/]+)$/ ) {
            open my $fh, '>', $1
              or warn "Cannot open $scan_file for writing: $!";
            print $fh "- - -\n"
              or warn "Failed to write to $scan_file: $!";
            close $fh
              or warn "Failed to close $scan_file: $!";
        }
    }
    ...

# After
foreach (@update_device_try) {
    _rescan_target_hosts( $ctx, $targetname, $lunid );
    ...
```

---

### PL-16 — Per-class timeout helpers

**File:** `Common.pm`

**Triggering test**

`snapshot_clone_from_r1_par` — session 2026-05-12 (Paweł): `vm-129 → vm-2029` clone
failed with `JovianDSS command timed out after 0 retries`.

**Observed failure**

Plugin call sites used ad-hoc `(timeout, retries)` pairs picked at the moment each
particular call site failed under load. Default `(40s, 0 retries)` remained in several
read paths (`list_images`, `hosts`, `snapshots list`, `rollback_do`) — under N=10
parallel clones some of these timed out before reaching the JDSS REST due to JD-5 RLock
queueing on the JovianDSS side.

Root cause: `find_free_diskname` → `list_images` using default 40s/0 retries; the call
queued behind 9 parallel listings and exceeded 40s.

**Design**

Four timeout classes, each with its own constant + `storage.cfg` override:

| Class | Default timeout | Retries |
|-------|----------------:|--------:|
| `JDSS_READ_META_TIMEOUT` | 15s | 3 |
| `JDSS_READ_LIST_TIMEOUT` | 120s | 3 |
| `JDSS_IDEMP_WRITE_TIMEOUT` | 180s | 3 |
| `JDSS_NONIDEMP_WRITE_TIMEOUT` | 180s | 0 |

Retries are NOT user-overridable — they encode class semantics (idempotency), not tuning.
`nonidemp_retries=0` is a safety invariant (no retry on non-idempotent writes to avoid
double-rename / double-delete).

Each class gets a thin helper wrapping `joviandss_cmd`. Every call site is migrated to
the appropriate helper based on its semantics.

```perl
use constant {
    JDSS_READ_META_TIMEOUT_DEFAULT      =>  15,
    JDSS_READ_META_RETRIES              =>   3,

    JDSS_READ_LIST_TIMEOUT_DEFAULT      => 120,
    JDSS_READ_LIST_RETRIES              =>   3,

    JDSS_IDEMP_WRITE_TIMEOUT_DEFAULT    => 180,
    JDSS_IDEMP_WRITE_RETRIES            =>   3,

    JDSS_NONIDEMP_WRITE_TIMEOUT_DEFAULT => 180,
    JDSS_NONIDEMP_WRITE_RETRIES         =>   0,
};

sub jd_cmd_read_meta { joviandss_cmd($_[0],$_[1],get_read_meta_timeout($_[0]),  JDSS_READ_META_RETRIES)  }
sub jd_cmd_read_list { joviandss_cmd($_[0],$_[1],get_read_list_timeout($_[0]),  JDSS_READ_LIST_RETRIES)  }
sub jd_cmd_idemp     { joviandss_cmd($_[0],$_[1],get_idemp_write_timeout($_[0]),JDSS_IDEMP_WRITE_RETRIES) }
sub jd_cmd_nonidemp  { joviandss_cmd($_[0],$_[1],get_nonidemp_write_timeout($_[0]),JDSS_NONIDEMP_WRITE_RETRIES) }
```

---

### PL-17 — Per-node semaphore (`max_parallel_volume_ops`)

**File:** `OpenEJovianDSSPlugin.pm` + new `/usr/share/perl5/OpenEJovianDSS/Semaphore.pm`


**Triggering scenario (PL-17 / PL-18 / PL-19 — shared)**

10–20 parallel `qm clone --target` from one PVE node, plus equivalent volume
of `qm destroy --purge` from a second PVE node, against two JDSS storeids
whose data resides on the same physical JDSS head. Reproducible in the
2-node test cluster with `max_parallel_volume_ops=1` after PL-18 deployment.


**Observed failures (before the set)**

```
TASK ERROR: clone failed: Unable to identify the multipath name for scsiid X
Request to /volumes/v_vm-125-disk-0/snapshots/s_s2 failed
  reason: File /mnt/config/storage_confs/Pool-1_conf/.../vm-322-1 was not found
plugin: 'JovianDSS request <verb> /pools/.../volumes timed out'
multipathd: <wwid>: failed to setup map for addition of new path sd<X>
```


**Why this fix is correct**

PL-17 introduces a per-node semaphore (`max_parallel_volume_ops`) that throttles
concurrent plugin volume operations. PL-18 (see below) promotes this to
cluster-wide using pmxcfs state, ensuring both PVE nodes collectively respect the
concurrency limit for a given JDSS storage. Together they prevent the thundering
herd bursts that cause JDSS REST/SCST/multipath cascade failures under high
parallel load.

Call sites in `OpenEJovianDSSPlugin.pm`:
```perl
my $sem_slot = jd_acquire_semaphore($ctx, $scfg);
# ... volume operation ...
jd_release_semaphore($ctx, $scfg, $sem_slot);
```

---

### PL-18 — Cluster-wide counting semaphore (`max_parallel_volume_ops=1`)

**File:** `/usr/share/perl5/OpenEJovianDSS/Semaphore.pm`


**Why this fix is correct (PL-18 vs PL-17)**

PL-17 used a per-node (`pvedaemon`-process) semaphore — it limited concurrency
within a single PVE node but did not coordinate between pve1 and pve2. PL-18
promotes the semaphore to **cluster-wide** using pmxcfs (`/etc/pve/priv/`) as the
shared state, with mkdir-atomicity on a lock directory as the distributed mutex.
The state file tracks live holders by `(pid, hostname, acquired_at)`; liveness is
checked via `kill(0)` for local PIDs and a max-operation-time timeout for remote
holders. This ensures both PVE nodes collectively respect `max_parallel_volume_ops`
for the same physical JDSS head.

```perl
package OpenEJovianDSS::Semaphore;

use strict;
use warnings;

use Fcntl qw(:DEFAULT);
use File::Path qw(make_path);
use Sys::Hostname qw(hostname);
use Time::HiRes qw(time sleep);
use JSON qw(decode_json encode_json);

use PVE::Tools qw(file_set_contents);

my $STATE_DIR        = '/etc/pve/priv/joviandss-sem';
my $LOCK_DIR_BASE    = '/etc/pve/priv/lock';
my $LOCK_NAME_PREFIX = 'joviandss-sem-';
my $MAX_OP_TIME      = 3600;
my $CFS_LOCK_TIMEOUT = 30;

sub _debugmsg {
    my ($ctx, $level, $msg) = @_;
    return unless $ctx;
    eval {
        require OpenEJovianDSS::Common;
        OpenEJovianDSS::Common::debugmsg($ctx, $level, $msg);
    };
}

sub _cluster_lock {
    my ($lock_name, $timeout, $code) = @_;
    my $lock_path = "${LOCK_DIR_BASE}/${LOCK_NAME_PREFIX}${lock_name}";

    my $deadline = time() + $timeout;
    my $got_lock = 0;
    while (1) {
        if (mkdir($lock_path)) {
            $got_lock = 1;
            last;
        }
        if (time() >= $deadline) {
            die "PL-18 cluster lock timeout (${timeout}s) on '${lock_name}'\n";
        }
        utime(0, 0, $lock_path);
        sleep(1);
    }

    my $result;
    my $err;
    eval { $result = $code->(); };
    $err = $@;

    rmdir($lock_path);

    die $err if $err;
    return $result;
}

sub _state_path {
    my ($host_key) = @_;
    return "${STATE_DIR}/host-${host_key}.json";
}

sub _read_state {
    my ($host_key) = @_;
    my $path = _state_path($host_key);
    return { holders => [] } unless -f $path;
    open(my $fh, '<', $path) or return { holders => [] };
    local $/;
    my $data = <$fh>;
    close($fh);
    return { holders => [] } unless defined($data) && length($data);
    my $state = eval { decode_json($data) };
    if ($@ || !$state || ref($state) ne 'HASH') {
        return { holders => [] };
    }
    $state->{holders} //= [];
    return $state;
}

sub _write_state {
    my ($host_key, $state) = @_;
    unless (-d $STATE_DIR) {
        eval { make_path($STATE_DIR, { mode => 0700 }) };
    }
    my $path = _state_path($host_key);
    file_set_contents($path, encode_json($state));
}

sub _filter_alive {
    my ($holders, $my_host, $now) = @_;
    my @alive;
    for my $h (@$holders) {
        next unless ref($h) eq 'HASH' && $h->{pid} && $h->{host};
        if ($h->{host} eq $my_host) {
            push @alive, $h if kill(0, $h->{pid});
        } else {
            my $age = $now - ($h->{acquired_at} // 0);
            push @alive, $h if $age < $MAX_OP_TIME;
        }
    }
    return \@alive;
}

sub acquire {
    my ($class, %args) = @_;

    my $host_key  = $args{host_key}  // die "PL-18 sem acquire: host_key required\n";
    my $storeid   = $args{storeid}   // '<unknown>';
    my $max_slots = $args{max_slots} // 4;
    my $timeout   = $args{timeout}   // 600;
    my $ctx       = $args{ctx};

    if ($ENV{PL17_SEMAPHORE_DISABLE} || $ENV{PL18_SEMAPHORE_DISABLE} || $max_slots <= 0) {
        return bless {
            disabled => 1,
            host_key => $host_key,
            storeid  => $storeid,
        }, $class;
    }

    my $my_host     = hostname();
    my $my_pid      = $$;
    my $start       = time();
    my $deadline    = $start + $timeout;
    my $poll        = 0.1;
    my $logged_wait = 0;
    my $lock_name   = $host_key;

    while (1) {
        my $got_slot = 0;
        my $cs_err;
        eval {
            _cluster_lock($lock_name, $CFS_LOCK_TIMEOUT, sub {
                my $state = _read_state($host_key);
                my $now = time();
                $state->{holders} = _filter_alive($state->{holders}, $my_host, $now);
                if (scalar(@{$state->{holders}}) < $max_slots) {
                    push @{$state->{holders}}, {
                        pid         => $my_pid,
                        host        => $my_host,
                        acquired_at => $now,
                        storeid     => $storeid,
                    };
                    _write_state($host_key, $state);
                    $got_slot = 1;
                }
            });
        };
        $cs_err = $@;

        if ($got_slot) {
            my $waited = time() - $start;
            _debugmsg($ctx, 'debug', sprintf(
                "PL-18 sem acquired host=%s storeid=%s waited=%.2fs max=%d (cluster-wide)",
                $host_key, $storeid, $waited, $max_slots));
            return bless {
                host_key    => $host_key,
                storeid     => $storeid,
                my_host     => $my_host,
                my_pid      => $my_pid,
                ctx         => $ctx,
                acquired_at => time(),
            }, $class;
        }

        if ($cs_err) {
            _debugmsg($ctx, 'warn',
                "PL-18 sem: cfs_lock_file critical section error ($cs_err)");
        }

        if (!$logged_wait) {
            _debugmsg($ctx, 'debug', sprintf(
                "PL-18 sem all slots busy, waiting (host=%s storeid=%s max=%d timeout=%ds)",
                $host_key, $storeid, $max_slots, $timeout));
            $logged_wait = 1;
        }

        if (time() >= $deadline) {
            die sprintf(
                "PL-18 semaphore timeout: host=%s storeid=%s max=%d waited=%ds — "
              . "upstream contention or stuck operation cluster-wide\n",
                $host_key, $storeid, $max_slots, $timeout);
        }

        sleep($poll);
        $poll *= 1.3;
        $poll = 1.0 if $poll > 1.0;
    }
}

sub release {
    my ($self) = @_;
    return if $self->{disabled};
    return if $self->{released};

    my $host_key = $self->{host_key};
    my $my_pid   = $self->{my_pid};
    my $my_host  = $self->{my_host};
    return unless $host_key && $my_pid && $my_host;

    if ($$ != $my_pid) {
        $self->{released} = 1;
        return;
    }

    my $lock_name = $host_key;
    my $err;
    eval {
        _cluster_lock($lock_name, $CFS_LOCK_TIMEOUT, sub {
            my $state = _read_state($host_key);
            $state->{holders} = [
                grep {
                    !(ref($_) eq 'HASH'
                      && ($_->{pid} // 0)   == $my_pid
                      && ($_->{host} // '') eq $my_host)
                } @{$state->{holders}}
            ];
            _write_state($host_key, $state);
        });
    };
    $err = $@;

    if ($err) {
        _debugmsg($self->{ctx}, 'warn',
            "PL-18 sem: release cfs_lock failed ($err) — slot will be reclaimed by stale sweep");
    } elsif ($self->{ctx}) {
        my $held = time() - $self->{acquired_at};
        _debugmsg($self->{ctx}, 'debug', sprintf(
            "PL-18 sem released host=%s storeid=%s held=%.2fs",
            $host_key, $self->{storeid}, $held));
    }
    $self->{released} = 1;
}

sub DESTROY {
    my $self = shift;
    $self->release if ref $self && !$self->{disabled};
}

1;
```

---

### PL-19 — Multipath retry budget 20 → 60 + `multipathd del map` every 15 attempts

**File:** `Common.pm` · **Function:** `volume_stage_multipath`


**Triggering scenario**

Multipath `Unable to identify the multipath name` final failures occurring under
the PL-18 semaphore — `multipathd add map` calls failing with "failed to setup
map for addition of new path" even after PL-18 reduced burst concurrency.


**Observed failure**

```
TASK ERROR: clone failed: Unable to identify the multipath name for scsiid X
multipathd: <wwid>: failed to setup map for addition of new path sd<X>
```

The original 20-attempt (~40s) multipath retry budget was insufficient.
`multipathd`'s internal state could get stuck (stale residual map entries),
causing all 20 retries to fail. Recovery required explicit `multipathd del map`
to clear the stale internal state before multipath could build a fresh map.


**Why this fix is correct**

Extending the budget from 20 to 60 attempts gives approximately 5 minutes of
retry window instead of 40 seconds. The `multipathd del map` recovery escalation
every 15 attempts clears stale internal multipathd state, allowing the daemon to
build a fresh map on the next attempt. Both together address the root cause:
multipathd getting stuck on stale residual state under concurrent iSCSI
path churn.

```perl
# Before
my $max_attempts = 20;

# After
my $max_attempts = 60;

# Added every 15 failures:
if ( $attempt % 15 == 0 ) {
    eval {
        my $cmd = [ $MULTIPATHD, 'del', 'map', $wwid ];
        run_command( $cmd, timeout => 10, noerr => 1 );
    };
}
```

---

### PL-20 — `size==0` kernel rescan in `volume_stage_multipath` Phase 2

**File:** `Common.pm` · **Function:** `volume_stage_multipath`


**The JDSS-side bug being worked around (BUG-026)**

A race between LUN attach and size commit on the JDSS target side. The initiator's
kernel sees the LUN attach event and runs `READ CAPACITY` against the LUN before
JDSS has finished setting the volume size on its side. Kernel gets back 0 blocks,
registers the sd-device as 0 bytes, and never re-runs `READ CAPACITY` on its own.
The device-mapper layer refuses to build a multipath map over a 0-byte device.

Empirically confirmed across 4 distinct historical incidents: **every single fail
has matching `0 512-byte logical blocks` lines in dmesg** for the sd-devices
involved.


**Observed failure**

```
TASK ERROR: clone failed: Unable to identify the multipath name for scsiid X
```

`multipathd` correctly fails `add map` for a 0-byte device. All PL-19 retries fail
identically because the kernel never re-reads `READ CAPACITY` for the stuck sd-device.


**Why this fix is correct**

At the top of each Phase 2 retry iteration, for each sd-device for this wwid:
read `/sys/block/<sd>/size`. If `size == 0`, log a `PL-20:` warn and write `1`
to `/sys/block/<sd>/device/rescan` — the documented kernel API to force a fresh
`READ CAPACITY` against the target.

- **Targets the actual cause.** Only takes action when size is genuinely zero.
- **Read-only kernel API.** `device/rescan` cannot corrupt anything.
- **No effect on happy path.** ~99.4% of activations have size > 0 on first check.
- **Bounded cost.** One stat + (occasionally) one write per sd per iter.

```perl
# Added at top of each Phase 2 retry iteration
for my $sd (@sd_devs) {
    my $size_file = "/sys/block/$sd/size";
    if ( open(my $fh, '<', $size_file) ) {
        my $sz = <$fh>; close $fh; chomp $sz;
        if ( defined $sz && $sz == 0 ) {
            debugmsg( $ctx, 'warn', "PL-20: $sd size=0, forcing kernel rescan\n" );
            my $rescan = "/sys/block/$sd/device/rescan";
            if ( open(my $rf, '>', $rescan) ) {
                print $rf "1\n";
                close $rf;
            }
        }
    }
}
```

---

### PL-20v2 — REST republish escalation when PL-20 kernel rescan is insufficient

**File:** `Common.pm` · **Function:** `volume_stage_multipath`


**Why PL-20 wasn't enough**

Live incident 2026-05-17 07:20-07:24 (`req=ce1b748d`): plugin observed **34+
consecutive PL-20 kernel rescans** on sd-devices `sdjq/sdjr`, each returning
`size=0`. JDSS kept replying `READ CAPACITY = 0` for 4+ minutes straight, until
the outer 60-attempt budget exhausted and clone failed.

PL-20's hypothesis (BUG-026 is a short race window) is empirically disproved.
The LUN is **persistently stuck at 0 bytes** from JDSS's perspective — kernel-side
rescan has no chance because the storage is returning 0 to every query.


**What PL-20v2 does**

After 15 consecutive ineffective PL-20 rescans within a single
`volume_stage_multipath` call, escalate beyond the kernel/multipathd layer
to the JDSS layer itself:

1. REST `volume_unpublish` — remove the LUN from its target on JDSS
2. `sleep 2` — let JDSS internal config DB settle
3. REST `volume_publish` — re-attach the LUN (fresh size-commit opportunity)
4. `iscsiadm -m session --rescan` — make initiator pick up the new attach event
5. `sleep 3` — kernel re-attach
6. Re-resolve sd-devnames (new kernel device names after detach/re-attach)
7. Reset PL-20 counter — clean budget for the fresh LUN

Triggered AT MOST ONCE per `volume_stage_multipath` call.


**Validation status — POSITIVE (2026-05-17 23:51)**

First live PL-20v2 fire confirmed outcome **(a)**: REST republish OK → multipath
built → `Activate volume vm-4026-disk-2 done`. No final failure. Operation
recovered cleanly from BUG-026 stuck LUN.

Timeline `req=[28043592]` for vm-4026-disk-2:
- 23:47:42 → 23:49:12: 15 attempts of PL-20 kernel rescan, size=0 every iteration
- 23:49:12: PL-20v2 escalation triggered: REST unpublish+republish
- 23:51:00: fresh sd-device has non-zero size
- 23:51:02: `Activate volume vm-4026-disk-2 done` ✅

```perl
# Triggered after 15 consecutive size=0 kernel rescans (at most once per call)
if ( $pl20_zero_count >= 15 && !$pl20v2_fired ) {
    $pl20v2_fired = 1;
    debugmsg( $ctx, 'warn',
        "PL-20v2: kernel rescan ineffective for 15 iters — escalating to "
        . "JDSS REST unpublish+republish (vmid=$vmid volname=$volname)\n" );

    eval {
        volume_unpublish( $ctx, $vmid, $volname, $snapname, undef );
        sleep 2;
        volume_publish( $ctx, $vmid, $volname, $snapname );
        run_command( [ $ISCSIADM, '-m', 'session', '--rescan' ],
                     noerr => 1, timeout => 30 );
        sleep 3;
        @sd_devs = _resolve_sd_devs( $ctx, $wwid );
        $pl20_zero_count = 0;
    };
    if ($@) {
        debugmsg( $ctx, 'warn', "PL-20v2: republish failed: $@\n" );
    }
}
```
