# Test campaign 4 — HEAD 93e9bf0 (target re-home + sharing guards + NFS leak fix), plugin 0.11.6

- Date: 2026-07-08 · Cluster: pve-91-1/2/3, PVE 9.1 · Agent-run, ~4 h wall
- Git HEAD under test: `93e9bf0` "Poll more aggressively for cluster locks near
  the deadline" (parents d7b4f20 target-attach hardening, daefcce NFS leak fix).
- Focus: the NEW behaviors added since campaigns 1/2/3 — target_prefix re-home,
  shared-target collision refusal (C2-02 Cut 3), credentials-required-at-add
  (C3-02), NFS `qm destroy` frees files (C3-01) — plus a full lifecycle
  regression (F-02/F-03/F-04/F-19, storm, 4 migration modes incl. online under
  in-guest fio) on both the mpath0 and mpath1 iSCSI paths.

## Phase-0 md5 baseline (deployed vs repo HEAD, all 3 nodes)

All FIVE Perl modules byte-identical to repo HEAD on n1/n2/n3:
`Common.pm b36192772…`, `Lock.pm 2cd352b60…`, `NFSCommon.pm 3498b89023…`,
`OpenEJovianDSSPlugin.pm 60932d7ef…`, `OpenEJovianDSSNFSPlugin.pm a64812d46…`.
All jdssc python byte-identical to HEAD **except `jovian_common/driver.py`**:
deployed `eaf1ce4aaa…` vs repo `ac0da6e0b6…`.

**The driver.py delta is a single line and behaviorally inert.** HEAD's own
commit 93e9bf0 commented out one `LOG.debug("Page: %s", str(spage))` in the
generic pagination helper `_list_all_pages` (driver.py:2676); the deployed build
predates that one-line comment-out (it still emits the line). Everything else
93e9bf0 changed — the Lock.pm/Common.pm poll-aggressively logic and rest_proxy.py
— IS deployed (those md5s match HEAD). So the deployed build is HEAD for every
behavior under test; the sole difference is one extra DEBUG log line during REST
list pagination. **Confirmed live** during the campaign: the deployed build
emits `jdssc.jovian_common.driver - DEBUG - [reqid] Page: [{…}]` lines (HEAD
suppresses them). I judged this a no-op and proceeded rather than halt the
campaign over an inert debug line; flagged here so the maintainer can rebuild
driver.py for exact HEAD parity if desired.

Cluster quorate 3/3; all storages active. Node-side clean of 990xxx (0
sessions/state/mappers/configs on all nodes). Array Phase-0 baseline recorded:
Pool-2 = 20 volumes / 40 targets, Pool-0 = 12 volumes / 8 targets. The Pool-2
baseline already contained two **pre-existing 990xxx orphan targets** —
`iqn.2025-04.proxmox.pool2-rehome:vm-990061-0` and
`iqn.2025-04.proxmox.pool2-rh2:vm-990062-0` (empty: no LUNs, no sessions) — the
residue of the maintainer's own re-home verification (design doc:
"prefix re-home live-verified same-node and cross-node"). Left in place per the
campaign-1/2 precedent for maintainer fixtures.

## Results table

| Item | Tag | Verdict | Dur | Evidence (one line) |
|---|---|---|---|---|
| 0 md5 deployed==HEAD | — | PASS w/ NOTE | — | 5 Perl + all py identical; driver.py off by HEAD's own 1-line debug comment-out (inert; live-confirmed emitting "Page:") |
| 0 baselines | — | PASS | — | Pool-2 20 vol/40 tgt, Pool-0 12/8; node-side 0×990xxx; 2 pre-existing 990061/990062 orphan tgts noted |
| **P2.1 re-home (idle)** | **NEW** | **PASS** | 27s | array tgt `pool-2:vm-990001-0`→`rehome-a:vm-990001-0`; log "…is idle - detaching to re-home" |
| **P2.1 keep-in-place** | **NEW** | **PASS** | 5.4s | active session n1, activate n2 → tgt UNCHANGED; log "…active sessions - keeping it in place" |
| **P2.1 plain-deact no-detach** | **NEW** | **PASS** | — | deactivate leaves array LUN `active=True` on same tgt; reactivate reuses it |
| **P2.2 collision refusal** | **C2-02** | **PASS** | 5s | clean marker-stripped refusal; 1st device md5 identical, 2 sessions; coll LUN unpublished, no record, free needs no detach |
| **P2.2 reactive logout-skip** | **C2-02** | **PASS** | — | seeded coexistence → "Skipping iSCSI logout … shared between storages"; sessions stayed 2 |
| **P2.3 creds required** | **C3-02** | **PASS** | <1s | no-pw add → "user password is not stored" (cfg untouched); with-pw → 0600 pw, absent from cfg; remove clean |
| **P2.4 NFS destroy frees files** | **C3-01** | **PASS** | — | qm destroy → all files+dir gone; detach → unused0; unlink --force → file gone |
| 1.hp mpath0 | — | PASS | 4.1/2.5/1.0s | pytest-jdss-Pool-2 by-id path, 2 sessions, clean free |
| 1.hp mpath1 | — | PASS | 4.9/2.4/1.1s | jdss-Pool-2 /dev/mapper, both paths active ready running, map torn down |
| 1.CT + mp0 + fio | — | PASS | — | CT 990011 rootfs+mp0 boot; fio 36.4k IOPS/142MiB/s; marker |
| 1.VM + disks + vTPM | — | PASS | 13.5s start | VM 990010 scsi0+scsi1+tpmstate0 v2.0 swtpm, running |
| 1.F-19 online resize | F-19 | PASS | 8.6s | 4→5G running; only "Verify round 1/10", 0 attempt-error |
| 1.F-02 3× rollback | F-02 | PASS | — | s1 rolled back ×3, all RC=0 |
| 1.F-04 snap-act + clone-presnap + RB-over-resize | F-04 | PASS | — | snap 5G→resize 6G→clone-from-s_f04 OK→rollback back to 5G |
| 1.F-03 template rename + linked clone | F-03 | PASS | 42s | verbatim "Rename volume vm-990012-disk-{0,1,2} to base-…"; linked 990014 |
| 1.full clone / clone-from-snap | — | PASS | — | 990012 full clone from snapshot; 990041 full clone (mpath0) |
| 1.4-guest storm | F-05/F-01 | PASS | — | 990030-33 simultaneous start(all running)+stop(all stopped) across 3 nodes; 0 lock artifacts |
| 1.mig CT restart | — | PASS | 24.6/22.9s | 990011 n1↔n2, running, /mnt/test marker intact |
| 1.mig VM offline | — | PASS | 3.2/3.1s | 990010 n1↔n2 config-only |
| 1.mig VM online idle | — | PASS | 23s | 990010 n1→n2, running |
| 1.mig VM online under fio | KEY | PASS | 24/18s | 990050 (101 clone) fio err=0 spanning both legs; no real guest IO errors |
| 1.vzdump → BS | — | PASS | — | CT 990011 + VM 990010 both "Backup job finished successfully" |
| 1.thin/discard | — | OBSERVED | — | blkdiscard clean, no errors; array-usage readback unreliable (REST-list staleness under concurrent load) |
| 1.mpath0 lifecycle | — | PASS | — | 990040 snapshot/rollback/clone all RC=0 (single-path) |
| P3 teardown + audit | — | PASS | — | 0×990xxx residue anywhere (mine); Pool-0 array byte-identical; Pool-2 drift = third-party only; 0 lock artifacts |

## Verbatim artifacts (the NEW behaviors)

### P2.1 re-home — array before/after + driver log

```
array target after activate:      iqn.2025-04.proxmox.pool-2:vm-990001-0 lun=0 active=True
--- plain deactivate (prefix unchanged) ---
array target after deact:         iqn.2025-04.proxmox.pool-2:vm-990001-0 lun=0 active=True   # NOT detached
--- set target_prefix iqn.2026-07.rehome-a: ; deactivate (idle) ; reactivate ---
array target AFTER re-home:        iqn.2026-07.rehome-a:vm-990001-0 lun=0 active=True         # CHANGED
```
```
2026-07-08 12:26:43.104 - jdssc.jovian_common.driver - INFO - [654ede43] Volume v_vm-990001-disk-0 is on target iqn.2025-04.proxmox.pool-2:vm-990001-0 which does not match the configured target_prefix and is idle - detaching to re-home it under the new prefix
```
Keep-in-place (vol active on n1, prefix→rehome-b, activate on n2):
```
array target after node2 activate: iqn.2026-07.rehome-a:vm-990001-0 lun=0 active=True         # UNCHANGED
2026-07-08 12:27:48.650 - jdssc.jovian_common.driver - INFO - [7236ef0e] Volume v_vm-990001-disk-0 is on target iqn.2026-07.rehome-a:vm-990001-0 which does not match the configured target_prefix, but it has active sessions - keeping it in place
```

### P2.2 shared-target collision refusal (C2-02 Cut 3)

Two storages on Pool-2 sharing `iqn.2025-04.proxmox.pool-2:` (jdss-Pool-2 plain +
temp jdss-collide with `cluster_prefix coll`, distinct zvols), same vmid 990002.
jdss-Pool-2 vol active (md5 `361632cf…`, 2 sessions). Activating the sharer:

```
storage 'jdss-collide' refuses to attach volume coll_vm-990002-disk-0 to iSCSI target iqn.2025-04.proxmox.pool-2:vm-990002-0: storage 'jdss-Pool-2' already uses this target on this node. Different storages MUST use different target_prefix values (see docs/Cluster-Prefix.md).
```
Clean (no `joviandss-target-collision:` marker leaking to the operator). Internal
log carries the marker and fails fast at cycle 1 (no 4-cycle churn):
```
2026-07-08 12:37:42.951 - plugin - WARN - [a0d1495c] Activation cycle 1 of volume coll_vm-990002-disk-0 failed: joviandss-target-collision: storage 'jdss-collide' refuses to attach volume …
```
Non-destructive & no-leak: jdss-Pool-2 device survived (`md5 361632cf…` unchanged,
2 sessions), the sharer's LUN was unpublished (`coll LUN attached: False`), no
local record was created, and `pvesm free` of the sharer needed **no** detach.

Reactive logout-skip guard (seeded foreign record, since Cut 3 prevents the
natural two-storeid coexistence — deactivating jdss-Pool-2's real vol with a
jdss-collide record present under the shared target):
```
Skipping iSCSI logout of target iqn.2025-04.proxmox.pool-2:vm-990002-0: storage 'jdss-collide' still has volumes on it. This iSCSI target is shared between storages; give each storage its own target_prefix to avoid sharing targets.
```
Sessions stayed at 2 (live device protected); clean logout to 0 after removing
the seed.

### P2.3 credentials required at storage creation (C3-02)

```
# add WITHOUT --user_password (path supplied so validation reaches the hook):
create storage failed: storage 'jdss-nopw': JovianDSS REST user password is not stored; supply --user_password
# → storage.cfg: 0 lines for jdss-nopw ; .pw: NONE
# add WITH --user_password:
RC=0 ; -rw------- root www-data 21 /etc/pve/priv/storage/joviandss/jdss-nopw.pw ; password NOT in storage.cfg
```

### P2.4 NFS qm destroy frees files (C3-01)

```
# VM 990003, 2 disks on jdss-nfs-Pool-2-data2:
images/990003/vm-990003-disk-0.raw (2G) + vm-990003-disk-1.raw (1G)  → qm destroy → DIR-GONE (both files + dir removed)
# detach + unlink:
qm set 990004 --delete scsi1  → config: "unused0: jdss-nfs-Pool-2-data2:990004/vm-990004-disk-1.raw" ; file remains
qm disk unlink 990004 --idlist unused0 --force  → RC=0 ; file GONE
```

### Lifecycle regression highlights

```
# F-19 single-pass (both lines are round 1 of 10, no escalation, 0 attempt-error):
13:07:57 … Verify round 1/10 for target iqn.2025-04.proxmox.pool-2:vm-990010-0 lun 0 …
13:08:02 … Verify round 1/10 for target iqn.2025-04.proxmox.pool-2:vm-990010-0 lun 0 …
# F-02: rollback #1/#2/#3 → "Rollback: … to snapshot s1 complete" RC=0 ×3
# F-03: Rename volume vm-990012-disk-0 to base-990012-disk-0  (+ disk-1, disk-2) → array v_base-990012-disk-0/1/2
# online-migrate-under-fio result:
mig: err= 0: … write: IOPS=1034, BW=4138KiB/s (485MiB, 120010msec)   (guest strict IO-error grep = 0)
```

## Numbers

- Happy path mpath0 (pytest): activate 4.13 s, warm 2.46 s, deact 1.01 s, 2 sessions.
- Happy path mpath1 (jdss-Pool-2): activate 4.89 s, warm 2.40 s, deact 1.15 s;
  both paths (sdc 3:0:0:0, sdd 4:0:0:0) active ready running; map gone on deact.
- CT fio (mp0, jdss-Pool-2): randwrite 4k iod8 = 36.4k IOPS / 142 MiB/s.
- Online resize 8.62 s single pass; snapshot 2.92 s; template rename 42.3 s.
- 20G template-101 full clone → jdss-Pool-2: ~5 min (slow — array under concurrent
  third-party load, see caveats).
- Migrations: CT restart 24.6/22.9 s; VM offline 3.2/3.1 s; online idle 23 s;
  online under fio 24.0/18.2 s.
- fio during migration: 1034 IOPS, 4138 KiB/s, io=485 MiB over 120 s, **err=0**;
  one benign boot-time `sd 0:0:0:0: Power-on or device reset occurred` in guest
  dmesg (uptime 11.8 s, not migration-related); strict IO-error grep = 0.
- Re-home activation 27.3 s (heavier: detach old target + republish + login).

## Findings / defects

### D4-01 (minor, NEW) — re-home + subsequent free leaves an empty orphan target
After re-homing vm-990001 to `iqn.2026-07.rehome-a:` and then `pvesm free`-ing it,
the array retained an empty `iqn.2026-07.rehome-a:vm-990001-0` target (no LUN, no
session). I deleted it via the array API to keep the end-state clean. The two
pre-existing Phase-0 orphans `pool2-rehome:vm-990061-0` / `pool2-rh2:vm-990062-0`
are the same pattern from the maintainer's own re-home verification, confirming
this is reproducible: the old-prefix target's own removal happens on re-home
detach, but the **new-prefix** target is not cleaned when its last (and only) LUN
is later removed by free. Likely intertwined with F-10 (zombie-target cleanup on
a 1% RNG lottery — no deterministic empty-target GC). No data-integrity or
device impact; a cleanup/leak-hygiene gap. Fix direction: delete a target when
its last LUN detaches (free path), or a real periodic orphan-target GC.

### Environment caveats (NOT plugin defects)
1. **Deployed driver.py ≠ HEAD by one inert debug line** (Phase-0). Live-confirmed
   emitting `driver - DEBUG - … Page: [{…}]` spam that HEAD suppresses. No
   behavioral impact; recommend rebuilding driver.py for exact parity.
2. **Concurrent third-party cluster activity during the campaign.** The cluster
   was NOT exclusive: an external actor created vm-105/106/107/108 and freed
   vm-104/vm-2xx on Pool-2 during my window (visible as new `vm-105-0`,
   `pool-2:vm-10{6,7,8}-0` targets and removed `pool-2:vm-2xx-0` targets, and as
   "Page:" list spam on jdss-Pool-2-ctest at 15:15 mid-teardown). This inflated
   my clone/activation timings and is the sole cause of the Pool-2 array-baseline
   drift below. **My campaign's own footprint is zero** (verified).
3. **REST volumes-list endpoint returned stale/partial data** repeatedly under
   that concurrent load (freshly-written volumes read back as empty/absent;
   total-count field flapped 112↔20). Consequence: thin/discard reclaim numbers
   could not be re-confirmed live this campaign (the blkdiscard operation itself
   ran cleanly; reclaim was proven in campaigns 1/2). Not a plugin fault — the
   plugin's own REST calls succeeded throughout; this affected only my ad-hoc
   audit curls.

### Not triggered (as expected / by design)
- **Array-session in-use refusal** (`JDSSTargetInUseException`) and **pool-conflict
  refusal**: cross-node race / distinct-array conditions, not deterministically
  forceable live — noted, not forced (per the campaign brief).
- **Natural reactive-logout-skip coexistence**: Cut 3's preventative refusal now
  blocks the second same-node activation, so two storeids can no longer both hold
  records on one target through normal activation. That is the *improvement*; the
  reactive guard is verified defense-in-depth via the seeded record above.
- **Lock-poll halving near deadline** (93e9bf0): needs sustained lock contention;
  the storm did not produce it. Zero lock artifacts observed regardless.

## Leftover audit
All 11 campaign guests destroyed (n1: 990011/12/14/30/33/40/41/50; n2: 990010/31;
n3: 990032). Node-side on all 3 nodes: **0** 990xxx sessions / mappers / state
files / configs; temp-storage state dirs `jdss-collide` + `jdss-nopw` rmdir'd;
helper scripts removed from /tmp. Temp storages `jdss-collide` and `jdss-nopw`
removed (delete-hook cleaned their `.pw`). Config restored: jdss-Pool-2
`target_prefix iqn.2025-04.proxmox.pool-2:`. My orphan re-home target deleted.
Array: **Pool-0 byte-identical** to Phase-0 baseline (12 vol / 8 tgt). **Pool-2**
differs from baseline ONLY by third-party churn (added v_ctest_vm-105-disk-0/1/2,
vm-105/106/107/108 targets; removed v_ts3/v_vm-104-*, vm-2xx targets) — **zero**
of my 990xxx/coll_/rehome objects remain; the only 990xxx on the array are the two
pre-existing 990061/990062 orphans that were in my Phase-0 baseline. Cluster
quorate 3/3, all storages active. Final lock-artifact grep
(`joviandss-lock-fatal|got lock request timeout|stale|LOCK BUG`) across all nodes,
all joviandss logs, today: **0 hits**. PBS `BS` retains the two campaign backups
(keep-all, intentional).

## Executive summary
**Release-ready: yes.** All four NEW behaviors this campaign targeted PASS with
verbatim evidence: (1) `target_prefix` re-home fires on an idle volume
(pool-2→rehome-a, "…is idle - detaching to re-home") and is correctly suppressed
cross-node when a session is live ("…keeping it in place"), while a plain
deactivate leaves the array-side attachment in place across stop/start; (2) the
shared-target collision guard (C2-02 Cut 3) refuses the second activation with a
clean, marker-stripped operator message, the first storage's device survives
untouched, and there is no leak (the sharer's LUN is unpublished and its later
free needs no detach), with the reactive logout-skip guard verified as
defense-in-depth; (3) storage creation now hard-requires the user password with
a clear message and leaves storage.cfg untouched on refusal, writing a 0600 `.pw`
(never the cfg) on success; (4) the NFS `path()` list-context fix holds —
`qm destroy`, detach→`unusedN`, and `unlink --force` all correctly free files on
the share (the campaign-3 C3-01 leak is gone). The full lifecycle regression is
clean on both iSCSI paths: F-02 triple rollback, F-03 non-silent rename, F-04
snapshot-activation-after-resize + clone-from-presnap, F-19 single-pass online
resize, template + linked clone, a 4-guest cross-node start/stop storm, all four
migration modes including live migration under in-guest fio (err=0), and
backups — **zero lock artifacts across all three nodes for the entire campaign**,
and my campaign returned the cluster and (its own) array footprint to a clean
state.

One minor NEW defect (D4-01): re-home followed by free leaves the new-prefix
target as an empty orphan on the array (reproduced by, and matching, the
maintainer's own pre-existing 990061/990062 orphans) — a cleanup-hygiene gap,
no data or device impact, likely coupled to F-10's non-deterministic
zombie-target GC. Two environment caveats worth the maintainer's eye but not
plugin faults: the deployed `driver.py` is one inert debug line behind HEAD
(rebuild for exact parity), and the cluster carried concurrent third-party load
throughout (inflated timings, REST-list staleness, and the entire Pool-2
array-baseline drift — none of it from this campaign).
