# Code Review: rollback-semaphor branch

## Files Reviewed
- [x] OpenEJovianDSS/Common.pm
- [x] OpenEJovianDSS/NFSCommon.pm
- [x] OpenEJovianDSSPlugin.pm
- [x] jdssc/jdssc/volumes.py
- [x] jdssc/jdssc/jovian_common/rest.py
- [x] jdssc/jdssc/jovian_common/rest_proxy.py
- [x] jdssc/jdssc/jovian_common/driver.py

## Summary
REQUEST_CHANGES — 8 commits, two feature areas (cluster_prefix isolation + rollback hardening) plus intentional removal of REST-level locking. Most cluster_prefix wiring is coherent but there is at least one concrete correctness bug in getfreename, commented-out merge artifacts, and an indentation regression.

## Critical Issues (Must Fix)

- [ ] `jdssc/jdssc/volumes.py:258` — **getfreename breaks with cluster_prefix**: `present_volumes` is populated with clustered names (`pveA_base-100-disk-0`) but `nname` is bare (`base-100-disk-0`), so `nname not in present_volumes` is always True. More critically, the fallback `self.jdss.get_volume({'id': nname})` also uses the bare name, which won't find the existing clustered volume. Net effect: when cluster_prefix is set, `getfreename` always returns `<prefix>0` regardless of collisions. Perl's retry loop in `create_base` will hit 10 "already exists" errors and die.

- [ ] `OpenEJovianDSSPlugin.pm:724` — **Commented-out git merge marker**: `#>>>>>>> 29a0397 (Add cluster_prefix for sharing a JovianDSS pool across clusters)` is a leftover from manual conflict resolution. Should be deleted.

## Suggestions (Should Consider)

- `OpenEJovianDSS/Common.pm:639` — Missing indentation on `return $size;` inside `get_content_volume_size`. Diff introduced `return $size;` (no leading whitespace) instead of `    return $size;`. Cosmetic but inconsistent.

- `jdssc/jdssc/jovian_common/rest.py` — Locking is commented out (not removed) across 8 target operations (create, delete, add_cred, set_active, set_vips, remove_cred, attach_lun, detach_lun). The commit message says this is intentional ("Comment out rest api level locking"). This removes concurrency protection on iSCSI target mutations. Needs documented rationale — is the lock being moved to a higher level (Perl semaphore), or is it being permanently dropped?

- `jdssc/jdssc/jovian_common/rest_proxy.py` — Retry counts cut from 50→17 (outer loop) and 50→5 (JSON decode error). No comment explaining why. If the original 50 covered real-world transient failures, 5 may be too few.

- `OpenEJovianDSS/Common.pm` — `get_cluster_prefix` validates with `/[[:alnum:]]/` (just "contains at least one alphanum") but the config property pattern is `[a-zA-Z][a-zA-Z0-9]*` (must start with letter). These don't agree; a prefix like `1bad` would pass the Perl check but be rejected at config parse time.

## Positive Notes

- `vm_tag_force_rollback_is_set` retry/hardening is well-structured: clear retry loop, distinct `_vm_tag_force_rollback_read` helper, explicit die on persistent failure, and useful debug logging at every exit path.

- `volume_name_clustered` / `volume_name_unclustered` pair in Common.pm is clean — the `s/^\Q${prefix}\E_//` regex safely handles special characters in prefix.

- `on_add_hook` returning `undef` for PVE 9.x compatibility is a targeted, correct fix.

- `list_snapshots` guid/creation property fix in driver.py is straightforward.

## Deep Analysis: getfreename cluster_prefix bug

### Root Cause — Two Compounding Defects

**Defect 1 — `volumes.py:258`: bare vs clustered name mismatch in `getfreename`**

`present_volumes` is populated with clustered names (e.g., `"pveA_base-100-disk-0"`) because
`search_prefix = "{cluster_prefix}_{volume_prefix}"`. But the candidate loop uses the bare name:

```python
nname = volume_prefix + str(i)          # "base-100-disk-0"
if nname not in present_volumes:        # always True — bare never matches clustered
    vd = {'id': nname}                  # bare name in REST lookup too
    data = self.jdss.get_volume(vd)     # 404 — JovianDSS stores "pveA_base-100-disk-0"
```

Both the membership check AND the REST fallback use the bare name. Result: `getfreename` always
returns index 0 regardless of how many `pveA_base-N-disk-*` volumes already exist on JovianDSS.

**Defect 2 — `OpenEJovianDSSPlugin.pm:802`: `find_free_diskname` omits `--cluster-prefix`**

`create_base` (line 621) correctly passes `--cluster-prefix` to `getfreename`. But
`find_free_diskname` (used by `_clone_image` and `_alloc_image`) does not:

```perl
my $newname = joviandss_cmd( $ctx,
    [ "pool", $pool, "volumes", "getfreename",
        '--prefix', $newnameprefix, '--suffix', $suffix ],
    118, 5
);
```

No `--cluster-prefix` → Python searches with bare `volume_prefix`, finds nothing in JovianDSS
(all volumes are `"pveA_vm-N-disk-*"`), returns index 0 unconditionally.

### Blast Radius

**`create_base` (Defect 1 only)**

Fails silently on the first call only when `"pveA_base-{vmid}-disk-0"` already exists. Concrete
scenario:

1. VM 100 has two disks: `pveA_vm-100-disk-0` and `pveA_vm-100-disk-1`.
2. `create_base(vm-100-disk-0)` succeeds → JovianDSS now has `pveA_base-100-disk-0`.
3. `create_base(vm-100-disk-1)` calls `getfreename(--prefix base-100-disk- --cluster-prefix pveA)`:
   - `present_volumes = ["pveA_base-100-disk-0"]`
   - `"base-100-disk-0" not in ["pveA_base-100-disk-0"]` → **True** (BUG)
   - REST: `get_volume({"id": "base-100-disk-0"})` → 404 → returns `"base-100-disk-0"` (index 0)
4. `_rename_volume("vm-100-disk-1", "base-100-disk-0")` → `"pveA_base-100-disk-0"` already
   exists → "already exists" error.
5. Perl retry loop retries 10 times, `getfreename` returns index 0 each time → **dies**.

The Perl retry loop in `create_base` does NOT rescue correctness — `getfreename` always
produces the same (wrong) answer.

**`clone_image` (Defect 2 only)**

First clone for a given vmid+disk-index works (index 0 is genuinely free). Second clone fails:

1. VM 101 already has `pveA_vm-101-disk-0` on JovianDSS.
2. `clone_image` calls `find_free_diskname` → `getfreename(--prefix vm-101-disk-)` (no cluster prefix).
3. Python: `present_volumes = []` (no bare-named volumes match), returns `"vm-101-disk-0"` (i=0).
4. `clone_name_clustered = "pveA_vm-101-disk-0"` → "already exists".
5. Retry calls `find_free_diskname` again → same result → **dies after 10 retries**.

**`alloc_image` (Defect 2 only)**

Same path as clone_image via `find_free_diskname`. Second disk allocated for the same VM fails
because index 0 is taken and the name-finding loop can't see past it.

### Fixes Required

**Fix A — `jdssc/jdssc/volumes.py:253–268`**: compare using the stored (clustered) name:

```python
for i in range(0, sys.maxsize):
    nname = volume_prefix + str(i)
    nname_stored = "{0}_{1}".format(cluster_prefix, nname) if cluster_prefix else nname
    if nname_stored not in present_volumes:
        vd = {'id': nname_stored}
        try:
            data = self.jdss.get_volume(vd)
        except jexc.JDSSVolumeNotFoundException:
            print(nname)   # return bare name — Perl re-applies cluster prefix
            return
        except jexc.JDSSResourceNotFoundException:
            print(nname)
            return
```

**Fix B — `OpenEJovianDSSPlugin.pm:802`**: add `--cluster-prefix` in `find_free_diskname`:

```perl
my $cluster_prefix = OpenEJovianDSS::Common::get_cluster_prefix($ctx);
my $cmd = [ "pool", $pool, "volumes", "getfreename",
    '--prefix', $newnameprefix, '--suffix', $suffix ];
push @$cmd, '--cluster-prefix', $cluster_prefix if defined($cluster_prefix);
my $newname = joviandss_cmd( $ctx, $cmd, 118, 5 );
```

Both fixes are needed: Fix A alone is incomplete (Defect 2 bypasses it for clone/alloc paths).

### Retry Loop Assessment

The 10-retry loops in `create_base` and `_clone_image` do NOT mitigate this bug. They were
designed for TOCTOU races (volume appears between list and create), but here `getfreename`
returns the identical wrong answer on every retry. All 10 attempts fail with "already exists"
and the operation dies.

## Needs Deep Analysis

2. **REST locking removal**: understand whether the Perl-level semaphore (rollback-semaphor branch name hints at this) fully replaces the removed locking, or if there are unprotected concurrent paths.
