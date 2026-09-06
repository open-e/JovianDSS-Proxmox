# Rollback Destroys a Same-Second Snapshot — Issue & Proposed Fix (OPEN)

> **Status: open — no code written.** The *defect* is confirmed against the
> live `Pool-2` appliance — reproduced 2/2 in batch 1 of the deep-verification
> run recorded in `pve-testing/testplans/results/deep-run-2026-08-21.md`
> (finding **P1**, severity high, data loss) and again independently by the
> coordinator — and the mechanism below is traced end to end through the current
> code. The *fix* is drafted only: four changes, of which
> [Change 3](#change-3--the-non-force-rollback-path) is **implementation-separable**
> and may be vetoed without affecting the others. Nothing here has been built or
> verified.

## Table of Contents

- [Overview](#overview)
- [Problem](#problem)
  - [Reproduction](#reproduction)
  - [The_four_step_failure_chain](#the-four-step-failure-chain)
  - [Why_the_guard_exists_and_still_fails](#why-the-guard-exists-and-still-fails)
- [Key_Observation](#key-observation)
- [Design](#design)
  - [Change_1_union_the_two_blocker_sources](#change-1--union-the-two-blocker-sources)
  - [Change_2_make_the_date_derivation_total](#change-2--make-the-date-derivation-total)
  - [Change_3_the_non_force_rollback_path](#change-3--the-non-force-rollback-path)
  - [Change_4_the_contradicted_docstring](#change-4--the-contradicted-docstring)
- [Why_Not_Fix_It_on_the_Appliance](#why-not-fix-it-on-the-appliance)
- [Alternatives_Considered](#alternatives-considered)
- [Consequences](#consequences)
- [Risks_Backward_Compatibility](#risks--backward-compatibility)
- [Testing](#testing)
- [Files_That_Would_Change](#files-that-would-change)
- [Relationship_to_Other_Work](#relationship-to-other-work)
- [Open_Questions](#open-questions)

---

## Overview

`qm rollback` is designed to refuse when snapshots newer than the rollback
target exist, unless the guest carries the `force-rollback` tag. When the newer
snapshot was created in the **same wall-clock second** as the target, that
refusal does not happen: the rollback proceeds, the newer snapshot is destroyed,
and nothing is printed. There is no prompt, no warning and no log line the
operator would read as a loss.

The change spans two layers. The **appliance** reports a blocker *count* derived
from a timestamp with one-second resolution; **jdssc** treats a zero count as
proof that nothing blocks and skips the check it already has. The Perl plugin is
not at fault — it asks the right question and honours the answer — but it is
where the loss becomes visible, and its call site carries a comment that this
design would make true again.

The purpose of this document is to make the blocker decision not depend on a
single source that is known to be lossy at a one-second boundary.

## Problem

### Reproduction

Reproduced 2/2 during batch 1 of the deep-verification run and once more
independently by the coordinator, on a scratch storage:

```
qm snapshot 991027 p1
curl -k -X POST .../pools/Pool-2/volumes/v_vm-991027-disk-0/snapshots \
     -d '{"snapshot_name":"restsnap"}'          # no delay between the two
qm rollback 991027 p1                           # guest carries no tags at all
```

Observed:

```
s_p1      creation="2026-08-21 08:42:16"  createtxg=32510874
restsnap  creation="2026-08-21 08:42:16"  createtxg=32510876
GET .../snapshots/s_p1/rollback  ->  {"data": {"snapshots": 0, "clones": 0}}
jdssc … snapshot p1 rollback check --concise  ->  (empty)
qm rollback 991027 p1 -> rc 0, "Rollback: … complete"
snapshots after: s_p1                            # restsnap destroyed
```

Insert `sleep 2` before the REST snapshot and the identical scenario is
correctly refused — the appliance reports `{"snapshots": 1, "clones": 0}`,
`rollback check --concise` prints `snap:restsnap`, and `qm rollback` exits 255
with `Rollback blocked by newer snapshots: 1 storage side snapshots: restsnap`.
The guard is therefore present and working; only its *input* is lossy.

Note the `createtxg` values differ (32510874 vs 32510876). The appliance knows
the ordering exactly; it is the `creation` field, not the underlying ZFS state,
that cannot express it.

**Not reachable through two consecutive `qm snapshot` calls** — those are ~2 s
apart (verified: `s_p1` 08:45:21, `s_p2` 08:45:23, correctly refused rc 255).
The exposure is snapshots created by scripts, backup tooling or the REST API
within the same second as a Proxmox snapshot — that is, by anything faster than
a human.

### The four-step failure chain
[The_four_step_failure_chain](#the-four-step-failure-chain)

| # | Layer | What happens |
|---|---|---|
| 1 | appliance | `GET /snapshots/<s>/rollback` counts successors by `creation`, which has one-second resolution, so a same-second successor is **not** counted → `{"snapshots": 0, "clones": 0}` |
| 2 | jdssc | [`driver.py:3158-3163`](../../jdssc/jdssc/jovian_common/driver.py#L3158-L3163) treats that zero count as authoritative and `return None`s — **never running** its own listing at [`:3167`](../../jdssc/jdssc/jovian_common/driver.py#L3167) |
| 3 | Perl | [`volume_rollback_check`](../../OpenEJovianDSS/Common.pm#L1966) parses empty output at [`:1996-2006`](../../OpenEJovianDSS/Common.pm#L1996-L2006), finds no blockers, and permits the rollback |
| 4 | Perl → appliance | the plugin issues `rollback do --force-snapshots` unconditionally ([`OpenEJovianDSSPlugin.pm:1519`](../../OpenEJovianDSSPlugin.pm#L1519)), and the REST call atomically deletes newer snapshots before restoring |

Step 4 is not a defect on its own. The call site says so explicitly at
[`OpenEJovianDSSPlugin.pm:1498-1500`](../../OpenEJovianDSSPlugin.pm#L1498-L1500):

```perl
# Always use --force-snapshots: volume_rollback_is_possible already
# verified this rollback is safe.  For VMs without the force-rollback tag,
# no blockers exist at this point so --force-snapshots is a no-op.
```

That comment states the load-bearing assumption of the whole path, and step 2
is precisely what falsifies it. When the check misses a blocker,
`--force-snapshots` stops being a no-op and becomes the instrument of the loss.
**Restoring the truth of that comment is the goal of this design**, and is why
the fix belongs in jdssc rather than in the plugin: removing `--force-snapshots`
would break tagged force-rollback instead, and would leave the check still
wrong.

### Why the guard exists and still fails
[Why_the_guard_exists_and_still_fails](#why-the-guard-exists-and-still-fails)

jdssc already owns a second, independent blocker listing —
[`_list_snapshot_rollback_dependency`](../../jdssc/jdssc/jovian_common/driver.py#L3050) —
whose filter at
[`:3089-3111`](../../jdssc/jdssc/jovian_common/driver.py#L3089-L3111) compares
each snapshot's creation time against the target's:

```python
if ts_dt >= rdate:
    return True
```

The comparison is **inclusive**, so an equal timestamp *is* a blocker. This
listing would have caught `restsnap`. It is simply never reached, because the
early return at step 2 happens first. The fix does not need new detection logic;
it needs to stop skipping the detection that already exists.

## Key Observation
[Key_Observation](#key-observation)

**Two independent blocker sources exist, they fail in opposite directions, and
the code currently lets the lossy one veto the other.**

| Source | Can miss a blocker? | Can invent one? |
|---|---|---|
| Appliance count (`get_snapshot_rollback`) | **yes** — same-second successors | no |
| Local listing (`_list_snapshot_rollback_dependency`) | yes — its own docstring disclaims completeness | yes — an inclusive tie, and an unparseable date |

Neither is sound alone. But a **union** — block if *either* reports something —
is safe in the only direction that matters, because the failure being fixed is a
silent deletion, and the cost of a false positive is a refusal the operator can
override with the `force-rollback` tag. Fail-closed is the correct bias for a
destructive operation.

The union is also strictly more conservative than today's behaviour: every
rollback currently refused stays refused.

## Design

### Change 1 — union the two blocker sources
[Change_1_union_the_two_blocker_sources](#change-1--union-the-two-blocker-sources)

In [`rollback_check`](../../jdssc/jdssc/jovian_common/driver.py#L3127), drop the
early return, always run the local listing, and report blocked when either
source has something:

```python
out = self._list_snapshot_rollback_dependency(vname, sname)

appliance_snapshots = dependency.get('snapshots', 0)
appliance_clones = dependency.get('clones', 0)

if len(out['snapshots']) == 0 and appliance_snapshots > 0:
    out['snapshots'] = ["Unknown"]

if len(out['clones']) == 0 and appliance_clones > 0:
    out['clones'] = ["Unknown"]

if len(out['snapshots']) == 0 and len(out['clones']) == 0:
    return None

LOG.debug("rolling back is blocked by resources %s", str(out))
return out
```

The existing `"Unknown"` fallbacks are what keep the appliance authoritative in
*its* direction: a blocker the local listing misses is still reported, just
without a name. Preserving them is why this is a widening rather than a
replacement.

The `None` return contract is unchanged, which matters because
[`rollback.py:76`](../../jdssc/jdssc/rollback.py#L76) branches on
`dependency is not None` to decide between printing blockers and logging that
rollback is possible.

Two details worth recording. `dependency.get(...)` replaces direct subscripting:
today, if `get_snapshot_rollback` returned `{}`, the guard at
[`:3158`](../../jdssc/jdssc/jovian_common/driver.py#L3158) would be false and
`dependency['snapshots']` at
[`:3169`](../../jdssc/jdssc/jovian_common/driver.py#L3169) would raise
`KeyError` — a latent bug on a path this change makes ordinary. And the
`LOG.debug` that currently reports the *appliance's* verdict moves to report the
**merged** verdict, so the log line stops disagreeing with the return value.

### Change 2 — make the date derivation total
[Change_2_make_the_date_derivation_total](#change-2--make-the-date-derivation-total)

Required by [Change 1](#change-1--union-the-two-blocker-sources), not
independent of it. At
[`driver.py:3080-3087`](../../jdssc/jdssc/jovian_common/driver.py#L3080-L3087)
the target's date is derived only when `creation` is a non-empty `str`:

```python
dformat = "%Y-%m-%d %H:%M:%S"
rdate = None
if (('creation' in rsnap) and
    (type(rsnap['creation']) is str) and
        (len(rsnap['creation']) > 0)):
    rdate = datetime.datetime.strptime(rsnap['creation'], dformat)
```

If that test fails, `rdate` stays `None`, and the filter's `else` at
[`:3105-3106`](../../jdssc/jdssc/jovian_common/driver.py#L3105-L3106) returns
`True` for **every** snapshot — every rollback on the volume becomes blocked.
Today the early return usually hides this. Change 1 removes the hiding, so the
derivation must become total:

```python
rdate = None
rcreation = jcom.time_to_epoch(rsnap.get('creation'))
if rcreation:
    rdate = datetime.datetime.fromtimestamp(rcreation)
```

[`time_to_epoch`](../../jdssc/jdssc/jovian_common/jdss_common.py#L38-L60)
already normalises int, all-digit string and `'%Y-%m-%d %H:%M:%S'` forms,
returning `0` for anything unrecognised. `dformat` becomes unused.

This also puts **both sides of the comparison through the same conversion**,
which is what makes the tie meaningful rather than accidental. The other side,
at [`:3098`](../../jdssc/jdssc/jovian_common/driver.py#L3098), is
`datetime.fromtimestamp(sp['creation'])` where `sp['creation']` was produced by
`time_to_epoch` at
[`:2892-2893`](../../jdssc/jdssc/jovian_common/driver.py#L2892-L2893).
`time_to_epoch` uses `time.mktime` (local), `fromtimestamp` renders local, so
the round-trip returns the same naive local datetime it started from. **This was
checked deliberately**: had the two sides used different frames, always running
the filter would have marked *older* snapshots as blockers and produced
false refusals on every rollback.

### Change 3 — the non-force rollback path
[Change_3_the_non_force_rollback_path](#change-3--the-non-force-rollback-path)

> **Scope note: implementation-separable.** This may be vetoed without affecting
> changes 1, 2 and 4. It is the same defect in a path the plugin never takes.

[`rollback()`](../../jdssc/jdssc/jovian_common/driver.py#L3177) has the same
early-exit shape at
[`:3245-3259`](../../jdssc/jdssc/jovian_common/driver.py#L3245-L3259) — when the
appliance reports `0/0` it calls `snapshot_rollback` immediately. The plugin
always passes `--force-snapshots` and so takes the branch at
[`:3204`](../../jdssc/jdssc/jovian_common/driver.py#L3204) instead, which
already lists dependencies locally. The non-force branch is therefore reachable
only by a human running `jdssc … rollback do` without the flag.

It is still wrong: the docstring promises it "commits rollback if no dependecy
is found. In other case it raises ResourceIsBusy", and for a same-second
successor it neither refuses nor reports. The fix is the same union — consult
the local listing before committing.

The argument for vetoing is that a bare `rollback do` can be read as *"I accept
the appliance's verdict"*. The argument against is that nothing documents it
that way, and the operator running jdssc by hand is the least likely to know
about the one-second boundary.

### Change 4 — the contradicted docstring
[Change_4_the_contradicted_docstring](#change-4--the-contradicted-docstring)

[`_list_snapshot_rollback_dependency`](../../jdssc/jdssc/jovian_common/driver.py#L3050)
carries:

```
List that is returned is not exact full list and should not be used
to make decision of rollback is possible
```

Changes 1 and 3 do exactly what that sentence forbids, so it would have to say
what is actually true: the list is **not** authoritative on its own and may be
incomplete, and is therefore used *together with* the appliance count, never as
the sole gate. Worth noting the sentence is already stale — the force path at
[`:3210`](../../jdssc/jdssc/jovian_common/driver.py#L3210) decides whether to
refuse a forced rollback purely from this list's `clones`.

## Why Not Fix It on the Appliance
[Why_Not_Fix_It_on_the_Appliance](#why-not-fix-it-on-the-appliance)

The true root cause is that `GET /snapshots/<s>/rollback` derives its counter
from `creation` rather than from `createtxg`, which is monotonic and exact — the
reproduction shows the appliance holding both values, differing correctly, at
the moment it answers `0`. An appliance-side fix would be narrower and would
help every consumer, not just this plugin.

It is not the fix proposed here because the plugin cannot ship it, cannot
require the appliance version that would carry it, and would still need to
behave correctly against every already-deployed appliance. This design is
therefore a **client-side compensation for a known-lossy input**, and should be
described that way rather than as the correction of the underlying defect.
Reporting the counter upstream is worthwhile independently, and is
[Open question 2](#open-questions).

## Alternatives Considered
[Alternatives_Considered](#alternatives-considered)

- **Compare `createtxg` instead of `creation` in the local filter.** Exact,
  monotonic, no tie possible — strictly better than timestamps. Rejected for now
  because the paged snapshot listing that feeds the filter carries `creation`
  (normalised at
  [`:2892-2893`](../../jdssc/jdssc/jovian_common/driver.py#L2892-L2893)) and not
  `createtxg`; plumbing a new field through the listing is a larger change than
  the defect warrants, and the inclusive `>=` already yields the correct verdict
  for the tie. Worth revisiting if false-positive refusals prove annoying, since
  it would remove them entirely — see
  [Open question 1](#open-questions).
- **Have the plugin stop passing `--force-snapshots` unconditionally.** Would
  not help: the deletion is authorised by the *check* having already passed, so
  a same-second blocker would still be missed, and untagged rollbacks would
  merely fail differently. It would also break tagged force-rollback, which
  depends on that flag.
- **Sleep or retry to force distinct timestamps.** Rejected outright: it makes
  correctness depend on wall-clock spacing, cannot be made reliable, and would
  slow every snapshot to protect against a case the code can simply detect.

## Consequences

Once this lands:

- A snapshot created in the same second as the rollback target **would be
  reported as a blocker**, and an untagged `qm rollback` would exit 255 with the
  existing message from
  [`format_rollback_block_reason`](../../OpenEJovianDSS/Common.pm#L1855) rather
  than silently destroying it. No new message text is needed.
- Adding the `force-rollback` tag would remain the way to proceed deliberately,
  and would behave exactly as it does today — the destructive path is unchanged,
  only the gate in front of it.
- The comment at
  [`OpenEJovianDSSPlugin.pm:1498-1500`](../../OpenEJovianDSSPlugin.pm#L1498-L1500)
  would become true again: with the check widened, `--force-snapshots` really is
  a no-op for untagged guests.
- `rollback check` would issue one additional REST listing per call on the
  previously-early-returning path. It is the same listing the blocked path
  already performs, so the cost is a listing that used to be skipped only in the
  success case.
- The `LOG.debug` blocker line would reflect the merged verdict, so logs stop
  showing "blocked by" for a call that returned "possible".

## Risks & Backward Compatibility
[Risks_Backward_Compatibility](#risks--backward-compatibility)

### Preserved (low risk)

- **The `None`/dict return contract is unchanged**, so
  [`rollback.py:72-108`](../../jdssc/jdssc/rollback.py#L72-L108) and the Perl
  parser at [`Common.pm:1996-2006`](../../OpenEJovianDSS/Common.pm#L1996-L2006)
  need no change. An empty-output call still means "not blocked" on the Perl
  side.
- **Every rollback refused today stays refused** — the change only adds blocker
  sources, never removes one.
- **The destructive path is untouched.** No change to `snapshot_rollback`, to
  the force branch, or to the plugin.

### Risks

1. **False refusal on a same-second *predecessor*.** At one-second resolution an
   older snapshot sharing the target's second is indistinguishable from a newer
   one, and the inclusive `>=` would report it as a blocker. The operator sees a
   refusal naming a snapshot that does not actually block. Mitigation: this is
   the fail-closed direction, and `force-rollback` overrides it; a `createtxg`
   comparison would eliminate it
   ([Open question 1](#open-questions)). Note the behaviour already exists on
   every path that reaches the filter — this change widens *when* it is reached,
   it does not introduce it.
2. **An unparseable `creation` blocks every rollback on the volume.** If
   `time_to_epoch` returns `0`, `rdate` is `None` and the filter returns `True`
   for everything. [Change 2](#change-2--make-the-date-derivation-total) reduces
   the surface by accepting all forms the appliance is known to emit, but a
   genuinely unknown format would still fail closed. Accepted deliberately:
   refusing to roll back when the ordering cannot be established is the correct
   response.
3. **Cost of the extra listing on large volumes.** `_list_all_volume_snapshots`
   pages through every snapshot of the volume
   ([`:2703-2728`](../../jdssc/jdssc/jovian_common/driver.py#L2703-L2728)). A
   volume with very many snapshots would pay that on each `rollback check` that
   previously returned early. Bounded by the existing 118 s / 5-retry budget the
   plugin already passes at
   [`Common.pm:1978-1987`](../../OpenEJovianDSS/Common.pm#L1978-L1987), and the
   blocked path already pays it today.
4. **`"Unknown"` becomes visible more often.** When the appliance counts a
   blocker the local listing cannot name, the operator sees `Unknown` in the
   refusal message. Pre-existing behaviour, unchanged in shape, but reached on
   more calls.

## Testing

Unit tests in `jdssc/tests/test_driver.py`, which already provides a `driver`
fixture with a `MagicMock` `ra`. Mocking `ra.get_volume_snapshots_page` rather
than `_list_all_volume_snapshots` keeps the **real filter** in the path, so the
tie is genuinely exercised instead of stubbed:

| Test | Setup | Expected |
|---|---|---|
| same-second successor is a blocker | appliance `0/0`, listing has a snapshot with `creation` equal to the target's | returns `{'snapshots': ['restsnap'], …}` — the P1 regression test |
| older snapshots do not block | appliance `0/0`, listing has only earlier snapshots | returns `None` — guards against the false-refusal regression |
| appliance-only blocker keeps its name | appliance `1/0`, listing empty | `out['snapshots'] == ["Unknown"]` |
| empty dependency dict | `get_snapshot_rollback` returns `{}` | no `KeyError`; verdict from the listing alone |
| int epoch `creation` | target `creation` is an int | date derived, not treated as unknown ([Change 2](#change-2--make-the-date-derivation-total)) |
| target itself excluded | listing includes the target snapshot | never reported as its own blocker |

Live verification on `pve-91-1` would re-run the reproduction above and assert
the inverse of the recorded outcome: `rollback check --concise` prints
`snap:restsnap`, `qm rollback` exits 255, and **`restsnap` still exists
afterwards**. The `sleep 2` control must stay refused, and an ordinary rollback
with no successors must stay permitted — that pair is what distinguishes the fix
from a blanket refusal.

The corpus already has rollback coverage under
`pve-testing/testcases/iscsi-plugin/rollback/` (8 testcases, batch 1) and
`pve-testing/testcases/jdssc/rollback/` (3, batch 7). None currently encodes the
same-second case; adding one there is the durable home for this scenario. Note
that batch 7 found the jdssc rollback testcases to be affected by the
`rollback-002`/`rollback-003` vacuous-assertion defect, so a new testcase should
not be modelled on them.

## Files That Would Change
[Files_That_Would_Change](#files-that-would-change)

| File | Change |
|---|---|
| [`jdssc/jovian_common/driver.py`](../../jdssc/jdssc/jovian_common/driver.py) | `rollback_check` unions both sources ([1](#change-1--union-the-two-blocker-sources)); `_list_snapshot_rollback_dependency` date derivation made total ([2](#change-2--make-the-date-derivation-total)); optionally `rollback` non-force path ([3](#change-3--the-non-force-rollback-path)); docstring ([4](#change-4--the-contradicted-docstring)) |
| `jdssc/tests/test_driver.py` | six new tests per [Testing](#testing) |
| `pve-testing/testcases/…/rollback/` | a new testcase encoding the same-second scenario (separate repo — plain reference) |
| `docs/issues/rollback-same-second-snapshot-data-loss.md` | this document |

No Perl file changes. The plugin's behaviour changes only because the answer it
receives from jdssc becomes correct.

## Relationship to Other Work
[Relationship_to_Other_Work](#relationship-to-other-work)

- Found by the deep-verification run (`deep-run-2026-08-21.md`, finding **P1**),
  the same run that produced the `alloc_image` / `free_image` name-validation
  asymmetry — an unrelated defect of similar shape, in that a guard exists on
  one side of an operation and not the other.
- Independent of [0008](../design/0008-sensitive-data-transfer-control.md); it touches
  `driver.py` but no credential path.
- Batch 7 of that run confirmed the jdssc-level guard **does** refuse and names
  the blocker when it is reached, which is what localised this defect to the
  early exit rather than to the detection logic.

## Open Questions
[Open_Questions](#open-questions)

1. **Should the filter compare `createtxg` instead of `creation`?** It would
   remove risk 1 entirely and make the comparison exact rather than
   resolution-bound. Cost: plumbing `createtxg` through the paged snapshot
   listing. Deferred, not rejected — see
   [Alternatives considered](#alternatives-considered).
2. **Should the appliance counter be reported upstream?** The one-second
   resolution of `GET /snapshots/<s>/rollback` is the true root cause and
   affects every client, not only this plugin. This design compensates for it
   but does not fix it.
3. **Is [Change 3](#change-3--the-non-force-rollback-path) in scope?** The
   non-force `rollback do` path is unreachable from the plugin; fixing it is
   correctness for direct CLI users at the cost of a wider diff.
4. **Should a same-second *predecessor* be distinguishable in the message?**
   If risk 1 proves annoying in practice, the refusal could say that the blocker
   shares the target's timestamp and may be older, rather than asserting it is
   newer.
