# Snapshot Rollback via SCSI XCOPY — Design Document

## Overview

This document describes a proposed implementation of non-destructive snapshot rollback
using the SCSI EXTENDED COPY (XCOPY) command for the JovianDSS Proxmox plugin.

The current rollback path calls the JovianDSS REST API `POST
/volumes/<vol>/snapshots/<snap>/rollback`, which performs a native ZFS `rollback -r`.
ZFS rollback is a metadata-only operation and is therefore fast, but it destroys all
snapshots created after the target snapshot. This makes rollback a destructive,
irreversible operation that discards part of the snapshot history.

The XCOPY-based approach replaces the ZFS rollback with a full block-level copy at the
Proxmox host level. The snapshot and the live volume are each activated as independent
iSCSI block devices using the plugin's existing `activate_volume` / `deactivate_volume`
infrastructure. `sg_xcopy` then copies the snapshot's data to the live volume. Because
the snapshot chain on the JovianDSS appliance is never modified, all newer snapshots
survive. The rollback is non-destructive.

The implementation is entirely in the Perl layer. It reuses existing activation and
block-device path helpers from `OpenEJovianDSS/Common.pm` and extends the `jdssc`
Python CLI with two new flags: `-b` on `volume get` to expose the ZFS
`volblocksize`, and `--latest` on `snapshots list` to retrieve the most recent
snapshot name for failure recovery.

The XCOPY copy runs in an adaptive loop: each `sg_xcopy` invocation is bounded by
a 50-second timeout; on timeout the chunk size is halved and the same offset is
retried. If the copy fails despite retries, a recovery ZFS rollback to the volume's
most recent snapshot restores it to a clean state.

The rollback method is selected automatically: if no blocking snapshots exist the
existing fast ZFS path is used unchanged; if blockers are present the XCOPY path is
used instead. No configuration flag is required.

---

## Problem with ZFS Rollback

The current `POST /volumes/<vol>/snapshots/<snap>/rollback` REST call maps directly to
`zfs rollback -r`. ZFS requires that all snapshots newer than the target be destroyed
before rolling back; the `-r` flag tells it to do so automatically.

Consequences:

1. **Snapshot history is permanently lost.** All snapshots created after the target
   snapshot are gone after the rollback completes, even if they were Proxmox-managed
   snapshots with associated VM config entries.

2. **Proxmox config must be patched.** The plugin walks the deleted snapshot names
   returned by `jdssc` (`snap:X` tokens) and strips their `[snapname]` sections from
   the VM's `.conf` file to keep Proxmox in sync. This requires direct writes to
   `/etc/pve/qemu-server/<vmid>.conf`, bypassing Proxmox cluster config locking.

3. **`force_rollback` tag is required for non-trivial cases.** When newer snapshots
   exist and the VM does not carry the `force_rollback` tag, rollback is refused
   entirely. The user must add the tag, accepting data loss.

4. **Clone blockers always prevent rollback.** Any ZFS clone from the target snapshot
   or a newer snapshot prevents even `force_rollback`; the clones must be deleted
   manually first.

The XCOPY approach eliminates all four issues. No snapshot is destroyed, no config
patching is required, `force_rollback` is irrelevant, and clone blockers do not
affect the copy path.

---

## SCSI XCOPY Background

SCSI EXTENDED COPY (XCOPY, operation code `0x83`) is defined in T10 SPC-3 and SPC-4.
It instructs a SCSI device to copy data from one location to another without requiring
the host to act as a data relay. The LID1 variant (List Identifier length = 1 byte) is
the widely supported form and is what `sg_xcopy` from sg3_utils uses.

### Third Party Copy — 3PC flag

An iSCSI target that supports XCOPY reports `3PC=1` in the standard INQUIRY response
(byte 5, bit 3). This bit indicates the device supports "Third Party Copy" — it can
act as either the source or destination of an XCOPY operation directed by a remote
initiator.

JovianDSS iSCSI LUNs report `3PC=1`:

```
standard INQUIRY:
  PQual=0  PDT=0  RMB=0  LU_CONG=0  version=0x06  [SPC-4]
  SCCS=0  ACC=0  TPGS=0  3PC=1  Protect=0
  Vendor identification: SCST_BIO
  Product identification: Storage
```

This flag means the target *can* accept and process XCOPY commands. It does not by
itself guarantee storage-side offload (see §XCOPY offload below).

### XCOPY offload — storage-side copy

When the XCOPY command is sent to the destination LUN (`--on_dst`, the sg_xcopy
default) and both source and destination LUNs reside on the same JovianDSS appliance,
the appliance is expected to perform the copy internally without user data traversing
the iSCSI network.

For a volume and its snapshot on the same pool the expected copy path is:

```
Proxmox host                       JovianDSS appliance
    │                                      │
    │──── XCOPY command ──────────────────►│
    │     (sent to destination/volume LUN) │
    │                                      │── read from snapshot LUN (internal)
    │                                      │── write to volume LUN   (internal)
    │◄─── command complete ────────────────│
    │     (no user data traverses iSCSI)   │
```

**Caveat:** `3PC=1` confirms the target accepts XCOPY commands; whether the copy is
performed fully on-appliance depends on the JovianDSS SCST implementation. Both LUNs
(live volume and snapshot) are always on the same appliance in the plugin's
single-appliance-per-storage-instance model, which is a necessary precondition for
appliance-side offload. The test described in §Confirmed working invocation below
verified that XCOPY completes successfully between two JovianDSS LUNs, but did not
measure throughput to confirm absence of data on the iSCSI wire. Storage-side offload
should be validated empirically against the target JovianDSS firmware version before
relying on it for performance estimates.

Compare with a host-side `dd if=<snap_dev> of=<vol_dev>`:

```
Proxmox host                       JovianDSS appliance
    │◄─── read from snapshot ─────────────┤   (data crosses iSCSI network)
    │──── write to volume ────────────────►│   (data crosses iSCSI network again)
```

For a 100 GiB volume over a 1 Gbit/s iSCSI link, `dd` takes ~1600 s; XCOPY offloaded
to the appliance would be bounded only by the appliance's internal storage bandwidth.

### `sg_xcopy` command-line syntax

`sg_xcopy` uses `key=value` pairs (not GNU `--key` long options):

```bash
sg_xcopy if=<src_dev> of=<dst_dev> bs=<block_size> skip=<N> seek=<N> count=<N>
```

- `if` — source block device (snapshot)
- `of` — destination block device (live volume)
- `bs` — block size in bytes; used to compute LBA offsets from skip/seek/count
- `skip` — source start offset in units of `bs`
- `seek` — destination start offset in units of `bs`
- `count` — number of `bs`-sized blocks to copy; when omitted, derived from IFILE
  READ CAPACITY when `dc=0` (the default)

The command is synchronous — it returns when the copy is complete (or on error). Exit
code 0 indicates success.

---

## JovianDSS XCOPY Capabilities — Observed on pve-91-1

The following was gathered from a pve-91-1 host connected to a JovianDSS appliance
via iSCSI (SCST_BIO backend, SPC-4):

### RECEIVE COPY OPERATING PARAMETERS response

```
Support No List IDentifier (SNLID): 1
Maximum target descriptor count:   5
Maximum segment descriptor count: 143
Maximum descriptor list length:  65535
Maximum segment length:    4294967295 (no practical limit)
Maximum inline data length:          0
Held data limit:                     0 (list_id_usage: discard)
Maximum concurrent copies:         255
Data segment granularity:        65536 bytes
Inline data granularity:             1 bytes
Held data granularity:               1 bytes
Implemented descriptor list:
    Copy Block to Block device
    Identification target descriptor
```

### Data segment granularity constraint

`Data segment granularity: 65536 bytes` means every XCOPY segment must transfer a
multiple of 65536 bytes. The `bpt` (blocks per transfer) must be a multiple of
`ceil(65536 / bs)` where `bs` is the block size used in the `sg_xcopy` invocation.

This implementation uses the ZFS `volblocksize` as `bs=`, obtained via
`jdssc volume get -b`. JovianDSS supports volblocksizes of 4K, 8K, 16K, 32K, 64K,
128K, 256K, 512K, and 1M. The `sg_xcopy` default `bpt=128` satisfies the granularity
constraint for all supported values:

```
bs=4096    (4K):   min_bpt = ceil(65536/4096)   = 16;  default bpt=128 >= 16  ✓
bs=8192    (8K):   min_bpt = ceil(65536/8192)   =  8;  default bpt=128 >=  8  ✓
bs=65536   (64K):  min_bpt = ceil(65536/65536)  =  1;  default bpt=128 >=  1  ✓
bs=131072  (128K): min_bpt = ceil(65536/131072) =  1;  default bpt=128 >=  1  ✓
bs=1048576 (1M):   min_bpt = ceil(65536/1048576)=  1;  default bpt=128 >=  1  ✓
```

No `bpt=` argument is required in the `sg_xcopy` invocation.

### Block size for `sg_xcopy` and `dd`

The `bs=` argument to both `sg_xcopy` and `dd` is the ZFS `volblocksize`, obtained
from the JovianDSS REST API via `jdssc volume get -b`. `sg_xcopy` uses `bs` to
compute LBA offsets from the `skip`, `seek`, and `count` parameters; it handles
the conversion to the device's physical sector size internally.

The same `$bs` value is passed to `run_zero_chunk` and used as `bs=` in the `dd`
zero-fill command for consistency.

`blockdev --getss` is not used — the ZFS volblocksize from `jdssc` provides the
single block-size value needed by both copy operations.

### SNLID=1

`Support No List IDentifier (SNLID): 1` means the target accepts XCOPY with
`list_id_usage=disable` (list ID field set to 0). sg_xcopy uses this mode
automatically when `Held data limit=0`. No `id_usage=` argument is needed.

### VPD page 0x83 truncation warning — non-fatal

sg_xcopy prints the following warning when identifying the source and destination
devices:

```
designator too long: says it is 8 bytes, but given 4 bytes
```

This occurs because the JovianDSS iSCSI target returns a VPD Device Identification
(page 0x83) designator whose claimed length (8 bytes) exceeds the data actually
present (4 bytes). sg_xcopy logs the warning, skips that designator, and falls back
to alternative identification. The XCOPY operation completes successfully. No
workaround is required.

### Confirmed working invocation

Tested on pve-91-1 between two JovianDSS LUNs on the same appliance. The test
verified that XCOPY completes without error; full-volume throughput and storage-side
offload were not measured in this test:

```bash
sg_xcopy if=/dev/sdb of=/dev/sdc bs=512 bpt=128 verbose=1
# Output: sg_xcopy: 128 blocks, 1 command
# Exit: 0
```

The production invocation (from `run_xcopy_chunk`) uses `bs=<volblocksize>` and omits
`bpt` (using the default of 128). The test above used the iSCSI logical block size
(512 bytes) as `bs`; both forms are accepted by the target.

---

## jdssc Extension: `volume get -b`

> **Scope of this extension.** `jdssc volume get -b` returns the ZFS
> `volblocksize` — the internal ZFS allocation-unit size. This value is used
> as `bs=` in both `sg_xcopy` and `dd` within `_volume_snapshot_rollback`.
> It is a single, consistent block-size value for all copy operations.

### Motivation

The Perl plugin needs the volume's ZFS `volblocksize` to use as `bs=` in `sg_xcopy`
and `dd` during XCOPY rollback. The value is available from the JovianDSS REST API
in the `GET /volumes/<volname>` response but is not currently exposed by any
`jdssc volume get` flag.

### Changes required

**`jdssc/jdssc/jovian_common/driver.py` — `get_volume`**

Add `volblocksize` to the returned dict:

```python
ret = {'name': name,
       'size': data['volsize']}

if 'volblocksize' in data:
    ret['volblocksize'] = data['volblocksize']  # ZFS block size in bytes (string)

if 'san:volume_id' in data:
    ret['san_scsi_id'] = data['san:volume_id']

if 'default_scsi_id' in data:
    ret['scsi_id'] = data['default_scsi_id']
```

**`jdssc/jdssc/volume.py` — `get` subparser**

Add `-b` / `--block-size` to the mutually exclusive print group:

```python
get_print.add_argument('-b', '--block-size',
                       dest='volume_block_size',
                       action='store_true',
                       default=False,
                       help='Print ZFS volblocksize in bytes')
```

**`jdssc/jdssc/volume.py` — `get` action**

```python
if self.args['volume_block_size']:
    bsize = d.get('volblocksize')
    if bsize is None:
        LOG.error("volblocksize not available for volume %s",
                  self.args['volume_name'])
        exit(1)
    print(bsize)
    return
```

### Usage from Perl

```perl
my $bs = clean_word( joviandss_cmd(
    $ctx,
    [ 'pool', $pool, 'volume', $volname, 'get', '-b' ],
    10, 3,
) ) + 0;
die "xcopy rollback: failed to get block size for ${volname}\n"
    unless $bs > 0;
```

`$bs` is used as `bs=` in both `sg_xcopy` (via `run_xcopy_chunk`) and `dd`
(via `run_zero_chunk`).

---

## jdssc Extension: `snapshots list --latest`

### Motivation

When an XCOPY rollback fails (timeout after chunk reduction, I/O error, or
zero-fill failure), the live volume may be partially overwritten. To restore
the volume to a clean state, the plugin performs a recovery ZFS rollback to the
volume's most recent snapshot. This undoes all partial writes without destroying
any snapshot (the most recent snapshot has no newer snapshots after it, so
`zfs rollback` needs no `-r`).

The Perl plugin needs the name of the most recent snapshot. The REST API
returns snapshots with `creation` timestamps, but no existing `jdssc` flag
exposes just the latest one.

### Changes required

**`jdssc/jdssc/jovian_common/driver.py` — `list_snapshots`**

No change required. The existing method already returns snapshots with
`creation` timestamps from the REST API.

**`jdssc/jdssc/snapshots.py` — `list` subparser**

Add `--latest` flag:

```python
list_parser.add_argument('--latest',
                         dest='latest_only',
                         action='store_true',
                         default=False,
                         help='Print only the name of the most recent snapshot')
```

**`jdssc/jdssc/snapshots.py` — `list` action**

```python
if self.args.get('latest_only'):
    if not snapshots:
        LOG.error("No snapshots found for volume %s",
                  self.args['volume_name'])
        exit(1)
    # Select the snapshot with the latest creation timestamp.
    latest = max(snapshots, key=lambda s: s.get('creation', ''))
    print(latest['name'])
    return
```

### Usage from Perl

```perl
my $latest_snap = clean_word( joviandss_cmd(
    $ctx,
    [ 'pool', $pool, 'volume', $volname, 'snapshots', 'list', '--latest' ],
    10, 3,
) );
```

---

## Architecture

### Approach

The XCOPY rollback reuses the plugin's existing activation machinery exclusively.
No temporary clones and no extra iSCSI targets beyond those created by the standard
activation path are needed. Two minor `jdssc` flag additions expose existing REST
data (`volume get -b` for volblocksize, `snapshots list --latest` for recovery).

The implementation follows the standard three-layer pattern used by all plugin
rollback and volume operations:

```
volume_snapshot_rollback
  └── _volume_snapshot_rollback_lock    (acquires single per-VM lock)
        └── _volume_snapshot_rollback   (ZFS path or XCOPY path)
```

A single lock covers the entire operation. This matches the existing pattern and
avoids the complexity of cross-phase state management.

### Rollback path selection

`_volume_snapshot_rollback` calls `volume_rollback_check` with `force=0`:

- Returns 1 (no blocking snapshots or clones) → **ZFS path**: a single
  `joviandss_cmd rollback do` call performs a fast metadata-only rollback.
  Since there are no blockers, no snapshots are destroyed and Proxmox snapshot
  records need no patching.

- Dies (blockers exist) → **XCOPY path**: the snapshot and live volume are each
  activated as independent block devices, `sg_xcopy` copies the snapshot content
  to the live volume in an adaptive loop (see §Adaptive chunking below), and
  both the snapshot and the live volume are deactivated on exit (unconditionally,
  whether copy succeeded or failed). If the copy fails for any reason, a recovery
  ZFS rollback to the volume's most recent snapshot is performed after
  deactivation to undo any partial writes. All snapshots on the appliance
  survive.

No configuration flag controls this selection. The path is determined entirely
by the runtime state of the snapshot chain.

### Adaptive chunking

`run_xcopy_chunk` copies the snapshot data to the live volume in a loop. Each
`sg_xcopy` invocation is bounded by a 50-second timeout. If a timeout fires,
the chunk size is halved (rounded down to the nearest granularity-aligned block
count) and the same offset is retried with the smaller chunk. The process
repeats until all blocks are copied or the chunk size cannot be reduced further,
at which point the function dies.

The minimum chunk size is derived from the XCOPY Data segment granularity
(65 536 bytes): `gran_blocks = max(1, 65536 / bs)`. Chunk sizes are always
kept as multiples of `gran_blocks` to satisfy the constraint that each XCOPY
segment must transfer a multiple of the granularity.

On any non-timeout error (I/O failure, SCSI error) `run_xcopy_chunk` dies
immediately without retrying — these errors are not recoverable by reducing
the transfer size.

### Block device paths after activation

After `_activate_volume($class, $ctx, $volname, undef, {})` and
`_activate_volume($class, $ctx, $volname, $snapname, {})`, the block device paths
are retrieved from the LUN record via `lun_record_local_get_info_list` +
`block_device_path_from_lun_rec`. Both functions already exist in `Common.pm`:

```perl
# For the live volume:
my $vol_til = lun_record_local_get_info_list($ctx, $volname, undef);
my ($tname, $lunid, undef, $lr) = @{ $vol_til->[0] };
my $vol_dev = block_device_path_from_lun_rec($ctx, $tname, $lunid, $lr);

# For the snapshot:
my $snap_til = lun_record_local_get_info_list($ctx, $volname, $snapname);
my ($stname, $slunid, undef, $slr) = @{ $snap_til->[0] };
my $snap_dev = block_device_path_from_lun_rec($ctx, $stname, $slunid, $slr);
```

### Snapshot activated as read-write

`volume_activate` with `$snapname` publishes the snapshot as a standard iSCSI LUN.
The LUN is exposed with read-write access — the same as a regular volume. For the
XCOPY rollback, the snapshot is the source and is never written to; the read-write
exposure is harmless in practice. If a future JovianDSS API version supports a
`readonly` flag on snapshot target publication, it should be used here as a defense-
in-depth measure.

### Block size

The `bs=` argument to `sg_xcopy` and `dd` is the ZFS `volblocksize`, obtained from
the JovianDSS REST API via `jdssc volume get -b`. This is the single block-size value
used consistently across all copy operations within the rollback. See
§Block size for `sg_xcopy` and `dd` above for the constraint analysis.

### Lock renewal during XCOPY

The plugin's per-VM lock has a 60-second execution timeout (`alarm(60)` in
`_cluster_lock_attempt`). For cluster-wide (shared) storage the lock is a
`mkdir` entry on pmxcfs; pmxcfs auto-drops entries whose mtime is older than
~120 seconds. An XCOPY rollback of a multi-terabyte volume can run for hours,
far exceeding both limits.

To keep the lock alive, a **`lock_renew`** function in `Lock.pm` performs two
actions:

1. **`alarm(60)`** — resets the Perl-level execution alarm, granting another
   60 seconds of wall-clock time before `SIGALRM` fires.
2. **`utime(undef, undef, $lockpath)`** — touches the pmxcfs lock directory's
   mtime so pmxcfs does not consider it stale. (No-op for node-local flock
   locks.)

`_volume_snapshot_rollback` creates a `$renew_lock` closure that captures the
lock identity (storeid, path, shared flag, vmid) and passes it to
`run_xcopy_chunk`. The closure is called:

- After each `_activate_volume` call (activation involves REST + iscsiadm
  login and can consume a significant portion of the 60-second window).
- After each successful `sg_xcopy` chunk inside the adaptive loop.
- Before `run_zero_chunk` (the zero-fill may itself take significant time
  for large resize deltas).

Each call extends the lock by another 60-second window. Individual operations
(one activation call, one `sg_xcopy` chunk, one `run_zero_chunk` call) must
still complete within 60 seconds — only the cumulative duration is unbounded.

---

## Perl Implementation

### `lock_renew` in `Lock.pm`

Resets the execution alarm and refreshes the pmxcfs lock directory's mtime.
Called repeatedly during long-running XCOPY rollbacks to prevent lock expiry.

```perl
# lock_renew($storeid, $path, $shared, $vmid)
#
# Extends the per-VM (or per-storage) lock's lifetime by another 60 seconds.
# Must be called from within the code block executing under the lock.
#
# For cluster-wide (shared) locks:
#   - Resets alarm(60) to prevent SIGALRM.
#   - Touches the pmxcfs lock directory to prevent stale-entry cleanup.
#
# For node-local (flock) locks:
#   - Resets alarm(60).  The flock has no mtime-based expiry, so no
#     filesystem touch is needed.
sub lock_renew {
    my ( $storeid, $path, $shared, $vmid ) = @_;

    alarm(60);

    if ( $shared ) {
        my $lockid = defined $vmid ? "vm-${vmid}" : 'storage';
        my $lockpath = "/etc/pve/priv/lock/joviandss-${storeid}-${lockid}";
        utime( undef, undef, $lockpath );
    }
}
```

The function must be added to `@EXPORT` in `Lock.pm` so callers in `Plugin.pm`
and `Common.pm` can invoke it without a package prefix.

### Adapting `volume_rollback_is_possible`

`volume_rollback_is_possible` is the first function Proxmox calls before executing a
rollback. With the new design it performs only the HA guard and returns 1. No blocker
check is needed: if no blockers exist the fast ZFS path is used; if blockers exist the
XCOPY path handles them. In either case rollback proceeds — the only condition that
prevents it is active HA management.

`volume_rollback_check` is **not** called here. Calling it only to populate `$blockers`
while always returning 1 would be misleading — it implies the check influences the
decision when it does not.

```perl
sub volume_rollback_is_possible {
    my ( $class, $scfg, $storeid, $volname, $snap, $blockers ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    # HA guard: the only condition that prevents rollback.
    my $managed_by_ha = ha_state_is_defined($ctx, $vmid);
    if ($managed_by_ha) {
        my $hastate = ha_state_get($ctx, $vmid);
        if ( $hastate ne 'ignored' ) {
            my $resource_type = ha_type_get($ctx, $vmid);
            print "vmid ${vmid}: HA check failed — managed by HA (state: ${hastate})\n";
            my $msg =
              "Rollback blocked: ${resource_type}:${vmid} is controlled by"
              . " High Availability (state: ${hastate}).\n"
              . "Disable HA management before retrying:\n"
              . "  ha-manager set ${resource_type}:${vmid} --state ignored\n";
            die $msg;
        }
    }

    return 1;
}
```

### `_volume_snapshot_rollback`

The unified rollback function. Called from `_volume_snapshot_rollback_lock` inside
the single per-VM lock. It selects the ZFS or XCOPY path based on the runtime state
of the snapshot chain.

```perl
sub _volume_snapshot_rollback {
    my ( $class, $ctx, $volname, $snap ) = @_;

    my $pool = get_pool($ctx);
    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    print "Rollback: starting rollback of ${volname} to snapshot ${snap}\n";
    debugmsg( $ctx, 'debug',
        "Volume ${volname} " . safe_var_print( 'snapshot', $snap ) . " rollback start" );

    my $zfs_ok = eval {
        volume_rollback_check( $ctx, $vmid, $volname, $snap, undef, 0 )
    };

    if ( $zfs_ok ) {
        # No blockers — fast ZFS metadata rollback.
        # No snapshots are destroyed; Proxmox snapshot records are untouched.
        joviandss_cmd(
            $ctx,
            [
                'pool',     $pool, 'volume',   $volname,
                'snapshot', $snap, 'rollback', 'do',
            ]
        );
    } else {
        # Blockers exist — block-level XCOPY, all snapshots preserved.
        die "xcopy rollback: VM ${vmid} is still running; "
          . "stop the VM before rolling back\n"
            if _vm_is_running($vmid);
        die "xcopy rollback: sg_xcopy not found; install sg3-utils\n"
            unless -x '/usr/bin/sg_xcopy';

        # Closure to extend the per-VM lock by another 60-second window.
        # Called after each activation, after each sg_xcopy chunk, and
        # before zero-fill.  Captures the lock identity from the outer
        # scope so run_xcopy_chunk does not need to know about locking.
        my $renew_lock = sub {
            lock_renew(
                $ctx->{storeid}, $ctx->{scfg}{path},
                $ctx->{scfg}{shared}, $vmid,
            );
        };

        eval {
            _activate_volume( $class, $ctx, $volname, undef, {} );
            $renew_lock->();

            my $vol_til = lun_record_local_get_info_list( $ctx, $volname, undef );
            die "xcopy rollback: no block device for ${volname}\n"
                unless @$vol_til;
            my ( $vtname, $vlunid, undef, $vlr ) = @{ $vol_til->[0] };
            my $vol_dev = block_device_path_from_lun_rec( $ctx, $vtname, $vlunid, $vlr );

            # If snapshot activation dies the error propagates out of this eval.
            # The cleanup block below deactivates the live volume (already activated
            # above) and re-raises the snapshot activation error.
            _activate_volume( $class, $ctx, $volname, $snap, {} );
            $renew_lock->();

            my $snap_til = lun_record_local_get_info_list( $ctx, $volname, $snap );
            die "xcopy rollback: no block device for snapshot ${snap}\n"
                unless @$snap_til;
            my ( $stname, $slunid, undef, $slr ) = @{ $snap_til->[0] };
            my $snap_dev = block_device_path_from_lun_rec( $ctx, $stname, $slunid, $slr );

            # ZFS volblocksize — used as bs= for sg_xcopy and dd.
            my $bs = clean_word( joviandss_cmd(
                $ctx,
                [ 'pool', $pool, 'volume', $volname, 'get', '-b' ],
                10, 3,
            ) ) + 0;
            die "xcopy rollback: failed to get block size for ${volname}\n"
                unless $bs > 0;

            my $snap_blocks = int( _getsize64( $ctx, $snap_dev ) / $bs );
            my $vol_blocks  = int( _getsize64( $ctx, $vol_dev  ) / $bs );

            print "Rollback: xcopy ${volname} \x{2192} ${snap}: "
                . "${snap_blocks} snap blocks, ${vol_blocks} vol blocks, "
                . "bs=${bs}\n";

            run_xcopy_chunk( $ctx, $snap_dev, $vol_dev, $bs, 0,
                             $snap_blocks, $renew_lock );

            if ( $vol_blocks > $snap_blocks ) {
                $renew_lock->();
                run_zero_chunk( $ctx, $vol_dev, $bs,
                    $snap_blocks, $vol_blocks - $snap_blocks );
            }
        };
        my $err = $@;

        # IMPORTANT: both deactivations MUST be called before leaving the XCOPY
        # path, regardless of whether the copy succeeded or failed.  The XCOPY
        # path activates the live volume and the snapshot as iSCSI block devices;
        # failing to deactivate either one leaves an orphaned iSCSI session on the
        # host.  Each call is wrapped in its own eval so that a failure of the
        # first (snapshot) never prevents the second (volume) from running.
        # _deactivate_volume is idempotent — safe to call even if the corresponding
        # activation never completed.
        # Any error from the inner eval is re-raised below after both calls finish.
        eval { _deactivate_volume( $class, $ctx, $volname, $snap, {}, {} ) };
        debugmsg( $ctx, 'warn',
            "xcopy rollback: snapshot deactivation failed: $@\n" ) if $@;

        eval { _deactivate_volume( $class, $ctx, $volname, undef, {}, {} ) };
        debugmsg( $ctx, 'warn',
            "xcopy rollback: volume deactivation failed: $@\n" ) if $@;

        # Recovery: if the copy failed, the live volume may be partially
        # overwritten.  Roll back to the most recent snapshot to restore it
        # to a clean state.  The most recent snapshot has no newer snapshots
        # after it, so ZFS rollback needs no -r and destroys nothing.
        if ( $err ) {
            eval {
                my $latest_snap = clean_word( joviandss_cmd(
                    $ctx,
                    [ 'pool', $pool, 'volume', $volname,
                      'snapshots', 'list', '--latest' ],
                    10, 3,
                ) );
                if ( $latest_snap ) {
                    debugmsg( $ctx, 'warn',
                        "xcopy rollback failed; recovering volume via "
                      . "ZFS rollback to latest snapshot ${latest_snap}\n" );
                    joviandss_cmd(
                        $ctx,
                        [
                            'pool',     $pool,        'volume',   $volname,
                            'snapshot', $latest_snap, 'rollback', 'do',
                        ]
                    );
                    print "Rollback: recovery rollback to ${latest_snap} "
                        . "complete — volume restored\n";
                }
            };
            debugmsg( $ctx, 'warn',
                "xcopy rollback: recovery rollback failed: $@\n" ) if $@;

            die $err;  # re-raises activation, copy, or zero-fill failures
        }
    }

    print "Rollback: ${volname} to snapshot ${snap} complete\n";
    debugmsg( $ctx, 'debug',
        "Volume ${volname} " . safe_var_print( 'snapshot', $snap ) . " rollback done" );
}
```

Both `_deactivate_volume` calls run unconditionally — on success, copy failure, and
activation failure. Each is wrapped in its own `eval` so that a failure of the first
(snapshot) does not prevent the second (volume) from being attempted. Both are always
tried. `_deactivate_volume` is idempotent: if the volume or snapshot was never
activated, the call is a no-op.

If the inner eval caught an error (`$err` is set), the cleanup block performs a
**recovery ZFS rollback** after both deactivations. It queries the most recent
snapshot via `jdssc snapshots list --latest` and calls `joviandss_cmd rollback do`
with that snapshot name. Because the most recent snapshot has no newer snapshots
after it, the ZFS rollback requires no `-r` flag and destroys nothing — it simply
undoes the partial XCOPY writes, restoring the volume to its state at the time of
the latest snapshot. The recovery rollback is wrapped in its own `eval` so that a
failure does not suppress the original error. After recovery (or recovery failure),
`die $err` re-raises the original error.

If no error occurred, the recovery block is skipped entirely and the rollback
completes successfully.

`_vm_is_running` and the `/usr/bin/sg_xcopy` existence check are placed in the
XCOPY branch, after the ZFS path is ruled out by `volume_rollback_check`. They are
defensive guards — Proxmox's own rollback entry point already requires the VM to be
stopped.

### `run_xcopy_chunk` helper in `Common.pm`

Copies a contiguous block range from a source device to a destination device
using `sg_xcopy` in an adaptive loop. Each `sg_xcopy` invocation is bounded by
a 50-second timeout. On timeout the chunk size is halved (granularity-aligned)
and the same offset is retried. On success the per-VM lock is renewed via the
`$renew_lock` callback (see §Lock renewal during XCOPY), the offset advances,
and the next chunk is issued. The function dies if the chunk size cannot be
reduced further or on any non-timeout error.

`$bs` is the ZFS volblocksize in bytes; `$skip` and `$count` are in units of
`$bs`. `$renew_lock` is a coderef that extends the per-VM lock by 60 seconds.

```perl
# run_xcopy_chunk($ctx, $src_dev, $dst_dev, $bs, $skip, $count, $renew_lock)
#
# Copies $count blocks from $src_dev to $dst_dev, starting at block offset
# $skip in both source and destination.  $bs is the ZFS volblocksize in bytes.
# $renew_lock is a callback (coderef) that extends the per-VM lock by another
# 60-second window; called after each successful chunk.
#
# The copy runs in an adaptive loop: each sg_xcopy call is bounded by a
# 50-second timeout.  On timeout the chunk size is halved (rounded down to
# the nearest granularity-aligned boundary) and the same offset is retried.
# On any non-timeout error the function dies immediately.
sub run_xcopy_chunk {
    my ( $ctx, $src_dev, $dst_dev, $bs, $skip, $count, $renew_lock ) = @_;

    my $timeout = 50;  # seconds per sg_xcopy invocation

    # XCOPY Data segment granularity: each segment must transfer a multiple
    # of 65536 bytes.  Keep chunk sizes aligned to this boundary.
    my $gran_blocks = int( 65536 / $bs );
    $gran_blocks = 1 if $gran_blocks < 1;          # bs >= 65536

    my $chunk_size = $count;                         # start with full range
    my $offset     = $skip;
    my $end        = $skip + $count;

    while ( $offset < $end ) {
        my $remaining  = $end - $offset;
        my $this_chunk = $chunk_size < $remaining ? $chunk_size : $remaining;

        # --on_dst (default): XCOPY command sent to the destination LUN.
        # Both LUNs are on the same JovianDSS appliance; the appliance is
        # expected to perform the copy internally (storage-side offload).
        my @cmd = (
            'sg_xcopy',
            "if=${src_dev}",
            "of=${dst_dev}",
            "bs=${bs}",
            "skip=${offset}",
            "seek=${offset}",
            "count=${this_chunk}",
            'time=1',
        );

        debugmsg( $ctx, 'debug', "xcopy: " . join( ' ', @cmd ) . "\n" );

        my $ok = eval {
            run_command(
                \@cmd,
                timeout => $timeout,
                outfunc => sub { debugmsg( $ctx, 'debug', "sg_xcopy: $_[0]\n" ) },
                errfunc => sub { debugmsg( $ctx, 'warn',  "sg_xcopy: $_[0]\n" ) },
            );
            1;
        };

        if ( $ok ) {
            debugmsg( $ctx, 'debug',
                "xcopy: offset ${offset} count ${this_chunk} complete\n" );
            $renew_lock->() if $renew_lock;
            $offset += $this_chunk;
            next;
        }

        # Timeout — halve chunk size, keep granularity alignment, retry.
        if ( $@ =~ /got timeout/ ) {
            my $new_chunk = int( $chunk_size / 2 );
            # Round down to nearest multiple of gran_blocks.
            $new_chunk = int( $new_chunk / $gran_blocks ) * $gran_blocks;
            $new_chunk = $gran_blocks if $new_chunk < $gran_blocks;

            if ( $new_chunk >= $chunk_size ) {
                # Already at minimum — cannot reduce further.
                die "xcopy rollback: timeout at offset ${offset}; chunk size "
                  . "${chunk_size} blocks is already at the granularity "
                  . "minimum (${gran_blocks}); giving up\n";
            }

            $chunk_size = $new_chunk;
            debugmsg( $ctx, 'warn',
                "xcopy: timeout at offset ${offset}, "
              . "reducing chunk to ${chunk_size} blocks\n" );
            next;   # retry same offset with smaller chunk
        }

        # Non-timeout error — propagate immediately.
        die $@;
    }
}
```

### `_getsize64` and `run_zero_chunk` helpers in `Common.pm`

`_getsize64` is a minimal wrapper around `blockdev --getsize64`. The same
invocation already exists inline in `Common.pm` (the size-wait loop at
`volume_stage_wait_size`); this extracts it as a reusable sub. It is called in
`_volume_snapshot_rollback` to read snapshot and volume sizes.

`run_zero_chunk` writes a fixed block range of zeros to a device using `dd`. It is
the zero-fill counterpart to `run_xcopy_chunk`, used when the live volume is larger
than the snapshot.

```perl
# _getsize64($ctx, $dev) — device size in bytes via blockdev --getsize64.
sub _getsize64 {
    my ( $ctx, $dev ) = @_;
    my $size;
    my $cmd = [ '/sbin/blockdev', '--getsize64', $dev ];
    run_command(
        $cmd,
        outfunc => sub {
            die "unexpected output from blockdev --getsize64: $_[0]\n"
                unless $_[0] =~ /^(\d+)$/;
            $size = int($1);
        },
        errfunc => sub { debugmsg( $ctx, 'warn', "blockdev: $_[0]\n" ) },
    );
    die "blockdev --getsize64 produced no output for ${dev}\n"
        unless defined $size;
    return $size;
}

# run_zero_chunk($ctx, $dev, $bs, $seek, $count)
#
# Writes $count blocks of zeros to $dev starting at block offset $seek.
# Used when the live volume grew after the snapshot was taken.
#
# $bs    — ZFS volblocksize in bytes (same value used in run_xcopy_chunk).
# $seek  — destination offset in blocks.
# $count — number of blocks to zero.
sub run_zero_chunk {
    my ( $ctx, $dev, $bs, $seek, $count ) = @_;

    # systemd-run --scope -p IOWeight=10: run dd in a transient systemd scope
    # with low I/O weight so zero-fill does not starve other I/O on the host.
    # dd oflag=direct bypasses page cache, ensuring data reaches the LUN.
    my @cmd = (
        'systemd-run', '--scope', '-p', 'IOWeight=10',
        'dd',
        'if=/dev/zero',
        "of=${dev}",
        "bs=${bs}",
        "seek=${seek}",
        "count=${count}",
        'oflag=direct',
    );

    debugmsg( $ctx, 'debug', "zero: " . join( ' ', @cmd ) . "\n" );

    run_command(
        \@cmd,
        outfunc => sub { debugmsg( $ctx, 'debug', "dd: $_[0]\n" ) },
        errfunc => sub { debugmsg( $ctx, 'warn',  "dd: $_[0]\n" ) },
    );
    # run_command throws on non-zero exit.
}
```

**Why `dd` and not `sg_write_same`?**

WRITE SAME (SCSI opcode `0x41` / `0x93`) can instruct the target to fill a
region with zeros without sending data over iSCSI, similar in spirit to XCOPY.
`sg_write_same` from sg3_utils would invoke it. However:

- WRITE SAME support on JovianDSS SCST targets has not been verified.
- The trailing region to zero is bounded by the volume's growth after the
  snapshot — typically a fraction of the volume's total size. The `dd` write
  traverses iSCSI but is proportional only to the grown bytes, not the full
  volume.
- `dd` is universally available and its behaviour on Linux block devices is
  well understood.

If WRITE SAME is confirmed supported on the target firmware, `run_zero_chunk`
can be replaced with a `sg_write_same` invocation for storage-side offload.

### Helper functions in `Plugin.pm`

`_vm_is_running` and the `sg_xcopy` existence check are used only within
`_volume_snapshot_rollback` and are not exported to `Common.pm`:

```perl
sub _vm_is_running {
    my ($vmid) = @_;
    return 0 unless defined $vmid;
    return PVE::QemuServer::check_running($vmid)
        || eval { require PVE::LXC; PVE::LXC::check_running($vmid) } // 0;
}
```

`run_xcopy_chunk`, `run_zero_chunk`, and `_getsize64` are defined in `Common.pm`
and must be added to its `@EXPORT` list so `Plugin.pm` can call them without a
package prefix, consistent with the existing exported helpers (`debugmsg`,
`joviandss_cmd`, `get_pool`, etc.).

---

## Call Flow

```
Proxmox Web UI / CLI
  │
  ├── volume_rollback_is_possible()               [Plugin.pm]
  │     ├── ha_state_is_defined/get()             — HA guard (only condition that blocks rollback)
  │     │     └── [HA active] → die "rollback blocked"
  │     │
  │     └── return 1  (ZFS path if no blockers, XCOPY path if blockers — both always proceed)
  │
  └── volume_snapshot_rollback()                  [Plugin.pm]
        └── _volume_snapshot_rollback_lock()
              │  [acquires single per-VM lock]
              │
              └── _volume_snapshot_rollback()
                    │
                    ├── eval { volume_rollback_check(..., force=0) }
                    │
                    ├── [zfs_ok=1: no blockers]
                    │     └── joviandss_cmd rollback do
                    │           (fast ZFS metadata rollback; no snapshots destroyed;
                    │            Proxmox snapshot records untouched)
                    │
                    └── [zfs_ok=0: blockers exist]
                          │
                          ├── _vm_is_running($vmid)?   → die "VM still running"
                          ├── -x '/usr/bin/sg_xcopy'?  → die "sg_xcopy not found"
                          │
                          ├── $renew_lock = sub { lock_renew(storeid, path, shared, vmid) }
                          │
                          ├── eval {
                          │     _activate_volume(volname, snap=undef)
                          │       └── volume_activate()    [Common.pm]
                          │             ├── volume_publish()     — REST: create volume iSCSI target
                          │             ├── volume_stage_iscsi() — iscsiadm login
                          │             └── lun_record_local_create()
                          │     $renew_lock->()                      — extend lock after vol activation
                          │
                          │     lun_record_local_get_info_list(volname, undef)
                          │       + block_device_path_from_lun_rec()   → vol_dev
                          │
                          │     _activate_volume(volname, snap=<snapname>)
                          │       └── volume_activate()    [Common.pm]
                          │             ├── volume_publish(snapname)  — REST: create snapshot target
                          │             ├── volume_stage_iscsi()      — iscsiadm login to snap target
                          │             └── lun_record_local_create()
                          │     $renew_lock->()                      — extend lock after snap activation
                          │
                          │     lun_record_local_get_info_list(volname, snapname)
                          │       + block_device_path_from_lun_rec()   → snap_dev
                          │
                          │     joviandss_cmd volume get -b            → bs (ZFS volblocksize)
                          │
                          │     _getsize64(snap_dev) → snap_blocks
                          │     _getsize64(vol_dev)  → vol_blocks
                          │
                          │     run_xcopy_chunk(snap_dev, vol_dev, bs, 0, snap_blocks, $renew_lock)
                          │       ┌── adaptive loop ──────────────────────────────────┐
                          │       │ sg_xcopy if=<snap> of=<vol> bs=<bs>              │
                          │       │         skip=<offset> seek=<offset>              │
                          │       │         count=<chunk>  timeout=50s               │
                          │       │                                                  │
                          │       │ [success]  → $renew_lock->(); offset += chunk   │
                          │       │ [timeout]  → chunk /= 2 (gran-aligned)          │
                          │       │              retry same offset                    │
                          │       │ [error]    → die immediately                     │
                          │       │ [chunk < min] → die "giving up"                  │
                          │       └──────────────────────────────────────────────────┘
                          │       JovianDSS appliance:
                          │         receives XCOPY (--on_dst default)
                          │         reads from snapshot LUN  (expected: internal)
                          │         writes to volume LUN     (expected: internal)
                          │
                          │     [vol_blocks > snap_blocks]
                          │       $renew_lock->()              — extend lock before zero-fill
                          │       run_zero_chunk(vol_dev, bs, snap_blocks, vol_blocks-snap_blocks)
                          │         systemd-run --scope -p IOWeight=10
                          │           dd if=/dev/zero of=<vol_dev> bs=<bs>
                          │              seek=<snap_blocks> count=<delta> oflag=direct
                          │   };
                          │   $err = $@
                          │
                          ├── eval { _deactivate_volume(volname, snap=<snapname>) }
                          │     └── volume_deactivate()              [Common.pm]
                          │           ├── iscsiadm logout (snap target)
                          │           ├── volume_unstage_multipath()   — (if multipath=1)
                          │           ├── volume_unpublish(snapname)   — REST: remove snap target
                          │           └── lun_record_local_delete()
                          │           deactivation error → logged at warn, not re-raised
                          │
                          ├── eval { _deactivate_volume(volname, snap=undef) }
                          │     └── volume_deactivate()              [Common.pm]
                          │           ├── iscsiadm logout (volume target)
                          │           ├── volume_unstage_multipath()   — (if multipath=1)
                          │           ├── volume_unpublish()           — REST: remove volume target
                          │           └── lun_record_local_delete()
                          │           deactivation error → logged at warn, not re-raised
                          │
                          ├── [err set] → recovery ZFS rollback
                          │     eval {
                          │       joviandss_cmd snapshots list --latest  → latest_snap
                          │       joviandss_cmd snapshot <latest_snap> rollback do
                          │     }
                          │     recovery error → logged at warn, not re-raised
                          │
                          └── die $err  (re-raise XCOPY error if any)
```

---

## Preconditions and Safety

### VM must be offline

XCOPY overwrites the live volume's block device. If a guest OS is simultaneously
reading or writing through iSCSI, the copy produces a torn, inconsistent image.

Proxmox's own rollback entry point (`PVE::AbstractConfig::snapshot_rollback`) already
refuses to roll back a running VM. The `_vm_is_running` check in
`_volume_snapshot_rollback` is a defensive guard to ensure a meaningful error message
if the path is reached unexpectedly.

### HA guard — unchanged

The HA guard in `volume_rollback_is_possible` (checks `ha_state_get`, refuses if state
is not `ignored`) applies regardless of rollback method and is retained without change.

### Live volume already activated

When a VM shuts down cleanly, Proxmox calls `deactivate_volume` for each disk.
When rollback is initiated, `_activate_volume` re-activates the volume. If the volume
is still active from a prior session (e.g. after an ungraceful shutdown),
`_activate_volume` detects the existing LUN record and skips re-publishing, performing
a block device path check only. Both cases are handled correctly by the existing
implementation.

### Snapshot and volume are on the same appliance

The JovianDSS Proxmox plugin connects to a single appliance per storage instance.
A snapshot always lives on the same appliance as its parent volume. Both iSCSI LUNs
therefore reside on the same appliance, which is the required precondition for
storage-side XCOPY offload. No cross-appliance case can arise.

### Volume size at rollback time vs snapshot time

The snapshot represents the volume state at snapshot time. If the volume was resized
after the snapshot:

- **Volume grew after snapshot**: `_volume_snapshot_rollback` reads `$snap_blocks`
  and `$vol_blocks` separately via `_getsize64`. The `run_xcopy_chunk` call is
  bounded by `$snap_blocks`; no block beyond the snapshot boundary is touched by
  XCOPY. After XCOPY completes, `run_zero_chunk` writes zeros over the trailing
  region so the live volume presents a clean image.

- **Volume shrunk after snapshot** (not supported by the plugin — iSCSI LUNs cannot
  be shrunk): `$snap_blocks` would exceed `$vol_blocks`; the XCOPY `count` would
  reference blocks past the live volume's end. `sg_xcopy` would fail. This case
  cannot arise in practice but is noted for completeness.

---

## Failure Handling

### `_activate_volume` fails for live volume

The volume cannot be brought online (REST error, iSCSI login failure). The error is
caught by the inner eval. The cleanup block runs unconditionally: both deactivations
are attempted (both are no-ops since nothing was activated). Recovery rollback is
attempted (no-op since no data was written). `die $err` re-raises the activation
error — rollback fails.

### `_activate_volume` fails for snapshot

The snapshot iSCSI session could not be established. The live volume was already
activated at this point. The error is caught by the inner eval and saved as `$err`.
The cleanup block then:

1. Attempts `_deactivate_volume(..., $snap, ...)` — no-op (snapshot was never activated).
2. Attempts `_deactivate_volume(..., undef, ...)` — deactivates the live volume.
3. Recovery rollback — no-op in effect (no data was written to the volume).

`die $err` re-raises the exact error returned by the snapshot activation call.
No copy or zero-fill is attempted.

### `jdssc volume get -b` fails (block size unavailable)

`joviandss_cmd` throws. The error is caught by the inner eval. Both deactivations
run (snapshot and volume were both activated by this point). Recovery rollback runs
but is a no-op in effect (no data was written). `die $err` re-raises the error.
No copy or zero-fill is attempted.

### `sg_xcopy` timeout — adaptive retry

`run_command` throws on timeout (50 seconds). `run_xcopy_chunk` catches the timeout,
halves the chunk size (rounded down to the nearest granularity-aligned boundary),
and retries the same offset. This repeats until:

- The chunk completes within the timeout → offset advances, next chunk is issued.
- The chunk size reaches the granularity minimum and still times out →
  `run_xcopy_chunk` dies. The error propagates out of the inner eval. Both
  deactivations run. Recovery rollback restores the volume to the latest snapshot
  (undoes partial writes). `die $err` re-raises.

### `sg_xcopy` fails (non-timeout error)

`run_command` throws on non-zero exit (I/O error, SCSI error). `run_xcopy_chunk`
propagates the error immediately without retrying. The exception is caught by the
inner eval. Both deactivations run. Recovery rollback restores the volume to the
latest snapshot (undoes partial writes). `die $err` re-raises.

The snapshot chain is completely intact. The operator can retry the XCOPY rollback
from the beginning after investigating the failure.

### Zero-fill fails

`run_zero_chunk` throws. The exception is caught by the inner eval as above.
Both deactivations run. Recovery rollback restores the volume to the latest snapshot,
undoing both the completed XCOPY blocks and the partial zero-fill. The volume is
returned to a clean, consistent state.

**Note:** If recovery rollback succeeds, the volume is fully restored and no manual
intervention is needed. If recovery rollback also fails (both errors are logged),
the volume remains in a partially written state — operator should manually
investigate.

### Deactivation fails in cleanup

Each deactivation call is wrapped in its own `eval`. If snapshot deactivation fails,
volume deactivation is still attempted. If volume deactivation fails, the snapshot
deactivation result is unaffected. Both failures are logged at `warn` level and not
re-raised. The recovery rollback (if needed) proceeds regardless.

Orphaned iSCSI sessions will be torn down when the node reboots or when
`deactivate_volume` is called explicitly. No data inconsistency results.

### Recovery rollback fails

The recovery ZFS rollback is wrapped in its own `eval`. If it fails (REST error,
appliance unreachable), the error is logged at `warn` level but does not suppress
the original XCOPY error. The live volume remains in a partially overwritten state.
The operator should:

1. Restore connectivity to the JovianDSS appliance if needed.
2. Manually roll back to the latest snapshot:
   ```
   jdssc pool <pool> volume <volname> snapshot <latest_snap> rollback do
   ```
3. Retry the original rollback operation.

---

## Performance

### Transfer rate

XCOPY between two LUNs on the same JovianDSS appliance is expected to be
storage-side offloaded, bounding transfer rate by appliance internal storage bandwidth
rather than iSCSI link speed.

| Method | 100 GiB volume, 1 Gbit/s iSCSI |
|---|---|
| ZFS rollback (current) | < 1 s (metadata only) |
| XCOPY offloaded (proposed, if offload confirmed) | seconds to minutes (appliance storage I/O) |
| `dd` over iSCSI (for comparison) | ~1600 s (network limited) |

### Zero-fill traverses iSCSI

When a volume grew after the snapshot, `run_zero_chunk` uses `dd` to write zeros
over the trailing region. This data does cross the iSCSI link. The written region
is bounded by the volume's growth after the snapshot (not the full volume size),
so the overhead is proportional to the resize delta.

If `sg_write_same` is confirmed supported by the target firmware it would eliminate
this traffic; `run_zero_chunk` is isolated for easy substitution.

---

## Comparison: ZFS Rollback vs XCOPY Rollback

| Property | ZFS rollback (current) | XCOPY rollback (proposed) |
|---|---|---|
| Snapshot chain after rollback | All newer snapshots destroyed | All snapshots preserved |
| Copy speed | < 1 s (metadata only) | Seconds to minutes (full data copy) |
| Data traverses iSCSI | No | XCOPY: expected no (offloaded); zero-fill: yes (host-side `dd`, proportional to resize delta) |
| VM must be offline | Yes (Proxmox requirement) | Yes (data consistency) |
| `force_rollback` tag required | Yes (when newer snapshots exist) | Not needed |
| Clone blockers block rollback | Yes | No |
| Proxmox config patching | Required (strip deleted snapshot sections) | Not required |
| HA guard | Required | Required (unchanged) |
| Blocker check in `volume_rollback_is_possible` | Required | Not performed — blockers are handled transparently (ZFS or XCOPY path) |
| Temporary iSCSI targets | No | Yes — snapshot and live volume both activated at XCOPY start and unconditionally deactivated at XCOPY exit |
| Volume grew after snapshot | ZFS rollback handles naturally | XCOPY copies snapshot range; trailing blocks zeroed by `run_zero_chunk` |
| XCOPY timeout handling | N/A | Adaptive chunking: 50 s timeout per sg_xcopy call; chunk halved on timeout; dies at granularity minimum |
| jdssc changes | None | New `-b` flag on `volume get`; new `--latest` flag on `snapshots list` |
| Residual state on failure | None | Both sessions deactivated; recovery ZFS rollback to latest snapshot restores volume to clean state |
| Lock per operation | One lock for entire rollback | One lock for entire rollback (same as ZFS path); `lock_renew` called after each activation and each XCOPY chunk to prevent 60 s expiry |
| Progress reporting | None | Printed before xcopy and zero-fill calls |

---

## Limitations

1. **Offline-only.** The VM must be stopped. Online non-destructive rollback would
   require a filesystem-level freeze and is out of scope.

2. **Same-appliance only.** Both LUNs must be on the same JovianDSS appliance. The
   plugin's single-appliance-per-storage-instance model guarantees this.

3. **XCOPY offload not empirically verified.** `3PC=1` confirms XCOPY is accepted.
   Storage-side offload — data not traversing iSCSI — has not been measured. It
   should be verified before relying on the performance estimate.

4. **`sg3-utils` runtime dependency.** The `sg_xcopy` binary is already in the
   plugin's listed runtime dependencies. This design formalises its use.

5. **Zero-fill traverses iSCSI.** When a volume grew after the snapshot,
   `run_zero_chunk` (`systemd-run … dd if=/dev/zero`) writes zeros over the
   trailing region. This data crosses the iSCSI link. The written region is bounded
   by the volume's growth (not the full volume size), so the overhead is proportional
   to the resize delta. If `sg_write_same` is confirmed supported by the target
   firmware it would eliminate this traffic; `run_zero_chunk` is isolated for easy
   substitution.

6. **VPD truncation warning is non-fatal.** The "designator too long" warning from
   JovianDSS VPD page 0x83 appears on every invocation. Cosmetic; copy succeeds.

7. **Recovery rollback on failure.** If the XCOPY adaptive loop or zero-fill fails,
   the volume may be partially overwritten. The cleanup block performs a recovery ZFS
   rollback to the volume's most recent snapshot, restoring it to a clean state. If
   the recovery rollback itself fails (appliance unreachable, REST error), the volume
   remains partially overwritten and the operator must manually roll back. The
   snapshot chain is always intact, so retry is safe after recovery.

8. **No checkpoint or partial-resume.** The adaptive loop retries timed-out chunks
   by halving the chunk size, but does not checkpoint progress across separate
   rollback invocations. If the entire rollback fails and is retried, the copy
   restarts from offset 0.

---

## Files

| File | Changes |
|---|---|
| `OpenEJovianDSSPlugin.pm` | Adapt `volume_rollback_is_possible` (HA guard only; always returns 1); unified `_volume_snapshot_rollback` (ZFS and XCOPY paths, `$renew_lock` closure, recovery rollback on failure); new `_vm_is_running` helper |
| `OpenEJovianDSS/Common.pm` | New `run_xcopy_chunk` (adaptive loop with timeout and lock renewal), `run_zero_chunk`, `_getsize64` helpers (exported) |
| `OpenEJovianDSS/Lock.pm` | New `lock_renew` function (exported): resets `alarm(60)` and touches pmxcfs lock directory |
| `jdssc/jdssc/volume.py` | New `-b` / `--block-size` flag in `get` subparser and `get` action |
| `jdssc/jdssc/snapshots.py` | New `--latest` flag in `list` subparser and `list` action |
| `jdssc/jdssc/jovian_common/driver.py` | `get_volume` returns `volblocksize` from REST response |

---

## Dependencies

| Component | Used for | Notes |
|---|---|---|
| `sg3-utils` (`sg_xcopy`) | Block-level XCOPY between iSCSI LUNs | Already in plugin runtime deps |
| `activate_volume` / `_activate_volume` | Bring snapshot and volume online as block devices | Existing method, no changes |
| `deactivate_volume` / `_deactivate_volume` | Tear down snapshot and volume iSCSI sessions on XCOPY exit (unconditional, each in its own eval) | Existing method, no changes |
| `lun_record_local_get_info_list` | Locate LUN record after activation | Existing `Common.pm` function |
| `block_device_path_from_lun_rec` | Resolve block device path from LUN record | Existing `Common.pm` function |
| `jdssc volume get -b` | Retrieve ZFS `volblocksize` for `bs=` in `sg_xcopy` and `dd` | New flag, minimal jdssc change |
| `jdssc snapshots list --latest` | Retrieve name of the most recent snapshot for recovery rollback | New flag, minimal jdssc change |
| `lock_renew` | Extend per-VM lock lifetime during long-running XCOPY; resets `alarm(60)` and touches pmxcfs lock directory | New function in `Lock.pm` (exported) |
| `PVE::Tools::run_command` | Execute `sg_xcopy` and `systemd-run … dd` as subprocesses | Standard Proxmox tool |
| `blockdev --getsize64` | Read block device size in bytes for snap and volume size calculation | Already used in `Common.pm`; extracted into `_getsize64` |
| `systemd-run --scope -p IOWeight=10 dd` | Zero-fill trailing blocks when volume grew post-snapshot | `systemd-run` part of `systemd`; `dd` part of `coreutils`; both universally available on Proxmox VE |
