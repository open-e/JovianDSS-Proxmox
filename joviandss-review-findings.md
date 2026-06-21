# JovianDSS Proxmox Plugin — Code Review Findings
Date: 2026-04-16

---

## Changes Already Applied

### 1. `OpenEJovianDSS/Common.pm:553` — `clean_word` missing `g` flag
```perl
# Before:
$word =~ s/[^[:ascii:]]//;
# After:
$word =~ s/[^[:ascii:]]//g;
```

### 2. `OpenEJovianDSSPlugin.pm` `_create_base` — refactor inline strip to `clean_word()`
```perl
# Before:
chomp($newname);
$newname =~ s/[^[:ascii:]]//g;
# After:
$newname = clean_word($newname);
```

### 3. `OpenEJovianDSSPlugin.pm` `volume_size_info` — refactor inline strip to `clean_word()`
```perl
# Before:
chomp($size);
$size =~ s/[^[:ascii:]]//g;
return $size;
# After:
return clean_word($size);
```

---

## Bugs (Unresolved)

### BUG-1 — `block_device_path_from_lun_rec` multipath path overwritten  [CRITICAL]
**File:** `OpenEJovianDSS/Common.pm` ~line 1885
**Impact:** When multipath is enabled and a device is already staged, the function always returns
the non-multipath `/dev/disk/by-id/...` path instead of the `/dev/mapper/...` path. VMs using
multipath get the wrong block device.

**Fix:** Add `return $block_device_path;` inside the `if (get_multipath($ctx))` block after
setting `$block_device_path = block_device_path_from_serial($id, 1)`:
```perl
if ( get_multipath($ctx) ) {
    unless ($lunrec->{multipath}) {
        ...
        return $block_dev;
    }
    $block_device_path = block_device_path_from_serial( $id, 1 );
    return $block_device_path;   # ADD THIS — currently missing, falls through below
}
# Without the return above this unconditionally overwrites:
$block_device_path = block_device_path_from_serial( $id, 0 );
```

---

### BUG-2 — `volume_unstage_iscsi_device`: `basename(undef)` crash risk  [HIGH]
**File:** `OpenEJovianDSS/Common.pm` ~line 2197
**Impact:** If `$bdp` is undef (device lookup failed), `basename($bdp)` throws a fatal Perl
exception, crashing the deactivate path without cleanup.

**Fix:** Guard before calling `basename`:
```perl
if (!defined $bdp || $bdp eq '') {
    WARN "block device path is undefined for $scsiid";
    return;
}
```

---

### BUG-3 — `lun_record_local_delete`: unchecked `opendir` causes premature iSCSI logout  [HIGH]
**File:** `OpenEJovianDSS/Common.pm` ~line 2933
**Impact:** If `opendir` fails silently, `@entries` is empty, and `volume_unstage_iscsi` is
called even though other LUN records still exist — causing unexpected iSCSI disconnect.
```perl
opendir( $dh, $ltdir );          # no 'or die' — silent failure
my @entries = grep { ... } readdir $dh;
unless ( @entries ) {
    volume_unstage_iscsi(...);   # incorrectly called when opendir failed
```
**Fix:**
```perl
opendir( my $dh, $ltdir ) or do {
    WARN "cannot open $ltdir: $!";
    return;
};
```

---

### BUG-4 — `get_control_addresses` rejects short valid IPv6 addresses  [MEDIUM]
**File:** `OpenEJovianDSS/Common.pm` ~line 279
**Impact:** `length($addr) > 4` rejects `::1` (3 chars) and any short valid IPv6 address.
**Fix:** Change `> 4` to `> 0`.

---

### BUG-5 — `vm_tag_force_rollback_is_set` whitespace in tag value  [MEDIUM]
**File:** `OpenEJovianDSS/Common.pm` ~line 3532
**Impact:** Proxmox tag strings may have leading/trailing whitespace after split (e.g.,
`"tag1; force_rollback"` splits to `" force_rollback"`). String equality check fails silently.
```perl
my @tags = split(/[,;]/, $conf->{tags});
foreach my $tag (@tags) {
    if ($tag eq 'force_rollback') {   # fails for " force_rollback"
```
**Fix:** Trim each tag before comparison:
```perl
$tag =~ s/^\s+|\s+$//g;
```

---

### BUG-6 — `safe_ford` declared in `@EXPORT_OK` but does not exist  [MEDIUM]
**File:** `OpenEJovianDSS/Common.pm` ~line 51
**Impact:** Any caller that imports `safe_ford` will get a runtime error. Dead symbol in exports
creates confusion.
**Fix:** Remove `safe_ford` from `@EXPORT_OK`.

---

### BUG-7 — `lun_record_update_device` double sleep inside lock window  [MEDIUM]
**File:** `OpenEJovianDSS/Common.pm` ~line 3289
**Impact:** Loop sleeps 1s at the top AND 1s at the bottom per iteration — up to 20s total delay
while holding the cluster lock. pmxcfs drops locks not refreshed within ~120s; under concurrent
load this can burn a significant fraction of the execution budget.
**Fix:** Remove one of the two `sleep(1)` calls; sleep once per iteration.

---

### BUG-8 — `OpenEJovianDSSPlugin.pm:~392` — `sleep(3)` before `die` (debugging artifact)  [LOW]
**File:** `OpenEJovianDSSPlugin.pm` ~line 392
**Impact:** 3-second stall in the `path()` error path when multiple LUN records are found.
Stalls Proxmox storage operations unnecessarily.
**Fix:** Remove `sleep(3)`.

---

## Design Issues (Unresolved)

### DESIGN-1 — Multi-cluster pool sharing impossible due to hardcoded target group names  [HIGH]
**File:** `OpenEJovianDSS/Common.pm` lines 1361, 1366
**Impact:** Two PVE clusters sharing one JovianDSS pool will have:
- Target group name conflicts: `vm-<vmid>` and `proxmox-content` are identical across clusters
- Volume name conflicts: `vm-<vmid>-disk-N` — same VMID in both clusters → same volume name
- One cluster can interfere with or delete another cluster's iSCSI targets/volumes

**Category 1 (volume names):** Requires separate JovianDSS pools per PVE cluster, OR guarantee
of non-overlapping VMID ranges across clusters.

**Category 2 (target group names):** Can be fixed by adding a `cluster_name` config option:
```perl
sub get_vm_target_group_name {
    my ( $ctx, $vmid ) = @_;
    my $cluster = $ctx->{cluster_name} // '';
    return $cluster ? "${cluster}-vm-${vmid}" : "vm-${vmid}";
}
sub get_content_target_group_name {
    my ($ctx) = @_;
    my $cluster = $ctx->{cluster_name} // '';
    return $cluster ? "${cluster}-proxmox-content" : "proxmox-content";
}
```
This eliminates iSCSI target group conflicts even when volumes are in the same pool.

---

### DESIGN-2 — CHAP authentication: ADR accepted but not implemented  [HIGH]
**ADR:** `docs/adr/0001-add-chap-auth.md` (Status: Accepted, 2026-04-15)
**Decision:** Single shared CHAP password per storage configuration.
**Current state:** Zero CHAP-related code exists in Plugin.pm or Common.pm.

**Implementation requires:**
1. Add to `properties()` in Plugin.pm:
   - `chap_enabled` (boolean)
   - `chap_user_name` (string)
   - `chap_user_password` (string, stored in `.pw` file)
2. Pass credentials to `jdssc targets create` during `volume_publish`
3. Configure local `iscsiadm` node auth before login during `volume_activate`

---

### DESIGN-3 — Double pvesh call for HA state in `volume_rollback_is_possible`  [LOW]
**File:** `OpenEJovianDSS/Common.pm` ~lines 1964, 2007
**Impact:** `ha_state_is_defined` and `ha_state_get` each independently call
`pvesh get /cluster/ha/resources/<vmid>`, meaning two HTTP round-trips for the same data
in a single `volume_rollback_is_possible` call.
**Fix:** Combine into one call that returns both existence and the state value.

---

## Code Quality / Naming

### QUALITY-1 — `store_settup` typo
**File:** `OpenEJovianDSS/Common.pm` ~line 3484
**Fix:** Rename `store_settup` → `store_setup` (and update all call sites).

### QUALITY-2 — Stale TODO comments
**File:** `OpenEJovianDSSPlugin.pm`
- Line ~38: `#TODO: comment/uncomment to enable criticue operation` — unclear intent
- Line ~863: `#TODO: rename jdssc variable`
- Line ~341: `#TODO: reevaluate this section` — deactivate/reactivate on lun miss

### QUALITY-3 — NFS clone not enforced read-only on server side
**File:** `OpenEJovianDSS/NFSCommon.pm` ~line 167
**Note:** `# TODO: Make sure that clone is mounted as READONLY` — NFS mount uses `-o ro` client
option but JovianDSS clone itself may not be configured read-only on the server. Client-only
`ro` mount can be bypassed in some NFS configurations.

---

## `rollback-by-xcopy` Branch Issues (Not on `main`)

- `_volume_snapshot_rollback` still calls `run_xcopy_chunk` — proven to NOT copy block data on
  JovianDSS ZVOLs (xcopy is metadata-only for ZVOL-to-ZVOL). Must be replaced with `run_dd_chunk`.
- Diagnostic/test code must be removed before merge: zero-write test, pre/post SHA1 computation,
  `sg_sync` call, `sleep 15`.
- `run_dd_chunk` implementation is correct and should be the primary (only) copy method.
- `lock_renew` added to `Lock.pm` on this branch — needed for long dd operations to keep cluster
  lock alive within pmxcfs ~120s window.

---

## Priority Order for Fixes

| Priority | Item | File | Impact |
|----------|------|------|--------|
| 1 | BUG-1: multipath path overwritten | Common.pm ~1885 | Wrong block device → data corruption risk |
| 2 | DESIGN-1: multi-cluster naming | Common.pm 1361,1366 | Two clusters can collide |
| 3 | DESIGN-2: CHAP not implemented | Plugin.pm + Common.pm | ADR accepted, security gap |
| 4 | BUG-2: basename(undef) crash | Common.pm ~2197 | Deactivate path crash |
| 5 | BUG-3: unchecked opendir | Common.pm ~2933 | Premature iSCSI logout |
| 6 | BUG-5: tag whitespace trim | Common.pm ~3532 | force_rollback tag silently ignored |
| 7 | BUG-4: address length check | Common.pm ~279 | Short IPv6 addresses rejected |
| 8 | BUG-6: safe_ford dead export | Common.pm ~51 | Runtime error if imported |
| 9 | BUG-7: double sleep in lock | Common.pm ~3289 | 20s stall under lock |
| 10 | BUG-8: sleep(3) before die | Plugin.pm ~392 | 3s unnecessary stall |
| 11 | QUALITY-1: store_settup typo | Common.pm ~3484 | Cosmetic |
| 12 | DESIGN-3: double HA pvesh | Common.pm ~1964 | Minor perf |
