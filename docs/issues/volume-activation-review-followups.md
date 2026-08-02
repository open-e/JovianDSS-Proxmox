# Volume Activation Review — Deferred Findings (TRACKING)

> **Status: all findings resolved at design level (2026-07-03, three
> rounds).** Findings from the critical review of
> [`volume-activation-with-reactivation.md`](volume-activation-with-reactivation.md)
> were tracked here; every entry — including the third round's 12–20
> (2026-07-03: internal contradictions, consistency, potential bugs, race
> conditions; spec code cross-checked against `Common.pm` / `Lock.pm`) —
> has been folded back into the design document (pointers below). The
> design was **accepted by the maintainer and implemented on 2026-07-03**
> (`Common.pm` / `Lock.pm` / `OpenEJovianDSSPlugin.pm`, syntax-verified on
> a live PVE 9.1 node; implementation-time findings folded into the
> design: `lock_error_acquire`'s three escaping error shapes, the
> load-bearing `dmsetup -y` on `udevcomplete_all`, the probes'
> stderr-logging delta). The `-ll` path-row watch-item **fired on first
> live use (2026-07-04)** — `multipath -ll` returns empty for a healthy map
> under daemon load, which failed the single-stage probe; resolved by the
> `dmsetup status` fallback (finding 21) and shipped in 0.11.6, with the
> deeper self-blinding/redundancy observation recorded as finding 22. This
> file stays as the decision record of the review rounds and the
> post-implementation findings.

**Resolved during the review session (first round, for traceability):**

| # | Finding | Resolution |
|---|---|---|
| 1 | temporal detach gate not enforced by construction | superseded — detach demoted to a one-shot rung before the final cycle (`VOLUME_ACTIVATE_CYCLE_ATTEMPTS` = 4), then session-evidence gated (`_target_foreign_sessions`); design's Open Question #1, revised twice |
| 2 | detach unsafe for aborted live migration | same resolution as #1 — session evidence is the primary guard, cycle position is defense-in-depth |
| 3 | cycle `eval`s swallow hold-cap enforcement | fatal-error classification: `LOCK_FATAL_ERROR_MARKER` + `lock_error_fatal`, rethrown by every cycle `eval`, no teardown on the fatal path |
| — | `target_get_sessions` invocation broken; jdssc REST endpoint unverified | [`jdssc-target-sessions.md`](jdssc-target-sessions.md) (accepted & **implemented** 2026-07-03, e2e-verified on `Pool-2`): `pool <pool> target <iqn> sessions list` over the per-target endpoint (REST/driver unchanged); `Common.pm` invocation fixed, `TARGET_SESSIONS_QUERY_*` bounds shipped, target name untainted via `safe_word` (taint-mode exec safety) |

## Open Findings

*None — findings 4–11 (second round) and 12–20 (third round) resolved
2026-07-03, see below.*

## Resolved

**Finding 4 — `volume_stage_iscsi` refresh gap (HIGH).** Resolved: explicit
`refresh_locks($ctx)` cooperation ticks — every login attempt and every 10th
device-wait tick — specified in the design's
*The refresh gap during staging* section and the new `volume_stage_iscsi`
entry in *Changed Functions*. The refresh-gap section no longer overclaims
per-command coverage; the residual (a minutes-long `rescan-scsi-bus` is
itself uncooperative) is recorded there as accepted.

**Finding 5 — teardown drops `$content_volume_flag` (HIGH).** Resolved:
`_volume_activate_attempt` records `$state->{content_volume_flag}`; every
teardown `volume_unpublish` call passes it, so content volumes unpublish
against the content target group; today's same latent bug at
`Common.pm:3881` is fixed alongside (design: the attempt sketch, the
`_volume_deactivate_attempt` entry, Table 6).

**Finding 6 — strict verification breaks the resize caller (HIGH).**
Resolved: `lun_record_update_device` gains a trailing `$strict` — strict
(activation) dies on exhaustion, lenient (default; `volume_update_size`,
the cross-node resize flow) keeps today's warn-and-return. The budget
sub-item is closed too: the verify loop's embedded re-stage passes an
attempts bound of 1, so a verify round can never embed a full staging loop
(design: *Device verification*, *Function Signature Change*, *Changed
Functions*).

**Finding 7 — staging fast path trusts a stale/dying map (HIGH).** Resolved:
`volume_stage_multipath` gains `$verify_map` (set by reactivation cycles
≥ 2, via the attempt's new `$cycle` parameter): an existing map must show at
least one active path (`_multipath_map_has_active_path`, one locked
`multipath -ll` read) or the rounds rebuild it. Direct callers keep the
cheap bare `-b` (design: *Staging under the lock*, *Function Signature
Change*, *New Functions*).

**Finding 8 — cookie sweep vs live LVM cookies under correlated load
(MEDIUM).** Resolved: the sweep is now **signature-gated** — it runs only
when the failed attempt recorded a command exiting 124/137 (survived its
whole termination ladder; `multipath_cmd` records the flag on `$ctx`), so an
age-only sweep never fires under generic IO distress where legitimate LVM
cookies are oldest. Age bound stays 3 minutes (design: *Stale-cookie
recovery*, the chokepoint's *Hang visibility* bullet, the cycle sketch).

**Finding 9 — acquire timeout costs a full teardown (MEDIUM).** Resolved:
three-way error classification — **fatal** (rethrow, no teardown) /
**contention** (`lock_error_acquire`, keyed on the lock design's
retry-friendly `acquire timeout` string: re-attempt with **no sweep, no
teardown**, and no recovery detach) / **device failure** (sweep + teardown +
reattempt). Lost acquire races no longer amplify contention into
logout/republish churn (design: *The reactivation cycle*'s classification
paragraphs, the cycle sketch, chokepoint bullets).

**Finding 10 — 1 s backstop margin (MEDIUM).** Resolved: new
`MULTIPATH_CMD_BACKSTOP_MARGIN` (Table 4b) replaces the `+ 1`;
`run_command`'s last-resort SIGKILL now sits a full margin above the
wrapper's escalation. Ladder invariant updated:
`MULTIPATH_CMD_TIMEOUT_MAX + MULTIPATH_CMD_KILL_GRACE +
MULTIPATH_CMD_BACKSTOP_MARGIN < LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT`
(30 + 5 + 5 < 60 — headroom preserved).

**Finding 11 — minor items (LOW).** Resolved:
1. `dmsetup udevcookies` parse — verify-during-implementation note added
   beside the sweep's grep (sibling of the `udevcomplete_all`
   confirmation-flag item).
2. `$probe->{exitcode}` undef guard — the sweep's probe check now reads
   `!defined($probe->{exitcode}) || $probe->{exitcode} != 0`.
3. Pre-cycle budget check — new `lock_deadline_remaining($ctx)` (Lock.pm)
   and `VOLUME_ACTIVATE_CYCLE_MIN_BUDGET` (Table 4b): the cycle rethrows
   the last error instead of starting an attempt the hold deadline would
   kill mid-way.
4. `noerr` caveat — the chokepoint's *Hang visibility* bullet now documents
   that `run_command`'s timeout death is a `die` even under `noerr => 1`
   (only reachable if the backstop loses its race; classified by the cycle
   like any attempt failure).

---

**Third round (2026-07-03) — internal contradictions, consistency,
potential bugs, race conditions; spec code cross-checked against
`Common.pm` / `Lock.pm`. All resolved same day; resolutions folded into
the design document.**

**Finding 12 — `$verify_map` defeated one call deeper; size verification
blind to zombie maps (HIGH).** Two coupled defects re-opened finding 7:
(a) the round body's entry `return $mpath if -b $mpath` returned the very
map the driver's fast path had just rejected — before any repair command
ran — and the post-loop settle check shared the hole, so on cycles ≥ 2
`$verify_map`'s only observable effect was a warn line; (b) worse, the
livelock reading was optimistic: `blockdev --getsize64` is answered from
the dm table length without touching a path, so a dead-but-intact leftover
map (*zombie*: device node present, paths dead or belonging to a
logged-out session) reports its correct size — Table 3's size-only
verification **passes** and activation returns a dead map as success, the
silent-wrong-device outcome the design exists to eliminate. Resolved:
`volume_stage_multipath` gains an **exit contract** — it returns only a
map showing at least one active path, or dies. Acceptance (`-b` **plus**
`_multipath_map_has_active_path`) moved to the top of the driving loop
(after each inter-round sleep — the grace multipathd's path checker needs,
so a transiently unchecked fresh map costs a round, never a cycle) and to
the settle check; the round body lost its entry `-b` return and issues
commands only (short-circuits stop escalation; return value advisory), so
a zombie receives the cheap in-place repair (`add path` of the fresh
session's paths) every round; a map that never shows an active path
exhausts the rounds and dies into the cycle's teardown — logout, unstage,
`dmsetup remove -f`: the designed repair for the incomplete teardown a
zombie evidences. `$verify_map` now means **the activation flow, every
cycle** (a leftover from an *earlier* operation would otherwise ride
cycle 1's bare `-b` into the same false success); direct callers keep the
bare `-b` fast path. Table 3 gains the path-evidence row — size can never
expose a zombie — and the verify loop reuses the same probe. The probe's
parse is now **load-bearing** (a false "no active path" fails activation
through every cycle; the old round-body bug ironically masked parse
failures): verify against deployed multipath-tools formats, with `dmsetup
status` A-flag counting specified as fallback evidence. (Design: *Staging
under the lock* — exit-contract paragraph and the driver, round-body and
acceptance-probe sketches; *Device
verification* / Table 3; *New/Changed Functions*.)

**Finding 13 — the activation attempt never passed `$strict` (HIGH).**
`lun_record_update_device`'s signature is `($ctx, $targetname, $lunid,
$lunrecpath, $lunrec, $expectedsize)` (`Common.pm:4056`); the design's
`$strict` is a trailing seventh argument and lenient is "the default —
every caller not passing the flag". The `_volume_activate_attempt` sketch
called it with six arguments — the activation flow, the one caller that
must be strict, ran lenient: warn-and-return on exhaustion, the attempt
reports success, the cycle never engages — Problem Statement #2
reproduced by the reference code while its own Stage 4 comment claimed
"dies on absent / zero / mismatched size". Resolved: the sketch passes the
strict flag explicitly, commented as the contract's load-bearing call
site.

**Finding 14 — strand-signature lifecycle contradiction (MEDIUM).** The
cycle sketch deleted `_multipath_cmd_ladder_exhausted` at the top of every
cycle ("fresh strand signature per attempt") while *Stale-cookie recovery*
promised that a ladder-exhausted command inside the sweep or teardown
"re-arms the flag for the next attempt's gate" — the loop-top delete
erased the re-arm, so a teardown-demonstrated strand gated no sweep when
the next attempt failed fast without touching a hung command (e.g. died at
publish). Resolved: the delete moved **above** the loop (isolating stale
`$ctx` state from earlier operations, once); the failure-branch `delete`
is the only consumer, so teardown/sweep signatures survive into the next
attempt's gate exactly as the sweep section claims. A signature also
survives a contention-class re-attempt — correct: the strand persists
until swept.

**Finding 15 — deactivation-pass retry machinery unreachable (MEDIUM).**
Every step of `_volume_deactivate_attempt` is best-effort (`$step`: eval +
warn, rethrow fatal) and the session probe follows the same policy, so no
non-fatal error could escape the sub: a pass could never fail,
`VOLUME_DEACTIVATE_ATTEMPTS` ("first try plus three retries — decided")
could never retry, and `_volume_unstage_multipath_wait_unused`'s comment
claiming "the deactivation-pass loop owns it (retrying the pass…)"
contradicted the `$step` wrapper that swallows exactly that error one
level below. Resolved: the retry loop and the constant are **dropped** —
one teardown pass per failed cycle; convergence across step failures is
supplied by the cycles themselves (every later failure re-runs the
teardown over the residue) and by the next attempt's rebuild-or-fail-loud
(now guaranteed by finding 12's exit contract). Considered and rejected:
making pass failure observable to re-enable the loop — redundant with
cycle-level convergence, and it re-opens the budget hazard of repeating
the pre-final pass's session probe (worst ≈ 4 × ~5 min against a hung
appliance, nearly the whole raised hold budget). The wait-unused comment
now names the per-step wrapper as the owner; the earlier "4 passes"
decision is superseded by this record.

**Finding 16 — verify-loop re-stage fired the full escalation ladder every
round (MEDIUM).** `volume_stage_multipath(…, attempts = 1)` made its
single round the final round (`$last = $attempt == $attempts`), and the
final round fires **every** escalation — per-WWID scan, udev triggers,
`multipathd reconfigure` — so each verify round with a missing map
hammered the daemon that the same section's Open Question #3 schedule
(reconfigure every 5th round) exists to protect, and broke the "10 verify
rounds ≈ 20 s" budget line. Resolved: `$last = $attempt == $attempts &&
$attempts > 1` — an attempts bound of 1 is a **gentle repair round**
(registration + whitelist + add map + the round-1 per-WWID scan; no
blast); the verify loop keeps the only escalation cadence; the embedded
call is eval-wrapped so its die is that round's failure, not a
lenient-caller abort (the old shape could kill a resize through
`volume_update_size`).

**Finding 17 — unstage wait-unused grace cut 60 s → 10 s, unflagged
(MEDIUM).** Today `_volume_unstage_multipath_wait_unused` loops `1 .. 60`
(`Common.pm:2925`) and the two-argument signature ignores the `(10, 20)`
literals at `Common.pm:3730`, so every caller effectively waits up to
60 s before removal escalates toward `dmsetup remove -f`; the drafted
default of 10 cut that guard 6× — on the normal deactivation path too,
whose own preserved comment ties the wait to migration-window data
corruption — while Non-goals claimed the path unchanged and Risks was
silent. Resolved: **defaults preserve today's effective bounds** —
`MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS` = 60,
`MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS` = 10 (the never-in-force `3730`
literals are not a precedent). The wait exits on the first free tick, so
the typical unheld teardown pays ~0 and the full bound is paid exactly
when something holds the device — when waiting is the point. New *Unstage
bounds* value-notes group records the reasoning.

**Finding 18 — cycle-completion contract had undocumented exception
end-states (LOW).** "Torn down to today's logout level" was violated by
(a) a final cycle failing as contention — teardown skipped, attempt
residue stays — and (b) a pre-cycle budget stop after the pre-final
teardown — recovery detach ran, its re-attach never did: volume left
detached. Resolved: both named in the contract paragraph (benign; the next
activation republishes) with a pointer from Risk 6.

**Finding 19 — detach rung could probe with an undef target name (LOW).**
`$state->{published}` is set before `volume_publish` returns coordinates,
so a mid-publish death reached the pre-final-cycle rung with no
`targetname` — `_target_foreign_sessions($ctx, undef)` built a jdssc
invocation with a missing argument (failing safe through its eval, but
noisy, with an uninitialized-value warn). Resolved: the rung additionally
requires `defined $state->{targetname}`, mirroring step 4's gate.

**Finding 20 — minor items (LOW).** Resolved:
1. `multipath_cmd` lower clamp — `$timeout = 1 if $timeout < 1`: coreutils
   `timeout 0` means *no bound*, which would disarm the TERM-first ladder
   and leave only `run_command`'s SIGKILL backstop (the re-strand hazard).
2. `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT` wording — 60 s outlasts **one**
   worst-case hold with headroom, not "a queue"; a deeper queue times out
   into the contention class. Table 4a and the chokepoint prose now agree
   with the Value notes.
3. "on acceptance" → "at implementation time" for the lock design's
   Table 9b updates (Table 4a rows now match *Relationship to Other
   Designs*, whose value tables describe shipped code).
4. Table 6's multi-layer row lists all Table 9b updates (`multipath`
   acquire **and** the `vm`/`storage` hold rows).
5. New Constants preamble no longer reads as claiming the changed lock
   values shipped — only the `TARGET_SESSIONS_QUERY_*` bounds shipped;
   `Lock.pm` holds 10/600/600 until implementation (verified).
6. Line anchors — sub-level anchors re-verified and corrected
   (`target_get_sessions` 1637, its invocation 1652,
   `get_local_initiator_name` 1673, the four-argument unstage call 3730,
   `volume_activate` 3769, binary detection 183–190, `volume_unpublish`
   3287); statement-level anchors flagged by an anchor note before
   Table 1; full refresh at implementation time.
7. Table 3 now states it describes the strict contract (lenient warns
   where strict dies) and treats an expected size of 0 as *no expected
   size* — zero can never verify a device.
8. Single-point-of-truth nit — the "first try plus three retries" prose
   value went away with `VOLUME_DEACTIVATE_ATTEMPTS` (finding 15).

*Held up under the same scrutiny (no change needed):* the termination-ladder
invariant (30 + 5 + 5 < 60), the cycle-budget sums and the ~5-minute probe
worst case, every Table 1 timeout-tier assignment against the sketches,
the teardown ordering (Table 2 vs `Common.pm`'s ordering comments), the
fatal-classification coverage of every introduced `eval` (the lsof/ps
evals cannot see lock errors), the sweep's safety rules and lock-leaf
placement, the detach gate's documented point-in-time residual, the
`undef` content-flag latent bug at today's error path (real, fix specified
alongside), and today's wait-unused loop polling a vanished device node
(claim verified).

---

**Post-implementation field findings (2026-07-04) — from the first live
multipath activation on PVE 9.1. Folded into the design's *Device
verification* section (Field diagnosis) and the `_multipath_map_has_active_path`
entry.**

**Finding 21 — `multipath -ll` is an unreliable liveness oracle; the probe
needs a socket-independent second stage (HIGH — first live failure).**
`activate_volume` for `vm-202-disk-0` failed all four cycles with *"map has
no active path"* over a **healthy** map. Root cause: `multipath -ll <wwid>`
queries `multipathd` over its socket and, while the daemon is busy
(`reconfigure` / concurrent-activation load), returns exit 0 with **empty
output** — which the single-stage exit-contract probe (finding #12) read as
"no active path." The map was provably fine: staging's `-ll` showed two
active paths immediately before and after, and the dm node was present
every verify round (*"no active path"* is the verify loop's second check,
after `-b`). Resolved: `_multipath_map_has_active_path` gains a
`dmsetup status <wwid>` A-flag fallback that fires when `-ll` is empty and
the dm node exists — device-mapper's table view can't be blinded by a busy
daemon. Genuine absence still fails (negative control verified live). Both
parses validated against live fixtures. **Shipped** (0.11.6). Also
hardened alongside: the strict-verify `$scsiid` (from the on-disk record)
is now `safe_word`-untainted before the new direct argv/path uses the
design added, and the probe logs a one-line trace per call (an empty `-ll`
logs nothing otherwise, which is what hid the bug at first).

**Finding 22 — the strict verify loop blinds its own probe and duplicates
staging (MEDIUM — design smell; simplification deferred).** Answering *"why
did it iterate if staging confirmed the device?"*: `lun_record_update_device`
runs `iscsiadm --rescan` / `-R` / `udevadm trigger` every round and
`multipathd reconfigure` every 5th — the churn that keeps the daemon busy
enough to blind `-ll` (finding #21). Each blind read triggers another round
of the same churn; the cycle then restarts and staging's un-churned `-ll`
succeeds again — four identical cycles over a device ready the whole time.
Two structural observations, deferred to a follow-up (the finding-21
fallback makes them a latency/log-noise cost, not a correctness bug):
(1) in the multipath activation flow staging's exit contract already
guarantees node + active path, so verification's path re-check is
redundant — only **size** is new evidence; (2) the disruptive
rescan/reconfigure ladder exists for the lenient `volume_update_size`
resize caller and is counterproductive in the strict path. Future cleanup:
skip the ladder (or the redundant path re-check) when the caller is the
strict activation flow.

**Finding 23 — the strict size check is a backend-export HEALTH probe, not
a resize mechanism (maintainer clarification + measurement, 2026-07-04).**
Its real purpose: under heavy concurrent create+attach load, JovianDSS's
SCST sometimes exports a LUN **wrong** — the volume attaches and looks fine
to Proxmox (node present, paths up) but is **non-functional**; the tell is
a device READ CAPACITY size that disagrees with the REST `volume_get_size`
(or reads zero). Data-plane capacity vs control-plane volsize is the
cross-check, and the maintainer confirms it catches the failure. A scratch
1 GiB→2 GiB test (to characterize *caching*, not resize) established: (1)
`blockdev`/`/sys/size`/dm-table are all **cache reads** — so the check is
valid only as **rescan → read**, else it could read a plausible cache and
**miss a broken export**; (2) SCST answers READ CAPACITY with current truth
on demand (no re-registration), so one forced rescan exposes a broken
export. Implication: moving the size check into `volume_stage_iscsi` is a
**better** health probe — the `sd` device is the raw LUN, the most direct
read of SCST's export — provided it forces the rescan. **`volume_stage_multipath`
gets NO size check** (a map's size derives from the now-verified `sd`; a
fresh map inherits it, a pre-existing map with active paths came from a
prior *successful* activation that already verified it) — the earlier plan
to add a `multipath -r` size reconcile was **rejected** as redundant and as
reintroducing the finding-21/22 dm-layer churn (the maintainer caught this).
The one case a map's size goes independently stale — a backend resize — is
the lenient `volume_update_size` flow, which keeps its rescan + `multipath -r`
ladder. **Option A IMPLEMENTED & validated on PVE 9.1 (2026-07-04):**
new `_iscsi_capacity_ok` (forced READ CAPACITY, rescan-then-read, compare to
`volume_get_size`) in `volume_stage_iscsi`'s exit contract;
`_volume_activate_attempt` fetches size before staging and **no longer
calls the strict `lun_record_update_device`** (verify loop retired from
activation). Validated: healthy volumes verify + activate first-cycle; the
helper accepts a correct size and **rejects a wrong one** (broken-export
detection); no strict verify loop runs; concurrent 8-VM storm clean.
Corrects my earlier resize-framed version. Folded into the design (*Staging
under the lock* exit contract, *Device verification* supersession, finding
#23, the attempt sketch, signatures, New/Changed Functions).
