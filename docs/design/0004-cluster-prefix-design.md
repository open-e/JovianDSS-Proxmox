# Cluster Prefix — Design Document

## Overview

This document describes the `cluster_prefix` property added to the JovianDSS
iSCSI Proxmox plugin. It allows multiple independent Proxmox clusters to share
the same JovianDSS pool without seeing each other's volumes.

The implementation is almost entirely in the Perl plugin layer
(`OpenEJovianDSSPlugin.pm`, `OpenEJovianDSS/Common.pm`). The only jdssc change
is in the two volume-enumeration commands (`volumes list`, `volumes
getfreename`): they filter volume names by the Proxmox `vm-`/`base-` pattern,
and since stored names now carry the cluster prefix (`<prefix>_vm-...`) they
must be told the prefix or they would discard every prefixed volume. The Python
driver, `jdss_common.py` (`vname`/`idname`), and the REST layer are unchanged.

---

## Problem

A JovianDSS pool is a storage resource that can be accessed by multiple
Proxmox clusters simultaneously. Without isolation, every cluster's plugin
instance queries the same `volumes list` endpoint and receives all volumes in
the pool — including volumes owned by other clusters.

The consequences:

- **VM ID collision.** Both clusters may have a VM 100. Both create
  `v_vm-100-disk-0`. The `list_images` output on each cluster contains the
  other cluster's disk, making it appear as an unrecognised orphan.
- **Accidental deletion.** `pvesm free` or `qm destroy --purge` on cluster A
  may find and delete a volume that belongs to cluster B.
- **Naming collisions.** `find_free_diskname` scans existing volume names to
  pick the next free index. If cluster B's volumes are included in the scan,
  cluster A skips indices it does not own, wasting names and causing
  unnecessary retries.

---

## Design

### Principle

Each Proxmox cluster is assigned a short alphanumeric prefix (e.g. `pveA`,
`cluster01`). The prefix is embedded in every volume name that the plugin
creates on JovianDSS. When listing volumes, the plugin filters to only those
whose names begin with the prefix, and strips the prefix before returning them
to Proxmox. The prefix is completely transparent to Proxmox — it never appears
in `storage.cfg` volume IDs or in the Proxmox UI.

### Volume naming

Without prefix:

```
Proxmox volname:   vm-100-disk-0
JovianDSS name:    v_vm-100-disk-0
```

With `cluster_prefix pveA`:

```
Proxmox volname:   vm-100-disk-0             ← unchanged
JovianDSS name:    v_pveA_vm-100-disk-0      ← prefix embedded by jdssc vname()
```

The prefix is inserted between the `v_` type marker (applied by jdssc's
`vname()` function) and the Proxmox volume name. From jdssc's perspective,
`pveA_vm-100-disk-0` is the Proxmox volname it receives — the `v_` prefix is
added by `vname()` as normal. `vname()` itself needs no change: it treats
`pveA_vm-100-disk-0` as an ordinary volume id because the name matches its
`^[-\w]+$` allowed-character pattern. (The only jdssc changes are in the
volume-listing commands — see `list_images` and `getfreename` below.)

### Separator and character constraints

The separator between the prefix and the Proxmox volname is `_`. To ensure
this separator is unambiguous, the prefix itself must not contain `_`. The
`pattern` constraint in `properties()` enforces this:

```perl
pattern => '[a-zA-Z][a-zA-Z0-9]*',
```

- Must start with a letter (avoids conflicts with `v_`, `vh_`, `s_`, `se_`
  type-marker prefixes).
- Only letters and digits after the first character — no `_`, no `-`.

Valid: `pveA`, `cluster01`, `prod`
Invalid: `pve-a`, `cluster_01`, `01cluster` (starts with digit)

### Immutability

`cluster_prefix` is declared as `fixed => 1` in `options()`. It cannot be
changed after the storage instance is created. Changing the prefix after
volumes exist would make all existing volumes invisible to the storage instance
(their names no longer match the new prefix), and would cause new volumes to be
created with a different prefix. Volumes created under the old prefix would be
orphaned on JovianDSS and unmanageable via Proxmox.

If a prefix change is necessary, all VMs must be stopped, all volumes deleted,
the storage instance removed and re-created with the new prefix.

---

## Implementation

### Two helper functions in `Common.pm`

```perl
sub volume_name_clustered {
    my ($ctx, $volname) = @_;
    my $prefix = $ctx->{scfg}{cluster_prefix};
    return defined($prefix) ? "${prefix}_${volname}" : $volname;
}

sub volume_name_unclustered {
    my ($ctx, $volname_clustered) = @_;
    my $prefix = $ctx->{scfg}{cluster_prefix};
    return $volname_clustered unless defined($prefix);
    return undef unless $volname_clustered =~ s/^\Q${prefix}\E_//;
    return $volname_clustered;
}
```

`volume_name_clustered` converts a Proxmox-side volname to the name that is
passed to jdssc (and ultimately appears on JovianDSS).

`volume_name_unclustered` converts a name returned by jdssc back to the
Proxmox-side volname. Returns `undef` if the name does not start with the
expected prefix — `list_images` uses this as a defensive filter signal (jdssc
already pre-filters by prefix; see below).

When no prefix is configured both functions are identity operations and have no
effect on behaviour.

Both are exported via `@EXPORT_OK` and the `:all` export tag.

### Call-site pattern

Inside each inner plugin method (the `_method_name` functions), the
transformation is applied once at the top of the function:

```perl
sub _alloc_image {
    my ( $class, $ctx, $vmid, $fmt, $name, $size ) = @_;
    ...
    my $volume_name_clustered = volume_name_clustered( $ctx, $volume_name );
    my $create_vol_cmd = [
        "pool", $pool, "volumes", "create",
        "--size", $size_assigned, "-n", $volume_name_clustered
    ];
    ...
    return clean_word($volume_name);   # return Proxmox-side name
}
```

The Proxmox-side `$volname` is preserved unchanged for:

- `$class->parse_volname($volname)` — the plugin's authoritative Proxmox name parser
- Pattern matching that expects Proxmox format (e.g. `^vm-(\d+)-state-`)
- Return values handed back to Proxmox VE

The clustered name is used for all calls that reach jdssc or the LUN record
filesystem cache:

- `jd_cmd_*` and `joviandss_cmd` calls
- `volume_activate`, `volume_deactivate`, `volume_publish`, `volume_unpublish`
- `lun_record_local_get_info_list`, `lun_record_local_*`
- `block_device_path_from_rest`
- `volume_get_size`, `volume_update_size`, `volume_snapshots_info`
- `volume_rollback_check`

### `list_images` — the filter point

`list_images` is the only place where volume names flow from jdssc back to
Proxmox. Filtering happens in two layers:

**1. jdssc side.** `volumes list --vmid` filters volume names with a regex to
keep only `vm-`/`base-` volumes and to parse the VM ID out of the name
(`volumes.py`). Stored idnames carry the cluster prefix
(`pveA_vm-100-disk-0`), so that regex must include the prefix or it discards
every prefixed volume. `list_images` therefore passes the configured prefix:

```perl
my $list_cmd = [ "pool", $pool, "volumes", "list", "--vmid" ];
my $cluster_prefix = $ctx->{scfg}{cluster_prefix};
push @$list_cmd, '--cluster-prefix', $cluster_prefix
  if defined($cluster_prefix);
```

When `--cluster-prefix pveA` is given, jdssc matches
`^pveA_(vm|base)-[0-9]+` and only pveA's volumes are emitted (other clusters'
volumes and legacy unprefixed volumes are dropped at the source). The emitted
name still carries the prefix (`pveA_vm-100-disk-0`).

**2. Perl side.** `list_images` then applies `volume_name_unclustered` to strip
the prefix back off each name:

```perl
foreach ( split( /\n/, $jdssc ) ) {
    my ( $raw_volname, $vm, $size, $ctime ) = split;

    my $volname = volume_name_unclustered( $ctx, clean_word($raw_volname) );
    next unless defined($volname);   # not ours — skip (defensive)

    my $volid = "$storeid:$volname";
    ...
}
```

With jdssc already filtering by prefix, the `next unless defined` guard is
defensive — every line reaching this loop is guaranteed to carry the prefix.
The `volume_name_unclustered` call still does the real work of converting
`pveA_vm-100-disk-0` back to the Proxmox-side `vm-100-disk-0`.

### `getfreename` — the same filter applies

`_create_base` (template conversion) does not go through `list_images`; it asks
jdssc directly for a free `base-<vmid>-disk-<n>` name via `volumes getfreename
--prefix base-<vmid>-disk-`. That command also enumerates volumes and matches
them with `startswith`, so it has the same blind spot: stored names are
`pveA_base-<vmid>-disk-<n>` and would not match a bare `base-<vmid>-disk-`
search, causing it to hand back an already-occupied index. `_create_base`
passes `--cluster-prefix` for the same reason; jdssc searches with the
fully-qualified `<prefix>_<volume_prefix>` but returns the bare
`base-<vmid>-disk-<n>` name, which the Perl layer re-clusters during the
subsequent rename.

### `_rename_volume` — two names, both clustered

Template conversion (`qm template`) renames `vm-N-disk-0` to `base-N-disk-0`.
Both the old and new names must carry the prefix:

```perl
my $original_volname_clustered = volume_name_clustered( $ctx, $original_volname );
my $new_volname_clustered      = volume_name_clustered( $ctx, $new_volname );

jd_cmd_idemp( $ctx,
    [ "pool", $pool, "volume", $original_volname_clustered,
      "rename", $new_volname_clustered ]
);
```

The return value `"${storeid}:${new_volname}"` uses the Proxmox-side
`$new_volname` — the prefix is not visible in the returned `volid`.

### `_clone_image` — source and destination

The source volume name and the candidate destination name both need the prefix.
The destination name is re-clustered on each retry attempt because
`find_free_diskname` returns a fresh Proxmox-side name each time:

```perl
my $volname_clustered = volume_name_clustered( $ctx, $volname );
...
for my $attempt ( 1 .. $max_retries ) {
    ...
    my $clone_name_clustered = volume_name_clustered( $ctx, $clone_name );

    jd_cmd_idemp( $ctx,
        [ "pool", $pool, "volume", $volname_clustered,
          "clone", "--size", $size, "-n", $clone_name_clustered ]
    );
}
return $clone_name;   # Proxmox-side name, no prefix
```

### LUN record consistency

LUN records are file-based local state stored under
`/etc/joviandss/state/<storeid>/`. The record filename is the volname used as
the key. Since all jdssc-bound calls now use the clustered name, LUN records
are also keyed by the clustered name. `lun_record_local_get_info_list` performs
a literal string match (`\Q$name\E`) — it works correctly with any consistent
key, clustered or not.

This is consistent: `_activate_volume` writes the record with
`$volname_clustered` and `path()` / `_deactivate_volume` look it up with the
same key.

### Regex on `$volname` in `Common.pm` — one special case

Inside `volume_stage_multipath` (Common.pm), a regex extracts the vmid from the
volname for the PL-20v2 deep-recovery path:

```perl
my ($v_vmid) = ($volname =~ /^vm-(\d+)-/);
```

At this point `$volname` is the clustered name (it was passed from
`_activate_volume` as `$volname_clustered`). The regex would not match because
the clustered name starts with `<prefix>_vm-`, not `vm-`. The fix applies
`volume_name_unclustered` before the regex:

```perl
my $volname_unclustered = volume_name_unclustered($ctx, $volname) // $volname;
my ($v_vmid) = ($volname_unclustered =~ /^vm-(\d+)-/);
```

The `// $volname` fallback applies only when `volume_name_unclustered` returns
`undef` — i.e. a prefix is configured but `$volname` does not start with it.
That should not occur here (the caller always passes the clustered name); if it
ever did, the regex below would simply fail to match and deep recovery would be
skipped. When no prefix is configured `volume_name_unclustered` returns the name
unchanged, so the fallback plays no role in that case.

The `volume_unpublish` and `volume_publish` calls that follow in the same block
still use the original `$volname` (clustered) — which is correct, since those
calls go to jdssc.

---

## What is NOT changed

| Component | Reason |
|---|---|
| `parse_volname` | Parses Proxmox-side names — prefix is never in those |
| `find_free_diskname` | Calls `list_images` which already strips the prefix; it works on Proxmox-side names |
| Lock naming in `Lock.pm` | Locks are keyed by storeid and vmid, not by volname |
| Snapshot names (`s_`, `se_`) | Snapshots live inside a volume on JovianDSS; the volume's clustered name already scopes them |
| `jdss_common.py` (`vname`/`idname`) | Prefixed names match `vname`'s `^[-\w]+$` pattern, so they pass through as opaque names with the usual `v_` marker; `idname` strips only `v_`, leaving the prefix intact |
| `driver.py` `list_volumes` | Returns `idname(...)` (prefix retained); the prefix-aware filtering lives one layer up in the `volumes` CLI command |
| `OpenEJovianDSSNFSPlugin.pm` | NFS plugin volumes are files on an NFS share; isolation is provided by the NFS export path, not by volume name prefixes |

---

## Configuration

### Property declaration

```perl
cluster_prefix => {
    description =>
      "Volume name prefix for cluster isolation. "
      . "When set, only volumes whose names start with this prefix "
      . "are visible to this storage instance. Allows multiple "
      . "Proxmox clusters to share the same JovianDSS pool without "
      . "seeing each other's volumes. "
      . "Only letters and digits allowed (e.g. 'pveA', 'cluster01').",
    type    => 'string',
    pattern => '[a-zA-Z][a-zA-Z0-9]*',
},
```

### Options entry

```perl
cluster_prefix => { optional => 1, fixed => 1 },
```

### Usage

Set at storage creation time:

```bash
pvesm add joviandss jdss-Pool-0 \
    --pool_name Pool-0 \
    --user_name admin \
    --user_password <password> \
    --control_addresses 192.168.28.100 \
    --data_addresses 192.168.29.100 \
    --cluster_prefix pveA \
    --shared 1
```

The resulting `storage.cfg` entry:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        cluster_prefix pveA
        control_addresses 192.168.28.100
        data_addresses 192.168.29.100
        shared 1
        ...
```

Two clusters sharing `Pool-0` on the same JovianDSS server:

```
# Cluster A — storage.cfg
joviandss: jdss-Pool-0
        pool_name Pool-0
        cluster_prefix pveA
        ...

# Cluster B — storage.cfg
joviandss: jdss-Pool-0
        pool_name Pool-0
        cluster_prefix pveB
        ...
```

Volumes on JovianDSS:

```
v_pveA_vm-100-disk-0   ← owned by cluster A, VM 100
v_pveA_vm-101-disk-0   ← owned by cluster A, VM 101
v_pveB_vm-100-disk-0   ← owned by cluster B, VM 100
v_pveB_vm-200-disk-0   ← owned by cluster B, VM 200
```

Each cluster's `list_images` returns only its own volumes.

---

## Touch Points in `OpenEJovianDSSPlugin.pm`

| Method | Change |
|---|---|
| `properties()` | Add `cluster_prefix` property |
| `options()` | Add `cluster_prefix => { optional => 1, fixed => 1 }` |
| `path()` | `$volname_clustered` for `lun_record_local_get_info_list`, `block_device_path_from_rest`, `volume_deactivate`, `volume_activate` |
| `_rename_volume` | `$original_volname_clustered`, `$new_volname_clustered` for `volume_deactivate`, `volume_unpublish`, `jd_cmd_idemp` rename |
| `_clone_image` | `$volname_clustered` for size read; `$clone_name_clustered` (re-computed each retry) for clone command |
| `_alloc_image` | `$volume_name_clustered` for `volumes create` command |
| `_free_image` | `$volname_clustered` for `volume_deactivate`, `joviandss_cmd` delete |
| `volume_snapshot` | `$volname_clustered` for snapshot create |
| `volume_snapshot_info` | `$volname_clustered` passed to `volume_snapshots_info` |
| `_volume_snapshot_rollback` | `$volname_clustered` for rollback command |
| `volume_rollback_is_possible` | `$volname_clustered` passed to `volume_rollback_check` |
| `_volume_snapshot_delete` | `$volname_clustered` for `volume_deactivate`, snapshot delete command |
| `volume_snapshot_list` | `$volname_clustered` for snapshots list command |
| `volume_size_info` | `$volname_clustered` for volume get size command |
| `_activate_volume` | `$volname_clustered` for `lun_record_local_get_info_list`, `volume_activate`, `volume_deactivate`, `volume_get_size`, `volume_update_size` |
| `_deactivate_volume` | `$volname_clustered` for `lun_record_local_get_info_list`, `volume_deactivate`, `volume_unpublish` |
| `_volume_resize` | `$volname_clustered` for resize command, `lun_record_local_get_info_list` |
| `_create_base` | Pass `--cluster-prefix` to `volumes getfreename` so the free-name search sees prefixed base volumes |
| `list_images` | Pass `--cluster-prefix` to `volumes list`; `volume_name_unclustered` to strip prefix from each returned name |

### One touch point in `Common.pm`

| Location | Change |
|---|---|
| `volume_stage_multipath` — PL-20v2 deep-recovery vmid regex | Apply `volume_name_unclustered` before `/^vm-(\d+)-/` regex to extract vmid from what is now a clustered name at that point |

### Touch points in `jdssc/jdssc/volumes.py`

| Location | Change |
|---|---|
| `list` subparser / `getfreename` subparser | Add optional `--cluster-prefix` argument |
| `list()` vmid filter | When a prefix is given, match `^<prefix>_(vm\|base)-[0-9]+`; VM ID extraction via `split('-')[1]` is unchanged (the prefix has no `-`) |
| `getfreename()` | Search existing volumes with `<prefix>_<volume_prefix>`, but print the bare `<volume_prefix><i>` (Perl re-applies the prefix) |

---

## Files Changed

| File | Change |
|---|---|
| `OpenEJovianDSS/Common.pm` | Add `volume_name_clustered`, `volume_name_unclustered`; export both; fix vmid regex in `volume_stage_multipath` |
| `OpenEJovianDSSPlugin.pm` | Add `cluster_prefix` to `properties()` and `options()`; apply `volume_name_clustered` / `volume_name_unclustered` across 16 methods; pass `--cluster-prefix` from `list_images` and `_create_base` |
| `jdssc/jdssc/volumes.py` | Add `--cluster-prefix` to the `list` and `getfreename` commands; make their volume-name filters prefix-aware so prefixed volumes are not discarded |
