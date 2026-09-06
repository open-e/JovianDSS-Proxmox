# Template Conversion Silently Overwrites a Same-Named Leftover Volume — Issue (OPEN)

> **Status: open — root cause partially understood, no fix drafted.** The
> *defect* is confirmed live on `Pool-2` with a rigorous reproduction —
> found in Wave 5 of the 2026-08-23 comprehensive campaign
> (`pve-testing/testplans/results/comprehensive-run-2026-08-23.md`, that
> report's finding **8**/**PL-1 and PL-2 revisited**) and independently
> re-traced through the current source while writing this document. What is
> established: the appliance's volume-rename operation does not refuse a
> colliding destination name, and two client-side guards that should catch
> that collision before it reaches the appliance did not engage in the
> observed reproduction. What is *not* established: why those guards missed
> it — the leading hypothesis is an appliance-side listing/lookup staleness
> window that this document cannot confirm without further live
> investigation. No fix is proposed yet; this is a record of what is known
> so the investigation does not restart from zero.

## Table of Contents

- [Overview](#overview)
- [Problem](#problem)
  - [Reproduction](#reproduction)
  - [The_evidence_this_is_a_real_overwrite_not_a_missing_retry](#the-evidence-this-is-a-real-overwrite-not-a-missing-retry)
- [Key_Observation](#key-observation)
- [Mechanism](#mechanism)
  - [The_rename_call_chain](#the-rename-call-chain)
  - [Two_client_side_guards_that_should_have_caught_this](#two-client-side-guards-that-should-have-caught-this)
  - [Why_the_guards_did_not_fire_unconfirmed](#why-the-guards-did-not-fire-unconfirmed)
- [Contrast_with_the_working_create_path](#contrast-with-the-working-create-path)
- [Impact](#impact)
- [Why_this_is_not_yet_a_design_document](#why-this-is-not-yet-a-design-document)
- [Files_Involved](#files-involved)
- [Relationship_to_Other_Work](#relationship-to-other-work)
- [Open_Questions](#open-questions)

---

## Overview

`qm template` converts a VM's disks into base volumes by **renaming** each one
to `base-<vmid>-disk-<n>` (`_create_base`,
[`OpenEJovianDSS/../OpenEJovianDSSPlugin.pm:860`](../../OpenEJovianDSSPlugin.pm#L860)).
If a volume already occupies the chosen target name — the documented
precondition being a **leftover from a previously aborted conversion** — the
existing retry machinery (the fix historically referred to as PL-1/PL-2) is
supposed to detect the collision, pick the next candidate name, and retry.

It does not. The conversion renames straight onto the colliding name, and
whatever occupied that name before is gone. No error, no retry, no log line
suggesting anything was amiss — `qm template` reports success.

## Problem

### Reproduction
[Reproduction](#reproduction)

From Wave 5, `concurrent-template-conversion.yaml`, testcase
`iscsi-plugin-concurrent-template-conversion-001`:

1. Create two VMs on a scratch iSCSI storage (`w5-conc`, `cluster_prefix
   w5cc`). VM2 has three disks.
2. Pre-create a volume directly via REST at the name VM2's first disk would
   receive during conversion: `v_w5cc_base-<VM2>-disk-0` — simulating a
   volume left behind by an earlier, aborted `qm template` run.
3. Run `qm template <VM2>`.

**Expected** (per the testcase's own design and the retry loop visible in
source): the rename to `disk-0` fails "already exists", the wrapper retries
against `disk-1`, and VM2's three disks land on `disk-1`/`disk-2`/`disk-3`.

**Observed**: `qm template <VM2>` exits `0` with no retry at all.
`qm config <VM2>` shows `scsi0`/`scsi1`/`scsi2` bound to
`base-<VM2>-disk-{0,1,2}` — the unshifted, no-collision pattern — and
`base-<VM2>-disk-3` was never created (confirmed absent via REST,
`ZfsResourceError`).

### The evidence this is a real overwrite, not a missing retry
[The_evidence_this_is_a_real_overwrite_not_a_missing_retry](#the-evidence-this-is-a-real-overwrite-not-a-missing-retry)

Two independent checks, both run live, rule out the more boring explanation
("the pre-created stub silently vanished on its own, so there never was a
collision to catch"):

- **Log shape.** `/var/log/joviandss/joviandss.log` shows the rename as a
  single clean `INFO` line — `update volume properties
  {'name': 'v_w5cc_base-<VM2>-disk-0'}` — with no preceding warning, no
  "already exists", no retry sequence. This is a materially different shape
  from the same log's own pattern elsewhere when an "already exists" *is*
  raised and retried, ruling out "the retry happened but logged
  identically."
- **Timestamp forensics.** `base-<VM2>-disk-0`'s ZFS `creation` timestamp was
  cross-referenced against the appliance's own `Date:` header and calibrated
  against a known-clean control (VM1's own `base-<VM1>-disk-0`, which had no
  injected collision and, by ordinary rename semantics, must preserve its
  source disk's original creation time — confirmed: predicted vs. actual
  differ by under 1 second). The same method predicts VM2's **original**
  `vm-<VM2>-disk-0` creation instant to within **0.187 seconds** of the
  object now living at `base-<VM2>-disk-0`. That object is VM2's real
  converted disk, not the pre-existing stub — the rename destroyed/replaced
  whatever occupied the name first, rather than refusing.

No data was lost in *this* reproduction only because the pre-existing volume
was an artificially-empty stub created for the test. The mechanism
generalizes to any volume occupying that name.

## Key Observation
[Key_Observation](#key-observation)

**The retry protection that exists for volume *creation* does not cover
volume *rename*, because the two operations fail differently at the
appliance.** Creation raises a catchable "already exists" error that the
existing retry loop matches on
(`OpenEJovianDSSPlugin.pm:903`,
`/already exists/i`). Rename — `update volume properties` with a `name`
field change — does not raise anything for a colliding destination; it
simply succeeds, silently replacing what was there. A retry loop keyed on
catching an exception cannot help when the exception is never thrown.

That much is fully proven. The harder question — *why did the two
client-side guards described below, which exist specifically to catch this
before it reaches the destructive rename call, both fail to fire in this
reproduction* — is not.

## Mechanism

### The rename call chain
[The_rename_call_chain](#the-rename-call-chain)

```
_create_base (OpenEJovianDSSPlugin.pm:860)
  loop up to 10 attempts:
    getfreename --prefix base-<vmid>-disk-   (jdssc, volumes.py:228)
    _rename_volume(..., new_volname)          (OpenEJovianDSSPlugin.pm:779)
      joviandss_cmd([... "rename", new_name, "--idempotent-scsi-id", $jscsiid])
        rename_volume(..., idempotent=scsi_id) (driver.py:2492)
          [idempotent collision/consistency checks - see below]
          self.ra.modify_lun(vname, {'name': new_vname})  -> appliance PUT
    catch /already exists/i -> retry with a fresh getfreename
    (anything else, including no exception -> loop exits, "success")
```

`_create_base`'s own retry loop
([`OpenEJovianDSSPlugin.pm:878-914`](../../OpenEJovianDSSPlugin.pm#L878-L914))
is the PL-1/PL-2 fix, and it is present and correctly shaped — it works for
the case it's designed for (an exception matching "already exists"). The
defect is entirely upstream of it: nothing on the path from `getfreename`
through `rename_volume` to the appliance raised that exception for a target
name that was, provably, already occupied.

### Two client-side guards that should have caught this
[Two_client_side_guards_that_should_have_caught_this](#two-client-side-guards-that-should-have-caught-this)

Traced through the current source while writing this document — two
independent mechanisms exist specifically to prevent this class of
collision, and by their own logic both should have triggered:

1. **`getfreename` excludes taken names by listing first.**
   [`jdssc/volumes.py:228-272`](../../jdssc/jdssc/volumes.py#L228-L272) calls
   `list_volumes()` fresh, collects every name matching the search prefix,
   and only offers a candidate not already in that set. Verified the
   prefix-construction is internally consistent with how
   [`list_volumes`](../../jdssc/jdssc/jovian_common/driver.py#L1917-L1956)
   de-prefixes appliance names via
   [`jcom.idname`](../../jdssc/jdssc/jovian_common/jdss_common.py#L95-L99)
   (strips the `v_` scheme prefix before the prefix comparison, matching how
   `search_prefix` is built without it) — no client-side prefix-matching bug
   found. For `getfreename` to have offered `disk-0`, the pre-created stub
   must not have appeared in the `list_volumes()` response it consulted.

2. **`rename_volume`'s own idempotency check looks up the destination name
   before renaming.**
   [`jdssc/jovian_common/driver.py:2505-2555`](../../jdssc/jdssc/jovian_common/driver.py#L2505-L2555)
   — when `idempotent` is set (it always is, from the Perl call site's
   `--idempotent-scsi-id`), the function calls `get_volume` on the
   *destination* name before renaming. If a volume is found there and its
   `scsi_id` does **not** match the id the caller expects (i.e. it's a
   genuinely different, pre-existing volume, not the result of an
   already-completed prior attempt), it raises `"Idempotent renaming is
   impossible since ... scsi id ... differ from source volume ..."` — a
   real exception that would in fact match `_create_base`'s
   `/already exists/i` if we widened that pattern, or at minimum would
   surface distinctly rather than silently. For this guard not to have
   fired, `get_volume` on `base-<VM2>-disk-0` must have returned "not
   found" despite the stub existing.

### Why the guards did not fire (unconfirmed)
[Why_the_guards_did_not_fire_unconfirmed](#why-the-guards-did-not-fire-unconfirmed)

Both guards depend on the same thing: an appliance query (`list_volumes` /
`get_volume` → `get_lun`) returning a volume that was, at the time of the
query, genuinely present on the appliance. No bug was found in the
client-side code that constructs or interprets those queries. That leaves
the appliance side — which is closed-source and not inspectable here — as
the remaining candidate, and specifically some form of **listing/lookup
staleness**: a window in which a just-created volume (in the reproduction,
created via a direct REST `POST`, which is also how a genuine "leftover from
an aborted conversion" would have been created — normal plugin operation,
not a synthetic-only path) is not yet visible to the query these two guards
rely on.

This is a hypothesis, not a finding. It has not been isolated with a
minimal repro (e.g., varying the delay between creating the stub and running
the conversion, to see if a longer wait makes the guards fire correctly),
and no appliance-side log or documentation was consulted to confirm or
refute it. Recorded here so the next investigation starts from "check
whether this is a listing-consistency window" rather than re-deriving the
two guards from scratch.

## Contrast with the working create path
[Contrast_with_the_working_create_path](#contrast-with-the-working-create-path)

Wave 5 also ran `concurrent-template-conversion-10vms.yaml` (10 VMs × 3
disks, all converting concurrently, no forced collision — base volume names
are VMID-scoped so 10 different VMs' conversions cannot naturally collide)
and `parallel-linked-clone-no-orphaned-snapshots.yaml` (the **create**-based
collision path via `_clone_image`,
[`OpenEJovianDSSPlugin.pm:943`](../../OpenEJovianDSSPlugin.pm#L943), which
shares `_create_base`'s retry loop but calls a create operation instead of a
rename). Both passed cleanly at real concurrency. The defect is narrowly
about the **rename** primitive's collision behavior, not a general weakness
in the retry mechanism, in concurrency handling, or in `getfreename` under
normal (non-stale) conditions.

## Impact

Any `qm template` conversion that lands on a volume name currently occupied
— the documented scenario being a leftover from a previously aborted
conversion, but the mechanism does not care how the name came to be occupied
— silently destroys that volume's data and proceeds as if nothing happened.
This is arguably a sharper failure mode than
[the same-second rollback issue](rollback-same-second-snapshot-data-loss.md):
that one at least has a *guard* whose input is lossy; this path has two
guards that are individually well-formed but, on this observation, neither
engaged, and nothing signals to the operator that anything went wrong.

**Untested**: whether the NFS plugin's template-conversion path shares this
exposure. NFS `qm template` most likely uses filesystem copy/move semantics
rather than an appliance `update volume properties` rename, which would make
it a different mechanism entirely — but no NFS template-conversion testcase
exists in the current corpus to confirm or refute this one way or the other.
This is an open question, not a resolved absence.

## Why this is not yet a design document
[Why_this_is_not_yet_a_design_document](#why-this-is-not-yet-a-design-document)

The [design-doc README](../design/README.md) expects a proposed fix, drafted
in the same rigor as the problem statement. That isn't possible yet here:
the client-side code is not obviously wrong (both guards are correctly
shaped for the failure they're meant to catch), and the actual gap looks to
be either an appliance-internal staleness window this document has no
visibility into, or a subtler interaction not yet isolated. Any fix drafted
now would be guessing at one of several plausible shapes:

- Re-verify the destination name immediately before the rename call
  ([`_rename_volume`](../../OpenEJovianDSSPlugin.pm#L779)) with a
  freshness-forcing re-query, if the appliance API offers one.
- Retry the whole `getfreename` → `rename` sequence on a short delay when a
  post-rename verification shows the destination's identity doesn't match
  what was expected — turning the *symptom* (wrong content at the target)
  into a detectable, retriable condition rather than relying on the
  pre-check being correct.
- Escalate to Open-E: if this is appliance-side staleness, the appliance's
  own `update volume properties` endpoint refusing a colliding name (the way
  volume *creation* already does) would close this at the root, the same
  way [the rollback issue](rollback-same-second-snapshot-data-loss.md#why-not-fix-it-on-the-appliance)
  identifies an appliance-side fix as the real root-cause resolution for a
  different lossy-input problem.

Picking between these needs the staleness hypothesis confirmed or refuted
first — otherwise a fix could be built for a mechanism that isn't the actual
cause.

## Files Involved
[Files_Involved](#files-involved)

| File | Relevance |
|---|---|
| [`OpenEJovianDSSPlugin.pm:860-917`](../../OpenEJovianDSSPlugin.pm#L860-L917) | `_create_base` - the retry loop that never engages for this failure |
| [`OpenEJovianDSSPlugin.pm:779-832`](../../OpenEJovianDSSPlugin.pm#L779-L832) | `_rename_volume` - composes the rename call and the idempotent-scsi-id argument |
| [`jdssc/jovian_common/driver.py:2492-2626`](../../jdssc/jdssc/jovian_common/driver.py#L2492-L2626) | `rename_volume` - contains the destination-collision idempotency check that did not fire |
| [`jdssc/volumes.py:228-280`](../../jdssc/jdssc/volumes.py#L228-L280) | `getfreename` - the free-name search that offered an occupied name |
| `pve-testing/testcases/iscsi-plugin/concurrency/concurrent-template-conversion.yaml` | the reproducing testcase |

## Relationship to Other Work
[Relationship_to_Other_Work](#relationship-to-other-work)

- [Rollback destroys a same-second snapshot](rollback-same-second-snapshot-data-loss.md) —
  the other data-loss-class finding from this testing effort. Different
  mechanism (a lossy timestamp comparison vs. a rename with no destination
  check), same shape of consequence (silent, no operator signal).
- `pve-testing/testplans/results/comprehensive-run-2026-08-23.md`, Wave 5 —
  original discovery, full reproduction transcript, and the campaign's
  closing release-readiness assessment naming this as one of two items that
  should influence a release decision.
- `pve-testing/testplans/results/deep-run-2026-08-21.md` — the PL-1/PL-2/PL-3
  bug reports this testcase was originally written against; PL-1/PL-2's own
  fix (the retry loop) is confirmed present and working for its own intended
  case (see [Contrast with the working create path](#contrast-with-the-working-create-path)).

## Open Questions
[Open_Questions](#open-questions)

1. **Is the appliance-listing-staleness hypothesis correct?** Needs a
   minimal, isolated repro varying the delay between creating the colliding
   volume and running the conversion. If a longer delay makes the guards
   fire correctly, that confirms a staleness window and narrows the fix to
   either a re-query-before-rename or an escalation to Open-E.
2. **Does NFS `qm template` share this exposure?** No testcase exists to
   answer this either way (see [Impact](#impact)). Writing one is
   straightforward using the same collision-then-convert shape as the
   reproducing iSCSI testcase.
3. **Should `_create_base`'s retry condition be widened** beyond
   `/already exists/i` to also catch `rename_volume`'s "Idempotent renaming
   is impossible" message, in case the destination-collision guard *does*
   fire under some timing and its exception is currently falling through to
   a bare `die` instead of triggering a retry? This would not fix the root
   cause (the guard still has to fire in the first place) but would make the
   failure loud instead of silent whenever the guard does engage.
4. **Is there an appliance API to force a consistent read** (bypassing
   whatever cache/index might be stale) that `getfreename`/`get_volume`
   could use specifically in this retry-sensitive path?
