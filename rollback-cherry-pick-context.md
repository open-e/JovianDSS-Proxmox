# Rollback-Semaphore Cherry-Pick — Working Context

_Last updated: 2026-06-19_

## Goal & strategy
Branch **`rollback-semaphor`** rolls back to a commit **before** `3f69198`
("Revert custom iSCSI lock; apply Open-E QA patches PL-4..PL-20v2") and replays
the worthwhile post-`3f69198` commits forward via cherry-pick.

Reason: `3f69198` is a monolithic squash that bundled three different things:
- **(a)** a questionable revert — removed the custom iSCSI lock *and* the race
  fixes that went with it (`force_umount=False` + retry loop), and dropped
  `jdssc/tests/` + design docs;
- **(b)** a fragile new abstraction — the PL-17/18 **Semaphore** (has a taint bug);
- **(c)** genuinely good independent fixes (PL-5, PL-11, PL-13, PL-16 timeout
  classes, PL-20/20v2).

Because it's one squashed commit you can't keep (c) while dropping (a)+(b) — hence
the rollback + selective replay. **A plain "revert the semaphore on main" does NOT
work**: main no longer contains the (a) fixes, they were deleted by `3f69198`.

## Branch topology
- merge-base of `rollback-semaphor` and `main` = **`85b08ae`** ("Fix spacing and text")
- **Base (rollback) world** = custom iSCSI lock: uses `OpenEJovianDSS::Lock::lock_vm`
  (18 refs in Plugin), **no** `Semaphore.pm`, **no** `jd_cmd_idemp` / PL-16 timeout
  classes, **no** `max_parallel_volume_ops`, **no** `volume_name_clustered` (yet).
- **`main` world** (tip `49a999a`) = semaphore + PL patches; custom lock reverted;
  has `jd_cmd_idemp`, PL-20v2, throttle, Semaphore.
- Currently **mid cherry-pick of `29a0397`** ("Add cluster_prefix …").

## PL-patch triage (is the fix already on the base?)
| Patch | Already on base? | Action |
|---|---|---|
| PL-11 (multipathd del-map / `_multipathd_map_exists`) | **Yes** (Common.pm ~3135) | keep, nothing to do |
| PL-5 (clone orphan-snapshot cleanup in `_clone_object`) | **Yes** (base `driver.py` has the "garbage collecting section") | keep |
| PL-13 (eval-guard in `_free_image` so ZVOL delete runs after deactivate fails) | **No** | re-port (it actually rides in via `29a0397` where it touches `_free_image`) |
| PL-16 timeout classes (`jd_cmd_idemp` etc.) | No | only re-port if you want it; cherry-picks assume it exists |
| PL-19/PL-20/20v2 (multipath retry storm + republish) | No | dropped by rollback; decide per-need |

Note: PL-13's companion (volume_deactivate returns 1 on missing LUN record) **is**
already on the base.

## Conflict-resolution rule
For each hunk: **keep the base's lock + `joviandss_cmd(...)` model; take the
incoming `cluster_prefix` semantics (`$volname_clustered` / `volume_name_*`).**
Do **NOT** accept `jd_cmd_idemp` / `jd_cmd_read_list` / `jd_cmd_read_meta` verbatim —
those helpers do **not exist on the base**; translate them back to
`joviandss_cmd($ctx, $cmd, <timeout>, <retries>)`.

## OPEN ISSUES in the current resolution (as of 2026-06-19)
1. **🔴 `volume_stage_multipath` (Common.pm ~2135) won't compile.**
   Signature is base 3-arg `($ctx,$scsiid,$block_devs)` but the body pulled in the
   incoming **PL-20v2** block (~2168–2231) that uses `$volname`/`$snapname` — which
   are not params and not declared → `use strict` compile error. Also re-imports the
   PL-20v2 republish code the rollback meant to drop.
   **Fix:** pick ONE — base's simple 3-arg version (drop PL-20v2), OR the full 5-arg
   incoming version + update signature + all callers. No blending.

2. **🔴 `create_base` getfreename conflict still OPEN (Plugin.pm ~615–640).**
   - HEAD draft (`# TODO: buggy section`): `if defined($cluster_prefix) {` is a syntax
     error (needs `if (defined(...))`); `push @$getfreename_cmd,...` uses a var never
     defined on that side.
   - Incoming: `jd_cmd_read_list(...)` — missing on base.
   - **Correct shape:** build `$getfreename_cmd` array, conditionally
     `push @$getfreename_cmd, '--cluster-prefix', $cluster_prefix` when defined, then
     `joviandss_cmd($ctx, $getfreename_cmd, 118, 5)`.

3. **🟡 `_deactivate_volume` (Plugin.pm ~1593) — verify** `volume_unpublish` uses
   **`$volname_clustered`**, not `$volname` (it passes `-v $volname` to jdssc; on a
   cluster_prefix pool plain `$volname` misses). The record-ordering part is already
   fixed (`$had_lun_record` computed BEFORE `volume_deactivate`, which deletes the
   local record via `volume_deactivate_by_lun_record` → `lun_record_local_delete`).

Resolved `Common.pm` has **no dangling `jd_cmd_*` calls** (only the one in the still-open
Plugin conflict #2). Fix #1 and #2 and the infra-dependency problem is contained.

**Verify mechanically:** `scp` Common.pm + Plugin.pm to `pve-91-1` and run `perl -c`
(real PVE modules there; can't compile locally — missing String::Util/PVE). This catches
all undefined-var/syntax errors at once.

## Production log evidence (logs/pve-3-2 & pve-3-3, the affected cluster)
- **`-EBUSY` multipath failure is real & recurring** — episodic (2026-06-10/11/16),
  same WWIDs (`23661323338373437`, `23730323237363064`), a single `multipath <wwid>`
  spins ~5 min retrying `addmap`, always preceded by `iscsiadm … "No active sessions"`
  → it's reloading a **stale/wedged map** with no live paths.
- **Semaphore taint bug confirmed** — 357× `Insecure dependency in kill … Semaphore.pm`
  on pve-3-3 in a 6-min burst (2026-06-16 12:21–12:27). Breaks dead-holder cleanup on
  every acquire. Correlates in time with a fresh EBUSY batch → broken semaphore stops
  throttling → concurrent multipath staging → more EBUSY. (But EBUSY also occurs without
  it, so EBUSY is its own bug.)
- `Unable to identify lun record for … vm-N-state-…` warnings = the state-volume
  deactivate path being edited (migration source-node "no local record" case).

## Multipath EBUSY fix direction (separate from the rollback)
The base already has the **hard-flush** sequence in the *unstage* path
`_volume_unstage_multipath_remove_device` (~3079): `multipathd del map` → `multipath -f`
→ `dmsetup remove`. The **staging** path `volume_stage_multipath` never flushes — it just
reloads a wedged map and spins on EBUSY.
**Fix:** before assembling the map (top of `volume_stage_multipath`, ~after `my $id=$1`),
if a stale/pathless map for `$id` exists, hard-flush it first, then rebuild. Factor the
teardown into a `_hard_flush_map($ctx,$id)` helper and **add a `dmsetup message <wwid> 0
fail_if_no_path` drain step at the front** (the base teardown lacks it; needed when a map
is wedged by `queue_if_no_path` queued I/O — `multipath -f` returns "map or partition in
use" until drained).

## Side facts
- `on_add_hook` PVE-9 result `config` taint/object bug and `force_rollback` hardening are
  already committed on **main** (`49a999a`, `957a17b`) — separate from this branch.
- Test clusters **pve-91** (node1/2/3) and **pve-92** (pve-node-1/2/3) both run kernel
  **7.0.2-pve**, where the exact `-EBUSY` could NOT be reproduced (dm shares path devices
  freely there). The affected PVE-3 cluster's `uname -r` is still unknown — likely the gate.
