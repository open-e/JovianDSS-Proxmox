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

The XCOPY copy runs in an adaptive loop with a configurable initial chunk size
(`xcopy_size` property, default 16 GiB): each `sg_xcopy` invocation is bounded
by a 50-second timeout; on timeout the per-VM lock is renewed, the chunk size
is halved, and the same offset is retried. The reduced chunk size applies to
all subsequent offsets. If the copy fails despite retries, a recovery ZFS
rollback to the volume's most recent snapshot restores it to a clean state.

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

Include `creation` in the returned dict. The REST API returns `creation`
timestamps via `_list_volume_snapshots`, but `list_snapshots` previously
stripped all fields except `name`. Without `creation`, the `--latest` flag
in `snapshots.py` cannot determine which snapshot is most recent.

```python
vid = jcom.vid_from_sname(r['name'])
if vid == volume_name or vid is None:
    entry = {'name': jcom.sid_from_sname(r['name'])}
    if 'creation' in r:
        entry['creation'] = r['creation']
    ret.append(entry)
```

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

- Dies with backend/command error (snapshot missing, appliance unreachable,
  `jdssc` failure) → **re-raised immediately**. The error message from
  `volume_rollback_check` is prefixed with "Unable to rollback"; this prefix
  is used to distinguish backend failures from blocker detection. XCOPY is
  never attempted when the check itself fails.

- Dies with blocker message (newer snapshots or clones prevent ZFS rollback) →
  **XCOPY path**: the snapshot and live volume are each activated as independent
  block devices, `sg_xcopy` copies the snapshot content to the live volume in
  an adaptive loop (see §Adaptive chunking below), and both the snapshot and
  the live volume are deactivated on exit (unconditionally, whether copy
  succeeded or failed). If the copy fails for any reason, a recovery ZFS
  rollback to the volume's most recent snapshot is performed after deactivation
  to undo any partial writes. All snapshots on the appliance survive.

No configuration flag controls this selection. The path is determined entirely
by the runtime state of the snapshot chain.

### Adaptive chunking

`run_xcopy_chunk` copies the snapshot data to the live volume in a loop. The
initial chunk size is derived from the `xcopy_size` storage property (default
16 GiB), converted to blocks by the caller (`xcopy_size * 1 GiB / bs`).
`run_xcopy_chunk` aligns the initial chunk size to the XCOPY granularity
internally. If the total block count is smaller than this value, the total
count is used instead.

Each `sg_xcopy` invocation is bounded by a 50-second timeout. If a timeout
fires, the per-VM lock is renewed (the timed-out invocation consumed up to
50 s of the 60 s alarm window), the chunk size is halved (rounded down to the
nearest granularity-aligned block count), and the same offset is retried with
the smaller chunk. The reduced chunk size is permanent — all subsequent offsets
use the smaller size, since a timeout indicates the storage cannot sustain the
larger transfer within the time budget. The process repeats until all blocks
are copied or the chunk size cannot be reduced further, at which point the
function dies.

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
`run_xcopy_chunk`. The closure is called **both before and after** every
`joviandss_cmd`-involving operation — activations, direct `joviandss_cmd`
calls, deactivations, and recovery calls. The pattern is:

```perl
$renew_lock->();     # before: reset alarm to give the full 60-second window
<joviandss_cmd …>;  # the operation itself
$renew_lock->();     # after:  reset again so the next operation also starts fresh
```

**Why before, not just after?** `joviandss_cmd` carries its own timeout and
retry parameters (e.g., `10 s × 3 retries`). If only a few seconds remain on
the alarm window when the call is made, `SIGALRM` fires mid-execution and
kills the entire rollback. Calling `$renew_lock` immediately before each
operation resets `alarm(60)` and guarantees the full 60-second budget is
available for that one call. The post-call renewal then resets the window again
for whatever comes next, preventing accumulated drift from previous work from
reducing the budget of the subsequent operation.

**Why after as well?** A jdssc call that succeeds near the end of its allotted
time leaves only the remaining seconds on the alarm. The following operation —
another jdssc call, a `blockdev --getsize64`, or the entry into
`run_xcopy_chunk` — starts without a full window unless the alarm is reset
after the previous call completes.

The complete list of renewal points in `_volume_snapshot_rollback`:

- **Before and after** `_activate_volume(volname, undef)` (live volume
  activation — involves REST target creation and `iscsiadm` login).
- **Before and after** `_activate_volume(volname, snap)` (snapshot activation
  — same REST + iSCSI sequence).
- **Before** `joviandss_cmd volume get -b` (resets alarm before the jdssc
  call; post-call renewal is provided by the `xcopy_sha1sum` pre-call below).
- **Before** each `xcopy_sha1sum` call — the hash read spans the full snapshot
  byte range, which can take minutes for large volumes. `xcopy_sha1sum` also
  calls `$renew_lock` after each internal read chunk (see §`xcopy_sha1sum`
  helper below).
- **Before** `run_zero_chunk` (renews before entering the zero-fill loop, after
  the hash verification completes).
- **Before and after** `_deactivate_volume(volname, snap)` (cleanup —
  involves REST target removal and iSCSI logout).
- **Before and after** `_deactivate_volume(volname, undef)` (cleanup — same).
- **Before** each `joviandss_cmd` in the recovery block (`snapshots list
  --latest` and `snapshot rollback do`).

Inside the adaptive loops:

- After each successful `sg_xcopy` chunk (`run_xcopy_chunk`).
- After each `sg_xcopy` timeout, before retrying with a smaller chunk (the
  timed-out invocation consumed up to 50 s of the 60 s alarm window;
  without renewal the retry would `SIGALRM` almost immediately).
- After each successful read chunk inside `xcopy_sha1sum`.
- After each successful `dd` chunk (`run_zero_chunk`).
- After each `dd` timeout, before retrying with a smaller chunk (same
  rationale as the `sg_xcopy` timeout case).

Each call extends the lock by another 60-second window. Individual operations
(one activation call, one `sg_xcopy` chunk, one `dd` chunk) must still
complete within 60 seconds — only the cumulative duration is unbounded.

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
        my $lockid = defined $vmid
            ? "vm-" . _sanitize_lockid($vmid)
            : 'storage';
        my $sid = _sanitize_lockid($storeid);
        my $lockpath = _cluster_lockdir() . "/joviandss-${sid}-${lockid}";
        utime( undef, undef, $lockpath );
    }
}
```

The lockpath construction reuses `_cluster_lockdir()` and `_sanitize_lockid()` — the
same helpers used by `_cluster_lock` — to guarantee the path matches the directory
created during lock acquisition.

The function must be added to `@EXPORT_OK` in `Lock.pm` so callers in `Plugin.pm`
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

        if (($hastate ne 'ignored')) {
            my $resource_type = ha_type_get($ctx, $vmid);
            print "vmid ${vmid}: HA check failed — managed by HA (state: ${hastate})\n";
            my $msg =
              "Rollback blocked: ${resource_type}:${vmid} is controlled by"
              . " High Availability (state: ${hastate}).\n"
              . "Rollback requires temporary manual control to prevent HA"
              . " from restarting or moving the resource.\n"
              . "Disable HA management before retrying:\n"
              . "Web UI: Datacenter -> HA -> Resources -> set state to ignored\n"
              . "CLI: ha-manager set ${resource_type}:${vmid} --state ignored\n";
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

    print "starting rollback of ${volname} to snapshot ${snap}\n";
    debugmsg( $ctx, 'debug',
        "Volume ${volname} " . safe_var_print( 'snapshot', $snap ) . " rollback start" );

    my $zfs_ok = eval {
        volume_rollback_check( $ctx, $vmid, $volname, $snap, undef, 0 )
    };
    my $check_err = $@;

    # volume_rollback_check dies for two reasons:
    #   1. Backend/command failure (snapshot missing, appliance unreachable,
    #      jdssc error) — prefixed with "Unable to rollback".
    #   2. Blockers exist (newer snapshots or clones prevent ZFS rollback).
    # Only case 2 should fall through to XCOPY.  Case 1 must be re-raised
    # immediately — proceeding with XCOPY on a backend error could overwrite
    # the live volume when the real problem is connectivity or a missing
    # snapshot.
    if ( $check_err && $check_err =~ /^Unable to rollback/ ) {
        die $check_err;
    }

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
        # Called BEFORE and AFTER every joviandss_cmd-involving operation
        # (activations, direct jdssc calls, deactivations, recovery calls).
        # "Before" resets alarm(60) to give the full window to the upcoming
        # call.  "After" resets it again so the next operation also starts
        # with a full budget.  Also called after each sg_xcopy/dd chunk
        # success or timeout inside the adaptive loops.  Captures the lock
        # identity from the outer scope so helpers do not need to know about
        # locking.
        my $renew_lock = sub {
            lock_renew(
                $ctx->{storeid}, $ctx->{scfg}{path},
                $ctx->{scfg}{shared}, $vmid,
            );
        };

        eval {
            $renew_lock->();
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
            $renew_lock->();
            _activate_volume( $class, $ctx, $volname, $snap, {} );
            $renew_lock->();

            my $snap_til = lun_record_local_get_info_list( $ctx, $volname, $snap );
            die "xcopy rollback: no block device for snapshot ${snap}\n"
                unless @$snap_til;
            my ( $stname, $slunid, undef, $slr ) = @{ $snap_til->[0] };
            my $snap_dev = block_device_path_from_lun_rec( $ctx, $stname, $slunid, $slr );

            # ZFS volblocksize — used as bs= for sg_xcopy and dd.
            # Renew before the jdssc call so it starts with a full 60-second
            # alarm window regardless of time consumed by activations above.
            $renew_lock->();
            my $bs = clean_word( joviandss_cmd(
                $ctx,
                [ 'pool', $pool, 'volume', $volname, 'get', '-b' ],
                10, 3,
            ) ) + 0;
            die "xcopy rollback: failed to get block size for ${volname}\n"
                unless $bs > 0;

            my $snap_blocks = int( xcopy_getsize64( $ctx, $snap_dev ) / $bs );
            my $vol_blocks  = int( xcopy_getsize64( $ctx, $vol_dev  ) / $bs );

            # xcopy_size is in GiB; convert to blocks.
            my $xcopy_gib    = get_xcopy_size($ctx);
            my $max_chunk    = int( $xcopy_gib * 1024 * 1024 * 1024 / $bs );
            $max_chunk = 1 if $max_chunk < 1;

            # sg_xcopy requires each segment to transfer a whole number of
            # 65536-byte granularity units.  Very small volumes (e.g. 528K
            # EFI vars disks) can fail with "not enough data to read".
            # Strategy: volumes under 1 MiB skip XCOPY entirely and use dd.
            my $snap_bytes = $snap_blocks * $bs;

            if ( $snap_bytes < 1048576 ) {
                # Too small — go straight to dd.
                print "dd copy ${volname} -> ${snap}: "
                    . "${snap_blocks} snap blocks (volume too small for "
                    . "XCOPY, using dd)\n";

                run_dd_copy( $ctx, $snap_dev, $vol_dev, $bs,
                             $snap_blocks, $renew_lock );
            } else {
                print "xcopy ${volname} -> ${snap}: "
                    . "${snap_blocks} snap blocks, ${vol_blocks} vol blocks, "
                    . "bs=${bs}, xcopy_size=${xcopy_gib} GiB\n";

                run_xcopy_chunk( $ctx, $snap_dev, $vol_dev, $bs, 0,
                                 $snap_blocks, $max_chunk, $renew_lock );
            }

            # Verify the copy: SHA1 of the first snap_blocks×bs bytes of
            # the snapshot and the volume must match.  The zero-filled
            # trailing region (when vol_blocks > snap_blocks) is excluded
            # from the comparison — it is not part of the snapshot content
            # and its SHA1 is trivially equal on both sides.
            # xcopy_sha1sum renews the lock after each 512 MiB read chunk
            # so the per-VM lock does not expire during verification of
            # large volumes.
            print "sha1 verify ${volname} <- ${snap}: "
                . "computing snapshot hash "
                . "(${snap_blocks} blocks × ${bs} B)...\n";
            $renew_lock->();
            my $snap_sha1 = xcopy_sha1sum(
                $ctx, $snap_dev, $bs, $snap_blocks, $renew_lock );
            debugmsg( $ctx, 'debug',
                "sha1sum snap ${snap}: ${snap_sha1}\n" );

            print "sha1 verify: computing volume hash...\n";
            $renew_lock->();
            my $vol_sha1 = xcopy_sha1sum(
                $ctx, $vol_dev, $bs, $snap_blocks, $renew_lock );
            debugmsg( $ctx, 'debug',
                "sha1sum vol ${volname}: ${vol_sha1}\n" );

            die "xcopy rollback: SHA1 mismatch after copy — "
              . "snapshot=${snap_sha1} volume=${vol_sha1}; "
              . "volume content does not match snapshot\n"
                unless $snap_sha1 eq $vol_sha1;

            print "sha1 verify OK (${snap_sha1}): "
                . "${volname} matches snapshot ${snap}\n";

            if ( $vol_blocks > $snap_blocks ) {
                $renew_lock->();
                # Use 512 MiB chunks for zero-fill so each dd finishes
                # well within the 60-second lock alarm window even
                # under IOWeight=10 throttling.  $max_chunk (xcopy_size)
                # can be up to 16 GiB which would run a single dd for
                # minutes, causing alarm timeout before lock_renew is
                # called.  If 512 MiB still times out, run_zero_chunk
                # will adaptively halve the chunk size.
                my $zero_chunk = int( 512 * 1024 * 1024 / $bs );
                $zero_chunk = 1 if $zero_chunk < 1;
                run_zero_chunk( $ctx, $vol_dev, $bs,
                    $snap_blocks, $vol_blocks - $snap_blocks,
                    $zero_chunk, $renew_lock );
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
        # Lock is renewed before and after each deactivation — deactivation involves
        # REST calls and iSCSI logout which can consume much of the 60-second window.
        $renew_lock->();
        eval { _deactivate_volume( $class, $ctx, $volname, $snap, {}, {} ) };
        $renew_lock->() unless $@;
        debugmsg( $ctx, 'warn',
            "xcopy rollback: snapshot deactivation failed: $@\n" ) if $@;

        $renew_lock->();
        eval { _deactivate_volume( $class, $ctx, $volname, undef, {}, {} ) };
        $renew_lock->() unless $@;
        debugmsg( $ctx, 'warn',
            "xcopy rollback: volume deactivation failed: $@\n" ) if $@;

        # Recovery: if the copy failed, the live volume may be partially
        # overwritten.  Roll back to the most recent snapshot to restore it
        # to a clean state.  The most recent snapshot has no newer snapshots
        # after it, so ZFS rollback needs no -r and destroys nothing.
        if ( $err ) {
            eval {
                $renew_lock->();
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
                    $renew_lock->();
                    joviandss_cmd(
                        $ctx,
                        [
                            'pool',     $pool,        'volume',   $volname,
                            'snapshot', $latest_snap, 'rollback', 'do',
                        ]
                    );
                    print "recovery rollback to ${latest_snap} "
                        . "complete — volume restored\n";
                }
            };
            debugmsg( $ctx, 'warn',
                "xcopy rollback: recovery rollback failed: $@\n" ) if $@;

            die $err;  # re-raises activation, copy, or zero-fill failures
        }
    }

    print "${volname} to snapshot ${snap} rollback complete\n";
    debugmsg( $ctx, 'debug',
        "Volume ${volname} " . safe_var_print( 'snapshot', $snap ) . " rollback done" );
}
```

Both `_deactivate_volume` calls run unconditionally — on success, copy failure, and
activation failure. Each is wrapped in its own `eval` so that a failure of the first
(snapshot) does not prevent the second (volume) from being attempted. Both are always
tried. `_deactivate_volume` is idempotent: if the volume or snapshot was never
activated, the call is a no-op.

Each deactivation is bracketed by `$renew_lock->()` calls — before to give the full
60-second alarm window for the REST + iSCSI logout sequence, and after (on success
only; on failure the deactivation error is logged and the next `$renew_lock` call
before the following deactivation covers the reset) so the subsequent operation
also starts with a fresh window.

If the inner eval caught an error (`$err` is set) — including a SHA1 mismatch
— the cleanup block performs a **recovery ZFS rollback** after both
deactivations. It queries the most recent snapshot via
`jdssc snapshots list --latest` and calls `joviandss_cmd rollback do` with that
snapshot name. Each `joviandss_cmd` call in the recovery block is preceded by
`$renew_lock->()` for the same reason as all other jdssc calls: the total time
for a retriable jdssc invocation can exceed what remains on the alarm window
without a reset. Because the most recent snapshot has no newer snapshots after
it, the ZFS rollback requires no `-r` flag and destroys nothing — it simply
undoes any partial XCOPY writes, restoring the volume to a clean state. The
recovery rollback is wrapped in its own `eval` so that a failure does not
suppress the original error. After recovery (or recovery failure), `die $err`
re-raises the original error.

If no error occurred, the recovery block is skipped entirely and the rollback
completes successfully.

`_vm_is_running` and the `/usr/bin/sg_xcopy` existence check are placed in the
XCOPY branch, after the ZFS path is ruled out by `volume_rollback_check`. They are
defensive guards — Proxmox's own rollback entry point already requires the VM to be
stopped.

### `run_xcopy_chunk` helper in `Common.pm`

Copies a contiguous block range from a source device to a destination device
using `sg_xcopy` in an adaptive loop. Each `sg_xcopy` invocation is bounded by
a 50-second timeout. On timeout the per-VM lock is renewed (to recover the
alarm budget consumed by the timed-out call), the chunk size is halved
(granularity-aligned), and the same offset is retried. On success the per-VM
lock is renewed via the `$renew_lock` callback (see §Lock renewal during
XCOPY), the offset advances, and the next chunk is issued. The function dies
if the chunk size cannot be reduced further or on any non-timeout error.

`$bs` is the ZFS volblocksize in bytes; `$skip` and `$count` are in units of
`$bs`. `$max_chunk` is the initial (maximum) chunk size in blocks, derived from
the `xcopy_size` storage property (GiB converted to blocks by the caller).
`$renew_lock` is a coderef that extends the per-VM lock by 60 seconds.

```perl
# run_xcopy_chunk($ctx, $src_dev, $dst_dev, $bs, $skip, $count,
#                 $max_chunk, $renew_lock)
#
# Copies $count blocks from $src_dev to $dst_dev, starting at block offset
# $skip in both source and destination.  $bs is the ZFS volblocksize in bytes.
# $max_chunk is the initial chunk size in blocks (from xcopy_size config
# property, GiB→blocks conversion done by the caller).
# $renew_lock is a callback (coderef) that extends the per-VM lock by another
# 60-second window; called after each successful chunk and after each timeout
# (before retry, since the timed-out call consumed most of the alarm budget).
#
# The copy runs in an adaptive loop: each sg_xcopy call is bounded by a
# 50-second timeout.  On timeout the chunk size is halved (rounded down to
# the nearest granularity-aligned boundary) and the same offset is retried.
# The reduced chunk size is permanent for all subsequent offsets.
# On any non-timeout error the function dies immediately.
sub run_xcopy_chunk {
    my ( $ctx, $src_dev, $dst_dev, $bs, $skip, $count,
         $max_chunk, $renew_lock ) = @_;

    my $timeout = 50;  # seconds per sg_xcopy invocation

    # XCOPY Data segment granularity: each segment must transfer a multiple
    # of 65536 bytes.  Keep chunk sizes aligned to this boundary.
    my $gran_blocks = int( 65536 / $bs );
    $gran_blocks = 1 if $gran_blocks < 1;          # bs >= 65536

    # Start with $max_chunk (from xcopy_size property) or $count, whichever
    # is smaller.  Align to granularity.
    my $chunk_size = $max_chunk < $count ? $max_chunk : $count;
    $chunk_size = int( $chunk_size / $gran_blocks ) * $gran_blocks;
    $chunk_size = $gran_blocks if $chunk_size < $gran_blocks;
    my $offset     = $skip;
    my $end        = $skip + $count;
    my $total      = $count || 1;                    # avoid division by zero

    while ( $offset < $end ) {
        my $remaining  = $end - $offset;
        my $this_chunk = $chunk_size < $remaining ? $chunk_size : $remaining;

        my $pct = int( ( $offset - $skip ) * 100 / $total );
        print "xcopy ${pct}% (block ${offset}/${end})\n";

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
            'prio=0',
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
            # Renew lock before retrying — the timed-out sg_xcopy consumed
            # up to 50 s of the 60 s alarm window; without renewal the
            # retry would SIGALRM almost immediately.
            $renew_lock->() if $renew_lock;
            next;   # retry same offset with smaller chunk
        }

        # Non-timeout error — propagate immediately.
        die $@;
    }

    print "xcopy 100% (${total} blocks copied)\n";
}
```

### `run_dd_copy` helper in `Common.pm`

Copies `$count` blocks from a source device to a destination device using a
single `dd` invocation with `iflag=direct oflag=direct`. Used as a fallback
when the volume is too small for `sg_xcopy` (under 1 MiB). Unlike
`run_xcopy_chunk` this is a single invocation — small volumes complete
instantly and do not need adaptive chunking or timeout handling.

```perl
# run_dd_copy($ctx, $src_dev, $dst_dev, $bs, $count, $renew_lock)
#
# Copies $count blocks from $src_dev to $dst_dev using dd.  Used as a
# fallback when the volume is too small for sg_xcopy.
#
# Unlike run_xcopy_chunk this is a single dd invocation — small volumes
# complete instantly and do not need adaptive chunking.
sub run_dd_copy {
    my ( $ctx, $src_dev, $dst_dev, $bs, $count, $renew_lock ) = @_;

    my @cmd = (
        'dd',
        "if=${src_dev}",
        "of=${dst_dev}",
        "bs=${bs}",
        "count=${count}",
        'iflag=direct',
        'oflag=direct',
    );

    debugmsg( $ctx, 'debug', "dd copy: " . join( ' ', @cmd ) . "\n" );

    run_command(
        \@cmd,
        outfunc => sub { debugmsg( $ctx, 'debug', "dd: $_[0]\n" ) },
        errfunc => sub { debugmsg( $ctx, 'warn',  "dd: $_[0]\n" ) },
    );
    # run_command throws on non-zero exit.

    $renew_lock->() if $renew_lock;
    print "dd copy 100% (${count} blocks copied)\n";
}
```

**Why 1 MiB threshold?**

`sg_xcopy` fails with "not enough data to read (min 65536 bytes)" on very
small volumes. The XCOPY Data segment granularity is 65536 bytes; with a
typical `volblocksize` of 16384, the granularity alignment rounds down block
counts (e.g. 33 blocks → 32) and the resulting transfer can be rejected by
`sg_xcopy`. Rather than trying to predict the exact minimum viable XCOPY
size (which depends on the interaction between `volblocksize`, device logical
sector size, and the XCOPY implementation), a conservative 1 MiB threshold
avoids the issue entirely. Volumes under 1 MiB are tiny (EFI vars, small
config disks) and copy instantly via `dd`.

### `xcopy_getsize64` and `run_zero_chunk` helpers in `Common.pm`

`xcopy_getsize64` is a minimal wrapper around `blockdev --getsize64`. The same
invocation already exists inline in `Common.pm` (the size-wait loop at
`volume_stage_wait_size`); this extracts it as a reusable sub. It is called in
`_volume_snapshot_rollback` to read snapshot and volume sizes.

`run_zero_chunk` writes a block range of zeros to a device using `dd` in a chunked
loop. It is the zero-fill counterpart to `run_xcopy_chunk`, used when the live
volume is larger than the snapshot. It uses the same adaptive-chunking algorithm
as `run_xcopy_chunk`: each `dd` invocation is bounded by a 50-second timeout; on
timeout the chunk size is halved and the same offset is retried. After each
successful chunk (or timeout) the per-VM lock is renewed so the 60-second alarm
window never expires mid-write.

The caller passes a default chunk size of 512 MiB (in blocks: `512 * 1024 * 1024
/ $bs`). This fits comfortably within the 50-second timeout even with the
`IOWeight=10` cgroup throttling applied via `systemd-run --scope`.

```perl
# xcopy_getsize64($ctx, $dev) — device size in bytes via blockdev --getsize64.
sub xcopy_getsize64 {
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

# run_zero_chunk($ctx, $dev, $bs, $seek, $count, $max_chunk, $renew_lock)
#
# Writes $count blocks of zeros to $dev starting at block offset $seek.
# Used when the live volume grew after the snapshot was taken.
#
# Same adaptive-chunking algorithm as run_xcopy_chunk: each dd invocation
# writes at most $max_chunk blocks with a 50 s timeout.  On timeout the
# chunk size is halved and the same offset is retried.  After each
# successful chunk (or timeout) the per-VM lock is renewed so the 60 s
# alarm window never expires mid-write.
#
# $bs         — ZFS volblocksize in bytes.
# $seek       — destination offset in blocks.
# $count      — number of blocks to zero.
# $max_chunk  — maximum blocks per dd invocation (default 512 MiB in blocks).
# $renew_lock — callback to extend per-VM lock by 60 s.
sub run_zero_chunk {
    my ( $ctx, $dev, $bs, $seek, $count, $max_chunk, $renew_lock ) = @_;

    my $timeout = 50;  # seconds per dd invocation

    my $chunk_size = $max_chunk < $count ? $max_chunk : $count;
    my $offset     = $seek;
    my $end        = $seek + $count;
    my $total      = $count || 1;

    my $min_chunk  = 1;

    while ( $offset < $end ) {
        my $remaining  = $end - $offset;
        my $this_chunk = $chunk_size < $remaining ? $chunk_size : $remaining;

        my $pct = int( ( $offset - $seek ) * 100 / $total );
        print "zero-fill ${pct}% (block ${offset}/${end})\n";

        # systemd-run --scope -p IOWeight=10: run dd in a transient systemd
        # scope with low I/O weight so zero-fill does not starve other I/O
        # on the host.  dd oflag=direct bypasses page cache, ensuring data
        # reaches the LUN.
        my @cmd = (
            'systemd-run', '--scope', '-p', 'IOWeight=10',
            'dd',
            'if=/dev/zero',
            "of=${dev}",
            "bs=${bs}",
            "seek=${offset}",
            "count=${this_chunk}",
            'oflag=direct',
        );

        debugmsg( $ctx, 'debug', "zero: " . join( ' ', @cmd ) . "\n" );

        my $ok = eval {
            run_command(
                \@cmd,
                timeout => $timeout,
                outfunc => sub { debugmsg( $ctx, 'debug', "dd: $_[0]\n" ) },
                errfunc => sub { debugmsg( $ctx, 'warn',  "dd: $_[0]\n" ) },
            );
            1;
        };

        if ( $ok ) {
            $renew_lock->() if $renew_lock;
            $offset += $this_chunk;
            next;
        }

        # Timeout — halve chunk size and retry same offset.
        if ( $@ =~ /got timeout/ ) {
            my $new_chunk = int( $chunk_size / 2 );
            $new_chunk = $min_chunk if $new_chunk < $min_chunk;

            if ( $new_chunk >= $chunk_size ) {
                die "zero-fill rollback: timeout at offset ${offset}; "
                  . "chunk size ${chunk_size} blocks is already at "
                  . "minimum; giving up\n";
            }

            $chunk_size = $new_chunk;
            $renew_lock->() if $renew_lock;
            next;   # retry same offset with smaller chunk
        }

        # Non-timeout error — propagate immediately.
        die $@;
    }

    print "zero-fill 100% (${total} blocks zeroed)\n";
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

### `xcopy_sha1sum` helper in `Common.pm`

Reads exactly `$count` blocks of `$bs` bytes each from a block device and
returns the SHA1 hex digest of that byte range. Used in
`_volume_snapshot_rollback` to verify that the XCOPY (or `dd` fallback) wrote
the snapshot content correctly to the live volume.

The read is performed by spawning `dd` in 512 MiB chunks via Perl's list-form
`open('-|', ...)`, feeding the output into `Digest::SHA`. List-form `open`
avoids shell interpretation of the device path, block size, and block count —
no shell quoting or injection risk. `Digest::SHA` is a Perl core module
(available since Perl 5.9.3; included in Proxmox VE's `perl` package).

Chunk size is fixed at 512 MiB (in blocks: `512 * 1024 * 1024 / $bs`). At a
conservative 100 MB/s iSCSI throughput, each 512 MiB chunk completes in ~5 s —
well within the 60-second alarm window. After each chunk `$renew_lock` is
called so the lock does not expire during verification of large volumes.

Unlike `run_xcopy_chunk` and `run_zero_chunk`, `xcopy_sha1sum` does not apply a
per-chunk timeout. `dd` reads over iSCSI are expected to progress at line rate;
hangs (e.g. full iSCSI session loss) will eventually fire `SIGALRM` on the
next lock-renewal boundary.

The function is added to `@EXPORT_OK` in `Common.pm` alongside the other XCOPY
helpers.

```perl
# xcopy_sha1sum($ctx, $dev, $bs, $count, $renew_lock)
#
# Reads $count blocks of $bs bytes each from $dev and returns the SHA1
# hex digest of that byte range.
#
# $dev         — block device path (snapshot or volume).
# $bs          — ZFS volblocksize in bytes; used as dd bs= argument.
# $count       — number of blocks to read; 0 returns SHA1 of empty input.
# $renew_lock  — callback to extend the per-VM lock by 60 s; called after
#                each 512 MiB read chunk.
#
# Reads are split into 512 MiB chunks so each dd invocation completes
# well within the 60-second alarm window.  The SHA1 is computed
# incrementally over all chunks using Digest::SHA.
sub xcopy_sha1sum {
    my ( $ctx, $dev, $bs, $count, $renew_lock ) = @_;

    require Digest::SHA;
    my $sha = Digest::SHA->new(1);

    # 512 MiB read chunks: ~5 s at 100 MB/s, well within the 60 s window.
    my $chunk_blocks = int( 512 * 1024 * 1024 / $bs );
    $chunk_blocks = 1 if $chunk_blocks < 1;

    my $offset = 0;
    my $total  = $count || 1;    # avoid division by zero

    while ( $offset < $count ) {
        my $remaining  = $count - $offset;
        my $this_chunk = $chunk_blocks < $remaining ? $chunk_blocks : $remaining;

        my $pct = int( $offset * 100 / $total );
        print "sha1 ${pct}% (block ${offset}/${count})\n";

        # List-form open: no shell — $dev, $bs, offsets are never interpreted
        # by a shell, so device paths with special characters are safe.
        open( my $fh, '-|', 'dd',
              "if=${dev}", "bs=${bs}",
              "skip=${offset}", "count=${this_chunk}",
              'iflag=direct' )
            or die "sha1sum: cannot open pipe from dd for ${dev}: $!\n";

        while (1) {
            my $buf;
            my $n = sysread( $fh, $buf, 65536 );
            last unless $n;
            die "sha1sum: read error from ${dev}: $!\n" unless defined $n;
            $sha->add($buf);
        }
        close($fh)
            or die "sha1sum: dd exited with error for ${dev} (exit $?)\n";

        $renew_lock->() if $renew_lock;
        $offset += $this_chunk;
    }

    print "sha1 100% (${count} blocks read)\n";
    return $sha->hexdigest;
}
```

**Why only `snap_blocks` bytes, not the full volume?**

The hash comparison covers exactly the byte range that was copied from the
snapshot (`snap_blocks * bs` bytes). The zero-filled trailing region (written
when `vol_blocks > snap_blocks`) is not included:

- It contains zeros on both devices after the rollback — the snapshot has no
  data beyond its boundary, and `run_zero_chunk` wrote zeros to the live
  volume's grown region. Including it would add a large read for content that
  cannot mismatch.
- The zero-fill is performed by a separate, well-understood `dd` invocation
  whose success is already confirmed by `run_zero_chunk` (non-zero exit dies).

**Placement in the call sequence**

`xcopy_sha1sum` is called after the copy (`run_xcopy_chunk` or `run_dd_copy`)
and **before** `run_zero_chunk`. Verifying before zero-fill confirms the
critical copied data is correct; the zero-fill is independent and verified
implicitly by `run_zero_chunk`'s exit-code check.

If the hash check fails, the die propagates out of the inner eval, triggering
the standard cleanup path: both devices are deactivated, recovery ZFS rollback
is attempted, and the mismatch error is re-raised to the caller.

### Helper functions in `Plugin.pm`

`_vm_is_running` and the `sg_xcopy` existence check are used only within
`_volume_snapshot_rollback` and are not exported to `Common.pm`:

```perl
sub _vm_is_running {
    my ($vmid) = @_;
    return 0 unless defined $vmid;
    # Pass nocheck=1 so check_running skips assert_config_exists_on_node.
    # Without it, the call dies for LXC containers (no qemu-server/<vmid>.conf).
    return ( eval { PVE::QemuServer::check_running( $vmid, 1 ) } // 0 )
        || ( eval { require PVE::LXC; PVE::LXC::check_running($vmid) } // 0 );
}
```

`run_xcopy_chunk`, `run_dd_copy`, `run_zero_chunk`, and `xcopy_getsize64` are defined in `Common.pm`
and must be added to its `@EXPORT_OK` list so `Plugin.pm` can call them without a
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
                    ├── [check_err =~ /^Unable to rollback/]
                    │     └── die $check_err
                    │           (backend/command failure: snapshot missing,
                    │            appliance unreachable, jdssc error —
                    │            never fall through to XCOPY)
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
                          │     $renew_lock->()                      — reset alarm before vol activation
                          │     _activate_volume(volname, snap=undef)
                          │       └── volume_activate()    [Common.pm]
                          │             ├── volume_publish()     — REST: create volume iSCSI target
                          │             ├── volume_stage_iscsi() — iscsiadm login
                          │             └── lun_record_local_create()
                          │     $renew_lock->()                      — reset alarm after vol activation
                          │
                          │     lun_record_local_get_info_list(volname, undef)
                          │       + block_device_path_from_lun_rec()   → vol_dev
                          │
                          │     $renew_lock->()                      — reset alarm before snap activation
                          │     _activate_volume(volname, snap=<snapname>)
                          │       └── volume_activate()    [Common.pm]
                          │             ├── volume_publish(snapname)  — REST: create snapshot target
                          │             ├── volume_stage_iscsi()      — iscsiadm login to snap target
                          │             └── lun_record_local_create()
                          │     $renew_lock->()                      — reset alarm after snap activation
                          │
                          │     lun_record_local_get_info_list(volname, snapname)
                          │       + block_device_path_from_lun_rec()   → snap_dev
                          │
                          │     $renew_lock->()                      — reset alarm before volume get -b
                          │     joviandss_cmd volume get -b            → bs (ZFS volblocksize)
                          │     get_xcopy_size($ctx)                   → xcopy_gib
                          │     max_chunk = xcopy_gib * 1 GiB / bs     (gran-aligned inside run_xcopy_chunk)
                          │
                          │     xcopy_getsize64(snap_dev) → snap_blocks
                          │     xcopy_getsize64(vol_dev)  → vol_blocks
                          │     snap_bytes = snap_blocks * bs
                          │
                          │     [snap_bytes < 1 MiB?]
                          │       ├── YES: run_dd_copy(snap_dev, vol_dev, bs,
                          │       │                    snap_blocks, $renew_lock)
                          │       │          └── dd if=<snap> of=<vol> bs=<bs> count=<N>
                          │       │
                          │       └── NO:  run_xcopy_chunk(snap_dev, vol_dev, bs, 0,
                          │                               snap_blocks, max_chunk, $renew_lock)
                          │       ┌── adaptive loop ──────────────────────────────────┐
                          │       │ sg_xcopy if=<snap> of=<vol> bs=<bs>              │
                          │       │         skip=<offset> seek=<offset>              │
                          │       │         count=<chunk>  timeout=50s               │
                          │       │                                                  │
                          │       │ [success]  → $renew_lock->(); offset += chunk   │
                          │       │ [timeout]  → $renew_lock->()                    │
                          │       │              chunk /= 2 (gran-aligned, permanent)│
                          │       │              retry same offset                    │
                          │       │ [error]    → die immediately                     │
                          │       │ [chunk < min] → die "giving up"                  │
                          │       └──────────────────────────────────────────────────┘
                          │       JovianDSS appliance:
                          │         receives XCOPY (--on_dst default)
                          │         reads from snapshot LUN  (expected: internal)
                          │         writes to volume LUN     (expected: internal)
                          │
                          │     $renew_lock->()              — reset alarm before snapshot hash
                          │     xcopy_sha1sum(snap_dev, bs, snap_blocks, $renew_lock) → snap_sha1
                          │       ┌── chunked read loop (512 MiB per chunk) ─────────┐
                          │       │ dd if=<snap_dev> bs=<bs>                         │
                          │       │    skip=<offset> count=<chunk> iflag=direct      │
                          │       │    → piped into Digest::SHA incrementally        │
                          │       │ [success]  → $renew_lock->(); offset += chunk   │
                          │       │ [dd error] → die immediately                     │
                          │       └──────────────────────────────────────────────────┘
                          │     $renew_lock->()              — reset alarm before volume hash
                          │     xcopy_sha1sum(vol_dev,  bs, snap_blocks, $renew_lock) → vol_sha1
                          │       ┌── (same chunked read loop as above) ─────────────┐
                          │       └──────────────────────────────────────────────────┘
                          │     [snap_sha1 eq vol_sha1?]
                          │       ├── YES → print "sha1 verify OK"
                          │       └── NO  → die "SHA1 mismatch" (triggers cleanup + recovery)
                          │
                          │     [vol_blocks > snap_blocks]
                          │       $renew_lock->()              — reset alarm before zero-fill loop
                          │       zero_chunk = 512 MiB / bs    — separate from xcopy max_chunk
                          │       run_zero_chunk(vol_dev, bs, snap_blocks,
                          │                      vol_blocks-snap_blocks, zero_chunk, $renew_lock)
                          │         ┌── adaptive loop ─────────────────────────────────┐
                          │         │ systemd-run --scope -p IOWeight=10              │
                          │         │   dd if=/dev/zero of=<vol_dev> bs=<bs>          │
                          │         │      seek=<offset> count=<chunk> oflag=direct   │
                          │         │      timeout=50s                                │
                          │         │                                                  │
                          │         │ [success]  → $renew_lock->(); offset += chunk   │
                          │         │ [timeout]  → $renew_lock->()                    │
                          │         │              chunk /= 2 (min 1 block, permanent) │
                          │         │              retry same offset                   │
                          │         │ [error]    → die immediately                     │
                          │         │ [chunk < min] → die "giving up"                  │
                          │         └──────────────────────────────────────────────────┘
                          │   };
                          │   $err = $@
                          │
                          ├── $renew_lock->()                        — reset alarm before snap deactivation
                          ├── eval { _deactivate_volume(volname, snap=<snapname>) }
                          │     └── volume_deactivate()              [Common.pm]
                          │           ├── volume_unstage_multipath()   — (if multipath=1) BEFORE iSCSI
                          │           ├── volume_unstage_iscsi_device()— remove iSCSI paths
                          │           ├── volume_unpublish(snapname)   — REST: remove snap target
                          │           │     (snapshots are unpublished on deactivation because they
                          │           │      are not involved in live migration)
                          │           └── lun_record_local_delete()    — cleanup local state + session
                          ├── $renew_lock->() (on success)           — reset alarm after snap deactivation
                          │           deactivation error → logged at warn, not re-raised
                          │
                          ├── $renew_lock->()                        — reset alarm before vol deactivation
                          ├── eval { _deactivate_volume(volname, snap=undef) }
                          │     └── volume_deactivate()              [Common.pm]
                          │           ├── volume_unstage_multipath()   — (if multipath=1) BEFORE iSCSI
                          │           ├── volume_unstage_iscsi_device()— remove iSCSI paths
                          │           ├── (no volume_unpublish)        — volume target is kept on the
                          │           │     appliance; unpublishing during deactivation would race
                          │           │     with live migration which re-attaches the same target
                          │           │     on the destination node. Only volume deletion triggers
                          │           │     unpublish.
                          │           └── lun_record_local_delete()    — cleanup local state + session
                          ├── $renew_lock->() (on success)           — reset alarm after vol deactivation
                          │           deactivation error → logged at warn, not re-raised
                          │
                          ├── [err set] → recovery ZFS rollback
                          │     eval {
                          │       $renew_lock->()                    — reset alarm before snapshots list
                          │       joviandss_cmd snapshots list --latest  → latest_snap
                          │       $renew_lock->()                    — reset alarm before rollback do
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
  and `$vol_blocks` separately via `xcopy_getsize64`. The copy call is
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
renews the per-VM lock (the timed-out call consumed up to 50 s of the 60 s alarm
window), halves the chunk size (rounded down to the nearest granularity-aligned
boundary; the reduction is permanent for all subsequent offsets), and retries the
same offset. This repeats until:

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

**Note — small volumes:** One known cause of non-timeout `sg_xcopy` failure is
very small volumes (observed: 528 KiB OVMF EFI vars disk, exit code 99, "not
enough data to read (min 65536 bytes)"). These are prevented by the 1 MiB
threshold check before the copy — volumes under 1 MiB use `run_dd_copy`
instead of `run_xcopy_chunk`, so this `sg_xcopy` error path should not be
reached in practice.

### Zero-fill fails

`run_zero_chunk` throws — either a `dd` error or a timeout that cannot be
resolved by halving the chunk size (already at minimum). On timeout,
`run_zero_chunk` uses the same adaptive retry as `run_xcopy_chunk`: the chunk
size is halved and the same offset is retried. If the chunk is already at the
minimum (1 block), the function gives up and dies.

The exception is caught by the inner eval as above. Both deactivations run.
Recovery rollback restores the volume to the latest snapshot, undoing both the
completed XCOPY blocks and the partial zero-fill. The volume is returned to a
clean, consistent state.

**Note:** If recovery rollback succeeds, the volume is fully restored and no manual
intervention is needed. If recovery rollback also fails (both errors are logged),
the volume remains in a partially written state — operator should manually
investigate.

### SHA1 mismatch after copy

`xcopy_sha1sum` returns different digests for the snapshot and the live volume.
`_volume_snapshot_rollback` dies with a mismatch error message. The exception
is caught by the inner eval. Both deactivations run. Recovery ZFS rollback
restores the volume to the latest snapshot, undoing all XCOPY writes (the copy
completed but produced incorrect content). `die $err` re-raises the mismatch
error.

This case indicates a defect in the XCOPY implementation on the JovianDSS
appliance — the SCSI EXTENDED COPY command claimed success but the data written
to the destination does not match the source. The operator should:

1. Report the firmware version of the JovianDSS appliance to Open-E support.
2. As a temporary workaround, disable XCOPY offload by setting the `xcopy_size`
   property to a very small value (e.g. `xcopy_size=0`) to force the `dd`
   fallback path for all volumes — **note:** the current 1 MiB threshold means
   only volumes under 1 MiB use `dd`; a firmware-level XCOPY defect would
   require a code change to force `dd` for all sizes.
3. Retry the rollback after the volume has been recovered by the ZFS rollback.

The snapshot chain is completely intact after this failure.

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
| XCOPY timeout handling | N/A | Adaptive chunking: initial chunk from `xcopy_size` property (default 16 GiB); 50 s timeout per sg_xcopy call; lock renewed and chunk halved permanently on timeout; dies at granularity minimum |
| jdssc changes | None | New `-b` flag on `volume get`; new `--latest` flag on `snapshots list` |
| Residual state on failure | None | Both sessions deactivated; recovery ZFS rollback to latest snapshot restores volume to clean state |
| Lock per operation | One lock for entire rollback | One lock for entire rollback (same as ZFS path); `lock_renew` called after each activation, after each successful XCOPY chunk, after each XCOPY timeout (before retry), before the zero-fill loop, and after each zero-fill chunk to prevent 60 s expiry |
| Progress reporting | None | Percentage progress printed per chunk for both XCOPY and zero-fill |

---

## Limitations

1. **Offline-only.** The VM must be stopped. Online non-destructive rollback would
   require a filesystem-level freeze and is out of scope.

2. **Same-appliance only.** Both LUNs must be on the same JovianDSS appliance. The
   plugin's single-appliance-per-storage-instance model guarantees this.

3. **XCOPY offload empirically disproved for ZVOL-to-ZVOL copies.** `3PC=1`
   confirms XCOPY is accepted and `sg_xcopy` returns success, but testing (Finding 9)
   confirmed that JovianDSS does NOT copy block data when the source and destination
   are both ZVOLs. Reads of the destination ZVOL immediately after sg_xcopy (same
   iSCSI session, before any target teardown) still return the original data. The XCOPY
   path was therefore replaced by `run_dd_chunk` as the primary copy method for volumes
   ≥ 1 MiB.

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

9. **Small volumes use `dd` fallback.** `sg_xcopy` fails on very small volumes
   (observed on a 528 KiB OVMF EFI vars disk: exit code 99, "not enough data to
   read (min 65536 bytes)"). The XCOPY Data segment granularity (65536 bytes)
   combined with `volblocksize`-based block alignment causes `sg_xcopy` to reject
   transfers that are technically above 65536 bytes but below its internal minimum
   after alignment. Volumes under 1 MiB bypass `sg_xcopy` entirely and are copied
   via `run_dd_copy` — a single `dd` invocation with `iflag=direct oflag=direct`.
   These volumes are tiny (EFI vars, config disks) and copy in under a second.

10. **Zero-fill runs under `IOWeight=10` throttling.** The `dd` zero-fill uses
    `systemd-run --scope -p IOWeight=10` to avoid starving host I/O. Combined
    with direct I/O over iSCSI, this means zero-fill throughput is significantly
    lower than unthrottled writes. The adaptive chunking (default 512 MiB, halved
    on timeout) ensures the operation completes even under heavy I/O contention,
    but large extended regions (tens of GiB) will take proportionally longer.

---

## Files

| File | Changes |
|---|---|
| `OpenEJovianDSSPlugin.pm` | New `xcopy_size` property (initial XCOPY chunk size in GiB, default 16); adapt `volume_rollback_is_possible` (HA guard only; always returns 1); unified `_volume_snapshot_rollback` (ZFS and XCOPY paths, `$renew_lock` closure, recovery rollback on failure); new `_vm_is_running` helper |
| `OpenEJovianDSS/Common.pm` | New `get_xcopy_size` getter; new `run_xcopy_chunk` (adaptive loop with configurable initial chunk, timeout, and lock renewal), `run_dd_copy` (small-volume fallback for volumes < 1 MiB), `run_dd_chunk` (chunked dd copy with adaptive 50 s timeout and lock renewal — primary copy method replacing sg_xcopy after Finding 9), `run_zero_chunk` (adaptive chunking with 50 s timeout, matching `run_xcopy_chunk`), `xcopy_getsize64` helpers (exported); `lun_record_update_device` uses targeted `udevadm trigger --action=change /sys/block/<dev>` + `udevadm settle` instead of `udevadm trigger -t all`; deactivation order reversed to multipath-first in `lun_record_local_delete` and error cleanup path |
| `OpenEJovianDSS/Lock.pm` | New `lock_renew` function (exported): resets `alarm(60)` and touches pmxcfs lock directory |
| `jdssc/jdssc/volume.py` | New `-b` / `--block-size` flag in `get` subparser and `get` action |
| `jdssc/jdssc/snapshots.py` | New `--latest` flag in `list` subparser and `list` action |
| `jdssc/jdssc/jovian_common/driver.py` | `get_volume` returns `volblocksize` from REST response; `list_snapshots` includes `creation` timestamp in returned dicts (required by `--latest` flag) |

---

## Dependencies

| Component | Used for | Notes |
|---|---|---|
| `sg3-utils` (`sg_xcopy`) | Block-level XCOPY between iSCSI LUNs | Already in plugin runtime deps |
| `activate_volume` / `_activate_volume` | Bring snapshot and volume online as block devices | Existing method, no changes |
| `deactivate_volume` / `_deactivate_volume` | Tear down snapshot and volume iSCSI sessions on XCOPY exit (unconditional, each in its own eval) | Existing method, no changes |
| `lun_record_local_get_info_list` | Locate LUN record after activation | Existing `Common.pm` function |
| `block_device_path_from_lun_rec` | Resolve block device path from LUN record | Existing `Common.pm` function |
| `xcopy_size` property | Initial XCOPY chunk size in GiB (default 16); converted to blocks by the caller | New storage property in `Plugin.pm`, getter in `Common.pm` |
| `jdssc volume get -b` | Retrieve ZFS `volblocksize` for `bs=` in `sg_xcopy` and `dd` | New flag, minimal jdssc change |
| `jdssc snapshots list --latest` | Retrieve name of the most recent snapshot for recovery rollback | New flag, minimal jdssc change |
| `lock_renew` | Extend per-VM lock lifetime during long-running XCOPY; resets `alarm(60)` and touches pmxcfs lock directory | New function in `Lock.pm` (exported) |
| `PVE::Tools::run_command` | Execute `sg_xcopy` and `systemd-run … dd` as subprocesses | Standard Proxmox tool |
| `blockdev --getsize64` | Read block device size in bytes for snap and volume size calculation | Already used in `Common.pm`; extracted into `xcopy_getsize64` |
| `systemd-run --scope -p IOWeight=10 dd` | Zero-fill trailing blocks when volume grew post-snapshot | `systemd-run` part of `systemd`; `dd` part of `coreutils`; both universally available on Proxmox VE |

---

## Testing Findings

Testing was performed on the pve-91 cluster (3 nodes: pve-91-1, pve-91-2, pve-91-3)
with JovianDSS storage and multipath enabled.

### Test environment — VM 103 on pve-91-2

VM 103 has three disks of different sizes, exercising different code paths:

| Disk | Size | volblocksize | Blocks | Copy method |
|---|---|---|---|---|
| `vm-103-disk-0` | 32 GiB | 16384 | 2,097,152 | XCOPY (normal path) |
| `vm-103-disk-1` | 528 KiB | 16384 | 33 | dd fallback (< 1 MiB) |
| `vm-103-disk-2` | 4 MiB | 16384 | 256 | XCOPY (small but above 1 MiB threshold) |

### Finding 1: `sg_xcopy` fails on very small volumes

**Observed:** `sg_xcopy` exit code 99 on `vm-103-disk-1` (528 KiB OVMF EFI vars
disk) with error "not enough data to read (min 65536 bytes)".

**Root cause:** The XCOPY Data segment granularity is 65536 bytes. With
`volblocksize=16384`, `gran_blocks = 65536/16384 = 4`. The volume has 33 blocks;
granularity alignment rounds this to 32 blocks (524288 bytes). Despite being well
above 65536 bytes, `sg_xcopy` rejects the transfer — the "min 65536 bytes" message
appears to refer to an internal `sg_xcopy` calculation that considers the device's
logical sector size (512 bytes) independently of the `bs=` parameter.

**Fix:** Volumes under 1 MiB (`snap_bytes < 1048576`) bypass `sg_xcopy` entirely
and use `run_dd_copy` — a single `dd if=<snap> of=<vol> bs=<bs> count=<N>
iflag=direct oflag=direct` invocation. The 1 MiB threshold is conservative;
volumes this small copy in under a second via `dd`.

### Finding 2: Recovery rollback on XCOPY failure works correctly

When the initial `sg_xcopy` attempt failed on `vm-103-disk-1`, the recovery path
attempted a ZFS rollback to the latest snapshot. On the first attempt this also
failed because the volume and snapshot iSCSI sessions were not properly cleaned up.
After fixing the deactivation ordering (both deactivations run unconditionally
before recovery), the recovery rollback works correctly.

### Finding 3: Stale lock on failed rollback

A failed rollback leaves a `lock: rollback` on the VM config. Proxmox refuses
subsequent rollback attempts until the lock is cleared with `qm unlock <vmid>`.
This is standard Proxmox behavior — not a bug in the XCOPY implementation.

### Finding 4: udev-worker blocks deactivation for ~30-40 seconds

During deactivation after XCOPY, the plugin's `lsof` polling loop
(`_volume_unstage_multipath_wait_unused`) repeatedly detects a `udev-worker`
process holding the `/dev/mapper/<scsiid>` device open, producing many lines:

```
Block device with SCSI 26363303966303966 is used by 1587101
Multipath device with scsi id 26363303966303966, is used by (udev-worker) with pid 1587101
```

The PID is the same across all iterations (single worker, not respawning), and
the stall lasts ~30-40 seconds per deactivated multipath device. The XCOPY
rollback deactivates 2 devices per disk (snapshot + volume), making the delay
very visible.

**Root cause analysis (via `udevadm monitor`):**

1. During **activation**, `lun_record_update_device()` (Common.pm line ~3607)
   calls `udevadm trigger -t all`, which fires a synthetic `change` event on
   **every** block device on the system — including dm-* multipath devices.

2. udev-worker spawns to process the `change` event on the newly created dm
   device. The rules chain includes `55-dm.rules` (sets `DM_NAME`, `DM_UUID`),
   multipath rules (sets `MPATH_DEVICE_READY`), `60-persistent-storage.rules`
   (runs `blkid` unless `UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG` is set),
   and `69-lvm.rules` (runs `pvscan`).

3. These probes open the dm device and issue I/O. With the snapshot LUN exposed
   via SCST iSCSI, SCSI probes can be slow (the target may need to service
   concurrent XCOPY I/O).

4. After the XCOPY copy completes, the plugin **deactivates** the snapshot by
   deleting iSCSI paths (`/sys/block/.../device/delete`). This removes the
   underlying sd paths from the multipath device.

5. The udev-worker spawned in step 2 may still be processing — now with dead
   underlying paths, its I/O stalls until the SCSI timeout expires (~30 s).

6. `_volume_unstage_multipath_wait_unused` polls with `lsof` every 1 second,
   detecting the stuck worker each time.

**Evidence from `udevadm monitor` (dm-6, first rollback disk):**

| Timestamp | Event | Notes |
|---|---|---|
| 3348920.50 | KERNEL add dm-6 | Snapshot activation |
| 3348922.46 | KERNEL change dm-6 | `udevadm trigger -t all` synthetic event |
| 3348924.57 | KERNEL change dm-6 (DM_COOKIE) | multipath reconfiguration |
| 3348924.68 | KERNEL change dm-6 | Last kernel event before gap |
| 3349045.54 | UDEV change dm-6 | **121 seconds later** — udev-worker finishes |
| 3349048.27 | KERNEL remove dm-6 | Device finally removed |

The 121-second gap (3348924 → 3349045) is the udev-worker stuck processing the
change event while the underlying iSCSI paths are removed.

**What was tested and did NOT fix the issue:**

- `udevadm settle` before multipath removal — runs too early, before
  deactivation triggers new events
- `UDEV_DISABLE_PERSISTENT_STORAGE_BLKID_FLAG=1` on dm-* devices — blkid is
  not the stalling rule; the stall comes from multipath path checker or LVM
  probes
- Both approaches were reverted after testing showed no improvement

**Impact:** Cosmetic — deactivation eventually succeeds. No data integrity
impact. The 60-iteration polling loop (1 s sleep each) waits out the stuck
worker and then `multipath -f` / `dmsetup remove` succeed. However, each
affected disk adds ~30-40 seconds to the total rollback time.

**Fix (implemented):** Two changes resolved this issue:

1. **Targeted udev triggers in `lun_record_update_device()`:** Replaced
   `udevadm trigger -t all` with a loop that triggers only the specific sd
   block devices involved: `udevadm trigger --action=change /sys/block/<bdn>`
   for each iSCSI block device. A `udevadm settle` call follows to wait for
   processing to complete. This eliminates synthetic change events on unrelated
   dm devices during activation.

2. **Reversed deactivation order:** Changed the unstage sequence from
   "iSCSI paths first, then multipath" to "multipath first, then iSCSI paths".
   The old order caused the problem: deleting SCSI paths emitted kernel change
   events on the dm device; udev-worker opened the dm device to probe it, but
   I/O stalled (~30 s SCSI timeout) because the paths were already gone.
   Removing the dm device first (while iSCSI paths are still up) lets any
   udev probes complete instantly on a functional device, then iSCSI path
   removal generates no dm events since the dm device is already gone.
   Applied at both call sites in `Common.pm` (error cleanup path and normal
   deactivation in `lun_record_local_delete`).

**Testing confirmed:** Zero "is used by" messages after both fixes. Rollback of
3× 1 GiB disks (VM 104) completes without delays. The `multipath -f` flush
succeeds cleanly before iSCSI paths are removed.

### Finding 5: `jdssc volume get -b` required implementation

The `-b` / `--block-size` flag was designed but not initially present in the
`jdssc` codebase. It required changes to:
- `jdssc/jdssc/volume.py` — add `-b` to the `get` subparser's mutually exclusive group
- `jdssc/jdssc/jovian_common/driver.py` — include `volblocksize` in the dict returned
  by `get_volume`

### Finding 6: `lock_renew` lockpath must use `_sanitize_lockid`

The `lock_renew` function must construct the lockpath identically to `_cluster_lock`.
Both use `_sanitize_lockid($storeid)` and `_cluster_lockdir()` to build the path.
An early implementation bug used the raw `$storeid` without sanitization, which would
have caused `utime` to target a non-existent path — silently failing to renew the lock.

### Finding 7: Zero-fill timeout on extended volumes

When a volume is extended after a snapshot (e.g. 32 GiB → 37 GiB), the
zero-fill phase must write zeros to the 5 GiB extended region. The original
`run_zero_chunk` used a single `dd` invocation for the entire region with no
timeout, running under `systemd-run --scope -p IOWeight=10` (minimum cgroup
I/O priority).

**Problem:** `IOWeight=10` severely throttles `dd` — writing 5 GiB via direct
I/O to iSCSI at minimum priority took longer than the 60-second `alarm()`
window set by `lock_renew`. When the alarm fired, Perl SIGALRM unwound the
stack to the error handler, which started deactivation cleanup. But the `dd`
subprocess (under `systemd-run --scope`) was still running, holding the
multipath device open. The `lsof` polling loop then showed "is used by dd"
for 60 iterations before `dd` was eventually killed.

**Fix:** Applied the same adaptive-chunking algorithm as `run_xcopy_chunk`:
- Default chunk size set to 512 MiB (in blocks: `512 * 1024 * 1024 / $bs`)
  by the caller in `OpenEJovianDSSPlugin.pm`
- Each `dd` invocation has a 50-second `timeout` on `run_command`
- On timeout, chunk size is halved and the same offset is retried
- `lock_renew` is called after each successful chunk or timeout, keeping the
  alarm window fresh
- `systemd-run --scope -p IOWeight=10` is preserved to avoid starving host I/O

**Testing:** VM 103 (32 GiB disk extended to 37 GiB) — 5 GiB zero-fill
completed in 10 chunks of ~512 MiB each with smooth 0–100% progress, no
timeouts at the 512 MiB chunk size.

### Finding 8: VM 104 clean rollback (3× 1 GiB, multipath)

VM 104 on pve-91-1 with 3× 1 GiB disks was used to verify the deactivation
order fix (Finding 4). Rollback to snap1 and snap3 both completed cleanly:
zero "is used by" messages in syslog, no udev-worker stalls, multipath flush
succeeded before iSCSI path removal.

### Successful rollback output (VM 103, all 3 disks, with zero-fill)

```
starting rollback of vm-103-disk-0 to snapshot snap1
xcopy vm-103-disk-0 -> snap1: 2097152 snap blocks, 2424832 vol blocks, bs=16384, xcopy_size=16 GiB
xcopy 0% (block 0/2097152)
xcopy 100% (2097152 blocks copied)
zero-fill 0% (block 2097152/2424832)
zero-fill 10% (block 2129920/2424832)
zero-fill 20% (block 2162688/2424832)
zero-fill 30% (block 2195456/2424832)
zero-fill 40% (block 2228224/2424832)
zero-fill 50% (block 2260992/2424832)
zero-fill 60% (block 2293760/2424832)
zero-fill 70% (block 2326528/2424832)
zero-fill 80% (block 2359296/2424832)
zero-fill 90% (block 2392064/2424832)
zero-fill 100% (327680 blocks zeroed)
vm-103-disk-0 to snapshot snap1 rollback complete
starting rollback of vm-103-disk-1 to snapshot snap1
dd copy vm-103-disk-1 -> snap1: 33 snap blocks (volume too small for XCOPY, using dd)
dd copy 100% (33 blocks copied)
vm-103-disk-1 to snapshot snap1 rollback complete
starting rollback of vm-103-disk-2 to snapshot snap1
xcopy vm-103-disk-2 -> snap1: 256 snap blocks, 256 vol blocks, bs=16384, xcopy_size=16 GiB
xcopy 0% (block 0/256)
xcopy 100% (256 blocks copied)
vm-103-disk-2 to snapshot snap1 rollback complete
```

### Finding 9: sg_xcopy EXTENDED COPY does not write block data to JovianDSS ZVOLs

**Test environment:** CT 109 (`vm-109-disk-0`), node pve-91-1. Volume: 2 GiB,
`volblocksize=16384`, 131072 blocks. Snapshot chain: snap1 → snap2 → snap3 → snap4 →
current live data. Rollback target: snap1 (XCOPY path applies because snap2/3/4 are
newer blockers — ZFS cannot do a direct `zfs rollback`).

**Key SHA1 values measured before any xcopy attempt:**

| Item | SHA1 |
|---|---|
| snap1 full volume | `6c6288e92d708b6284a9573070dea0134d8429d1` |
| vol live data (original) | `db36df65d3faac227f07b95fd4c445d041a7c731` |
| snap1 block0 = vol block0 | `1da02b385c9a1cddccdf29b2d6cedabaf1f89cb6` |

**sg_xcopy performance characteristics:**
- Reported: 3 SCSI commands, 131072 blocks transferred, exit code 0
- Wall-clock time: ~18 ms for a 2 GiB volume (≈ 6975 MB/s)
- This matches ZFS metadata update speed, not actual data copy speed

**Tests performed in sequence (all showed no data update):**

1. **Session refresh (iscsiadm reconnect only):** Logged out and back in on the
   initiator side. Vol SHA1 after xcopy + session refresh = `db36df65` (original,
   unchanged).

2. **Full target unpublish/republish:** `_deactivate_volume` (snap then vol) +
   explicit `jdssc targets delete` + `_activate_volume` (vol then snap). Forces
   JovianDSS to close and reopen its ZFS dataset handle. Vol SHA1 after = `db36df65`
   (original, unchanged).

3. **sg_sync (SYNCHRONIZE CACHE) before target teardown:** `sg_sync <vol_dev>` issued
   after xcopy, before target deletion. Vol SHA1 after target delete + create = `db36df65`
   (original, unchanged). SYNCHRONIZE CACHE does not force a ZFS ZVOL commit on
   JovianDSS.

4. **Pre-refresh SHA1 on the same iSCSI session (definitive test):** After xcopy but
   before any target teardown, `xcopy_sha1sum` read the full 2 GiB vol_dev via
   `dd iflag=direct` on the same session that had already processed the xcopy SCSI
   commands. Result: vol SHA1 = `db36df65` (original). This proves sg_xcopy writes
   nothing — not even to JovianDSS's write buffer. The data never moves.

**Block-zero write buffer observation:**

A diagnostic zero-write (`dd if=/dev/zero of=<vol_dev> bs=16384 count=1 oflag=direct`)
was issued before xcopy. This changed block0 SHA1 from `1da02b38` → `897256b6` on the
same session (dd writes via SCSI WRITE(16) work correctly). After xcopy, block0 SHA1
read back as `1da02b38` — which is snap1's block0 value. However, since snap1's block0
and the original vol block0 are identical (`1da02b38`), this does not indicate xcopy
wrote snap1 data. What actually occurred: sg_xcopy invalidated the write-buffer entry
for block0 (discarding the zero-write), causing the next read to fetch from ZFS, which
has the original `1da02b38` value. No new data was written to ZFS by sg_xcopy at all.

**Root cause:** JovianDSS's EXTENDED COPY implementation processes the SCSI XCOPY
command as a metadata-only operation when both source and destination are ZVOLs on the
same pool. It returns success and reports the correct block count, but performs no data
copy. This is consistent with JovianDSS's XCOPY support being designed for snapshot
space-efficiency metadata operations rather than ZVOL-to-ZVOL block data movement.

**Impact:** The XCOPY-based rollback path was producing silent data corruption — sg_xcopy
returned success, SHA1 verification detected the mismatch, and rollback was failed and
rolled back to the latest snapshot. Windows VMs that had been rolled back using the
initial XCOPY implementation retained their original data (not the snapshot data).

**Fix:** `run_xcopy_chunk` was replaced by `run_dd_chunk` as the primary copy method
for volumes ≥ 1 MiB. `run_dd_chunk` uses chunked `dd if=<snap> of=<vol>` with
`iflag=direct oflag=direct`, a 50-second per-chunk timeout with adaptive halving, and
lock renewal after each chunk. SHA1 verification was retained as the final correctness
check.

**SHA1 verification outcome:** With `run_dd_chunk` as the copy method, SHA1 of the
volume after copy (same session, before target refresh) matches SHA1 of the snapshot,
confirming correct data transfer.

---

### Finding 10: JovianDSS iSCSI write buffer is discarded on target deletion

This is a corollary of Finding 9. SCSI WRITE(16) commands issued via `dd` are
acknowledged by JovianDSS (iSCSI target confirms write receipt), and the written data
is visible on the same iSCSI session via subsequent reads. However, when the iSCSI
target is deleted (`jdssc targets delete`) before the write buffer is flushed to ZFS,
the buffered writes are discarded. After target delete + create, the volume shows the
original ZFS ZVOL data as if the dd writes never happened.

**Demonstrated by:**
- dd zero-write to block0 → block0 SHA1 changes to `897256b6` (visible same session)
- `jdssc targets delete` + `jdssc targets create` (volume_unpublish + volume_publish)
- block0 SHA1 reads as `1da02b38` (original ZFS value) — write buffer discarded

**sg_sync (SYNCHRONIZE CACHE) does not prevent this.** Issuing `sg_sync <vol_dev>`
before target deletion did not cause the write buffer to be persisted to the ZFS ZVOL.
JovianDSS's SYNCHRONIZE CACHE handling appears not to trigger a ZFS ZVOL `zil_commit`
or equivalent.

**Implication for `run_dd_chunk`:** The dd-based copy must keep the iSCSI session open
until after SHA1 verification. The SHA1 check must be performed on the same session that
did the writes (not after a target refresh). The current implementation does this
correctly — SHA1 is read before any `_deactivate_volume` calls in the cleanup path.
