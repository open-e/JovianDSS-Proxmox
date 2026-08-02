# Code review — commit `4e6281d` "Scope-typed locking, cluster sharing, and hardened volume activation"

- **Scope:** `git diff HEAD~1..HEAD` (~9,800 insertions / ~2,700 deletions across
  `OpenEJovianDSS/Common.pm`, `OpenEJovianDSS/Lock.pm` (new), the two plugin modules,
  the removed `OpenEJovianDSS/Semaphore.pm`, and the Python `jdssc/` layer).
- **Review date:** 2026-07-04/05, extra-high effort (recall mode).
- **Method:** 10 independent finder angles → ~40 deduplicated candidates → per-candidate
  verification (CONFIRMED / PLAUSIBLE / REFUTED) against the code, `git show HEAD~1:`,
  and the **live PVE 9.1.11 libraries on pve-91-1** (installed plugin files verified
  byte-identical to this commit). A final gap-sweep pass is recorded in §6.
- **Verdict legend:** CONFIRMED = trigger and wrong outcome demonstrated from code;
  PLAUSIBLE = mechanism real, trigger uncertain; findings that were checked and
  disproved are listed in §5 so they are not re-litigated later.

Related design documents (in this repo):
- [docs/design/multi-layer-lock-design.md](multi-layer-lock-design.md) — the lock-layer spec
- [docs/design/volume-activation-with-reactivation.md](volume-activation-with-reactivation.md) — activation spec
- [docs/design/volume-activation-review-followups.md](volume-activation-review-followups.md) — findings 1–23 from the prior review arc
- [docs/design/jdssc-target-sessions.md](jdssc-target-sessions.md) — sessions subcommand spec

External references used during verification:
- pmxcfs cluster filesystem & lock semantics: <https://pve.proxmox.com/pve-docs/chapter-pmxcfs.html>
- PVE::Tools source (pve-common): <https://git.proxmox.com/?p=pve-common.git;a=blob;f=src/PVE/Tools.pm>
  (line numbers below refer to the installed PVE 9.1.11 copy on pve-91-1:
  `run_with_timeout` at :152, run_command's timeout kill at :575–578)

---

## 1. Critical — break core operations or risk data integrity

### F-01. Cluster-lock hold alarm is armed at 117 s for locks whose budget is 1320 s
**`OpenEJovianDSS/Lock.pm:599`** — CONFIRMED

For any cluster-backend lock, `_lock_exec` clamps the watchdog:
`$alarm_cap = $ceiling` where the ceiling is `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` (117 s,
`Common.pm:158`) — even for the `vm`/`storage` classes whose hold cap is 1320 s. The
alarm is armed **once** in `run_bounded` and never re-armed (`refresh_locks` only does
`utime` + deadline bookkeeping). Crucially, the countdown keeps running during plain
`sleep()` and during any `run_command` invoked **without** a `timeout` (live
`PVE::Tools` only saves/restores the alarm `if $timeout`; the `iscsiadm --login` calls
at `Common.pm:2340-2354` pass none).

**Failure:** on `shared 1` storage, the documented activation waits (the 240×`sleep(1)`
device-wait loop at `Common.pm:2419-2441` alone) blow through 117 s ~2 minutes into any
slow activation → SIGALRM → `joviandss-lock-fatal: lock hold exceeded` →
`volume_activate` rethrows fatally (`Common.pm:3980`). The entire reactivation feature
(4 cycles, 13–17 min budget) is unreachable on cluster-backed locks; every slow
activation aborts spuriously. The design's premise "the alarm is suspended during every
command" is false for `sleep()` and untimed `run_command`.

**Fix direction:** arm the alarm at the class's real `hold cap`, re-arm at cooperation
points (`refresh_locks`), and pass explicit timeouts to every `run_command` under a lock.

### F-02. Non-idempotent snapshot rollback is now retried up to 5 times
**`OpenEJovianDSSPlugin.pm:1210`** — CONFIRMED

`snapshot … rollback do --force-snapshots` runs via `joviandss_cmd(..., 118, 5)`.
`joviandss_cmd` clamps to 117 s and, on `/got timeout/`, sleeps 3–8 s and **re-executes
the command** (`Common.pm:1112-1117`). `run_command` SIGKILLs jdssc mid-rollback on
timeout (`PVE::Tools` :576). HEAD~1 ran rollback through the deleted `jd_cmd_nonidemp`
class: 540 s, `retries=0`, with the explicit comment *"NOT retried on timeout — partial
rollback + retry corrupts VM state across disks."* Nothing in this commit made rollback
idempotent; the invariant was silently dropped, and the per-attempt budget also fell
540 s → 117 s.

**Failure:** large/heavily-snapshotted volume under load → first attempt killed at
117 s after some blocker snapshots were already deleted / one disk rolled back → the
same non-idempotent operation re-fires up to 5 times → inconsistent multi-disk VM state.

**Fix direction:** restore `retries=0` (and a rollback-sized timeout) for `rollback do`,
or make the whole operation idempotent end-to-end first.

**CLOSED 2026-07-05 — maintainer ruling: rollback IS idempotent.** The
pre-4e6281d "never retry — partial rollback + retry corrupts VM state"
comment was wrong/outdated: a killed or repeated `rollback do
--force-snapshots` converges on the same outcome (volume at the snapshot
state, newer blockers removed), so timeout retries are safe by design.
Live-checked on pve-91-1: three consecutive backend rollbacks of the same
snapshot all succeeded. The ruling is now recorded AT THE CALL SITE
(`OpenEJovianDSSPlugin.pm`, above the rollback command) so a future review
does not resurrect this finding from the historical comment. Residual note:
the per-attempt budget aspect (540 s → 117 s clamp) is the F-11 discussion,
not a rollback-specific one — a single attempt needing > 117 s relies on
the backend accumulating progress across killed attempts, which idempotence
plus the retry budget covers.

### F-03. `rename_volume` can report success without renaming anything
**`jdssc/jdssc/jovian_common/driver.py:2338`** — CONFIRMED

In the outer `for i in range(3):` loop every pre-rename probe failure `continue`s
(`except JDSSVolumeNotFoundException: sleep(1); continue`,
`except JDSSException: continue`) and **no code follows the loop** — three failures
fall off the end, the function returns `None`, the CLI exits 0. Worse, the not-found
handler can never fire: `rest.py:342` raises `JDSSResourceNotFoundException`, which is
the **parent** of `JDSSVolumeNotFoundException` (`exception.py:111`), so a vanished
source volume takes the generic path too.

**Failure:** `create_base`/`_rename_volume` during a REST blip → jdssc exits 0 →
the Perl caller (`OpenEJovianDSSPlugin.pm:585`) returns the new volname → Proxmox
writes a VM config that points at a **nonexistent disk**. (The post-rename verify
poll at :2454-2461 is sound; the hole is only the pre-rename probe path.)

**Fix direction:** `raise last_err` after the loop (mirror `_delete_volume`'s
`if not deleted: raise last_err` pattern) and catch `JDSSResourceNotFoundException`.

**RESOLVED 2026-07-05:** `last_err` tracked across the retry loop and raised
after it — the fall-off-the-end implicit success no longer exists; both probe
sites catch the parent `JDSSResourceNotFoundException` (restoring the
idempotent pre-probe's intended "new absent → proceed" fast path and making a
vanished source surface as its real not-found), the generic handler gained the
`sleep(1)` it lacked (three retries now actually span a blip), and the
confirmation-failure message stops claiming "Failed to list snapshots".
Contract pinned by three new mocked-REST tests (`TestRenameVolume` in
`jdssc/tests/test_driver.py`); suite 51/51.

### F-04. Snapshot of a later-resized volume can never activate (strict size gate)
**`OpenEJovianDSS/Common.pm:4103`** — CONFIRMED

`_volume_activate_attempt` fetches the expected capacity with
`volume_get_size($ctx, $volname)` — the **parent's current size**; there is no
snapshot variant (`volume_get_size` takes no snapname, jdssc `volume get -s` has no
`--snapshot`). But snapshot activation exports a clone of the snapshot
(`driver.py` `create_export_snapshot` → `_clone_object(..., readonly=True)`) whose
capacity is the volsize **at snapshot time**. `_volume_resize` has no
"no-resize-with-snapshots" restriction. The strict gate
`int($sz) == int($expected)` (`Common.pm:2497`) then fails every round.

**Failure:** snapshot vm-100 → resize vm-100 → any snapshot activation
(`qm clone --snapname`, snapshot content access) spins the full 240 s wait loop and
all 4 reactivation cycles (~17 min of teardown/rebuild churn) and fails permanently.
The size check is the backend-export health probe from follow-up finding 23 — for
snapshots it is being fed the wrong expected value.

**Fix direction:** fetch the snapshot's own volsize (extend jdssc `volume snapshot get
-s`), or relax the gate to non-zero for snapshot activations.

**Live-confirmed 2026-07-05** on pve-91-1 / Pool-2 (scratch vm-990001, snapshot
`f04probe`, parent resized 1G→2G after the snapshot): parent `get -s` returns
2147483648 while the published export entity (`se_f04probe_…`, `is_clone: True`,
origin `…@s_f04probe`) reports `volsize: 1073741824` — mismatch permanent. Decisive
for the fix: that volsize sits in the SAME `get_lun` payload the existing
`snapshot get -i` path (`driver.get_snapshot(export=True)`) already fetches and
discards — option A costs one field in the driver, one `-s` flag in snapshot.py,
an optional snapname arg on `volume_get_size`, and passing `$snapname` at
`Common.pm:4103`. Bonus: for snapshots this queries the exported entity itself
(purer finding-23 cross-check than the parent-volume case), and it also fixes the
silently wrong `size` stored in the snapshot's LUN record (`lun_record_local_create`
currently persists the parent's current size).

**RESOLVED 2026-07-05 — option B, extended to ALL activations (maintainer
decision):** the exact-size gate is retired from the activation attempt
entirely; the exit contract requires a **non-zero** staged capacity only
(`$size = undef` at the former `Common.pm:4103` fetch site), which is the
actual finding-#23 broken-export tell. Side effects: one cluster-locked
jdssc round-trip removed from every activation (partial F-20 relief); the
LUN record stores `size: null` for activation-created records (truthful —
no exact size enforced; the lenient resize path keeps its own exact check).
Both design docs amended in place.

### F-05. Held cluster lock can go >120 s without a keep-alive during iSCSI login
**`OpenEJovianDSS/Common.pm:2242`** — PLAUSIBLE (needs a two-node contention test)

pmxcfs auto-expires lock directories under `/etc/pve/priv/lock` after ~120 s
(CFS_LOCK_TIMEOUT; see the pmxcfs chapter and `PVE::Cluster` :651 *"cfs locks have a
timeout of 120"*). The only refreshes in the login phase are at each attempt top
(`refresh_locks` at :2242) and every 10th device-wait second (:2439) — but one attempt
can run N portals × 30 s `iscsiadm --login` (`node.conn[0].timeo.login_timeout=30`,
:2313, via **untimed** `run_command`) plus 5×`sleep(2)` polls. With ≥4 slow/unreachable
portals that is a >120 s un-refreshed window while waiters poke the lock with
`utime(0,0)` (`Lock.pm:494`).

**Failure (if pmxcfs expires a poked-but-unrefreshed lock):** node B steals
`joviandss-lock-vm-100` while node A is mid-activation → concurrent staging/teardown
of the same VM's volumes — lost mutual exclusion. Additional hazard either way: on
unwind the original holder runs `rmdir $lockpath if $got_lock` (`Lock.pm:521`) and
would delete the **thief's** lock.
**What would confirm:** pmxcfs source (`cfs-plug-memdb.c` utimens handler) or a live
two-node steal test. Until then treat the login phase as needing a refresh between
portals.

**RESOLVED 2026-07-05 (window closed; steal question left moot):** every
per-portal login is now followed by its own `refresh_locks` cooperation point
(which also re-arms the wedge alarm — both clocks share the epoch), and the
login command is bounded end-to-end by the new `ISCSI_LOGIN_CMD_TIMEOUT` (35 s,
> the node-DB `ISCSI_LOGIN_TIMEOUT` = 30 s, now a named constant instead of an
inline literal; a bounded-login expiry counts as a failed login for that host
only). The un-refreshed window is capped at ~one bounded login — far inside
CFS_LOCK_TIMEOUT — regardless of portal count, so whether pmxcfs would have
expired a poked-but-unrefreshed lock no longer matters. The old
thief's-lock-rmdir hazard was separately eliminated by the acquire/divest
refactor's owned-guard. Design doc's refresh-gap section amended in place.

---

## 2. High — wrong results, leaks, or major operational regressions

### F-06. One slow `rescan-scsi-bus.sh` aborts the whole activation attempt
**`OpenEJovianDSS/Common.pm:2073`** — CONFIRMED

`_scsi_bus_rescan_try` calls `run_command(..., timeout => 55, noerr => 1)` with **no
eval**, but PVE's `run_command` dies on timeout **before** the `noerr` check
(`PVE::Tools` :575-578: `kill(9,...); die "command ... failed: got timeout"` — only
the later `elsif (!$noerr)` honors noerr). The sub's own contract says "return 0 if
error happens", and its call chain (`_rescan_target_hosts` → `volume_stage_iscsi` wait
loop :2447) has no eval either.

**Failure:** exactly the documented concurrent-load case ("each rescan takes minutes")
turns a skippable rescan tick into a full activation-attempt failure → teardown →
another reactivation cycle. **Fix:** wrap in `eval`, return 0 on `$@`.

### F-07. Publish failures silently swallowed in clone/alloc — including lock-fatal
**`OpenEJovianDSSPlugin.pm:786` and `:934`** — CONFIRMED

`eval { … volume_publish(...); }; last;` — `$@` is never read, nothing logged. A
`joviandss-lock-fatal:` die from `with_lock` inside `joviandss_cmd` does not match
the `/got timeout/` retry, propagates here, and is absorbed — violating the Lock.pm
contract that the marker "is never absorbed" (`Lock.pm:102`). Clone/alloc then report
success with the volume unpublished.
**Fix:** check `$@`; rethrow when `lock_error_fatal($@)`, at minimum `debugmsg` a warn.

**CLOSED 2026-07-05 — maintainer ruling: not a bug.** These publishes are
best-effort PRE-ACTIVATION warm-ups; the authoritative publish happens inside
`volume_activate`, so a failure here is acceptable by design and deliberately
not examined. The ruling is recorded at both call sites so the bare evals are
not re-flagged. (Within this ruling the absorption of a marker-tagged die is
also accepted: the inner lock a hold-cap fatal would refer to has already been
divested by the sequencer before the error reaches the warm-up eval.)

### F-08. Busy volume + cascade delete reports success while deleting nothing; forced unmount dropped
**`jdssc/jdssc/jovian_common/driver.py:227/232`** — CONFIRMED

This commit flips `force_umount=True` → `False` on `delete_lun` and the origin-snapshot
`delete_snapshot` (:264), and the `JDSSResourceIsBusyException` cascade branch does
`deleted = True; break` → exit 0. (The busy-swallow shape predates the commit; dropping
forced unmount is what **widens** the trigger to any stale attachment.) The Perl side
(`free_image` → `volume delete -c`) sees success and PVE forgets the disk.

**Failure:** stale attach after a node crash / leftover LUN record elsewhere → ZVOL and
LUN persist on the appliance forever (silent space leak, future name collisions).
**Fix:** restore forced unmount for the cascade path, or make busy-with-cascade an error.

**Campaign observation (2026-07-06, plugin 0.11.6):** the cross-node probe now
behaves *better than the finding predicted on the array side* — `pvesm free`
from node B of a node-A-active volume returned success AND genuinely deleted
the array volume — but node A retained **stale iSCSI sessions and a stale
by-id device** (no false-success-with-leftover-volume observed in this run).
Refined shape of the issue: cross-node free needs remote-node deactivation or
a defensive session GC on the activating node. (`deactivate_volumes` on the
gone volume cleaned up gracefully — the recovery path exists.)

### F-09. `_free_image` aborts before the backend delete when deactivation fails
**`OpenEJovianDSSPlugin.pm:1026`** — CONFIRMED

`volume_deactivate(...)` is now unguarded (HEAD~1 wrapped it in `eval` + "proceeding
with delete" warn — the PL-13 guard). `volume_deactivate` has real die paths
(`Common.pm:3899`, unguarded `volume_unstage_iscsi_device` :3879), and nothing else in
`free_image → _free_image_lock → _free_image` catches — so local teardown trouble now
leaks the volume on the appliance and fails the PVE task.
**Fix:** restore the eval-warn-proceed guard (deletion is the operation that matters).

**CLOSED 2026-07-05 — maintainer ruling: the finding's fix direction was
backwards.** A volume must NEVER be deleted while its deactivation has not
completed: deleting under live node-side state (sessions, maps, LUN records)
breaks the node, and — the decisive asymmetry with creation-side activation —
once the volume is deleted the plugin has nothing left to reference for
cleanup, whereas a failed deletion leaves the volume referencable and the
operation retryable after the cause is fixed. Deactivation already retries
internally; a persistent failure correctly fails the deletion. The removed
PL-13 warn-and-proceed guard was the actual bug. Ruling recorded at the call
site so the unguarded call is not re-flagged. (The finding's observed cost — a
failed PVE task and the volume remaining on the appliance — is the intended
lesser evil.)

### F-10. Zombie-target cleanup runs on a 1 % lottery
**`jdssc/jdssc/jovian_common/driver.py:828`** — CONFIRMED

`if random.randint(1, 100) == 7: self._delete_zombie_targets(...)`. HEAD~1 called it
unconditionally **and** had a dedicated already-gone path ("Volume is already gone but
its target may still be alive") that was also deleted. No comment justifies the gate —
it reads like leftover sampling/debug code.

**Failure:** each interrupted delete leaves a target that survives ~100 subsequent
unpublish operations on average; zombies accumulate, slow target scans, and behavior
differs randomly between identical runs (untestable).
**Fix:** unconditional cleanup, or a real periodic GC hook — not RNG.

### F-11. `delete_timeout` is silently clamped to 117 s (docs and schema still say 600)
**`OpenEJovianDSS/Common.pm:1075` (clamp), `:365` (default)** — CONFIRMED

Default fell 600 → 118, and `joviandss_cmd` now clamps **every** timeout:
`$timeout = PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX if $timeout > …` (117). The
`delete_timeout` option is still registered and its description still claims
"default 600" (`OpenEJovianDSSPlugin.pm:194-201`) — but an operator setting 600 gets
117 without any warning. The Plugin-configuration.md section documenting the remedy
("increase this if the pool has many dependent snapshots") was deleted in this commit.

**Failure:** genuine 5-minute cascade delete → 6 kill-at-118 s attempts (~12 min wall)
→ fails unless the backend happens to make cumulative progress between kills. The
operator's documented knob is dead.
**Fix:** exempt explicitly-configured per-op timeouts from the cluster-lock clamp (or
run long deletes under the node backend), and fix the option description.

### F-12. `status()` can wedge pvestatd for ~25 minutes per call
**`OpenEJovianDSSPlugin.pm:1378`** — CONFIRMED

New shape: outer `for my $attempt (1..3)` × `joviandss_cmd([pool get], 118, 3)` =
up to 12 subprocess runs × ~118 s + retry sleeps ≈ 25 min against a TCP-blackholing
appliance (jdssc's own REST timeout is 570 s, so the 117 s kill dominates). HEAD~1
used 15 s/3 retries (~60–88 s worst). pvestatd polls storages sequentially every
~10 s — one unreachable JovianDSS grays out **all** storages on the node for the
duration.
**Fix:** short probe timeout (the old 15 s class) and one retry layer, not two.
**Healthy baseline (2026-07-06 campaign):** `pvesm status` ×5 per node with 4
jdss storages: worst 5.09 s, typical 3.3–4.8 s. The pathological blackhole
case remains untestable on the live cluster.

---

## 3. Medium

### F-13. Deactivation retry loop strips the lock-fatal marker
**`OpenEJovianDSS/Common.pm:3885`** — CONFIRMED
The 3-attempt eval loop around `volume_unstage_multipath` warns, retries under locks
that can no longer be trusted, then dies with a **new** string (:3899) lacking
`joviandss-lock-fatal:` — so `lock_error_fatal()` callers misclassify. Every comparable
wrapper rethrows first (`die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);` —
:4157, :4007, :4031, :4200, :4452). **Fix:** add the same rethrow before retrying.

### F-14. Degraded single-path activation persists silently
**`OpenEJovianDSS/Common.pm:2412`** — CONFIRMED
Old code died unless **all** portals produced devices; new code warns
("proceeding with X of Y") at debug level and continues. Both fast paths
(`volume_stage_iscsi` :2193, `volume_stage_multipath` :2522) short-circuit before any
session work, so the missing path is never re-established until a full
deactivate/reactivate. Acceptable as a policy choice — but it needs (a) a loud warning,
and (b) a path-healing check in the fast path or a periodic reconcile.

### F-15. Clone-collision cleanup of the temporary snapshot was dropped
**`jdssc/jdssc/jovian_common/driver.py:617`** — CONFIRMED
On `JDSSVolumeExistsException`, HEAD~1 deleted the just-created hidden snapshot before
re-raising; new code just re-raises. The Perl retry-with-new-name loop
(`OpenEJovianDSSPlugin.pm:751,792-797`) makes collisions a designed-for case — each one
now strands a snapshot on the origin volume (future rollback blockers / busy-delete
errors). **Fix:** restore the cleanup in the except branch.

**RESOLVED 2026-07-06 (with maintainer amendment — intermediate-only):** the
collide-and-reraise branch restores the cleanup, and BOTH cleanup branches
(it and the generic GC below it) now fire only on
`create_snapshot and jcom.is_volume(sname)` — only the intermediate,
volume-named snapshot this call created is ever deleted. Rationale: the
snapshot-exists handler's warn-and-continue path can proceed over a
pre-existing REAL (s_-named) user snapshot even under `create_snapshot=True`,
and an unconditional cleanup would then destroy user snapshot data. The GC
branch also switched its delete target from the confusing `cvname` spelling
to `sname` — what the create call actually made (equal for the only current
`create_snapshot=True` caller).

### F-16. REST failover retry window cut below JovianDSS VIP failover time
**`jdssc/jdssc/jovian_common/rest_proxy.py:114`** — CONFIRMED
`range(50)` → `range(17)` with 3 s sleeps ≈ 51 s (was ~150 s); JSON-decode retry
`tries=50` → `5`. A 60–120 s HA VIP migration now outlasts the budget, so operations
that previously rode out failover fail. Also: the new
`if request_method == 'GET' and out is None: continue` (:161) is dead code (`_send`
never returns None) and, unlike every other retry branch, skips `_next_host()`.

**PARTIALLY RESOLVED 2026-07-06 (guard reworked; budgets still open):** the
"dead" guard turned out to be maintainer-intended protection against a real
JovianDSS bug — under heavy load a GET can return a success response with no
payload. The spelling just didn't match the bug's shape: `_send` always
returns a dict, so `out is None` never fired and the dataless response
(`{'code': 200, 'error': None, 'data': None}`) sailed through to crash the
caller. Reworked to detect exactly that payload signature for GETs, advance
`_next_host()` like every other retry branch (previously missing), and log
the event; a short-circuiting `out is None` arm is retained as defense so the
resilience loop itself can never TypeError on a bare miss. Non-GET methods
and error/204 responses are deliberately excluded (no retry-delay on real
answers, no non-idempotent replays). The finding's budget half —
~51 s total retry window vs 60–120 s VIP failover — remains a maintainer
decision.
If the cut was deliberate (to fit under the Perl-side 117 s kill), document it and
delete the dead branch.

### F-17. Cluster-lock `<class>_lock_path` override silently disables stale-lock recovery
**`OpenEJovianDSS/Lock.pm:240`** — CONFIRMED
`get_lock_class_dir(...) // $default_dir` applies the override unconditionally, but
pmxcfs only auto-expires entries under `/etc/pve/priv/lock` (per `Lock.pm:57-58`'s own
comment). Any override → holder crash leaves a permanent lock (every waiter spins the
full 600 s and dies, forever); a node-local override path silently loses cluster
exclusion instead. **Fix:** reject/ignore path overrides for cluster-backend classes.

### F-18. `_cluster_lock_path`'s retry loop is dead — and can re-run a locked body
**`OpenEJovianDSS/Lock.pm:572`** — CONFIRMED
The inner attempt consumes the entire remaining budget before raising "acquire
timeout", so the outer `while` never truly re-attempts (it only renames the error).
The one live path is pathological: a locked **body** whose own die text contains
"acquire timeout" is misclassified and the body is **re-acquired and re-executed**.
**Fix:** fold the error translation into the attempt and drop the loop; tag internal
acquire-timeouts unambiguously (marker, not substring).

### F-19. Resize recovery loop dies on one transient size-probe failure
**`OpenEJovianDSSPlugin.pm:1713`** — CONFIRMED
`volume_get_size` inside the `while ($retry_count <= 10)` recovery loop is un-eval'd —
a single REST blip aborts the loop the resize may already have survived. (In-loop
resize errors are deferred to the terminal `die $rerr` at :1739, so the asymmetry with
the pre-loop attempt is deliberate-ish but undocumented.) Related altitude issue: this
is a third retry layer on top of `joviandss_cmd` retries and jdssc's own 9×1 s
size-confirm poll — worst case >1.5 h inside the method lock. **Fix:** eval the probe;
collapse to one owner of resize retries.

**RESOLVED 2026-07-05 (probe fragility; maintainer's design):** the whole
recovery step — size probe + conditional re-resize — now runs inside one
in-loop eval with the error recorded into `$rerr`, so a transient probe
failure costs one iteration instead of aborting the recovery; the loop also
gained the `lock_error_fatal` rethrow every comparable wrapper has (a
hold-cap death is never absorbed into a retry). The layered-retry altitude
concern (third layer on top of `joviandss_cmd` + jdssc's poll) remains open
by choice.

### F-20. Read-only probes take the global cluster jdssc lock while holding the vm lock
**`OpenEJovianDSS/Common.pm:1817` (`target_get_sessions`), `:4605` (`volume_get_size`), `:1260` (`volume_snapshots_info`)** — CONFIRMED (perf/budget, not corruption)
`joviandss_cmd` defaults `$lock_class //= 'jdssc_cluster'`; these read-only calls omit
the arg while comparable reads pass `'jdssc_node'`. `target_get_sessions` runs inside
teardown with the vm lock held — parking up to 600 s × 8 tries on a cluster-wide mutex
exactly when the appliance is struggling, burning the 1320 s hold budget
(→ feeds F-01). `volume_get_size` runs on **every** activate. The design doc's
`jdssc_node` list is a closed set, so this is a doc-sanctioned-but-costly default —
extend the node-class list to these three probes.

### F-21. `_rescan_target_hosts` lost its `defined` guard on the hostN capture
**`OpenEJovianDSS/Common.pm:2153`** — PLAUSIBLE
HEAD~1: `next unless defined $hostN;`. Now an unmatched `m{/(host\d+)/}` interpolates
undef → `/sys/class/scsi_host//scan` → warn + fall-through to the broad
`_scsi_bus_rescan_try` (55 s full-bus rescans every 3rd second of the wait loop) in
precisely the concurrent-load scenario the targeted rescan was written to avoid.
Standard sysfs layouts always match; the guard is one line — restore it.

### F-22. Clone lock identity diverges for unparseable source volnames
**`OpenEJovianDSSPlugin.pm:692`** — PLAUSIBLE (theoretical trigger)
`_clone_image_lock` treats undef src_vmid as same-vm (vm lock only) while
`_rename_volume_lock`/`_free_image_lock` fall back to the **storage** lock — two lock
identities for the same resource. PVE core always passes parseable images volnames, so
no live trigger today; align the fallback for consistency.

**RESOLVED 2026-07-06 (maintainer ruling — opposite direction from the
finding):** cloning is a special case: it never modifies the source volume,
it only takes an array-side snapshot of it, and snapshot creation is atomic —
so the clone's **destination vmid is the only lock needed**. Instead of adding
a storage-lock fallback, `_clone_image_lock` was reduced to a single
`with_lock($ctx,'vm',$vmid,…)`: the src_vmid parse, the undef fallback
question, and the entire two-lock deadlock-ordering ladder are all removed.
The "two lock identities" divergence is moot because the source is no longer
a locked resource at all.

---

## 4. Cleanup (confirmed reuse / simplification / efficiency / conventions)

| # | Where | What | Suggested form |
|---|-------|------|----------------|
| N-01 | `OpenEJovianDSSPlugin.pm:1376` vs `:1404` | `status()` is a line-for-line copy of `get_identity()`'s 3-attempt pool-get fetch+parse (the format changed in this very commit — next change must be made twice) | one `_pool_info($ctx)` helper returning the 5 fields |
| N-02 | `driver.py:2355/2400`, `targets.py:255` (+ pre-existing `volume.py:220`, `snapshot.py:166`) | scsi_id→hex WWID formula now exists in ~7 sites (3 new) | one `jcom` helper (or `str.encode().hex()`) |
| N-03 | `Common.pm:3581` vs `:3652` | `lun_record_local_get_info_list` / `_get_snapshot_list` duplicate the same File::Find walk verbatim | one walker + snapname filter param |
| N-04 | `rest.py:372` vs `:494` | errno-13/CfgParser→`JDSSCfgParserException` mapping duplicated with drifted style | one `_raise_if_cfg_parser_error(resp)` |
| N-05 | `Common.pm:3754` + `:2451` | `log_dir_content` dead (its only call commented out in this commit); also the commented-out `#my $volume_name_clustered` at `Plugin.pm:912` | delete both (CLAUDE.md §3: clean up your own orphans) |
| N-06 | `NFSCommon.pm:33` | `file_get_contents`/`file_set_contents` imports orphaned by this commit (call sites removed) | trim the import list (CLAUDE.md §3) |
| N-07 | `Common.pm:1840` | `get_local_initiator_name` hand-rolls open/while/close; the same file uses `PVE::Tools::file_get_contents` 3× | file_get_contents + one `/^InitiatorName=(.+)$/m` |
| N-08 | `Common.pm:3316`, `:4471` | bare `sleep(1)` literals inside the new hardened loops while every other pacing value got a named constant; `MULTIPATH_UNSTAGE_BLOCKER_WAIT` counts ticks whose 1 s length is the inline literal | name them |
| N-09 | `driver.py:1296` | `except JDSSException: raise` no-op scaffold (old code deleted the target here) | remove try/except |
| N-10 | `driver.py:1478` | `ensure_target_volume` drops `acq_scsi_id` and `_ensure_target_volume_lun` re-fetches it via REST (extra round-trip on every publish); `create_export_snapshot` (:797) forwards it correctly | pass `scsi_id=acq_scsi_id` |
| N-11 | `driver.py:2327-2460` | `rename_volume` ~130 lines of copy-paste: hex block ×2, verbatim except-blocks ×2, `i` shadowed by 3 nested loops, final error text says "Failed to list snapshots" | helper + for/else |
| N-12 | `driver.py:219` | `get_lun` moved inside the CfgParser retry loop though its result is consumed only after | fetch once before the loop |
| N-13 | `driver.py:244` | 3×`sleep(1)` blind retry for "stale target reference" — the same commit added `rest.get_target_by_lun_name` that could find and detach the referencing target instead | detach-then-delete repair |
| N-14 | `Common.pm:2193` / `:2586` | fast-path `_iscsi_capacity_ok` forces a /sys rescan + `blockdev` spawn on every re-activation of a healthy volume; multipath staging sleeps 1 s unconditionally even on the round that succeeded | cached-size-first probe; probe-after-round |
| N-15 | `volumes.py:266` | `getfreename`: O(n) list scan per candidate + a REST `get_volume` per candidate on top of the full listing | build a set; trust the listing (or verify only the winner) |
| N-16 | `OpenEJovianDSSPlugin.pm:1604` | "Use of uninitialized value in numeric gt" in the activate-path size comparison (`$current_size > $lr->{size}`) — observed live during CT mount-point attach (2026-07-06 campaign); records now legitimately carry `size: null` since the F-04 change | guard: `if ( defined $lr->{size} && ... )` |

## 5. Checked and cleared (REFUTED) — do not re-flag

- **vm/storage lock scfg knobs "dead"** — the lock design doc explicitly declares only
  the jdssc/multipath property sets; vm/storage knobs are intentionally not registered.
- **`lock_error_acquire` regex fragility** — patterns match live PVE 9.1 wording
  exactly (`can't lock file '…' - got timeout`); run_command's process-timeout die
  deliberately does **not** match. Only a future PVE rewording risk.
- **`run_bounded` duplicating `PVE::Tools::run_with_timeout`** — justified: the
  lock-fatal marker die text is load-bearing for error classification.
- **`_create_base` vs `_find_free_diskname` name divergence** — both converge on the
  same stored `<cluster_prefix>_<name>` pattern (jdssc returns the bare name and Perl
  re-applies the prefix on one path; the other pre-joins).
- **verify-round size probe "missing" the READ CAPACITY refresh** — it does force
  rescans (`/sys/.../device/rescan` :4395, `iscsiadm --rescan/-R`, `multipath -r`)
  before the `blockdev` probe.
- **Leftover `Semaphore.pm` references** — none (grep clean); both plugins compile and
  register on live PVE 9.1 (`PVE::Storage::Plugin->lookup('joviandss'/'joviandss-nfs')`).
- **New Perl→jdssc CLI flags** — all newly passed flags exist in the parsers
  (`--sparselun`/`--largelun` go to rescan-scsi-bus.sh, `--deferred` to dmsetup);
  `sessions list` is wired via `target.py` → `sessions.Sessions`.

## 6. Gap-sweep results (fresh-eyes pass over areas the main angles missed)

### S-01. VERSION/changelog not bumped — mixed-locking-cluster hazard on rollout
**`debian/changelog:1`, `VERSION`** — CONFIRMED (facts checked)
`VERSION` is still `0.11.5` and the top changelog entry (`0.11.5-0`) describes the
**previous** architecture — it even records *removing* `JDSSCfgParserException`,
which this commit re-adds. `install.pl` does not `--reinstall` by default, and apt
treats an equal version as "already newest": a partial rollout leaves some nodes on
Semaphore.pm locking and others on Lock.pm. **The two schemes do not interlock**, so
cluster-wide jdssc serialization silently disappears, and nothing in dpkg output
distinguishes the builds. (Live cluster note: `dpkg` on pve-91-* reports plain
`0.11.5` for the `v0.11.5-5-g4e6281d` build — exactly this ambiguity.)
**Fix:** bump VERSION + changelog before any deploy; consider making install.pl
compare file hashes, not versions.

### S-02. Cross-node snapshot exports are no longer cleaned before cascade delete
**`OpenEJovianDSS/Common.pm:4273`** — PLAUSIBLE (needs a two-node trace)
`volume_deactivate` now enumerates snapshot exports from
`lun_record_local_get_snapshot_list()` — **this node's** records only. HEAD~1
enumerated array-side (the old `volume delete -c -p` listing + the parallel loop in
`volume_unpublish`). A snapshot exported on node A and deleted from node B leaves the
snapshot's target attached; combined with F-08 (`force_umount` now False + busy
swallow), `volume delete -c` goes busy → PVE reports success while volume + zombie
snapshot target persist. **Confirm by:** activate a snapshot on node A, destroy the
VM from node B, check the array for the leftover target.

**REPRODUCED live (2026-07-06 campaign, plugin 0.11.6) → upgrade to CONFIRMED:**
destroy from node B while node A held a snapshot export leaked the array-side
`se_*` export clone + its target + node-A sessions/mapper; the clone later
resurfaced as a standalone promoted volume (`is_clone=False`) caught only by
the campaign's leftover audit. Cleanup path that works: node-A
`deactivate_volumes(volid, snapname)` removes local state, the `se_` clone AND
the target. Fix direction: destroy-time cluster-wide export teardown, or an
orphan GC for `se_*` clones/targets.

### S-03. Rename idempotency mechanism is unreachable in its own target scenario
**`OpenEJovianDSSPlugin.pm:573`** — PLAUSIBLE
`_rename_volume` fetches the source's scsi id (`volume <orig> get -i`) *before* the
rename to pass as `--idempotent-scsi-id`. But in the re-drive case the mechanism
exists for — previous attempt already renamed server-side — the *original* name no
longer exists, so the `get -i` dies before the idempotent rename is ever issued.
**Fix:** on not-found, fall through to probing the *target* name (the jdssc side
already has the compare logic).

### S-04. Unescaped IQN prefix in target-scan regex
**`jdssc/jdssc/jovian_common/driver.py:1373`** — CONFIRMED
`re.compile(fr'^{tname}-(?P<id>\d+)$')` — no `re.escape`, while both sibling scans
(:1049, :1102) escape. IQNs are dot-heavy; every `.` matches any char, so a
foreign/legacy target differing only at dot positions can be classified as a free
slot and receive the new LUN — exported on a target the plugin's exact-prefix
cleanup will never manage. **Fix:** `re.escape(tname)` like its siblings.

### S-05. Routine unpublish logs at ERROR + triple DEBUG copies
**`jdssc/jdssc/targets.py:268`** — CONFIRMED
Every normal `targets delete` writes `LOG.error("Targets delete request …")`
(:268) followed by three near-identical DEBUG lines (:275/:280/:289) — leftover
scaffolding. Severity-based monitoring fires on healthy operations; real errors
drown. **Fix:** demote :268 to debug/info, collapse the copies.

### S-06. NFS storage: clearing `user_password` now aborts the whole config update
**`OpenEJovianDSSNFSPlugin.pm:1057`** — CONFIRMED (diff-verified)
The clear-password branch changed from `NFSCommon::password_file_delete` (succeeded)
to `Common::password_file_delete_user_password`, which unconditionally dies
("user_password … never individually cleared"). Deliberate policy for iSCSI
pre-commit; for NFS it's a silent behavior flip that also rejects any other
properties bundled in the same `pvesm set`. If intended, document it in the
changelog; if not, restore the delete for NFS.

### S-07. Storage identity degrades to a constant when the array omits the pool id
**`jdssc/jdssc/jovian_common/driver.py:2780`** — CONFIRMED (code fact)
`pool_id = 'unknown'` fallback → `get_identity` returns e.g. `Pool-0-unknown` for
*every* such array, so PVE's cross-node same-backing-store comparison passes even
when nodes point at different arrays — the exact misconfiguration the identity
check exists to catch. **Fix:** die (or degrade to a per-array value like the GUID
of a probe volume) instead of a shared constant.

## 7. Live test-campaign findings (2026-07-06, plugin 0.11.6)

Three full campaigns (jdss-Pool-2; jdss-Pool-2-ctest with `cluster_prefix`;
jdss-nfs-Pool-2-data2 on the NFS plugin) passed every mandatory item —
F-02/F-03/F-04/F-19 fixes held under load, zero lock artifacts across all
nodes and phases in all three, live migration under in-guest fio clean
everywhere, name translation correct on every data path including error
messages. Full reports: `OpenEJovianDSS/tmp/test-campaign-{1,2,3}-*.md`.
Four NEW defects surfaced:

### C2-02. Cross-storage iSCSI target collision under cluster_prefix — CONFIRMED (campaign FAIL 2.1)
The name-translation layer does not extend to **target naming**: the target
group is `vm-<vmid>` and the target IQN carries the storage's `target_prefix`
but NOT the `cluster_prefix` — so same-vmid volumes on a prefixed and an
unprefixed storage of the same pool (same default target_prefix) share ONE
target, as separate LUNs. Array-side per-LUN attach/detach is correct, but LUN
records are per-storeid (`/etc/joviandss/state/<storeid>/…`), so one storage's
deactivation cannot see the other's live LUN and **logs out the shared
session**: the other storage's active device vanishes under it (verified:
`dmsetup status` → "Device does not exist" while the volume was active).
**Mitigation, verified working:** distinct `target_prefix` per storage.
**Fix directions:** fold the cluster prefix into the target group name
(`<prefix>-vm-<vmid>`), or make deactivation target-logout conditional on a
cross-storeid LUN scan / array-side LUN count on the target.

**RESOLVED 2026-07-06 (cross-storeid logout guard; live-verified):** new
`lun_record_local_search_by_target($ctx, $targetname)` scans every
other storage's local state for lun records under the byte-identical target
directory name — exactly the string `iscsiadm --logout` would kill by, so
the guard condition equals the kill condition with no pattern matching
(`vm-101` can never match `vm-1011`; empty foreign target dirs — that
storage's own "none left" state — do not block). Both logout sites in
`lun_record_local_delete` (the missing-target-dir early path and the
last-record residual path) now skip the logout with a WARN naming the
foreign storeid. Covers all sharing topologies: same-pool plain+prefix
(the campaign FAIL), same-pool plain+plain (e.g. jdss-Pool-2 +
pytest-jdss-Pool-2), and two different arrays minting the same IQN (the
initiator's node DB keys by IQN alone; per-LUN device teardown stays
correct via portal-scoped by-path resolution, multipath separates by WWID).
Cross-storage scan-then-logout is race-free for shared storages: the vm
lock (`joviandss-lock-vm-<vmid>`, no storeid in the identity) resolves to
the cluster lockdir for both. Trade-off accepted: a stale foreign record
suppresses logout (session lingers, heals on that storage's next op) —
conservative direction vs killing a live device. Follow-up option noted,
not implemented: portal-scoped logout (`-p`) using hosts from foreign
records when portal sets are disjoint (two-array case) to trim the
lingering-session window. Live reproducer of campaign 2.1 on pve-91-1:
same-vmid volumes on jdss-Pool-2 + jdss-Pool-2-ctest shared target
`…:vm-990003-0` (2 sessions); deactivating the plain volume logged
"Skipping iSCSI logout … storage jdss-Pool-2-ctest still holds lun records"
— sessions stayed up and the ctest mapper read clean via direct IO (the
exact device the campaign found dead); deactivating the ctest volume then
fired the residual logout (sessions 0); frees left zero state/mapper/node
residue. `docs/Cluster-Prefix.md` amended: the unique-target_prefix rule is
per STORAGE, not just per cluster.

**Amendments (same day):** (1) helper renamed to
`lun_record_local_search_by_target` (family-consistent; maintainer request);
(2) the whole-path charset untaint inside the helper was replaced by a
storeid-schema check on the one untrusted component (the readdir entry) —
the assembled path is only used for read-only `-d`/`opendir`, and
`$targetname` is already validated by the caller, so path-level charset
filtering was both unnecessary and anti-conservative (maintainer caught it);
(3) **preventative layer — three design iterations, final one checks the
REAL published target name (maintainer requests + Opus-4.8 review):**
  - *Cut 1 (leaked):* an exact-target check in `lun_record_local_create`
    (Stage 4) — runs AFTER `volume_publish` (Stage 1), so a colliding
    activation had already attached its LUN to the shared target group, and
    the 4-cycle wrapper re-published it every cycle (cycle-3 detach undone by
    cycle 4). 53 s churn, LUN orphaned on the shared target — proven by the
    delete-time detach when the volume was later freed.
  - *Cut 2 (reconstruction, rejected):* moved to `volume_activate` before the
    cycle loop, matching a target-GROUP stem `get_target_prefix.":".$tgname`.
    Zero mutation and instant (~0.76 s), but it **reconstructed** the target
    name on the Perl side while the authoritative name is assembled by jdssc
    and returned only at publish (`$tinfo->{target}`). Maintainer caught it:
    the reconstruction duplicates jdssc's join logic and would silently
    diverge (e.g. `get_target_prefix` strips only one trailing colon via
    `s/:$//`, so a `foo::` prefix mismatches) → false negative → collision
    missed.
  - *Cut 3 (final, shipped):* the check runs in `_volume_activate_attempt`
    right after publish, on the **real** `$tinfo->{target}`, using the exact
    search `lun_record_local_search_by_target` (the same one the reactive
    logout guard uses — records are keyed by the exact target name). On
    collision it explicitly `volume_unpublish`es the just-attached LUN (the
    cycle teardown's detach is gated and would not run) and dies with
    `TARGET_COLLISION_ERROR_MARKER`; `volume_activate` detects the marker
    (`error_is_target_collision`), strips it, and **fails fast** with the
    clean message — no 4-cycle churn. Cost: one publish+detach round-trip
    (~11 s) on the misconfigured path, the unavoidable price of learning the
    real name. Granularity is now EXACT (same IQN) not group: two storages on
    *different* targets of the same group are independent sessions and are
    correctly NOT refused. `lun_record_local_search_by_target_group` was
    deleted. `volume_publish` (Common.pm:1943) is the SINGLE target-attach
    chokepoint — the only `targets create` in the tree — so its three
    callers are the complete set: `_volume_activate_attempt` (covers
    activation incl. snapshots and content volumes) plus the two best-effort
    warm-up publishes (F-07) in `_alloc_image` AND `_clone_image`. Both
    warm-ups got the same treatment: publish, and if the real returned
    target is already used, `volume_unpublish` (alloc/clone still succeed;
    activation refuses later). The clone warm-up was the last unguarded
    path — found on a maintainer's "check clone too" prompt.
Live acceptance (990009/10/11, pve-91-1): warm-up publish-then-undo on the
real name; activation refused with a CLEAN message (marker stripped);
**decisive leak test** — the timeline shows warm-up and activation each
publish+detach (net zero) and the later free needs NO detach (vs the Cut-1
leak where free had to detach); **same-storage multi-LUN NOT refused**;
normal single-storage activate/deactivate/free clean; zero residue. Accepted
residual: the stale-foreign-record trade-off (a foreign record that never
clears leaves a session lingering until the record-holder's own teardown)
still stands.

### C2-02b. Array-session detach guard — never yank an in-use target (2026-07-07)
The host-local guards above see only THIS node's lun records. The array,
however, knows every initiator connected to a target. New protection at the
jdssc/driver layer: `_detach_target_volume(tname, vname, check_in_use=False)`
gains the flag, and `_ensure_target_volume_lun` passes `check_in_use=True` on
its busy-recovery detach. When set, the driver queries
`get_target_sessions(tname)` first; if any initiator is connected it raises a
new `JDSSTargetInUseException(target, addresses)` instead of detaching (and
possibly deleting) the target out from under a live session. This fires in
the cross-node race the host-local guard cannot cover: another node created
`tname`, attached the volume, and a client connected, all between this node's
"target absent" check and its create-then-detach recovery. Full-stack
handling: jdssc `targets create` (CLI) catches it, logs — via the
ERROR→stderr handler — a message prefixed `joviandss-target-in-use:` naming
the target and the initiator IP(s) and telling the operator to deactivate
everywhere first or use a distinct `target_prefix`, then exits 1. The Perl
plugin captures that stderr in `joviandss_cmd`, and `volume_activate` detects
the marker (`error_is_target_in_use`), strips it, and **fails the activation
immediately without cycling** — retrying cannot free a device another host is
using. The exception is not caught by `ensure_target_volume`'s retry loop
(only CfgParser retries) and error exits are never retried by `joviandss_cmd`,
so it propagates cleanly. Verified: 55/55 pytest incl. 4 new driver tests
(sessions present → raise + no detach/delete; empty → normal detach; missing
target → not in use; flag off → no session query); Perl classifier +
marker-strip live on the deployed module; marker string identical across
`targets.py` and `Common.pm`; session `ip` shape matches existing
`sessions.py` usage. The end-to-end race itself is impractical to force
deterministically (needs concurrent cross-node timing); each layer and seam
verified instead.

### C2-01. Empty-name `pvesm alloc` mints an invisible orphan zvol — CONFIRMED
`pvesm alloc <storage> <vmid> "" 1G` reports `successfully created
'<storage>:'` and creates an array zvol literally named `v_<cluster_prefix>`
(empty translated name) — invisible to `pvesm list`, collides on the second
attempt. A pre-existing anonymous 1G volume on Pool-2 is this bug's unprefixed
twin. The API path (`vdisk_alloc` with undef name) is correct; only the
CLI empty-string path escapes name validation. **Fix:** reject empty/invalid
volume names in `alloc_image` before translation.

**RESOLVED 2026-07-06 (maintainer ruling — normalise, don't reject):** an
empty name is treated as a request for auto-naming, same as passing no name:
`_alloc_image` normalises blank `$name` to undef before the
`$volume_name = $name` copy, so all three defined()-gates (initial
`_find_free_diskname` pick, stale-list re-query at retry, and the
already-exists retry that checks `$name` itself) coherently follow the
auto-select path. `_find_free_diskname`/`getfreename` was audited for this:
stale-list candidates are double-checked with an authoritative per-name
`get_volume` lookup, the residual TOCTOU race is closed by the create-side
"already exists" retry-with-requery, first-fit matches PVE convention, and
campaign 2 item 2.2 exercised the chain live.

### C3-01. NFS `path()` drops PVE's list-context contract → qm-side deletions silently leak files — CONFIRMED (campaign 3, MAJOR)
**`OpenEJovianDSSNFSPlugin.pm:145`** — `sub path` (via `_path`) returns a bare
scalar; PVE core calls `path()` in list context expecting
`($path, $owner, $vtype)` — the iSCSI plugin maps its fixed `[$path, $vmid,
$vtype]` shape onto exactly that wantarray contract
(`OpenEJovianDSSPlugin.pm:325-335`). With `$owner`/`$vtype` undef, every
ownership-gated core deletion path silently skips: `qm destroy` leaks ALL VM
disk files (reproduced 5×), `qm disk unlink --force` removes the config entry
but leaves the file (3×), plain detach doesn't register `unusedN`, and
`pvesm free` warns "$vtype uninitialized" (PVE Content.pm:488/498).
`pct destroy` is unaffected (different core path) — CT files freed correctly.
**Fix:** one line — mirror the iSCSI plugin's wantarray mapping in `path()`.

**RESOLVED 2026-07-06 (fixed, deployed, live-verified):** `path()` now
delegates to `_path` for the path string (internal callers keep the scalar
contract), parses the volname for `$vtype`/`$vmid`, and returns
`wantarray ? ($path, $vmid, $vtype) : $path` — the iSCSI plugin's mapping.
All three campaign failure modes re-driven on pve-91-1 post-deploy:
`qm destroy` removes the whole `images/<vmid>/` directory (was: leaked all
files, 5×), detach registers `unused0` in the config (was: dropped
untracked), and `qm disk unlink --force` deletes the file from the share
(was: config-only). Zero residue after cleanup.

### C3-02. NFS storage add can leave no password file → all REST ops dead — CONFIRMED (campaign 3)
After the storage was added, `/etc/pve/priv/storage/joviandss-nfs/<storeid>.pw`
did not exist and every REST operation failed with "JovianDSS REST user
password is not provided." (an orphan sibling `.pw` under a different storeid
from the same minute suggests an add-under-different-id history). `pvesm set
--user_password` (update-hook) repaired it. **Fix direction:** the add-hook /
password flow should fail loud at add time when the pw file is missing or
cannot be written, instead of leaving a storage that activates but cannot
perform any array operation.

**RESOLVED 2026-07-06 (hook invariant; schema route disproven live):**
`Common::password_file_require_user_password($ctx, $storeid)` — the
creation-time half of the existing "mandatory while the storage exists"
policy — is called at the end of both plugins' `on_add_hook`: if no
user_password is stored after the add processed its sensitive params, the
add itself dies (`storage '<id>': JovianDSS REST user password is not
stored; supply --user_password`) and nothing lands in storage.cfg.
Verified live: add-with-password → 0600 `.pw` written, storage listed;
add-without → clean rejection, cfg untouched; `pvesm remove` still deletes
the `.pw`; single-property `pvesm set` unaffected on both types (update
validates with create=0). **Load-bearing lesson:** marking `user_password`
required in `options()` CANNOT work — sensitive properties are extracted
before create-validation (add fails "missing value" even with the flag
supplied) and are never written to storage.cfg, and required-ness is ALSO
enforced at parse time, which un-parses every existing joviandss section
(reproduced live: all sections "skip section … missing value for required
option 'user_password'"; reverted within minutes). `user_name` (plain,
stored property) IS now required in both plugins — safe because every
section stores it. Re-add under a storeid whose `.pw` survived a hand-edit
removal adopts the stored password (idempotent). Hand-editing storage.cfg
still bypasses all hooks — not fixable plugin-side.

### S-06 addendum (live confirmation, campaign 3)
Exact behavior confirmed on 9.1: solo `--delete user_password` → RC=255
"update storage failed: user_password cannot be cleared; provide a new value
or remove the storage"; bundling it with another property change rejects BOTH
(storage.cfg unchanged, pw file intact). The bundled-rejection cost from the
S-06 write-up is real.

### Campaign-3 minor observations (NFS)
Clone-from-snapshot leaves the snapshot share published + RO-mounted until the
next `deactivate_volume` (crash in the window strands array-side clone+share —
the 2.6 leftovers); `qm destroy` neither deactivates snapshots nor (per C3-01)
frees files, so post-destroy snapshot cleanup is manual; empty
`private/mounts` skeleton dirs accumulate. NFS-inherent (document, not bugs):
snapshots are dataset-wide ZFS snapshots (`{vmid}_{snap}`, pin blocks of ALL
guests on the share), rollback is a full file copy (~60 s / 3 G), linked
clones are disabled by design, and NFSv3 has no trim-based reclamation
(deletion + snapshot dropping is the only reclaim path; NFSv4.2 would enable
hole punching).

### S-02 addendum (prefix variant)
Reproduced under `cluster_prefix` as a **busy-refusal** variant: destroy from
node B with a live snapshot export on node A exits 0 while the volume, the
`se_*` clone, the target, and node-A sessions/mapper/record all survive (no
promoted-clone resurface this time — the busy refusal comes earlier). The
documented node-A cleanup (`deactivate_volumes(volid, snapname)` + free)
removes everything.

## 8. Verification environment notes

- Installed modules on pve-91-1/2/3 verified **byte-identical** to `4e6281d`
  (md5, 2026-07-04), so all findings apply to the deployed build
  (dpkg `0.11.5`, build `v0.11.5-5-g4e6281d`).
- Python: `python3 -m compileall` clean; the new pytest suite (`jdssc/tests/`) was
  run in a local venv (pytest via `python3 -m venv`): **48 passed** in 0.08 s
  (2026-07-05). Note: the suite is pure unit-level (mocked REST) — it does not cover
  the confirmed findings above, all of which live in retry/timeout/lock interplay.
- Score: 27 CONFIRMED, 4 PLAUSIBLE, 4 REFUTED across 5 verification batches
  (~40 deduplicated candidates from 10 finder angles), plus 7 gap-sweep findings
  (5 fact-checked CONFIRMED, 2 PLAUSIBLE) in §6.
- Happy-path field verification (2026-07-05, PASS): alloc → activate → fast-path
  re-activate → deactivate → free driven live on pve-91-1 via the PVE::Storage API,
  on both `pytest-jdss-Pool-2` (multipath 0) and `jdss-Pool-2` (multipath 1, both
  paths active, map created/torn down cleanly). Timings: ~3.5–4 s cold activation,
  ~1.1 s warm, ~1 s deactivation. None of the confirmed findings' triggers
  (timeouts, lock contention, appliance duress) occur on an idle cluster, so this
  PASS does not contradict them. Recipe persisted in `.claude/skills/verify/SKILL.md`.
