# Volume Activation with Reactivation — Design Document (ACCEPTED)

> **Status: accepted & implemented (2026-07-03).** Every finding from the critical review
> ([`volume-activation-review-followups.md`](volume-activation-review-followups.md))
> — three rounds, findings 1–20; the third round (12–20: the staging exit
> contract, strict-verification wiring, strand-flag and teardown-pass
> lifecycle, unstage defaults) folded 2026-07-03 — is in this document;
> that file is the review rounds' decision
> record. All three open
> questions are resolved; see [Open Questions](#open-questions) for the decision
> record. Builds directly on
> [`multi-layer-lock-design.md`](multi-layer-lock-design.md) (accepted, implemented):
> this design **activates the reserved `multipath` lock class** — every
> `multipath` / `multipathd` / `udevadm` / `dmsetup` invocation runs under the
> node-scope `multipath` lock — and adds a bounded **reactivation cycle** to
> `volume_activate`: when staging fails or the resulting device verifies wrong
> (absent, size zero, size mismatch), the volume is **deactivated and activation
> is retried from scratch**. The teardown **before the final cycle** — and only
> that one — additionally **detaches the volume from its iSCSI target**
> (`volume_unpublish`): a one-shot recovery rung, **gated on session evidence**
> — JovianDSS is asked for the target's active sessions first, and the detach
> is skipped while any foreign initiator is connected (Open Question #1).
> A stranded udev-cookie semaphore — the `ISSUES.md` Issue 2 condition — is
> repaired by a bounded **stale-cookie sweep** that runs after a failed
> activation attempt, before its teardown
> ([Stale-cookie recovery](#stale-cookie-recovery)).
> This document replaces the raw code draft that previously occupied this file (a
> copy also sits in the untracked `OpenEJovianDSS/multipath.pm`) — see
> [Relationship to the draft](#relationship-to-the-draft).

## Table of Contents

- [Problem_Statement](#problem-statement)
- [Background_and_Research](#background-and-research)
  - [The_activation_flow_today](#the-activation-flow-today)
  - [The_verification_gap](#the-verification-gap)
  - [The_multipath_semaphore](#the-multipath-semaphore)
  - [The_reserved_multipath_lock_class](#the-reserved-multipath-lock-class)
  - [The_refresh_gap_during_staging](#the-refresh-gap-during-staging)
- [Project_Values](#project-values)
- [Options_Considered](#options-considered)
- [Recommended_Solution](#recommended-solution)
  - [The_host_device_command_chokepoint](#the-host-device-command-chokepoint)
  - [Stale_cookie_recovery](#stale-cookie-recovery)
  - [Staging_under_the_lock](#staging-under-the-lock)
  - [Unstaging_under_the_lock](#unstaging-under-the-lock)
  - [The_reactivation_cycle](#the-reactivation-cycle)
  - [The_recovery_detach_and_its_session_gate](#the-recovery-detach-and-its-session-gate)
  - [Device_verification](#device-verification)
  - [Time_budget](#time-budget)
- [Open_Questions](#open-questions)
- [Function_Signature_Change](#function-signature-change)
- [New_Constants](#new-constants)
  - [Value_notes](#value-notes)
- [New_Functions](#new-functions)
- [Changed_Functions](#changed-functions)
- [Obsolete_Functions](#obsolete-functions)
- [Relationship_to_the_draft](#relationship-to-the-draft)
- [Relationship_to_Other_Designs](#relationship-to-other-designs)
- [Risks_and_Backward_Compatibility](#risks--backward-compatibility)
- [Files_That_Would_Change](#files-that-would-change-when-implemented)
- [List_of_Tables](#list-of-tables)

## List of Tables
[List_of_Tables](#list-of-tables)

Each table carries a unique `tbl_*` tag, repeated verbatim in its caption (vim: `*` on
the tag jumps between this list and the table).

1. `tbl_locked_commands` — **Locked host-device commands**: every `multipath` /
   `multipathd` / `udevadm` / `dmsetup` invocation, its purpose and lock treatment.
2. `tbl_activation_cycle` — **Reactivation cycle**: the stages of one activation
   attempt and the teardown step that inverts each.
3. `tbl_verify_outcomes` — **Verification outcomes**: what the device check can find
   and what happens next.
4. `tbl_constants_desc` — **Constant descriptions** (Table 4a) and
   `tbl_constants_values` — **Constant values** (Table 4b): the single point of truth
   for every value this design introduces or changes.
5. `tbl_constants_related` — **Related existing constants**: pre-existing constants
   the invariants and the budget arithmetic lean on.
6. `tbl_files_changed` — **Files that would change**: files touched when implemented.

---

## Problem Statement
[Problem_Statement](#problem-statement)

**What's wrong.** Three related failures in volume activation:

1. **Host device-layer commands run unserialized.** Every activation and
   deactivation drives `multipath`, `multipathd`, `udevadm` and `dmsetup` directly.
   These contend on shared node-wide state — the multipath IPC semaphore and the one
   device-mapper table — and a killed holder can strand the semaphore, hanging every
   later `multipath` call on the node (a real production hang: live migration froze
   at the destination's `activate_volume`; `ISSUES.md` Issue 2). The multi-layer
   lock design reserved the `multipath` lock class for exactly this and left the
   wiring as a follow-up — this design is that follow-up.
2. **Activation can "succeed" with a wrong device.** The size check in
   `lun_record_update_device` (`Common.pm:4159–4173`) compares
   `blockdev --getsize64` against the expected size, retries its rescan loop, and on
   persistent mismatch **falls out of the loop and returns silently** — a zero-size
   or stale-size device is handed to Proxmox as a successful activation.
3. **There is no recovery path beyond in-place retries.** When multipath staging
   fails, the inner loops retry the *same* staging against the *same* iSCSI session
   and target attachment. A failure rooted below the staging — a wedged target/LUN
   attachment on the backend, a session that came up wrong — persists across all
   attempts, because nothing tears the stack down and rebuilds it.

**Desired behavior change.**

- Every `multipath` / `multipathd` / `udevadm` / `dmsetup` invocation is **lockable
  under the node lock**: routed through one chokepoint that wraps the single command
  in `with_lock($ctx, 'multipath', …)` (node scope by default, operator-tunable like
  any lock class).
- Activation ends with a **verified** device: present, size **non-zero** and equal
  to the storage-side size — or it fails loud.
- On multipath-staging or verification failure, activation performs a
  **deactivation — unstage multipath, log out iSCSI** — then retries the whole
  cycle, a bounded number of times. The teardown **before the final cycle** —
  after every earlier cycle has failed — additionally **detaches the volume
  from its target (`volume_unpublish`)**: a recovery mechanism, not a routine
  step, **gated on session evidence** — JovianDSS is asked for the target's
  active sessions, and the detach is skipped while any foreign initiator is
  connected (Open Question #1). All other passes keep today's partial cleanup
  (snapshot unpublish only).

**Non-goals.**

- **`iscsiadm` serialization.** iSCSI session management contends on `iscsid`, a
  different component; if it needs a lock it gets its own class later (the lock
  design makes that a configuration row, not new machinery).
- **General post-crash repair.** This design prevents the semaphore-strand trigger
  (serialization + TERM-first bounding) **and** self-repairs verified-stale udev
  cookies ([Stale-cookie recovery](#stale-cookie-recovery)) — but telling a wedged
  `multipathd` from a slow one, restarting the daemon (disruptive to path
  checking), and anything stuck in D-state remain host-level operator escalations.
- **Deactivation-path redesign.** `volume_deactivate*` keeps its structure; it only
  picks up the parameterized unstage signatures and the locked chokepoint.

---

## Background and Research
[Background_and_Research](#background-and-research)

### The activation flow today
[The_activation_flow_today](#the-activation-flow-today)

`volume_activate` (`Common.pm:3769`) is single-shot. One `eval` runs, in order:
`volume_publish` (jdssc — creates/attaches the target), `volume_stage_iscsi`
(login, yields the iSCSI block paths), `volume_stage_multipath` (builds the dm map;
only when multipath is enabled), `volume_get_size` (jdssc),
`lun_record_local_create`, and `lun_record_update_device` (rescan + size recheck).
On error the unwind unstages iSCSI and multipath and deletes the local LUN record —
but **unpublishes only snapshots** (`Common.pm:3876–3889`), with the comment *"We do
not delete target on joviandss as this will lead to race condition in case of
migration"*. There is no retry of the whole sequence; the only retries live *inside*
`volume_stage_multipath` (60 hardcoded attempts, `sleep(2)`, `Common.pm:2296`) and
`lun_record_update_device` (10 hardcoded attempts, `Common.pm:4048`).

### The verification gap
[The_verification_gap](#the-verification-gap)

`lun_record_update_device`'s loop exits three ways (`Common.pm:4159–4173`): size
matches → record updated, `last`; no expected size given → `last`; **attempts
exhausted with a mismatch → the loop simply ends and the sub returns**. Nothing
dies. A device that reports size `0` — the observed failure this design exists for —
passes activation, and `volume_activate` returns its block devices as if all were
well.

### The multipath semaphore
[The_multipath_semaphore](#the-multipath-semaphore)

From `ISSUES.md` Issue 2 (live-migration hang, status fixed): concurrent `multipath`
invocations compete for a Linux IPC semaphore; a holder killed with **SIGKILL**
strands it at value 1, and every later `multipath` call blocks forever in
`semtimedop(…, NULL)`. The applied fix replaced bare `multipath` scans with per-WWID
calls plus a timeout, on the rationale that the timeout delivers SIGTERM, which
`multipath`'s signal handler catches to release the semaphore.

**Verified against the PVE source: that rationale does not hold for `run_command`.**
`PVE::Cmd::run` kills a timed-out command with `kill(9, $pid)`
(`pve-common/src/PVE/Cmd.pm:315`) — SIGKILL, the one signal that bypasses the
handler. So today every command timeout re-creates the exact strand hazard the fix
meant to remove. Two consequences for this design: serialization must remove the
*competition* trigger (the lock), and command bounding must be **TERM-first** with
SIGKILL only as a last resort (the chokepoint's `timeout --signal=TERM` wrapper —
see [The host-device command chokepoint](#the-host-device-command-chokepoint)).
`ISSUES.md`'s fix note should be corrected alongside.

### The reserved multipath lock class
[The_reserved_multipath_lock_class](#the-reserved-multipath-lock-class)

The multi-layer lock design ships the `multipath` class fully wired
(`LOCK_DEFAULT_TYPE` / timeout maps / `LOCK_CLASS_PROPERTY` rows in
`OpenEJovianDSS/Lock.pm`), default scope `node` → a host-local `flock` at
`/run/lock/joviandss-lock-multipath`, status *reserved*. Its binding rule is that
design's Open Question #1a: **component locks are leaves** — a body under the
`multipath` lock must not take another `with_lock` lock and never calls
`joviandss_cmd`. Wrapping each bare command invocation (never a retry loop)
satisfies that structurally. The class's `storage.cfg` properties
(`multipath_lock_*`) are honored by the generic getters but not yet declared in the
schema; declaring them is a `lock_properties()` + `options()` addition.

### The refresh gap during staging
[The_refresh_gap_during_staging](#the-refresh-gap-during-staging)

Method locks on shared storage are pmxcfs locks and must be refreshed within
`CFS_LOCK_TIMEOUT`. The lock design's refresh brackets fire around every `with_lock`
body — which today means **around jdssc runs only**. `volume_activate` performs its
longest work *between* jdssc runs: iSCSI login and a multipath stage loop that can
run for minutes with **no cooperation point at all** — the outer `vm` lock's mtime
goes stale, and a same-vmid waiter on another node (exactly the migration pattern)
could stale-reclaim it mid-activation. Two mechanisms close the gap
(review follow-up #4 — the first alone was originally overclaimed as
sufficient):

- **The multipath phase** is covered incidentally by routing every host-device
  command through `with_lock`: each locked command is bracketed by
  `run_refreshed`, so the outer method lock is refreshed — and its hold
  deadline checked — at every `multipath`/`udevadm`/`dmsetup` invocation.
- **The iSCSI phase** — `volume_stage_iscsi`'s login loop and its 240-tick
  device wait (`Common.pm:2194`), the activation's longest uncooperative
  stretch, with zero locked commands — gains **explicit refresh ticks**:
  `OpenEJovianDSS::Lock::refresh_locks($ctx)` on every login attempt and
  every 10th device-wait tick. A refresh call takes no lock (the leaf rule is
  untouched) and runs the hold-deadline check, giving the fatal-error
  classification eyes inside the wait. **Amended 2026-07-05 (review F-05):**
  the per-attempt tick alone was insufficient — one attempt runs the portal
  logins back-to-back, and each login can block up to the initiator login
  timeout via an *untimed* command, so ≥4 slow portals could outlast
  `CFS_LOCK_TIMEOUT` between ticks while waiters poke the held lock
  (stale-reclaim of a held lock = split-brain). Now every **portal** login is
  followed by its own `refresh_locks` cooperation point, and the login
  command itself is bounded end-to-end by `ISCSI_LOGIN_CMD_TIMEOUT` (which
  must exceed `ISCSI_LOGIN_TIMEOUT`, the value written into the iscsiadm
  node DB — the command bound reaches a wedged iscsid, which the node-DB
  timeout cannot). The un-refreshed window is thereby capped at roughly one
  bounded login, far inside the pmxcfs idle window. *Residual, accepted:*
  the periodic `rescan-scsi-bus` escalation can itself run minutes under
  load — an uncooperative stretch no tick can enter; if the field shows
  stale reclaims from inside a rescan, bounding the rescan is the follow-up.

---

## Project Values
[Project_Values](#project-values)

The [values of the multi-layer lock design](multi-layer-lock-design.md#project-values)
govern here unchanged, with #1 (*component safety / correctness first — fail loud*)
and #5 (*robustness under failure*) doing the deciding: a wrong-size device must
fail activation rather than pass it, a failed stack must be rebuilt rather than
re-polled, and every new command invocation must be serialized and exception-safe.

---

## Options Considered
[Options_Considered](#options-considered)

**Option A — Hard-fail verification only (no cycle).** Make the size check die and
add the locks, but keep activation single-shot. *Rejected:* it converts silent
corruption into a loud failure (good) but leaves the failure permanent — the class
of failure actually observed (device stuck at size 0) is rooted in
session/attachment state that only a teardown resets; the operator would retry by
hand what the plugin can retry itself.

**Option B — Reactivation cycle with target detach as a last-chance recovery
(chosen, revised).** Bounded outer loop in `volume_activate`: attempt → verify →
on failure tear down what the attempt built — multipath map, iSCSI session —
and start over; **once, in the teardown before the final cycle**, the target
attachment is torn down too (`volume_unpublish`). *Tradeoff:* the detach is
what makes a retry actually reset backend state, but it is also the step with a
migration co-activation hazard (Open Question #1 — revised twice: the detach is
demoted to a one-shot recovery rung before the final cycle **and** gated on
backend session evidence — skipped while any foreign initiator is connected);
and worst-case activation latency grows by the
cycle count — bounded by the budget below and ultimately by the `vm` lock's
hold deadline.

**Option C — Reactivation cycle without detach.** Tear down only to the iSCSI
logout and re-login. *Rejected as the sole mechanism:* it cannot fix a wedged
target/LUN attachment on the JovianDSS side — re-login to a broken attachment
reproduces the same device. (Under the revised Open Question #1 this shape **is**
the routine teardown: every failed cycle except the one before the final attempt
tears down to the logout level only. Its known limitation — a wedged attachment
survives it — is exactly why the pre-final-cycle teardown escalates to the
Option B detach.)

---

## Recommended Solution
[Recommended_Solution](#recommended-solution)

### The host-device command chokepoint
[The_host_device_command_chokepoint](#the-host-device-command-chokepoint)

All `multipath` / `multipathd` / `udevadm` / `dmsetup` invocations move onto **one
chokepoint**, mirroring how `joviandss_cmd` is the single chokepoint for jdssc:

```perl
# multipath_cmd($ctx, $cmd, $timeout, $outfunc)
#   $cmd      argv arrayref of ONE multipath/multipathd/udevadm/dmsetup invocation
#   $timeout  seconds for the command (TERM bound), or undef →
#             MULTIPATH_CMD_TIMEOUT_DEFAULT; clamped to MULTIPATH_CMD_TIMEOUT_MAX
#   $outfunc  optional stdout line handler (default: capture + debug log)
# Runs the one command under the node-scope 'multipath' lock. The locked body is
# the bare run — the lock design's leaf rule: it takes no other with_lock and
# never calls joviandss_cmd. All retry sleeps stay at the callers, OUTSIDE the lock.
sub multipath_cmd {
    my ( $ctx, $cmd, $timeout, $outfunc ) = @_;

    $timeout //= MULTIPATH_CMD_TIMEOUT_DEFAULT;
    $timeout = MULTIPATH_CMD_TIMEOUT_MAX
        if $timeout > MULTIPATH_CMD_TIMEOUT_MAX;
    $timeout = 1 if $timeout < 1;   # coreutils timeout treats 0 as NO bound —
                                    # it would disarm the TERM-first ladder,
                                    # leaving only run_command's SIGKILL
                                    # backstop (finding #20)

    my $out = '';
    my $capture = $outfunc // sub {
        my ($line) = @_;
        $out .= "$line\n";
        cmd_log_output( $ctx, 'debug', $cmd, $line );
    };

    # TERM-first bounding (see The multipath semaphore): coreutils timeout(1)
    # sends SIGTERM at $timeout — multipath's handler releases the IPC
    # semaphore — and escalates to SIGKILL only MULTIPATH_CMD_KILL_GRACE later.
    # run_command's own kill is SIGKILL (PVE::Cmd::run) — the exact re-strand
    # hazard this ladder exists to avoid — so it is armed a full
    # MULTIPATH_CMD_BACKSTOP_MARGIN above the escalation (not 1 s: under the
    # loaded regime this code runs in, fork/exec latency can eat a thin
    # margin — review follow-up #10): it can only fire after the graceful
    # termination already failed.
    my $tcmd = [ '/usr/bin/timeout', '--signal=TERM',
                 '--kill-after=' . MULTIPATH_CMD_KILL_GRACE,
                 $timeout, @$cmd ];

    my $exitcode;
    my $run = sub {
        $exitcode = run_command( $tcmd,
            outfunc => $capture,
            errfunc => sub { cmd_log_output( $ctx, 'error', $cmd, shift ) },
            timeout => $timeout + MULTIPATH_CMD_KILL_GRACE
                       + MULTIPATH_CMD_BACKSTOP_MARGIN,
            noerr   => 1,
        );
    };
    OpenEJovianDSS::Lock::with_lock( $ctx, 'multipath', undef, undef, $run );

    # Stranded-cookie signature (124 = TERM'd at the bound, 137 = KILL'd
    # after the grace): remembered on $ctx for the reactivation cycle's
    # sweep gate (Stale-cookie recovery) — the chokepoint itself retries
    # and repairs nothing.
    $ctx->{_multipath_cmd_ladder_exhausted} = 1
        if defined($exitcode) && ( $exitcode == 124 || $exitcode == 137 );

    return { exitcode => $exitcode, out => $out };   # fixed shape (return convention)
}
```

Properties this buys, all at one code site:

- **Serialization.** One host-device command per node at a time — the semaphore
  competition trigger from `ISSUES.md` Issue 2 is gone by construction. Scope is
  operator-tunable via `multipath_lock_type` like any lock class.
- **Safe termination.** A hung command dies by SIGTERM (semaphore released), SIGKILL
  only `MULTIPATH_CMD_KILL_GRACE` later; `run_command`'s un-catchable kill sits
  `MULTIPATH_CMD_BACKSTOP_MARGIN` above both. Invariant, argued symbolically:
  `MULTIPATH_CMD_TIMEOUT_MAX + MULTIPATH_CMD_KILL_GRACE +
  MULTIPATH_CMD_BACKSTOP_MARGIN < LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT` — a maximal
  legitimate command can never trip the lock's hold cap (values: Table 4b).
- **Cooperation points.** Every locked command runs under `run_refreshed`,
  refreshing every held outer lock and enforcing hold deadlines — closing
  [the refresh gap](#the-refresh-gap-during-staging) throughout staging.
- **Uniform logging and error handling.** The `cmd_log_output` + `eval {}`
  boilerplate repeated at ~20 sites today collapses: `noerr => 1` means a failing
  command reports through `->{exitcode}` instead of dying, so the per-site `eval`
  wrappers disappear — and a *lock-machinery* failure now deliberately propagates:
  it fails the activation attempt, and the cycle's
  [error classification](#the-reactivation-cycle) decides what happens next
  (an acquire timeout is **contention** — retried without teardown; a hold-cap
  breach is **fatal** — rethrown out of the cycle entirely, teardown skipped).
- **Hang visibility.** A command that survives its **whole** termination ladder
  comes back with coreutils `timeout`'s distinctive exit codes (124 = TERM'd at
  the bound, 137 = KILL'd after the grace) — the classic stranded-cookie
  signature, which the chokepoint **records on `$ctx`**
  (`_multipath_cmd_ladder_exhausted`) as the reactivation cycle's sweep gate.
  The chokepoint itself does nothing more with it (decided — a
  per-command sweep-and-retry would compound under a stuck window, every hung
  command paying its ladder twice); repair belongs to the reactivation cycle
  ([Stale-cookie recovery](#stale-cookie-recovery)). One `noerr` caveat for
  implementers: `->{exitcode}` is not the only failure channel — if the
  backstop ever fires, `run_command`'s timeout death is a `die` even with
  `noerr => 1`, and it propagates as an ordinary attempt failure for the
  cycle to classify.

Acquisition under load: the class's acquire wait must outlast one full worst-case
hold with real headroom — a deeper queue can still time a waiter out, which the
cycle's contention class absorbs (finding #20) — so this design **raises
`LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT`** (Table 4b;
the lock design's Table 9b row updates at implementation time). A failed acquisition dies →
the attempt fails → the cycle retries — self-healing, not hanging. (An acquire
timeout is **contention** under the cycle's error classification: it reports a
lock **not yet held** — nothing was modified under it, every lock already held
is still valid, and nothing suggests the device stack is broken — so the retry
runs **without a teardown**, sparing the full logout/republish churn a
transient queue would otherwise cost — review follow-up #9. A hold-cap breach,
by contrast, is fatal and rethrows.)

**Table 1 — Locked host-device commands** · `tbl_locked_commands`

Current invocation sites (`Common.pm` lines) and their treatment. Every row routes
through `multipath_cmd` with a named timeout tier (values: Table 4b):
`MULTIPATH_CMD_TIMEOUT` for `multipath` CLI per-WWID operations and read probes,
`MULTIPATHD_CMD_TIMEOUT_FAST` for quick `multipathd` socket commands (a healthy
daemon answers in well under a second — a longer wait signals trouble, and the
round/cycle retries), `MULTIPATH_CMD_TIMEOUT_MAX` for commands that do real
synchronous work or stall under load (scans, flushes, path/map registration, block
triggers, dm removals), and `MULTIPATH_CMD_TIMEOUT_DEFAULT` for the middle ground
and any caller that passes nothing.

*Anchor note (finding #20):* the `Common.pm` line anchors in this document
predate the `jdssc-target-sessions` implementation (shipped 2026-07-03);
sub-level anchors were re-verified and corrected 2026-07-03, while
statement-level anchors (including this table's site column) may sit
~10–20 lines off and get a full refresh at implementation time.

| Command | Sites today | Purpose | Timeout tier |
|---|---|---|---|
| `multipath -a <wwid>` | 2229, 2401 | whitelist WWID — kept as CLI (decided: the chokepoint's TERM-first bound covers the kill hazard; `multipathd add wwid` stays optional hardening) | `MULTIPATH_CMD_TIMEOUT` |
| `multipath <wwid>` | 2366 | per-WWID scan/build | `MULTIPATH_CMD_TIMEOUT_MAX` |
| `multipath -ll <wwid>` | 2542, 3257 | read map state; also the exit-contract acceptance probe (`_multipath_map_has_active_path` — new caller) | `MULTIPATH_CMD_TIMEOUT` |
| `multipath -w <wwid>` | 3018 | un-whitelist WWID | `MULTIPATH_CMD_TIMEOUT_DEFAULT` |
| `multipath -f <wwid>` | 3051 | flush map | `MULTIPATH_CMD_TIMEOUT_MAX` |
| `multipath -r <path>` | 4121 | reload map (size recheck) | `MULTIPATH_CMD_TIMEOUT_DEFAULT` |
| `multipath reconfigure` | 4128 | *(invalid — a silent no-op today)* — **corrected to `multipathd reconfigure`** (decided, Open Question #3), gated to every 5th verify round | `MULTIPATH_CMD_TIMEOUT_MAX` |
| `multipathd add path <dev>` | 2303 | register path with daemon | `MULTIPATH_CMD_TIMEOUT_MAX` (stalls under load — production experience) |
| `multipathd add map <wwid>` | 2412 | create map | `MULTIPATH_CMD_TIMEOUT_MAX` (same) |
| `multipathd del map <wwid>` | 2395, 3040, 3064 | drop map (unstage path; the staging-loop recovery site 2395 is **dropped** — the cycle's teardown supersedes it) | `MULTIPATHD_CMD_TIMEOUT_FAST` |
| `multipathd reconfigure` | 2430 | heavy daemon re-read fallback | `MULTIPATH_CMD_TIMEOUT_MAX` |
| `udevadm trigger /sys/block/<dev>` | 2323 | targeted event replay | `MULTIPATH_CMD_TIMEOUT_MAX` |
| `udevadm trigger --property-match=ID_SERIAL=<wwid>` | 2342 | WWID-scoped event replay | `MULTIPATH_CMD_TIMEOUT` |
| `udevadm trigger -t all` | 4102 | **replaced** by the WWID-scoped form — the broad trigger disrupts active multipath devices (the hazard `Common.pm:2292` documents) | — |
| `dmsetup info <name>` | 3150 | orphan-map probe (same device-mapper state as multipath, hence locked) | `MULTIPATH_CMD_TIMEOUT` |
| `dmsetup remove -f / --deferred` | 3082, 3125 | orphan-map removal | `MULTIPATH_CMD_TIMEOUT_MAX` |
| `dmsetup udevcookies` | — (new) | stale-cookie probe, read-only ([Stale-cookie recovery](#stale-cookie-recovery)) | `MULTIPATH_CMD_TIMEOUT` |
| `dmsetup -y udevcomplete_all <age>` | — (new) | age-bounded stale-cookie sweep (`-y`: the command prompts, and a declined prompt still exits 0 — verified on PVE 9.1) | `MULTIPATH_CMD_TIMEOUT_DEFAULT` |

**Deliberately not locked:** `lsof`, `ps`, `readlink`, `blockdev --getsize64`
(read-only process/device queries — no multipath state), the `/sys/…/rescan`
writes, `iscsiadm` (different component — non-goal), `pvesh` (cluster API). Sleeps
between attempts always sit outside the lock, so waiters are never held behind a
sleeping holder.

### Stale-cookie recovery
[Stale_cookie_recovery](#stale-cookie-recovery)

Prevention shrinks the strand hazard to a rare tail — the wrapper's last-resort
SIGKILL, the OOM killer, a crash — but that tail is exactly the condition that
today freezes a node until an operator runs `dmsetup udevcomplete_all` / `ipcrm`
by hand (`ISSUES.md` Issue 2: `semtimedop` waits with **no** timeout). The
device-mapper layer ships its own repair tools; the design question is **where**
to invoke them.

**Placement (decided 2026-07-03): in the reactivation cycle, not the
chokepoint.** A per-command hook — sweep-and-retry whenever a command exhausts
its termination ladder — was specified first and rejected: under a stuck window
*every* command hangs, so every command would pay its full ladder, then a sweep,
then a **retried** full ladder — the repair machinery itself would multiply the
stall. Instead the sweep runs **after a failed activation attempt, before the
teardown — and only while the strand signature is armed**: at least one
command since the signature was last consumed survived the whole termination
ladder (exit 124/137, recorded on `$ctx` by `multipath_cmd` — review
follow-up #8; the signature survives from a previous cycle's teardown or
sweep into the next attempt's gate — finding #14). Gating on the signature keeps the sweep away from the one
regime where it could do harm: a node under generic IO distress, where
*legitimate* dm cookies (node-local LVM under the same load) are at their
oldest and an age-only sweep could complete a live operation early. A failed
attempt with no hung command sweeps nothing. The sweep stays cheap (the probe
is one read-only command), bounded (at most `VOLUME_ACTIVATE_CYCLE_ATTEMPTS`
sweeps per activation), and placed where it helps most — a strand that broke
the attempt would otherwise hang the teardown's own dm commands too. There is
no per-command retry anywhere; the "retry" after a sweep is the next
activation cycle itself, re-running everything over a repaired field.

The call sits in `volume_activate`'s failure branch (see
[The reactivation cycle](#the-reactivation-cycle)):

```perl
        # Stale-cookie sweep BEFORE the teardown — and only while the
        # strand signature is armed: set by this attempt, or re-armed by
        # the previous teardown's/sweep's own hung command (finding #14;
        # exit 124/137, i.e. survived the whole termination ladder;
        # recorded on $ctx by multipath_cmd). If a stranded cookie broke
        # the attempt, the teardown's dm commands would hang on it too.
        # Best-effort — a sweep failure must not mask $last_err — except
        # a fatal lock-machinery error, which rethrows.
        if ( delete $ctx->{_multipath_cmd_ladder_exhausted} ) {
            eval { _multipath_cookie_sweep($ctx) };
            if ($@) {
                die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
                debugmsg( $ctx, 'warn', "Stale-cookie sweep failed: $@" );
            }
        }
```

```perl
# Probe-then-sweep for stranded device-mapper udev cookies (see The multipath
# semaphore in Background): a cookie whose owner was SIGKILL'd is never
# completed by anyone, and every later waiter blocks forever. Called from
# volume_activate's failure branch — only while the 124/137 strand
# signature is armed, before the teardown. Both commands
# route through multipath_cmd — same node lock, same bounds. Returns the
# number of outstanding cookies found (diagnostic).
sub _multipath_cookie_sweep {
    my ($ctx) = @_;

    my $probe = multipath_cmd( $ctx, [ $DMSETUP, 'udevcookies' ],
                               MULTIPATH_CMD_TIMEOUT );
    return 0                              # dm layer unreachable — nothing to do
        if !defined( $probe->{exitcode} ) || $probe->{exitcode} != 0;

    # udevcookies prints a header row and a version-dependent column layout;
    # matching cookie lines by the leading 0x is the portable read
    # (verified on PVE 9.1, 2026-07-03: rows print as "0xd4d711c  7  1  ...").
    my @cookies = grep { /^0x/ } split /\n/, $probe->{out};
    return 0 if !@cookies;                # no outstanding cookies — nothing to sweep

    debugmsg( $ctx, 'warn',
        scalar(@cookies) . " outstanding udev cookie(s) after a failed "
      . "activation attempt; completing those older than "
      . MULTIPATH_COOKIE_STALE_AGE . " minutes" );

    # Age-bounded: touches nothing younger than MULTIPATH_COOKIE_STALE_AGE.
    # -y is LOAD-BEARING (verified on PVE 9.1, 2026-07-03):
    # udevcomplete_all prompts for confirmation, and answering "n" still
    # exits 0 — without -y the sweep would silently do nothing.
    multipath_cmd( $ctx,
        [ $DMSETUP, '-y', 'udevcomplete_all', MULTIPATH_COOKIE_STALE_AGE ] );

    return scalar(@cookies);
}
```

Rules that keep the sweep safe:

- **Probe first, read-only.** `dmsetup udevcookies` only lists outstanding
  cookies; none listed → no completion runs — the attempt failed for another
  reason and the teardown proceeds normally.
- **Age-bounded completion only.** `dmsetup -y udevcomplete_all` with an age
  argument touches nothing younger than `MULTIPATH_COOKIE_STALE_AGE` — far above
  any legitimate udev latency (the documented inquiry backlog is tens of
  seconds), so live operations are never completed early. LVM shares the cookie
  mechanism and is protected by the same bound; a cookie whose owner is dead
  will never be completed by anyone else anyway.
- **Once per signature-bearing failed attempt, best-effort.** The sweep runs
  only while the 124/137 strand signature is armed, is bounded by
  the cycle count, its own two commands are bounded by the chokepoint's
  termination ladder, and a sweep failure is warned and swallowed (fatal lock
  errors excepted — those rethrow) — it must never mask the attempt's real
  error. No recursion is possible: nothing inside the sweep triggers
  sweeping — and a ladder-exhausted command *inside* the sweep or teardown
  re-arms the flag for the **next** attempt's gate, never a re-sweep of this
  one.
- **Under the same node lock.** The sweep's commands route through
  `multipath_cmd` like any other (the sweep itself runs *between* locked
  commands, never inside one — the re-entry guard would refuse otherwise), so
  they serialize with, and cannot race, the plugin's own device-mapper work.

A strand younger than `MULTIPATH_COOKIE_STALE_AGE` is deliberately not completed
by the first sweep: that cycle may fail loud, and the cookie crosses the age
bound while later cycles — or simply the next operation — run their sweeps, so
the node self-heals within minutes instead of waiting for a manual intervention.

**Prevention hardening — the daemon-over-CLI option.** Where a `multipathd`
socket command is equivalent to a `multipath` CLI call, moving the call into
the daemon removes a strand candidate outright: the daemon owns the
device-mapper operations and their cookies, and killing the plugin's
short-lived client — even with SIGKILL — strands nothing (the Issue 2 holder
was a `multipath` CLI process). **Decided:** with `multipath_cmd`'s TERM-first
bound already covering the routine kill hazard, the staging round keeps the
proven CLI `multipath -a` for its whitelist step; `multipathd add wwid` — and
daemon forms of the other CLI calls (`-w`, `-f`, `-ll`, `-r`, the per-WWID
scan), where a multipath-tools version provides them — stay recorded here as
optional hardening to adopt if field behavior warrants (Table 1 stays the
routing inventory either way).

### Staging under the lock
[Staging_under_the_lock](#staging-under-the-lock)

**Load-bearing invariant — `volume_stage_iscsi`'s exit contract (contract
now explicit; option A extends it with capacity — see below).**
`volume_stage_iscsi`'s body works in terms of iSCSI
*sessions* — its login loop's only evidence is `iscsiadm --mode session` output —
and a session alone proves nothing about the LUN's block device: the kernel must
still instantiate the disk and udev must still process it (run the inquiry that
names it). What makes the function safe to build on is its **final device wait**:
it returns only once `-b` on `block_device_path_from_serial($scsiid, 0)` succeeds
— the device node exists *and* udev has processed it (the by-id symlink is
inquiry-derived) — and otherwise dies (`Common.pm:2196–2218`, up to 240 s with
periodic rescans). Everything downstream relies on that post-condition: the VPD
wait's no-op-guard argument, the sd-name resolution, the budget arithmetic. Any
future rework of `volume_stage_iscsi` **must not return on session evidence
alone**. (The contract covers *one* path — the by-id winner; with several
portals the remaining paths may still be pending udev processing, which
multipathd absorbs asynchronously, helped by the round body's add-path and
trigger escalations.)

**Option A (finding #23): the exit contract also verifies capacity.**
*(Amended 2026-07-05 — review F-04: activation no longer supplies an expected
size at all. The broken-export tell of finding #23 is a zero/absent READ
CAPACITY, so the exit contract requires a **non-zero** staged capacity only;
exact-match was wrong for snapshots — the exported entity is a clone frozen
at snapshot-time volsize while the parent's current size diverges after any
post-snapshot resize — and dropping the `volume_get_size` fetch also removes
one cluster-locked jdssc round-trip from every activation. The exact-match
rows below remain the contract for any caller that does supply an expected
size; today none does — the lenient resize path has its own check.)* With
option A, `volume_stage_iscsi` takes an optional expected size and its final
wait returns only once the by-id device is present **and** reports a
conforming non-zero capacity — a forced
rescan → `blockdev --getsize64` → compare, using the rescans the wait loop
already performs (rescan-then-read: the rescan is the wire READ CAPACITY,
`getsize64` reads the refreshed cache). This is the **backend-export health
probe** (finding #23): under heavy create-and-attach load SCST can export a
LUN wrong — node present, paths up, *looks* healthy — but non-functional,
and the tell is a wrong/zero capacity at the raw LUN. Verifying it here, at
the `sd` layer, catches that at the most direct point and fails the attempt
into the reactivation cycle (teardown → re-publish → re-login), which is the
recovery. The multipath map's size is *derived* from this now-verified `sd`,
so `volume_stage_multipath` adds **no** size check of its own.

**A matching exit contract for the multipath stage (finding #12).**
`volume_stage_multipath` returns only a map that shows **at least one
active path** — or dies. Bare existence of the mapper node is never
acceptance evidence outside the direct callers' fast path: a leftover map
from an earlier failed operation (a *zombie*: device node present, paths
dead or belonging to a logged-out session) passes `-b` indefinitely, and
size verification cannot expose it either — `blockdev --getsize64` is
answered from the dm table length without touching a path, so a
dead-but-intact map reports its correct size and would ride a size-only
check into a **false success**. The acceptance predicate — `-b` **plus**
`_multipath_map_has_active_path` — gates every return of an existing or
newly built map: the `$verify_map` fast path, the top of the driving loop
after each inter-round sleep (which doubles as the grace multipathd's path
checker needs, `polling_interval` typically ~5 s, to mark freshly attached
paths — a just-assembled healthy map costs a round, never a cycle), and
the post-loop settle check; only the direct callers' bare `-b` fast path
sits outside it. The round body issues
commands only; its `-b` short-circuits stop further escalation within a
round and are never acceptance. A map that never shows an active path
exhausts the rounds and **dies into the reactivation cycle's teardown** —
logout, unstage, `dmsetup remove -f`: the designed repair for the
incomplete prior teardown a zombie is evidence of — while the rounds
meanwhile attempt the cheap in-place repair for free (`add path` attaches
the fresh session's paths to the existing map).

`volume_stage_multipath` splits into a driving loop and a single-round body (the
draft's shape). The caller owns sanitation, the map fast-path (for the direct
callers — the common case — return before any command and before any lock;
under `$verify_map`, the activation flow, one locked active-path probe
first), the up-front WWID whitelist (issued
**before** the VPD wait, so the wait overlaps with multipathd already claiming
paths as they appear — the order current code uses), the VPD wait, the sd-device
resolution, every sleep, and a post-loop settle check (the final round's
trigger/reconfigure escalations land asynchronously — one last look after the
settle sleep, instead of dying on their heels); the body owns one round of
commands — through `multipath_cmd`, with advisory `-b` short-circuits between
commands, never under the lock; acceptance (node present **and** an active
path) belongs to the driving loop alone:

```perl
sub volume_stage_multipath {
    my ( $ctx, $scsiid, $block_devs, $attempts, $verify_map ) = @_;

    $scsiid    = OpenEJovianDSS::Common::safe_word( clean_word($scsiid),
                                                    'multipath scsi id' );
    $attempts //= MULTIPATH_STAGE_ATTEMPTS;

    my $mpath = clean_word( block_device_path_from_serial( $scsiid, 1 ) );

    # Fast path — the map already exists (typical for the direct callers
    # re-resolving an active volume): return before any command, no lock
    # taken at all. Mirrors volume_stage_iscsi's own fast path.
    # $verify_map (set by the ACTIVATION flow — EVERY cycle, finding #12;
    # direct callers keep the bare -b): existence is not evidence there —
    # a leftover map whose teardown could not remove it, or one marked
    # for deferred removal, still owns a device node while its paths
    # belong to a logged-out session; trusting it would replay the same
    # wedged map (the livelock of review follow-up #7), and stage-4 size
    # verification cannot catch a dead-but-intact map. Require at least
    # one active path before returning, else fall through into the
    # rounds and rebuild/repair in place.
    if ( -b $mpath ) {
        return $mpath if !$verify_map;
        return $mpath if _multipath_map_has_active_path( $ctx, $scsiid );
        debugmsg( $ctx, 'warn',
            "Existing map for ${scsiid} has no active path — rebuilding" );
    }

    # Whitelist the WWID FIRST: it needs no device present, and multipathd
    # reacts to udev events on its own — so the VPD wait below overlaps with
    # the daemon already claiming paths as they appear instead of being dead
    # time (current code runs its `multipath -a` before the wait for the same
    # reason). The CLI form is fine under multipath_cmd's TERM-first bound
    # (decided — supersedes the earlier `multipathd add wwid` swap, which
    # stays recorded as optional hardening).
    multipath_cmd( $ctx, [ $MULTIPATH, '-a', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT );

    # Phase 1 — wait for the SCSI VPD symlink (multipathd cannot associate
    # paths with the WWID before the inquiry completes; under load the inquiry
    # queue backs up 30+ s). In the ACTIVATION flow this is a no-op guard:
    # volume_stage_iscsi's exit condition is this very symlink — it waits up
    # to 240 s for it, rescanning, or dies (Common.pm:2196) — so the first -e
    # here succeeds with zero sleeps. The wait only ever waits for the direct
    # callers that stage multipath without a fresh iSCSI stage
    # (block_device_path_from_lun_rec, lun_record_update_device).
    my $scsi_by_id = block_device_path_from_serial( $scsiid, 0 );  # by-id path device
    for my $tick ( 1 .. MULTIPATH_VPD_WAIT_ATTEMPTS ) {
        last if -e $scsi_by_id;
        debugmsg( $ctx, 'debug', "Waiting for SCSI device ${scsi_by_id} (${tick})" )
            if $tick == 1 || $tick % 10 == 0;
        sleep(MULTIPATH_VPD_WAIT_SLEEP);
    }
    debugmsg( $ctx, 'warn',
        "SCSI device ${scsi_by_id} not found, attempting staging anyway" )
        if !-e $scsi_by_id;

    # Resolve iSCSI by-path symlinks to sd names ONCE — reused every round.
    my $sd_devnames = [];
    if ( $block_devs && ref($block_devs) eq 'ARRAY' ) {
        for my $bp (@$block_devs) {
            my $real = Cwd::abs_path($bp);
            push @$sd_devnames, $1 if $real && $real =~ m{^/dev/(sd[a-z]+)$};
        }
    }

    # Phase 2 — bounded staging rounds; sleeps out here, never under the lock.
    # ACCEPTANCE runs at the TOP of each iteration — after the previous
    # round's sleep, so multipathd's path checker has had its window
    # before a fresh map is judged — and, with the settle check below, is
    # the rounds' only gate (finding #12): a map is returned only with at
    # least one active path; the round's return value is advisory (its -b
    # short-circuits only stop escalation within the round).
    # $last: the final round of a REAL ladder fires EVERY escalation
    # whatever its modulo gate — the last chance must not depend on the
    # attempts count's divisibility. An attempts bound of 1 requests one
    # GENTLE repair round instead (the verify loop's embedded re-stage —
    # finding #16), so the blast is suppressed: $attempts > 1.
    for my $attempt ( 1 .. $attempts ) {
        return $mpath
            if -b $mpath && _multipath_map_has_active_path( $ctx, $scsiid );
        my $last = $attempt == $attempts && $attempts > 1;
        _volume_stage_multipath( $ctx, $scsiid, $sd_devnames,
                                 $attempt, $last );
        sleep(MULTIPATH_STAGE_SLEEP);    # after the final round this is the
                                         # settle window for its async
                                         # escalations — see the check below
    }

    # The final round fired trigger/reconfigure-class escalations whose effect
    # lands asynchronously — look once more after the settle sleep instead of
    # dying on their heels; same acceptance predicate, never a bare -b.
    return $mpath
        if -b $mpath && _multipath_map_has_active_path( $ctx, $scsiid );

    die "Unable to stage multipath device for scsiid ${scsiid} "
      . "after ${attempts} attempts\n";
}

# One staging round — no loops, no sleeps (the caller owns both), NO
# acceptance: the driver's loop-top predicate is the only judge of success
# (finding #12 — an entry -b return here once re-trusted the very zombie
# map the driver's fast path had just rejected, before any repair command
# ran). The -b short-circuits below only stop further escalation inside
# the round; the returned path is advisory. The modulo escalation schedule
# is preserved from the current 60-round loop MINUS its %15 del-map
# recovery — the reactivation cycle's teardown supersedes it (decided) —
# and the round count shrinks instead (MULTIPATH_STAGE_ATTEMPTS), because
# the cycle now supplies the deep retries a broken stack actually needs.
# On the final round of a real ladder ($last) every escalation fires
# regardless of its modulo gate. NOTE a deliberate consequence of the -b
# short-circuits: when the node PRE-EXISTS (a rejected zombie), every round
# returns right after add path / -a / add map — the escalations never
# fire. By design: the escalation ladder exists to MATERIALIZE a missing
# node; attaching paths to an existing map is exactly the add path /
# add map pair, and a daemon too wedged for those fails the attempt into
# the cycle's teardown, which removes the node — re-opening the full
# ladder for the next cycle's rebuild.
sub _volume_stage_multipath {
    my ( $ctx, $scsiid, $sd_devnames, $attempt, $last ) = @_;

    my $mpath = clean_word( block_device_path_from_serial( $scsiid, 1 ) );

    # Register the resolved sd paths with multipathd FIRST — under load udev
    # events lag and map creation fails unless the daemon is told its paths
    # explicitly. KEPT from current code for the same reason as the VPD wait.
    multipath_cmd( $ctx, [ $MULTIPATHD, 'add', 'path', $_ ],
                   MULTIPATH_CMD_TIMEOUT_MAX ) for @$sd_devnames;

    # Re-assert the whitelist (the driver did it once before its VPD wait) —
    # the belt-and-braces the current in-loop '-a' provides. The CLI form is
    # acceptable under multipath_cmd's TERM-first bound (decided); migrating
    # to `multipathd add wwid` stays recorded as optional hardening.
    multipath_cmd( $ctx, [ $MULTIPATH, '-a', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT );
    multipath_cmd( $ctx, [ $MULTIPATHD, 'add', 'map', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT_MAX );
    return $mpath if -b $mpath;

    # Escalations, cheapest first:
    if ( $last || $attempt == 1 || $attempt % 5 == 0 ) {   # heavier per-WWID scan
        multipath_cmd( $ctx, [ $MULTIPATH, $scsiid ], MULTIPATH_CMD_TIMEOUT_MAX );
        return $mpath if -b $mpath;
    }

    if ( $last || $attempt % 4 == 0 ) {              # udev event replay
        if (@$sd_devnames) {                         # targeted — never broad
            multipath_cmd( $ctx, [ 'udevadm', 'trigger', "/sys/block/$_" ],
                           MULTIPATH_CMD_TIMEOUT_MAX ) for @$sd_devnames;
        } else {
            multipath_cmd( $ctx, [ 'udevadm', 'trigger',
                                   '--subsystem-match=block',
                                   "--property-match=ID_SERIAL=${scsiid}" ],
                           MULTIPATH_CMD_TIMEOUT );
        }
        return $mpath if -b $mpath;
    }

    if ( $last || $attempt % 10 == 0 ) {             # daemon-wide re-read
        multipath_cmd( $ctx, [ $MULTIPATHD, 'reconfigure' ],
                       MULTIPATH_CMD_TIMEOUT_MAX );
        return $mpath if -b $mpath;
    }

    return -b $mpath ? $mpath : undef;
}
```

The acceptance probe, in full — its failure mode is chosen so that *no
evidence* never means *trust*:

```perl
# The exit contract's acceptance probe (finding #12): ONE locked
# `multipath -ll <wwid>` read; true when at least one PATH row reports the
# dm state `active` — a path the kernel will route IO to. Path-GROUP rows
# (`status=active`) are ignored: a group can be the serving group while
# every path inside it has failed. Command failure, timeout or empty
# output all return 0 — no evidence reads as "no active path", failing
# toward the rebuild rounds and, ultimately, the cycle's teardown (never
# toward trusting a zombie). A fresh map whose paths the checker has not
# visited yet can legitimately return 0 for a round or two — the driver
# probes at the loop top, after each inter-round sleep, precisely to
# absorb that window (a round's cost, never a cycle's). TWO-STAGE, and the
# second stage is NOT optional (finding #21, live-diagnosed 2026-07-03):
# `multipath -ll <wwid>` was observed returning exit 0 with EMPTY output
# for a live, healthy, seconds-old map under activation load (it queries
# multipathd over its socket; while the daemon reconfigures it answers
# empty) — which made the single-stage probe reject healthy maps and fail
# activation through all four cycles (the vm-202 field failure). So on an
# empty `-ll` WITH the dm node present, the probe falls back to
# `dmsetup status <wwid>` — near-kernel-ABI, no daemon socket, one A/F
# flag per path — and treats an A as an active path. Silence from a busy
# daemon is never read as death when device-mapper itself still has the
# map. Genuine absence (no dm node) still fails, so a real zombie is still
# rejected. Both `-ll` PATH-row parse and the dmsetup A-flag parse were
# validated against live PVE 9.1 fixtures.
sub _multipath_map_has_active_path {
    my ( $ctx, $scsiid ) = @_;

    my $cmd    = [ $MULTIPATH, '-ll', $scsiid ];
    my $active = 0;
    my $lines  = 0;
    my $res    = multipath_cmd( $ctx, $cmd, MULTIPATH_CMD_TIMEOUT, sub {
        my ($line) = @_;
        $lines++;
        cmd_log_output( $ctx, 'debug', $cmd, $line );
        # PATH rows carry an H:C:T:L tuple then devnode and major:minor
        # ("7:0:0:0 sdb 8:16 active ready running"); require the dm state
        # column to say `active`, and disqualify a row whose checker
        # already says `faulty` (checker verdicts lag dm state).
        $active = 1
            if $line =~ /\b\d+:\d+:\d+:\d+\s+\S+\s+\d+:\d+\s+active\b/
            && $line !~ /\bfaulty\b/;
    } );

    # A trace on every call — an empty -ll logs no output lines at all, so
    # without this a failing probe is invisible in the debug log (exactly
    # what hid finding #21 at first).
    debugmsg( $ctx, 'debug',
        "Map active-path probe for ${scsiid}: exitcode "
      . ( $res->{exitcode} // 'undef' )
      . ", lines ${lines}, active ${active}" );

    return 1 if $active
        && defined( $res->{exitcode} ) && $res->{exitcode} == 0;

    # Fallback (finding #21): -ll came back empty but the dm node exists —
    # ask device-mapper directly. A multipath status line carries one A
    # (active) / F (failed) flag per path:
    # "0 8192 multipath 2 0 0 0 1 1 A 0 2 0 8:208 A 0 65:0 A 0".
    if ( $lines == 0 && -b block_device_path_from_serial( $scsiid, 1 ) ) {
        my $dmactive = 0;
        my $dcmd = [ $DMSETUP, 'status', $scsiid ];
        my $dres = multipath_cmd( $ctx, $dcmd, MULTIPATH_CMD_TIMEOUT, sub {
            my ($line) = @_;
            cmd_log_output( $ctx, 'debug', $dcmd, $line );
            $dmactive = 1
                if $line =~ /\bmultipath\b/ && $line =~ /\d+:\d+\s+A\b/;
        } );
        debugmsg( $ctx, 'debug',
            "Map active-path dmsetup fallback for ${scsiid}: exitcode "
          . ( $dres->{exitcode} // 'undef' ) . ", active ${dmactive}" );
        return 1 if $dmactive
            && defined( $dres->{exitcode} ) && $dres->{exitcode} == 0;
    }

    return 0;
}
```

### Unstaging under the lock
[Unstaging_under_the_lock](#unstaging-under-the-lock)

The unstage entry gains the two phase bounds as trailing optional parameters —
`Common.pm:3730` already calls it in this four-argument shape (today's two-argument
signature silently ignores the extras); that call site drops its literals for the
defaults:

```perl
sub volume_unstage_multipath {
    my ( $ctx, $scsiid, $attempts_wait_unused, $attempts_remove_device ) = @_;

    # No writes or sync before unmounting, and no unmounting of the volume —
    # unexpected writes during an active migration are a data-corruption
    # hazard (comment preserved from current code).

    $scsiid = OpenEJovianDSS::Common::safe_word( clean_word($scsiid),
                                                 'multipath scsi id' );
    $attempts_wait_unused   //= MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS;
    $attempts_remove_device //= MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS;

    debugmsg( $ctx, 'debug', "Volume unstage multipath scsiid ${scsiid}" );

    # Phase 1 — wait for the device to fall unused (Proxmox may deactivate
    # before qemu is gone; racing that is the corruption hazard above). One
    # tick per call — the loop and the sleep live here, mirroring the staging
    # split; no post-loop recheck is needed (we proceed either way), so the
    # sleep is skipped on the last tick.
    my $device_ready = 0;
    for my $tick ( 1 .. $attempts_wait_unused ) {
        $device_ready =
            _volume_unstage_multipath_wait_unused( $ctx, $scsiid, $tick );
        last if $device_ready;
        sleep(MULTIPATH_UNSTAGE_WAIT_UNUSED_SLEEP)
            if $tick < $attempts_wait_unused;
    }
    debugmsg( $ctx, 'warn',
        "Device ${scsiid} may still be in use, proceeding with cleanup" )
        unless $device_ready;

    # Phase 2 — removal rounds. One round per call; the round's own tail
    # (blocker grace) is the inter-round pacing, so no sleep here.
    my $removed = 0;
    for my $round ( 1 .. $attempts_remove_device ) {
        $removed = _volume_unstage_multipath_remove_device( $ctx, $scsiid,
                                                            $round );
        last if $removed;
    }

    # Final fallback — AFTER the rounds, never inside one: deferred removal
    # marks the device to disappear when its last opener closes it. A device
    # that vanished on its own between the last round and this probe counts
    # as removed (today's code reads that as failure — fixed).
    if ( !$removed ) {
        if ( _dmsetup_device_exists( $ctx, $scsiid ) ) {
            debugmsg( $ctx, 'info',
                "Using deferred dmsetup removal for ${scsiid}" );
            my $res = multipath_cmd( $ctx,
                [ $DMSETUP, 'remove', '--deferred', $scsiid ],
                MULTIPATH_CMD_TIMEOUT_MAX );
            die "Failed to remove multipath device for SCSI ID ${scsiid}: "
              . "${attempts_remove_device} rounds exhausted and deferred "
              . "removal failed\n"
                if !defined( $res->{exitcode} ) || $res->{exitcode} != 0;
        }
        # else: gone on its own — success
    }

    return;
}
```

`_volume_unstage_multipath_wait_unused($ctx, $scsiid, $tick)` becomes **one
tick** — no loops, no sleeps, the caller above owns both (the draft's duplicated
public/private pair collapses into this). Its return value is the decision:

```perl
# ONE wait-unused tick — returns 1 when the mapper device is free or gone
# (stop waiting, removal may proceed), 0 while a process still holds it (wait
# another tick). No outer catch-all eval: a `multipath` lock failure inside
# get_device_mapper_name propagates by design — in the reactivation
# teardown the per-step best-effort wrapper warns and moves on (fatal lock
# errors rethrow through it); in a standalone deactivation it fails the
# operation loud (finding #15).
sub _volume_unstage_multipath_wait_unused {
    my ( $ctx, $scsiid, $tick ) = @_;

    my $mapper_name = get_device_mapper_name( $ctx, $scsiid );   # locked probe
    return 1 if !defined $mapper_name;        # no map — nothing to wait on

    if ( $mapper_name !~ /^([\:\-\@\w.\/]+)$/ ) {
        debugmsg( $ctx, 'debug',
            "Multipath device mapper name is incorrect: ${mapper_name}" );
        return 1;                             # unusable name — proceed
    }
    my $mapper_path = "/dev/mapper/$1";       # mapper-NAME path — the one place
                                              # the serial helper cannot build
    return 1 if !-b $mapper_path;             # node gone — nothing to wait on
                                              # (today's loop kept waiting here)

    # lsof/ps are read-only process queries — deliberately NOT under the lock.
    # lsof -t exits non-zero when NOBODY holds the device — the success case —
    # so noerr is required; an empty pid list means "free".
    my $pid;
    my $cmd = [ 'lsof', '-t', $mapper_path ];
    eval {
        run_command( $cmd,
            outfunc => sub { $pid = clean_word(shift); },  # last line wins —
                                                           # diagnostics only
            errfunc => sub { cmd_log_output( $ctx, 'error', $cmd, shift ) },
            noerr   => 1,
        );
    };
    if ($@) {
        debugmsg( $ctx, 'warn',
            "Unable to identify mapper user for ${mapper_path}: $@" );
        return 1;                             # cannot tell — proceed (as today)
    }
    return 1 if !$pid;                        # free

    # Still held — name the blocker for diagnostics, gated so a long wait
    # does not emit one warning per tick.
    if ( ( $tick == 1 || $tick % 10 == 0 ) && $pid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $blocker_name;
        my $pscmd = [ 'ps', '-o', 'comm=', '-p', $1 ];
        eval {
            run_command( $pscmd,
                outfunc => sub { $blocker_name = clean_word(shift); },
                errfunc => sub { cmd_log_output( $ctx, 'error', $pscmd, shift ) },
                noerr   => 1,
            );
        };
        $blocker_name //= 'unknown';
        my $warningmsg = "Multipath device with scsi id ${scsiid} "
                       . "is used by ${blocker_name} with pid ${pid}";
        debugmsg( $ctx, 'warn', $warningmsg );
        warn "${warningmsg}\n";
    }

    return 0;                                 # still in use — wait another tick
}
```

Contract deltas from today's loop, all deliberate: a missing device node now
means *done* instead of waiting the full bound (today's loop keeps polling a
node that no longer exists); the clean "nobody holds it" case no longer travels
through `lsof`'s error branch (`noerr` + empty-pid instead of dying on lsof's
non-zero "no users" exit); and the blocker warning is tick-gated instead of
firing every second. On exhaustion the caller proceeds to removal with a
warning — semantics unchanged.

`_volume_unstage_multipath_remove_device($ctx, $scsiid, $round)` becomes **one
removal round** (the caller above owns the loop), preserving today's escalation
sequence. The draft's `#TODO: review this section` on the del-map-before-flush
order resolves to *keep*: that order is what current production code runs. The
deferred-removal fallback deliberately does **not** live here — inside a round
it would fire on the first failure and report success with the map still
present, skipping every retry:

```perl
# ONE removal round — returns 1 when map and dm device are gone, 0 when
# something still holds them (the caller retries; the deferred fallback runs
# in the caller AFTER the rounds). $scsiid arrives sanitized by the caller.
# The round tail's blocker grace doubles as the inter-round pacing — the
# caller's loop adds no sleep (the documented exception to sleeps-in-caller).
sub _volume_unstage_multipath_remove_device {
    my ( $ctx, $scsiid, $round ) = @_;

    debugmsg( $ctx, 'debug',
        "Multipath removal round ${round} for SCSI ID ${scsiid}" );

    # Step 1 — un-whitelist the WWID.
    multipath_cmd( $ctx, [ $MULTIPATH, '-w', $scsiid ] );

    # Step 2 — drop the map: daemon first, then flush (-f, never a bare
    # rescan, which would recreate the device), then daemon again if the map
    # survived. Order preserved from current code.
    multipath_cmd( $ctx, [ $MULTIPATHD, 'del', 'map', $scsiid ],
                   MULTIPATHD_CMD_TIMEOUT_FAST ) if $MULTIPATHD;
    multipath_cmd( $ctx, [ $MULTIPATH, '-f', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT_MAX );
    multipath_cmd( $ctx, [ $MULTIPATHD, 'del', 'map', $scsiid ],
                   MULTIPATHD_CMD_TIMEOUT_FAST )
        if $MULTIPATHD && _multipathd_map_exists( $ctx, $scsiid );

    # Step 3 — the flush can leave an orphaned dm device; probe with dmsetup
    # (multipath -ll only sees the multipath map) and remove it directly.
    return 1 if !_dmsetup_device_exists( $ctx, $scsiid );

    multipath_cmd( $ctx, [ $DMSETUP, 'remove', '-f', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT_MAX );

    sleep(MULTIPATH_UNSTAGE_REMOVE_SETTLE);       # let the removal land
    return 1 if !_dmsetup_device_exists( $ctx, $scsiid );

    # Still held — bounded grace for the blocker before the next round.
    my $mapper_name = get_device_mapper_name( $ctx, $scsiid ) // $scsiid;
    my $blocker_pid =
        _volume_unstage_multipath_get_blocker( $ctx, $scsiid, $mapper_name );
    if ($blocker_pid) {
        debugmsg( $ctx, 'debug',
            "Waiting for blocker pid ${blocker_pid} (round ${round})" );
        for ( 1 .. MULTIPATH_UNSTAGE_BLOCKER_WAIT ) {    # 1 s ticks
            last unless -d "/proc/${blocker_pid}";
            sleep(1);
        }
    } else {
        sleep(MULTIPATH_UNSTAGE_REMOVE_SLEEP);
    }

    debugmsg( $ctx, 'debug',
        "Multipath mapping for ${scsiid} still present after round ${round}" );
    return 0;
}
```

Contract deltas from today, all deliberate: the deferred fallback runs once,
after the rounds, and its exit code now backs the caller's die (today it was
assumed successful, and the die was reachable only through the vanished-device
misread); a device gone by the fallback probe counts as removed; the per-round
re-validation of `$scsiid` is dropped (the caller's `safe_word` already dies on
bad input — a soft `return 0` here would burn every round on garbage).

### The reactivation cycle
[The_reactivation_cycle](#the-reactivation-cycle)

`volume_activate` keeps its public signature and becomes a bounded loop over an
extracted single attempt, with a **teardown** between attempts (the pass before
the final cycle additionally detaches the target — Open Question #1):

```perl
sub volume_activate {
    my ( $ctx, $vmid, $volname, $snapname, $content_volume_flag ) = @_;

    # ... $tgname resolution exactly as today ...

    my $last_err;
    delete $ctx->{_multipath_cmd_ladder_exhausted};   # isolate from earlier
                                                      # operations on this $ctx —
                                                      # ONCE, not per cycle: a
                                                      # signature set inside a
                                                      # teardown or sweep must
                                                      # survive into the next
                                                      # attempt's gate
                                                      # (finding #14)
    for my $cycle ( 1 .. VOLUME_ACTIVATE_CYCLE_ATTEMPTS ) {
        my $state = {};    # reached stages + target coordinates — the teardown reads it
        my $block_devs = eval {
            _volume_activate_attempt( $ctx, $vmid, $volname, $snapname,
                                      $content_volume_flag, $tgname, $state,
                                      $cycle );
        };
        return $block_devs if !$@ && defined($block_devs);

        $last_err = $@ || "activation produced no block devices\n";
        debugmsg( $ctx, 'warn',
            "Activation cycle ${cycle} of volume ${volname} "
          . safe_var_print( 'snapshot', $snapname )
          . " failed: ${last_err}" );

        # ERROR CLASSIFICATION — before any recovery machinery runs.
        #
        # (1) FATAL: a marked lock-machinery die (hold-cap overrun, hold
        # alarm) means the locks protecting this operation can no longer be
        # trusted; retrying — or even running the teardown, whose steps
        # touch shared state up to and including the target detach — would
        # race whoever may have stale-reclaimed them. Rethrow: die → unwind
        # → every held lock released (the lock design's contract). The
        # stack residue is deliberate — nothing touches shared state
        # without valid locks; the next activation rebuilds or fast-paths
        # over whatever is left.
        die $last_err
            if OpenEJovianDSS::Lock::lock_error_fatal($last_err);

        # (2) CONTENTION: an acquire timeout reports a lock that was NEVER
        # OBTAINED — nothing was modified under it, every held lock is
        # still valid, and nothing says the device stack is broken.
        # Teardown buys nothing: skip the sweep and the teardown, and
        # re-attempt over whatever the attempt left behind
        # (publish/login/staging all fast-path or re-run idempotently).
        # On the pre-final-cycle pass this also skips the recovery detach —
        # deliberate: contention is not the backend wedge the detach
        # exists to reset.
        if ( !OpenEJovianDSS::Lock::lock_error_acquire($last_err) ) {

            # (3) DEVICE/STAGING FAILURE — repair, tear down, rebuild.

            # Stale-cookie sweep BEFORE the teardown — and only when the
            # strand signature is armed: set by this attempt, or re-armed
            # by the previous teardown's/sweep's own hung command
            # (finding #14; exit 124/137: survived the whole termination
            # ladder; recorded on $ctx by multipath_cmd — see Stale-cookie
            # recovery). If a stranded cookie broke the attempt, the
            # teardown's dm commands would hang on it too. Best-effort —
            # must not mask $last_err — except a fatal lock error, which
            # rethrows.
            if ( delete $ctx->{_multipath_cmd_ladder_exhausted} ) {
                eval { _multipath_cookie_sweep($ctx) };
                if ($@) {
                    die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
                    debugmsg( $ctx, 'warn', "Stale-cookie sweep failed: $@" );
                }
            }

            # Teardown so the next cycle rebuilds the stack from a clean
            # slate. ONE pass (finding #15): its steps are individually
            # best-effort, so short of a fatal lock error — which
            # rethrows — a pass cannot fail; convergence across step
            # failures is supplied by the CYCLES themselves, whose every
            # later failure runs this teardown again over the residue (an
            # inner pass-retry loop was unreachable machinery). The pass
            # BEFORE THE FINAL CYCLE — and only that one — adds the target
            # detach (volume_unpublish): a one-shot recovery for backend
            # state a logout-level teardown cannot reset, gated on session
            # evidence — skipped while JovianDSS shows a foreign initiator
            # on the target (Open Question #1).
            eval {
                _volume_deactivate_attempt( $ctx, $vmid, $volname,
                                            $snapname, $tgname, $state,
                                            $cycle );
            };
            if ($@) {
                # Defensive: reachable by a fatal lock error (which must
                # rethrow) or a future unwrapped step.
                die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
                debugmsg( $ctx, 'warn',
                    "Teardown after failed activation cycle ${cycle} "
                  . "failed: $@" );
            }
        }

        # Pre-cycle budget check: starting another cycle with less than a
        # typical cycle's budget left on the method lock's hold deadline
        # only moves the hold-cap die into the middle of the next attempt —
        # fail NOW, with the real error, while this cycle's teardown has
        # already run (review follow-up #11.3).
        if ( $cycle < VOLUME_ACTIVATE_CYCLE_ATTEMPTS ) {
            my $remaining =
                OpenEJovianDSS::Lock::lock_deadline_remaining($ctx);
            die $last_err
                if defined($remaining)
                && $remaining < VOLUME_ACTIVATE_CYCLE_MIN_BUDGET;
            sleep(VOLUME_ACTIVATE_CYCLE_SLEEP);
        }
    }

    die "Activation of volume ${volname} "
      . safe_var_print( 'snapshot', $snapname )
      . " failed after " . VOLUME_ACTIVATE_CYCLE_ATTEMPTS
      . " cycles: ${last_err}";
}
```

`_volume_activate_attempt` is today's `eval` body (`Common.pm:3784–3848`),
extracted — publish, stage iSCSI, stage multipath, **verify**, create/refresh
the LUN record — recording in `$state` everything the teardown needs: the
reached-stage flags (`published`, `iscsi_staged`, `multipath_staged`,
`record_created`), the target coordinates learned along the way
(`targetname`, `lunid`, `hosts`, `scsiid` — today these live in
`volume_activate`'s lexicals, which the extracted teardown can no longer see),
**and** `content_volume_flag` — `volume_unpublish` derives the target group
from it (`Common.pm:3287`), so a teardown without it would unpublish a
content volume against the wrong (VM) target group (review follow-up #5;
today's error path at `Common.pm:3881` has the same latent bug — passing
`undef` — and is fixed alongside). It also receives the cycle counter —
kept for signature symmetry since finding #12 made the staging's map
verification unconditional: the activation flow never trusts a bare `-b`
on an existing map, in any cycle
([Staging under the lock](#staging-under-the-lock), review follow-ups
#7, #12):

```perl
# ONE activation attempt — today's volume_activate eval body. The reached-stage
# flags are set BEFORE each action, as today: if a step dies midway, its
# inverse still runs in the teardown. Returns the block-device list (fixed
# shape); dies on any failure.
sub _volume_activate_attempt {
    # $vmid and $cycle are unused in this body — kept for signature symmetry
    # with _volume_deactivate_attempt, which needs them (volume_unpublish;
    # the detach rung's cycle gate). $cycle stopped driving $verify_map when
    # finding #12 made map verification unconditional in the activation flow.
    my ( $ctx, $vmid, $volname, $snapname, $content_volume_flag,
         $tgname, $state, $cycle ) = @_;

    my $multipath = get_multipath($ctx);
    my $shared    = get_shared($ctx);

    # Recorded for the teardown: volume_unpublish derives the target group
    # from the flag — without it a content volume would be unpublished
    # against the VM target group.
    $state->{content_volume_flag} = $content_volume_flag;

    # Stage 1 — attach the volume to its target (jdssc).
    $state->{published} = 1;
    my $tinfo = volume_publish( $ctx, $tgname, $volname, $snapname,
                                $content_volume_flag );
    die "Publishing volume ${volname} "
      . safe_var_print( 'snapshot', $snapname )
      . " failed to provide target info\n"
        if !$tinfo;

    # Target coordinates — recorded for the teardown's inverse steps.
    $state->{targetname} = $tinfo->{target};
    $state->{lunid}      = $tinfo->{lunid};
    $state->{hosts}      = $tinfo->{iplist};
    $state->{scsiid}     = $tinfo->{scsiid};

    # Checked BEFORE the login (today it is checked after — a missing scsi id
    # wasted a full iSCSI stage before failing).
    die "Unable to identify scsi id for ${volname}"
      . safe_var_print( 'snapshot', $snapname ) . "\n"
        if !defined $state->{scsiid};

    # No exact-size gate on activation (F-04 amendment, 2026-07-05): the
    # exit contract requires a non-zero staged capacity only — undef =>
    # _iscsi_capacity_ok checks non-zero, which is the finding-#23 tell.
    my $size = undef;

    # Stage 2 — iSCSI login + capacity verification; exits only with the
    # device present, udev done, AND reporting the correct non-zero size
    # (option A / finding #23 — a wrong/zero capacity is SCST's under-load
    # export failure, caught here at the raw-LUN layer).
    $state->{iscsi_staged} = 1;
    my $block_devs = volume_stage_iscsi( $ctx, $state->{targetname},
                                         $state->{lunid}, $state->{hosts},
                                         $state->{scsiid}, $size );
    die "Unable to connect to any storage address\n"
        if !( $block_devs && @$block_devs );

    # Stage 3 — multipath map (when enabled). $verify_map is TRUE on
    # EVERY cycle (finding #12): a leftover map from an EARLIER failed
    # operation passes a bare -b in cycle 1 just as a torn-down attempt's
    # map does in cycle 2. NO size check — the map's size derives from the
    # sd, which Stage 2 verified (option A: no dm-layer reconcile, no churn).
    if ($multipath) {
        $state->{multipath_staged} = 1;
        my $mpath = volume_stage_multipath( $ctx, $state->{scsiid},
                                            $block_devs, undef, 1 );
        $block_devs = [ clean_word($mpath) ];
    }

    # Stage 4 — persist the LUN record. Verification is complete (Stage 2 =
    # size at the raw LUN, Stage 3 = live map); the strict post-staging
    # verify loop is retired from activation (option A). lun_record_local_create
    # stores the authoritative $size, so the record is correct by
    # construction — no lun_record_update_device recheck.
    $state->{record_created} = 1;
    lun_record_local_create( $ctx,
        $state->{targetname}, $state->{lunid}, $volname, $snapname,
        $state->{scsiid}, $size, $multipath, $shared,
        @{ $state->{hosts} } );

    return $block_devs;
}
```

One delta from today, deliberate: the scsi-id presence check moves **before**
the iSCSI stage (today it sits after — `Common.pm:3817` — so a publish that
yielded no id still paid a full login before dying).

`_volume_deactivate_attempt` — named for symmetry with
`_volume_activate_attempt` — is today's error-path cleanup promoted to a named
function and **completed**: it inverts every reached stage, in deactivation
order, each step best-effort (`eval` + warn) so one failed step never blocks the
rest — with one exception: a step whose error is a **fatal lock-machinery
error** (`lock_error_fatal`) rethrows instead of warning, because a step must
not continue past evidence that its locks no longer protect it (see
[Fatal errors](#the-reactivation-cycle) below). It reads the stage flags and
target coordinates from `$state`. It also
receives the cycle counter: the detach rung fires only when
`$cycle == VOLUME_ACTIVATE_CYCLE_ATTEMPTS - 1` — the teardown before the final
attempt — and even then only with the target coordinates recorded
(finding #19) and after `_target_foreign_sessions` reports the
target free of foreign initiators (Open Question #1):

**Table 2 — Reactivation cycle: stages and their teardown** · `tbl_activation_cycle`

| # | Attempt stage | Teardown step (deactivation order) |
|---|---|---|
| 1 | `volume_publish` — attach volume to its target (jdssc) | 3 — `volume_unpublish` — **detach volume from the target** (jdssc `targets delete -v <volname>`); **for every volume, not only snapshots**, but **only in the teardown before the final cycle**, **only with the target coordinates recorded** (finding #19) and **only when `_target_foreign_sessions` shows no foreign initiator** on the target (one-shot, session-gated recovery — see Open Question #1); every other pass keeps today's snapshot-only unpublish |
| 2 | `volume_stage_iscsi` — login, collect block paths | 1 — `volume_unstage_iscsi_device` — logout **first**, so multipath removal cannot resurrect the device (the ordering rule from `Common.pm:3699`) |
| 3 | `volume_stage_multipath` — build the dm map | 2 — `volume_unstage_multipath` — wait-unused + remove, bounded by the unstage constants |
| 4 | `lun_record_local_create` — persist the record (device already verified: size in Stage 2 via `volume_stage_iscsi`, live map in Stage 3; the strict `lun_record_update_device` verify loop is retired from activation — option A / finding #23) | 4 — `lun_record_local_delete` — **last**, as today: it checks the target's remaining volumes and performs the residual iSCSI logout when none are left (the "last step" rule, `Common.pm:3892`) |

```perl
# The complete inverse of one activation attempt (Table 2). Each step is
# best-effort (eval + warn) so one failed step never blocks the rest —
# EXCEPT a fatal lock error, which rethrows (lock_error_fatal: a step must
# not continue past evidence that its locks no longer protect it). Reads
# the reached-stage flags and target coordinates from $state; $cycle gates
# the recovery detach.
sub _volume_deactivate_attempt {
    my ( $ctx, $vmid, $volname, $snapname, $tgname, $state, $cycle ) = @_;

    # Best-effort step wrapper with the fatal-error exception.
    my $step = sub {
        my ($code) = @_;
        eval { $code->() };
        if ($@) {
            die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
            debugmsg( $ctx, 'warn', "Deactivation step failed: $@" );
        }
    };

    # 1 — iSCSI logout FIRST, so multipath removal cannot resurrect the
    # device (the ordering rule from Common.pm:3699).
    $step->( sub {
        volume_unstage_iscsi_device( $ctx, $state->{targetname},
                                     $state->{lunid}, $state->{hosts} );
    } ) if $state->{iscsi_staged};

    # 2 — multipath unstage (wait-unused ticks + removal rounds, the
    # unstage constants' defaults — today's effective bounds, finding #17).
    $step->( sub { volume_unstage_multipath( $ctx, $state->{scsiid} ) } )
        if $state->{multipath_staged} && defined $state->{scsiid};

    # 3 — unpublish. Snapshots keep today's cleanup in EVERY pass (that is
    # current behavior, not the recovery detach). For volumes, this is the
    # RECOVERY DETACH — the review's finding #1 resolution — behind two
    # gates, neither of them temporal:
    #   (a) CYCLE POSITION: only the teardown BEFORE THE FINAL CYCLE.
    #       Counter-keyed and structural — a fast post-login failure
    #       cannot skip it, which is the defect that sank the superseded
    #       session_up/staging-window gate.
    #   (b) SESSION EVIDENCE: JovianDSS must show no foreign initiator on
    #       the target; a failed query counts as foreign — no evidence,
    #       no detach.
    if ( defined $snapname ) {
        $step->( sub {
            volume_unpublish( $ctx, $vmid, $volname, $snapname,
                              $state->{content_volume_flag} );
        } ) if $state->{published};
    }
    elsif ( $state->{published}
         && defined $state->{targetname}   # publish may have died before
                                           # returning coordinates — nothing
                                           # to probe or detach (finding #19)
         && $cycle == VOLUME_ACTIVATE_CYCLE_ATTEMPTS - 1 )
    {
        my $foreign = eval {
            _target_foreign_sessions( $ctx, $state->{targetname} );
        };
        if ($@) {
            die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
            debugmsg( $ctx, 'warn',
                "Session query for $state->{targetname} failed - "
              . "skipping recovery detach (no evidence, no detach): $@" );
        }
        elsif (@$foreign) {
            my $warningmsg =
                "Skipping recovery detach of volume ${volname}: target "
              . "$state->{targetname} has foreign session(s) from "
              . join( ',', @$foreign );
            debugmsg( $ctx, 'warn', $warningmsg );
            warn "${warningmsg}\n";
        }
        else {
            $step->( sub {
                volume_unpublish( $ctx, $vmid, $volname, $snapname,
                                  $state->{content_volume_flag} );
            } );
        }
    }

    # 4 — LUN record delete LAST, as today: it checks the target's
    # remaining volumes and performs the residual iSCSI logout when none
    # are left (the "last step" rule, Common.pm:3892).
    $step->( sub {
        lun_record_local_delete( $ctx, $state->{targetname},
                                 $state->{lunid}, $volname, $snapname );
    } ) if defined $state->{targetname} && defined $state->{lunid};

    return;
}
```

The teardown runs **once per failed cycle** (finding #15 — superseding the
earlier `VOLUME_DEACTIVATE_ATTEMPTS` pass-retry loop, which was unreachable
machinery: with every step best-effort and fatal errors rethrown, no error
class remained that could fail a pass into a retry). Convergence across
step failures comes from the cycles themselves — every later cycle's
failure runs the teardown again over the residue — and from the next
attempt re-running publish/login/staging against whatever is left, failing
loud itself if the residue blocks it (the staging exit contract rebuilds
or rejects leftover maps by construction). Considered and rejected: making
pass failure observable to re-enable the retry loop — redundant with
cycle-level convergence, and it re-opens the budget hazard of repeating
the pre-final pass's session probe.

**Fatal errors are rethrown, never retried (added 2026-07-03 after review).**
The cycle's `eval`s would otherwise swallow the one error class that must
terminate the operation: the lock design enforces its hold caps by a `die`
inside `refresh_locks` (fired from `run_refreshed` around every locked body —
i.e. inside every `multipath_cmd` and `joviandss_cmd`) and by `run_bounded`'s
hold alarm, and its whole contract is *die → unwind → every held lock
released*. Caught by the attempt `eval` and treated as an ordinary attempt
failure, that die would instead start the teardown — whose every locked
command hits the same deadline die, each swallowed by the per-step best-effort
`eval`s — then the next
cycle, with the `vm` lock held far past its cap. (`run_bounded`'s alarm is
worse: it fires once, and once swallowed is never re-armed.) And for a
cluster-scoped lock past its deadline, a waiter on another node may already
have stale-reclaimed it — the stale reclaim is **not directly observable** by
the holder; the hold cap is its proxy — so continuing to run teardown steps,
up to and including the target detach, would race the other node's activation:
the exact co-activation hazard the lock design exists to prevent. Therefore
the cycle **classifies errors**: the two hold-enforcement dies carry a marker
(`LOCK_FATAL_ERROR_MARKER`, prefixed to their messages), the helper
`OpenEJovianDSS::Lock::lock_error_fatal($err)` detects it by substring match
(so any outer error prefixing survives), and **every `eval` this design
introduces** — the attempt, the stale-cookie sweep, the teardown
pass, and the per-step `eval`s inside `_volume_deactivate_attempt` — rethrows
a fatal error instead of absorbing it. No teardown runs on the fatal path: the
unwound locks are the release, the stack residue is deliberate (nothing
touches shared state without valid locks), and the next activation rebuilds or
fast-paths over whatever is left. The fatal class is deliberately coarse —
*any* marked die aborts, even a leaf `multipath`-lock hold-cap breach whose
outer locks may still be valid — because a hold-cap breach means the bounding
invariants the recovery machinery itself depends on have already failed (fail
loud, value #1).

**Contention is retried without teardown (review follow-up #9).** The third
class: an **acquire timeout** (`lock_error_acquire` — matching the three
acquisition-failure shapes that actually escape to callers, not the
internal `acquire timeout` string alone; see its New Functions entry)
reports a lock that
was **never obtained**. Nothing was modified under it, every held lock is
still valid, and nothing suggests the device stack is broken — under the
parallel-activation storm of Risk 3, tearing down and republishing on every
lost acquire race would amplify the very contention that failed the attempt.
So the cycle skips the sweep and the teardown and simply
re-attempts: publish and login fast-path or re-run idempotently over the
state left behind, and the staging exit contract re-validates any leftover
map (`$verify_map`, every cycle). On the pre-final-cycle pass this also skips
the recovery detach — contention is not the backend wedge the detach exists
to reset. Everything else — device absent, staging exhausted, verification
mismatch, jdssc errors — stays on the normal sweep-teardown-reattempt path.

### The recovery detach and its session gate
[The_recovery_detach_and_its_session_gate](#the-recovery-detach-and-its-session-gate)

**When the detach rung fires (Open Question #1 — revised 2026-07-03; session
gate adopted same day).** The teardown always logs out and cleans records; its
`volume_unpublish` rung is a **recovery mechanism, not a routine step**, behind
**two gates**:

1. **Cycle position.** It fires only in the teardown before the final cycle —
   i.e. after `VOLUME_ACTIVATE_CYCLE_ATTEMPTS − 1` consecutive failed
   attempts — keyed on the cycle counter
   (`$cycle == VOLUME_ACTIVATE_CYCLE_ATTEMPTS − 1`), so the last attempt runs
   against a freshly re-attached target. Every other pass — earlier cycles and
   the pass after the final failure — keeps today's cleanup (snapshot
   unpublish only).
2. **Session evidence.** Before detaching, the rung asks JovianDSS for the
   target's active sessions — `_target_foreign_sessions`, over the existing
   `target_get_sessions` (`Common.pm:1637`, jdssc
   `pool <pool> target <iqn> sessions list` —
   [`jdssc-target-sessions.md`](jdssc-target-sessions.md)) — and compares
   each session's initiator
   against the node's own (`get_local_initiator_name`, `Common.pm:1673`).
   **Any foreign initiator connected → the detach is skipped**, warned loudly
   with the initiators named, and the pass completes at the logout level; the
   final attempt then runs without the re-attach. A failed session query also
   skips the detach — *no evidence, no detach* (conservative; a backend that
   cannot answer a session query is unlikely to honor a detach cleanly
   either). The query is a **bounded probe**: each run capped at
   `TARGET_SESSIONS_QUERY_TIMEOUT` with `TARGET_SESSIONS_QUERY_RETRIES`
   timeout-retries (Table 4b; `joviandss_cmd` retries only on process
   timeouts — error exits fail the probe immediately), replacing the
   `118, 5` literals at `Common.pm:1652` and paid only in this one pass
   (arithmetic: value notes). Skip-on-failure obeys the fatal-error rule
   like every other `eval` in the cycle: a `lock_error_fatal` die surfacing
   through the query's jdssc run **rethrows** — *skip the detach* never
   means *swallow the fatal*. The node's **own** lingering session never blocks the rung: the
   pass logs iSCSI out before the unpublish step, and clearing the local
   residue is what the teardown is for.

The gate's probe, in full — the safety property it implements is: **the only
sessions that may be present at detach time are the local node's own**; any
other initiator's session, and any inability to prove otherwise, blocks the
detach:

```perl
# Foreign-session probe for the recovery detach (gate (b)): returns an
# arrayref of initiator IQNs — OTHER THAN THIS NODE'S — holding active
# sessions on $targetname; empty means "only local sessions (or none) —
# safe to detach". Dies when the query fails; the caller reads a die as
# "no evidence, no detach". The local identity is what the node's own
# initiator sends on login (/etc/iscsi/initiatorname.iscsi), which is
# byte-for-byte what the appliance reports back — compared
# case-insensitively anyway (RFC 3722 prescribes lowercase; guard
# against case drift). target_get_sessions groups by initiator, so a
# multipath node's several sessions (one per portal) are one key here.
sub _target_foreign_sessions {
    my ( $ctx, $targetname ) = @_;

    my $sessions = target_get_sessions( $ctx, $targetname );  # initiator → [ips]
    my $local_initiator = lc( get_local_initiator_name($ctx) );

    my @foreign;
    for my $initiator ( sort keys %$sessions ) {
        push @foreign, $initiator
            if lc($initiator) ne $local_initiator;
    }

    debugmsg( $ctx, 'debug',
        "Target ${targetname} foreign sessions: "
      . ( @foreign ? join( ',', @foreign ) : 'none' ) );

    return \@foreign;
}
```

**Residual risk, accepted:** the check is point-in-time — a session
established in the window between the query and the `targets delete` slips
through (the window is one jdssc call wide); and initiator comparison assumes
per-node-unique IQNs (the Proxmox installation default). The dangerous case —
a live-migration source still using the target — holds its session
*continuously*, so the evidence gate catches it reliably; the earlier
argument ("that many consecutive destination failures most likely mean the
migration fails and the VM terminates anyway") remains as defense-in-depth,
no longer the primary guard. The original staging-window/`session_up` gate
stays superseded; the `session_up` flag is dropped.

Cycle-completion contract (both gates spent or not): the final failure (all
cycles spent) leaves the volume **torn down to today's logout level** — the
last teardown has already run, and it does not detach (the recovery detach
ran before the final cycle) — and dies with the last attempt's error. Two
exception end-states, both benign and both repaired by the next
activation's publish/staging (finding #18): a final cycle failing as
**contention** skips its teardown, so that attempt's residue stays (the
contention-class rule); and a **pre-cycle budget stop** after the
pre-final teardown dies before the final attempt runs — the volume may
then be left *detached* (the recovery detach ran; its re-attach never
did). A **fatal** lock error leaves residue by design (Risk 6). Callers
see exactly the contract they see today: block devices on success, a die on
failure; only the internal persistence changes.

The cycle nests inside the method locks unchanged: `vm`/`storage` lock → attempt →
(jdssc locks inside `joviandss_cmd`, `multipath` lock inside `multipath_cmd`) — all
leaves, no new ordering edges.

### Device verification
[Device_verification](#device-verification)

> **Superseded for the activation flow by option A (finding #23,
> 2026-07-04).** The strict post-staging verify loop described below is
> **retired from activation**: the backend-export size check moved into
> `volume_stage_iscsi`'s exit contract (at the raw-LUN layer), and the
> redundant path re-check is dropped (staging's finding #12 contract already
> proved it). `lun_record_update_device` now serves **only** the lenient
> `volume_update_size` resize caller — which genuinely needs the rescan +
> `multipath -r` ladder to propagate a backend resize. The strict/lenient
> `$strict` split still exists at the code level, but the activation flow no
> longer calls it; the description below is retained as the contract of the
> **lenient** path.

`lun_record_update_device` keeps its role — rescan paths, re-read capacity, update
the record — and gains a caller-selected contract via a trailing `$strict`
parameter (review follow-up #6): **strict** (formerly the activation flow —
now unused there per option A above) **dies when
the device does not verify** within `VOLUME_ACTIVATE_VERIFY_ATTEMPTS` rounds
(today it returns silently — [the verification gap](#the-verification-gap));
**lenient** (the default — every caller not passing the flag) keeps today's
behavior, warn-and-return on exhaustion. Lenient exists for the one other
in-tree caller, `volume_update_size` (`Common.pm:4187, 4198`, reached from
`_activate_volume`'s cross-node-resize branch): there a *transient* mismatch
is expected — the device reports the old size until rescans propagate — and a
die would abort a resize that completes moments later. Each round rescans (the
targeted `udevadm` form per Table 1 — the broad `-t all` trigger goes),
re-stages the map when it is missing — **bounded to a single gentle staging
round** (`volume_stage_multipath` with an attempts bound of 1: the verify
loop owns the retry cadence, so one verify round can never embed a full
`MULTIPATH_STAGE_ATTEMPTS` loop, keeping the budget honest — follow-up #6's
budget sub-item; the bound of 1 also suppresses the final-round escalation
blast — an attempts-1 call is a repair round, not a last chance,
finding #16 — and the call is eval-wrapped, so its die is this round's
failure, not a lenient-caller abort) — reloads the map (`multipath -r` via
`multipath_cmd`),
escalates to `multipathd reconfigure` every 5th round (the corrected Open
Question #3 call — today's invalid form was a silent no-op, so the
now-working command is gated rather than fired per round), reads
`blockdev --getsize64` (unlocked read) **and, for multipath devices, the
map's path evidence** (`_multipath_map_has_active_path` — the staging exit
contract's probe reused: size alone cannot expose a dead-but-intact map,
finding #12), and sleeps
`VOLUME_ACTIVATE_VERIFY_SLEEP` between rounds:

**Table 3 — Verification outcomes** · `tbl_verify_outcomes`

The table states the **strict** contract (the activation flow); lenient
callers warn and return where strict dies. An expected size of **0** is
treated as *no expected size supplied* — zero can never verify a device
(finding #20).

| Check result | Meaning | Action |
|---|---|---|
| device node absent (`-b` fails) | staging incomplete | next round; exhausted → **die** → teardown + next cycle |
| map present, **no active path** (multipath only) | a dead-but-intact map — size cannot expose it: `blockdev --getsize64` answers from the dm table without touching a path (finding #12). "No active path" here is the **two-stage** verdict: `multipath -ll` shows no active path **and** the `dmsetup status` fallback also shows none (finding #21 — an empty `-ll` alone is not evidence, since a busy `multipathd` blinds it) | next round — the reload/rescan may recover a checker lag, but the embedded re-stage does **not** fire (it triggers on a *missing* node only; a pathless map usually means a dead session, which is cycle territory); exhausted → **die** → teardown + next cycle |
| size = 0 | LUN attachment wedged (the observed failure) | next round; exhausted → **die** → **teardown + next cycle** (the pre-final-cycle teardown includes the recovery detach) |
| size > 0 but ≠ expected | stale capacity (e.g. activation after a resize elsewhere); a rescan usually corrects it, a re-login always re-reads it | next round; exhausted → **die** → teardown + next cycle |
| size = expected | verified | update LUN record, return |
| no expected size supplied | nothing to compare against | device present with **non-zero** size suffices; zero still fails |

Since the F-04 amendment (2026-07-05) the activation attempt supplies **no
expected size** — the "no expected size supplied" row is the activation
norm, and the exact-match rows apply only to a caller that passes one
(today none does; the lenient resize path keeps its own exact check in
`lun_record_update_device`). The recovery semantics are unchanged — the
die originates in Stage 2. A verification die is an ordinary attempt failure: the cycle's
teardown and re-login repair the stale-capacity case, and the pre-final-cycle
teardown — with its target detach and re-attach — is precisely the reset that
repairs the wedged-attachment case.

**Implementation note — the device size check is NEW code (decided).** Nothing in
today's activation path fails on device size: the size compare exists only as the
silently-falling-through loop of
[the verification gap](#the-verification-gap), and a **zero**-size check exists
nowhere at all. The verification loop above must therefore be *added* during
implementation, not merely relocated — and a device that stays at size zero
through `VOLUME_ACTIVATE_VERIFY_ATTEMPTS` rounds **must** fail the attempt into
the deactivation and the next reactivation cycle; if the condition persists
through every earlier cycle, the pre-final-cycle teardown applies the
session-gated recovery detach (Open Question #1) so the last attempt runs
against a re-attached target.

**Field diagnosis — `multipath -ll` is an unreliable liveness oracle
(findings #21 and #22, 2026-07-04).** First live activation of a real
multipath volume (`vm-202-disk-0`, PVE 9.1) failed loudly: *"Device
verification … failed after 10 rounds: map has no active path"*, all four
cycles. The device was never the problem — the log proves it:

- **The map was healthy throughout.** Staging's own acceptance probe
  returned a full `multipath -ll` (two `active ready running` paths)
  immediately before verification, and again at the next cycle's staging
  immediately after. The dm node `/dev/mapper/<wwid>` was present every
  verify round — *"map has no active path"* is the verify loop's **second**
  check, reached only after `-b` on that node passes, so node-presence is a
  logged invariant of the failure.
- **`multipath -ll <wwid>` returned empty during verification.** It queries
  `multipathd` over its socket; while the daemon is busy (a
  `multipathd reconfigure`, or contention from concurrent activations —
  the Issue 2 regime) it answers a per-WWID `-ll` with exit 0 and **no
  output**. The single-stage probe read that silence as "no active path."
  Reproduced live: under `multipathd reconfigure` load, `multipath -ll`
  returns empty where `dmsetup status` (which reads the dm **table**, not
  the daemon socket) still reports the paths.

**Finding #21 — the probe needs a socket-independent second stage.**
`_multipath_map_has_active_path` falls back to `dmsetup status <wwid>`
A-flag counting when `-ll` is empty **and** the dm node exists (the exact
signature above). Device-mapper's own view can't be blinded by a busy
daemon. Genuine absence (no dm node) still fails, so a real zombie is still
rejected — the negative control was verified live. This is the shipped fix.

**Finding #22 — verification blinds its own probe, and largely duplicates
staging (design smell; simplification deferred).** The deeper answer to
*"if staging already confirmed the device, why did verification iterate?"*
is that **verification manufactures the very condition it then reports as
failure.** `lun_record_update_device` runs, every round,
`iscsiadm --rescan` / `iscsiadm -m node -R` / `udevadm trigger` and — every
5th round — `multipathd reconfigure`; that churn is what keeps the daemon
busy enough to blind `multipath -ll`. Each blind read drives another round
of the same churn (self-reinforcing), then the whole cycle restarts and
staging's un-churned `-ll` succeeds again, only for verification to blind
itself once more — hence four identical cycles over a device that was ready
the entire time. Two observations follow, both deferred to a follow-up
rather than fixed here:

1. **Redundancy.** In the multipath **activation** flow, staging's exit
   contract (finding #12) has *already* guaranteed node-present +
   ≥ 1 active path before `lun_record_update_device` runs. Its path
   re-check therefore re-proves what staging proved; the only new evidence
   verification adds is **size**.
2. **Counterproductive method.** The disruptive rescan/reconfigure ladder
   exists for the **lenient** `volume_update_size` resize caller (where a
   rescan is how a new size propagates). In the strict activation path it
   buys nothing and actively breaks the path probe. **Resolved by option A
   (finding #23, below): the strict post-staging verify loop is retired —
   the SIZE check moves to `volume_stage_iscsi` (the raw-LUN layer, where a
   broken SCST export is most directly visible) and the redundant PATH
   re-check is dropped.** The `dmsetup` fallback (finding #21) keeps the
   staging probe robust in the meantime; `lun_record_update_device` remains
   for the lenient `volume_update_size` caller only.

**Finding #23 — the strict size check is a backend-export *health probe*,
and it must force a real READ CAPACITY (maintainer clarification +
measurement, 2026-07-04).** The size check's job is **not** resize
propagation (that path is tested and works separately). It detects a
**JovianDSS-side failure**: under heavy concurrent volume-create-and-attach
load, SCST sometimes exports a LUN wrong — the volume logs in, the device
node appears, the paths come up, so it *looks fine to Proxmox* — yet the LUN
is **not functional**. The tell is capacity: the device's READ CAPACITY size
disagrees with the volume's REST `volume_get_size`, or reads zero. Comparing
the **data-plane** capacity (what SCST actually exports) against the
**control-plane** volsize (what the volume metadata says) is a cross-plane
liveness cross-check — exactly the right detector for a broken data-plane
export, and the maintainer confirms it catches the failure in the field.

A scratch-volume test (a throwaway 1 GiB grown to 2 GiB — used only to
characterize the *caching layers*, not to exercise resize) pins down how the
check must be written:

| Stage (1 GiB → 2 GiB) | backend zvol | **target** (fresh READ CAPACITY) | `sd` cache (`/sys/block/*/size`) | dm table | mapper (Proxmox reads) |
|---|---|---|---|---|---|
| after backend change, **no initiator action** | 2 GiB | **2 GiB** | 1 GiB | 1 GiB | 1 GiB |
| after `sd` rescan (`/sys/.../device/rescan`) | 2 GiB | 2 GiB | **2 GiB** | 1 GiB | 1 GiB |
| after `multipath -r` reload | 2 GiB | 2 GiB | 2 GiB | **2 GiB** | **2 GiB** |

Two facts decide the implementation:

1. **`blockdev --getsize64`, `/sys/block/*/size` and the dm table are all
   cache reads — no wire I/O.** A size check that reads only the cache could
   see a stale-but-plausible value and **miss a broken export**. So the check
   is valid only as **rescan → then read**: the rescan issues the wire
   READ CAPACITY that forces SCST to answer, and a broken export answers
   wrong or zero. (This is the real reason the "does it query storage or read
   cache?" question matters — it is about *health detection*, not resize.)
2. **The SCST target answers READ CAPACITY with its current truth on demand,
   no re-login/re-registration** (row 1: the changed size appeared the instant
   after the backend change, via `sg_readcap`, before any initiator action).
   So a single forced rescan is enough to expose a broken export — there is no
   target-side cache to defeat.

**Where the size check goes — option A, implemented 2026-07-04** (deployed
and validated on PVE 9.1: healthy volumes verify and activate first-cycle,
the helper accepts a correct size and rejects a wrong one, the strict verify
loop no longer runs, no regression under a concurrent storm). The size
check moves to `volume_stage_iscsi` **and lives there only.** The `sd`
device is the raw iSCSI LUN — the most direct read of what SCST actually
exported, one layer below the multipath map — so verifying its capacity
(forced rescan → READ CAPACITY → compare against `volume_get_size`) is the
authoritative backend-export health probe, and the staging wait loop
already rescans. `volume_stage_multipath` keeps **only** its active-path
exit contract (finding #12) and gains **no** size check:

- **A freshly built map inherits the verified `sd` size** — `volume_stage_iscsi`
  verifies the LUN *before* the map is built, so the dm table is correct by
  construction.
- **A pre-existing map with active paths came from a prior *successful*
  activation**, which already passed this same `sd`-layer size check — so
  its table is already correct.

A size reconcile (`multipath -r`) on the activation staging path was
**considered and rejected**: it is redundant with the `sd`-layer check
(the map's size is *derived* from the `sd`) and would reintroduce exactly
the dm-layer churn findings #21/#22 removed. The one case a map's size can
go independently stale — a **backend resize while the map is up** — is not
an activation concern: that is the lenient `volume_update_size` flow, which
keeps `lun_record_update_device` and its rescan + `multipath -r` ladder
(the dm table being a *separate* cache, per the table above, is exactly why
*that* flow needs the reload). So option A retires the strict post-staging
verify loop entirely, adds size verification **only at the raw-LUN layer**,
and adds **no** new multipath churn. The PATH re-check in the current verify
loop stays redundant with staging (finding #22); the **SIZE check is the
load-bearing backend-health detector**, preserved at the `sd` layer.

### Time budget
[Time_budget](#time-budget)

The whole cycle runs under the method lock, so its **typical** cost times the cycle
count must fit inside `LOCK_CLASS_VM_HOLD_TIMEOUT` with headroom:

```
VOLUME_ACTIVATE_CYCLE_ATTEMPTS ×
    (  publish + iSCSI login                                        [jdssc + iscsiadm]
     + MULTIPATH_VPD_WAIT_ATTEMPTS × MULTIPATH_VPD_WAIT_SLEEP       [worst]
     + MULTIPATH_STAGE_ATTEMPTS × (commands + MULTIPATH_STAGE_SLEEP) [worst]
       (the iSCSI-layer capacity check of option A is folded into the iSCSI
        login/device-wait line above — the strict verify loop, formerly
        VOLUME_ACTIVATE_VERIFY_ATTEMPTS × VOLUME_ACTIVATE_VERIFY_SLEEP, is
        retired from activation)
     + teardown (one pass: unstage waits + remove rounds; the wait-unused
                 bound is paid only while something still holds the device)
     + session probe: (TARGET_SESSIONS_QUERY_RETRIES + 1) ×
                 (TARGET_SESSIONS_QUERY_TIMEOUT + 1) + retry sleeps
                 [pre-final-cycle pass only; worst case = hung appliance]
     + VOLUME_ACTIVATE_CYCLE_SLEEP )
  <  LOCK_CLASS_VM_HOLD_TIMEOUT
```

The inner attempt counts are deliberately **smaller than today's** hardcoded bounds
(Table 4b vs the 60-round stage loop): several shorter batches with a full stack
rebuild between them recover more than one long batch polling a broken stack ever
will. The budget is sized for the typical-failure path (commands return promptly,
the device just is not there); a pathological run where many commands eat their
full timeouts can still exceed it — then the `vm` hold deadline kills the operation
loudly, which is that mechanism's job (fail loud, value #1) — and the cycle *lets*
it: hold-cap dies are classified **fatal** and rethrown, never absorbed as attempt
failures (see the fatal-error classification in
[The reactivation cycle](#the-reactivation-cycle)). Worked numbers:
[Value notes](#value-notes).

---

## Open Questions
[Open_Questions](#open-questions)

1. **Does the teardown's target detach need a co-activation gate? — resolved
   (decided 2026-07-03, revised twice same day): yes — the detach is a
   recovery mechanism that fires only in the teardown before the final cycle,
   and only when JovianDSS shows no foreign session on the target.**
   The hazard: `volume_unpublish` runs jdssc `targets delete -v <volname>`, and
   during a live migration the **source** node holds an active session to that
   same target while the **destination** activates (the `vm` lock serializes
   their *calls*, not the source's standing session — the old comments at
   `Common.pm:3731` and `:3877` guarded exactly this). Review showed the first
   decision's temporal gate — "the attempt structure IS the gate", keyed on the
   post-login `session_up` flag — was not enforced by construction (fast
   post-login failures such as a lock acquire timeout, a staging fast-path hit
   followed by a jdssc error, or a non-multipath deployment's short verify loop
   all skip the claimed staging window) and did not cover the aborted-migration
   case at all (a source whose destination keeps failing never releases the
   device — it keeps running). **Revised decision:** the detach is demoted from
   a routine teardown step to a **one-shot recovery rung**: it fires only in
   the teardown **before the final cycle**, i.e. after
   `VOLUME_ACTIVATE_CYCLE_ATTEMPTS − 1` consecutive failed attempts (cycle
   count raised — Table 4b), keyed on the cycle counter; all other passes keep
   today's cleanup (snapshot unpublish only), and the `session_up` flag is
   dropped. **Second revision (decided 2026-07-03): the session-evidence
   upgrade path is adopted now, as the primary guard.** Before detaching, the
   rung queries the target's active sessions via `_target_foreign_sessions` —
   built on machinery already in the tree: `target_get_sessions`
   (`Common.pm:1637`) over the jdssc session subcommand, compared against
   `get_local_initiator_name` (`Common.pm:1673`). Two supporting changes ship
   alongside, both specified in
   [`jdssc-target-sessions.md`](jdssc-target-sessions.md): the jdssc
   subcommand becomes `pool <pool> target <iqn> sessions list`, REST-backed
   by the per-target sessions endpoint (live-verified 2026-07-03); and
   `target_get_sessions`' invocation is corrected to that form
   (`Common.pm:1652` — the pre-fix form omitted the `pool <pool>` prefix,
   which jdssc's CLI rejects outright; **shipped 2026-07-03**). Any foreign initiator connected, or a failed query → the
   detach is skipped (*no evidence, no detach*) and the teardown completes at
   the logout level. The accepted residual shrinks to the point-in-time window
   between the query and the `targets delete`, plus the assumption of
   per-node-unique initiator IQNs; the cycle-position argument ("that many
   consecutive destination failures most likely mean the migration fails and
   the VM terminates anyway") remains as defense-in-depth (recorded in
   [Risks](#risks--backward-compatibility) #1).
2. **Where does the code live? — resolved (decided 2026-07-03): in `Common.pm`.**
   All new and changed functions stay in `Common.pm`, alongside the `$MULTIPATH` /
   `$MULTIPATHD` / `$DMSETUP` binary detection that is `Common.pm`-lexical today
   (`Common.pm:183–190`). A split into an `OpenEJovianDSS::Multipath` module
   (precedent: `NFSCommon.pm`) stays available as mechanical follow-up work if
   ever wanted; the scratch `multipath.pm` draft is superseded and deleted either
   way (Table 6).
3. **`multipath reconfigure` (`Common.pm:4128`) is not a valid `multipath(8)`
   invocation — resolved (decided 2026-07-03): corrected to
   `multipathd reconfigure`.** `reconfigure` is a `multipathd` interactive
   command; today the call fails harmlessly inside its best-effort `eval`, so
   the correction turns a silent no-op into a working — and heavy — daemon-wide
   re-read. To keep it from hammering the daemon once per verification round,
   it fires on a sparse schedule inside the verify loop (every 5th round),
   mirroring the staging body's gating of the same command; `multipath -r`
   stays the every-round reload. Routed through `multipath_cmd` at
   `MULTIPATH_CMD_TIMEOUT_MAX` like its staging twin (Table 1).

---

## Function Signature Change
[Function_Signature_Change](#function-signature-change)

Public contracts that change (callers in both plugins are unaffected unless
listed):

- `volume_activate($ctx, $vmid, $volname, $snapname, $content_volume_flag)` —
  **signature unchanged**; behavior gains the bounded reactivation cycle. Failure
  now implies the teardown for every stage the last attempt reached has already
  run.
- `volume_stage_iscsi($ctx, $targetname, $lunid, $hosts, $scsiid)` →
  `volume_stage_iscsi(…, $scsiid, $expected_size)` — trailing optional
  (option A, finding #23); when given, the exit contract requires the
  device to report this exact non-zero capacity (forced READ CAPACITY via
  `_iscsi_capacity_ok`) before returning — the backend-export health check
  at the raw-LUN layer. `undef` → "non-zero capacity" (still catches a
  size-0 export). The activation flow passes `volume_get_size`.
- `volume_stage_multipath($ctx, $scsiid, $block_devs)` →
  `volume_stage_multipath($ctx, $scsiid, $block_devs, $attempts,
  $verify_map)` — both trailing optional; `$attempts` undef →
  `MULTIPATH_STAGE_ATTEMPTS` (a bound of 1 is a gentle repair round —
  finding #16); `$verify_map` true (the activation flow, every cycle)
  makes the fast path require an active path before trusting an existing
  map; independently of it, the staging loop returns only maps showing an
  active path — the exit contract of finding #12.
- `volume_unstage_multipath($ctx, $scsiid)` →
  `volume_unstage_multipath($ctx, $scsiid, $attempts_wait_unused,
  $attempts_remove_device)` — trailing optional; undef →
  `MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS` /
  `MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS`. (`Common.pm:3730` already passes the
  four-argument form.)
- `lun_record_update_device(…, $expectedsize)` →
  `lun_record_update_device(…, $expectedsize, $strict)` — trailing optional;
  **strict** dies on exhaustion, **lenient** (default) warns and returns.
  Since **option A (finding #23)** the **activation flow no longer calls
  this** (size moved to `volume_stage_iscsi`); the sole remaining caller is
  the lenient `volume_update_size` resize flow, which legitimately sees
  transient mismatches while rescans propagate. The `$strict` parameter is
  retained (no activation caller passes it today).
- `_volume_unstage_multipath_wait_unused($ctx, $scsiid)` →
  `_volume_unstage_multipath_wait_unused($ctx, $scsiid, $tick)` — becomes **one
  tick per call** returning the wait decision (1 = free/gone, 0 = still held);
  the loop and sleep move to `volume_unstage_multipath` (internal).
- `_volume_unstage_multipath_remove_device($ctx, $scsiid)` →
  `_volume_unstage_multipath_remove_device($ctx, $scsiid, $round)` — becomes
  **one removal round per call** returning 1 (gone) / 0 (still held); the loop
  and the deferred-removal fallback move to `volume_unstage_multipath`
  (internal).

---

## New Constants
[New_Constants](#new-constants)

Single point of truth: **values appear in Table 4b only** (and Table 5 for
pre-existing constants). Prose and code reference constants by name; relations are
argued symbolically. All constants are **implemented** (2026-07-03) — the
three **changed** existing values landed in `OpenEJovianDSS/Lock.pm` with
this design's implementation; the two `TARGET_SESSIONS_QUERY_*` bounds had
already shipped with the
[`jdssc-target-sessions.md`](jdssc-target-sessions.md) implementation
(2026-07-03).

**Table 4a — Constant descriptions** · `tbl_constants_desc`

| Constant | Description |
|---|---|
| `MULTIPATH_CMD_TIMEOUT_DEFAULT` | per-command TERM bound `multipath_cmd` applies when the caller passes none — the middle tier. |
| `MULTIPATH_CMD_TIMEOUT` | tier for `multipath` CLI per-WWID operations, read probes (`-a`, `-ll`, `dmsetup info` / `udevcookies`) and the WWID-scoped udev trigger — sized to cover CLI + udev-sync latency under load while staying under `MULTIPATH_CMD_TIMEOUT_MAX` (assignments: Table 1). |
| `MULTIPATHD_CMD_TIMEOUT_FAST` | quick tier for `multipathd` **socket** commands (`del map`; `add wwid` if the optional hardening lands) — kept separate from the CLI quick tier so each binary tunes independently. The heavy daemon operations (`add path` / `add map` / `reconfigure`) are not socket-quick and use `MULTIPATH_CMD_TIMEOUT_MAX`. |
| `MULTIPATH_CMD_TIMEOUT_MAX` | ceiling for any per-command timeout (clamped in `multipath_cmd`, mirroring `joviandss_cmd`'s clamp); commands that do real synchronous work or stall under load pass it explicitly (Table 1). |
| `MULTIPATH_CMD_KILL_GRACE` | grace between the wrapper's SIGTERM and its SIGKILL escalation; `run_command`'s own kill sits `MULTIPATH_CMD_BACKSTOP_MARGIN` above `timeout + grace`. |
| `MULTIPATH_CMD_BACKSTOP_MARGIN` | margin between the wrapper's SIGKILL escalation and `run_command`'s last-resort SIGKILL backstop — wide enough that fork/exec latency under load cannot let the backstop (whose kill is the exact re-strand hazard the ladder avoids) win the race (review follow-up #10). Ladder invariant: chokepoint *Safe termination* bullet. |
| `MULTIPATH_COOKIE_STALE_AGE` | age bound for the stale-cookie sweep: `dmsetup udevcomplete_all` completes only cookies older than this. In **minutes** — `udevcomplete_all`'s own unit, unlike every other constant here. |
| `MULTIPATH_STAGE_ATTEMPTS` | default rounds of `_volume_stage_multipath` per activation attempt (replaces the hardcoded 60 — deliberately smaller: the reactivation cycle supplies the deep retries). |
| `MULTIPATH_STAGE_SLEEP` | sleep between stage rounds (outside the lock). |
| `MULTIPATH_VPD_WAIT_ATTEMPTS` | ticks waiting for the `/dev/disk/by-id/scsi-<id>` VPD symlink before staging. |
| `MULTIPATH_VPD_WAIT_SLEEP` | sleep per VPD wait tick. |
| `MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS` | default ticks waiting for the mapper device to become unused before removal — keeps today's effective 60-tick bound (finding #17): the wait exits early the moment the device is free, so the full bound is paid only while something genuinely holds it — the migration window whose corruption hazard the wait guards. |
| `MULTIPATH_UNSTAGE_WAIT_UNUSED_SLEEP` | sleep per wait-unused tick. |
| `MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS` | default removal rounds (`-w` / `del map` / `-f` / `dmsetup`) before the deferred-removal fallback — keeps today's hardcoded 10 (finding #17: defaults preserve today's effective bounds; the ignored four-argument literals at `Common.pm:3730` were never in force). |
| `MULTIPATH_UNSTAGE_REMOVE_SETTLE` | settle inside a removal round between `dmsetup remove` and its re-probe. |
| `MULTIPATH_UNSTAGE_BLOCKER_WAIT` | bounded grace at a removal round's tail for an identified blocker pid (1 s ticks); doubles as the inter-round pacing. |
| `MULTIPATH_UNSTAGE_REMOVE_SLEEP` | round-tail pacing when no blocker pid could be identified. |
| `VOLUME_ACTIVATE_CYCLE_ATTEMPTS` | full publish → stage → verify cycles before activation fails for good; the teardown after the penultimate cycle's failure — and only that one — includes the recovery detach (Open Question #1). |
| `VOLUME_ACTIVATE_CYCLE_SLEEP` | sleep between cycles (after teardown). |
| `VOLUME_ACTIVATE_CYCLE_MIN_BUDGET` | minimum remaining method-lock hold budget (`lock_deadline_remaining`) required to start another cycle; with less, the cycle rethrows the last error instead of launching an attempt doomed to die mid-way at the hold cap (review follow-up #11.3). |
| `VOLUME_ACTIVATE_VERIFY_ATTEMPTS` | verification rounds in `lun_record_update_device` before it dies (was 10 silent rounds). |
| `VOLUME_ACTIVATE_VERIFY_SLEEP` | sleep between verification rounds. |
| `ISCSI_CAPACITY_PROBE_TIMEOUT` | bound on the `blockdev --getsize64` capacity probe in `_iscsi_capacity_ok` (added 2026-07-05): a wedged/broken export can hang the open or the size ioctl — the very failure the probe detects — and every command under a held lock must carry an explicit timeout. Expiry fails toward retry (round treats it as not-verified). |
| `ISCSI_LOGIN_TIMEOUT` | initiator-side login timeout written into the iscsiadm node DB (`node.conn[0].timeo.login_timeout`) — was an inline `'30'` literal; named 2026-07-05 (review F-05). |
| `ISCSI_LOGIN_CMD_TIMEOUT` | end-to-end bound on each per-portal `iscsiadm --login` run (added 2026-07-05, review F-05): reaches a wedged iscsid, which the node-DB timeout cannot. **Invariant: > `ISCSI_LOGIN_TIMEOUT`**, so a legitimate maximal login is never killed by its own wrapper. Expiry counts as a failed login for that host only. |
| `TARGET_SESSIONS_QUERY_TIMEOUT` | per-run execution timeout of the detach gate's session query (`target_get_sessions` → jdssc `sessions list`) — deliberately short per try: a healthy appliance answers in seconds, so each try fails fast; persistence across transient stalls comes from `TARGET_SESSIONS_QUERY_RETRIES`, not from a long single wait. Replaces the pre-gate `118` literal at `Common.pm:1652`. |
| `TARGET_SESSIONS_QUERY_RETRIES` | timeout-retries for that query (`joviandss_cmd` retries only on a **process timeout**; error exits die immediately, so a broken appliance still fails fast) — sized to ride out a transient appliance stall rather than forfeit the recovery detach. Worst case ≈ (retries + 1) × (`TARGET_SESSIONS_QUERY_TIMEOUT` + 1) plus 3–8 s inter-retry sleeps, paid only against a hung appliance and only in the pre-final-cycle pass (arithmetic: value notes; contained by the raised hold deadline below). Replaces the pre-gate `5` literal riding the 117 s clamp (~12 minutes worst). |
| `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT` | **(changed existing)** the `multipath` class's wait-to-acquire; raised so a waiter outlasts **one** full worst-case command hold with real headroom (`≥ MULTIPATH_CMD_TIMEOUT_MAX + MULTIPATH_CMD_KILL_GRACE + MULTIPATH_CMD_BACKSTOP_MARGIN`; a deeper queue can still time a waiter out — that is the cycle's **contention** class, retried without teardown — finding #20). The lock design's Table 9b row updates at implementation time. |
| `LOCK_CLASS_VM_HOLD_TIMEOUT` | **(changed existing)** the method-lock deadline the whole reactivation cycle must fit inside — raised so the pessimistic four-cycle budget **plus** the pre-final-cycle session probe fit with headroom instead of dying mid-recovery (arithmetic: value notes). The deadline remains the loud backstop for runs beyond even that (the fatal-error classification rethrows its die). The lock design's Table 9b row updates at implementation time. |
| `LOCK_CLASS_STORAGE_HOLD_TIMEOUT` | **(changed existing)** the same deadline for the `storage` method class — the cycle runs under it when no vmid resolves (`_activate_volume_lock`'s fallback, e.g. content volumes); raised in step with the `vm` class for the same budget. |
| `LOCK_FATAL_ERROR_MARKER` | marker string prefixed to every lock-machinery die that must never be swallowed by best-effort machinery — today the two hold-enforcement dies (`refresh_locks` hold-cap overrun, `run_bounded` hold alarm). `lock_error_fatal` detects it by **substring** match, so outer error prefixing (e.g. `with_lock`'s machinery prefix) survives. |

**Table 4b — Constant values** · `tbl_constants_values`

| Constant | Value | Denomination | Location |
|---|---|---|---|
| `MULTIPATH_CMD_TIMEOUT_DEFAULT` | 20 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_CMD_TIMEOUT` | 20 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATHD_CMD_TIMEOUT_FAST` | 5 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_CMD_TIMEOUT_MAX` | 30 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_CMD_KILL_GRACE` | 5 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_CMD_BACKSTOP_MARGIN` | 5 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_COOKIE_STALE_AGE` | 3 | **minutes** | `OpenEJovianDSS::Common` |
| `MULTIPATH_STAGE_ATTEMPTS` | 20 | rounds | `OpenEJovianDSS::Common` |
| `MULTIPATH_STAGE_SLEEP` | 1 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_VPD_WAIT_ATTEMPTS` | 30 | ticks | `OpenEJovianDSS::Common` |
| `MULTIPATH_VPD_WAIT_SLEEP` | 1 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS` | 60 | ticks | `OpenEJovianDSS::Common` |
| `MULTIPATH_UNSTAGE_WAIT_UNUSED_SLEEP` | 1 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS` | 10 | rounds | `OpenEJovianDSS::Common` |
| `MULTIPATH_UNSTAGE_REMOVE_SETTLE` | 1 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_UNSTAGE_BLOCKER_WAIT` | 5 | seconds | `OpenEJovianDSS::Common` |
| `MULTIPATH_UNSTAGE_REMOVE_SLEEP` | 2 | seconds | `OpenEJovianDSS::Common` |
| `VOLUME_ACTIVATE_CYCLE_ATTEMPTS` | 4 | cycles | `OpenEJovianDSS::Common` |
| `VOLUME_ACTIVATE_CYCLE_SLEEP` | 5 | seconds | `OpenEJovianDSS::Common` |
| `VOLUME_ACTIVATE_CYCLE_MIN_BUDGET` | 120 | seconds | `OpenEJovianDSS::Common` |
| `VOLUME_ACTIVATE_VERIFY_ATTEMPTS` | 10 | rounds | `OpenEJovianDSS::Common` |
| `VOLUME_ACTIVATE_VERIFY_SLEEP` | 1 | seconds | `OpenEJovianDSS::Common` |
| `ISCSI_CAPACITY_PROBE_TIMEOUT` | 10 | seconds | `OpenEJovianDSS::Common` |
| `ISCSI_LOGIN_TIMEOUT` | 30 | seconds | `OpenEJovianDSS::Common` |
| `ISCSI_LOGIN_CMD_TIMEOUT` | 35 | seconds | `OpenEJovianDSS::Common` |
| `TARGET_SESSIONS_QUERY_TIMEOUT` | 30 | seconds | `OpenEJovianDSS::Common` |
| `TARGET_SESSIONS_QUERY_RETRIES` | 7 | retries | `OpenEJovianDSS::Common` |
| `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT` | 60 (was 10) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_VM_HOLD_TIMEOUT` | 1320 (was 600) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_STORAGE_HOLD_TIMEOUT` | 1320 (was 600) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_FATAL_ERROR_MARKER` | `joviandss-lock-fatal:` | string | `OpenEJovianDSS::Lock` |

### Value notes
[Value_notes](#value-notes)

Why each value (Table 4b) is what it is — grouped by mechanism.

#### Command timeout tiers
`MULTIPATHD_CMD_TIMEOUT_FAST` · `MULTIPATH_CMD_TIMEOUT` ·
`MULTIPATH_CMD_TIMEOUT_DEFAULT` · `MULTIPATH_CMD_TIMEOUT_MAX`

Fail fast only where a healthy answer is near-instant; honor the 20–30 s
bounds production code learned under load everywhere else. The fast tier
(5 s) covers socket-quick daemon commands — a healthy daemon answers
near-instantly, and on a slow one the round/cycle retries. `MULTIPATH_CMD_TIMEOUT`
and the default are both 20 s — equal today, separate knobs — because CLI
operations pay libdevmapper / udev-sync latency under load. The 30 s ceiling
covers the commands that do real synchronous work (scans, flushes, map
registration).

#### The termination ladder
`MULTIPATH_CMD_TIMEOUT_MAX` · `MULTIPATH_CMD_KILL_GRACE` ·
`MULTIPATH_CMD_BACKSTOP_MARGIN` · `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT`

A locked command is TERM'd at ≤ 30 s, KILL'd by the wrapper at ≤ 35 s, and
KILL'd by `run_command` at ≤ 40 s. The backstop margin is a full 5 s — a 1 s
margin loses races under fork/exec load, and the backstop's kill is the exact
re-strand hazard the ladder avoids. The whole ladder sits under the
`multipath` hold cap (`LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT`, 60 s), so hold-cap
enforcement never fires on a legitimate command; the raised acquire wait
(60 s) outlasts one full worst-case hold with real headroom.

#### The cycle budget
`MULTIPATH_STAGE_ATTEMPTS` · `VOLUME_ACTIVATE_VERIFY_ATTEMPTS` ·
`VOLUME_ACTIVATE_CYCLE_ATTEMPTS` · `VOLUME_ACTIVATE_CYCLE_SLEEP`

Typical-failure path, per cycle: VPD wait ≈ 0 in the activation flow
(`volume_stage_iscsi`'s exit condition is the same by-id symlink; up to 30 s
only for the direct multipath-staging callers) + 20 stage rounds ≈ 40–60 s +
10 verify rounds ≈ 20 s (a missing-map round adds one gentle re-stage
round — finding #16) + teardown ≈ 30–60 s (the wait-unused bound exits
early when the device is free; the full minute is paid only while held) +
inter-cycle sleep 5 s +
publish and iSCSI stage (seconds when healthy; `volume_stage_iscsi`'s
internal login/device waits can reach minutes when unhealthy — in that regime
the hold deadline is the operative bound) ⇒ roughly one minute typical,
2–3 minutes pessimistic per cycle; four cycles ≈ 4 minutes typical,
8–12 pessimistic.

#### `TARGET_SESSIONS_QUERY_TIMEOUT` / `TARGET_SESSIONS_QUERY_RETRIES`

The pre-final-cycle pass adds the session-evidence probe:
`TARGET_SESSIONS_QUERY_RETRIES` + 1 runs × (`TARGET_SESSIONS_QUERY_TIMEOUT`
+ 1) s plus 3–8 s inter-retry sleeps ⇒ 8 × 31 + ~40 ≈ **5 minutes worst** —
and only against a *hung* appliance: error exits never retry, so a broken
appliance fails the probe in seconds.

#### `LOCK_CLASS_VM_HOLD_TIMEOUT` / `LOCK_CLASS_STORAGE_HOLD_TIMEOUT`

Pessimistic ceiling — four pessimistic cycles plus the probe's worst case —
is ≈ 13–17 minutes; the deadline is 1320 s (22 min; raised from 600 s)
precisely so that path fits with headroom instead of dying mid-recovery. The
deadline stays the loud backstop for runs beyond even that, and the
fatal-error classification guarantees its die terminates the cycle instead
of being absorbed.

#### `VOLUME_ACTIVATE_CYCLE_MIN_BUDGET`

120 s is roughly two typical cycles. Before starting another cycle,
`volume_activate` compares it against `lock_deadline_remaining($ctx)`; with
less remaining, it rethrows the last attempt's error instead of launching an
attempt the hold deadline would kill mid-way — the check errs toward failing
early **with the real device error** rather than late with a generic
hold-cap message and a half-built attempt.

#### `MULTIPATH_COOKIE_STALE_AGE`

3 **minutes** (`udevcomplete_all`'s own unit) sits an order of magnitude
above the documented worst udev backlog (tens of seconds), yet low enough
that a strand created mid-activation crosses the bound while the
reactivation cycle is still running — the sweep then repairs it within the
same operation, or at latest the next one.

#### Unstage bounds
`MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS` · `MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS`

Both keep today's **effective** behavior (finding #17): what callers get
today comes from the hardcoded loops, not from the ignored four-argument
literals at `Common.pm:3730` (today's two-argument signature discards
them). The wait is cheap when it matters least and long when it matters
most — it exits on the first free tick, so the typical (unheld) teardown
pays ~0, while a held device (Proxmox deactivating before qemu is gone —
the data-corruption window the function's own comment documents) gets the
full bound before removal escalates toward `dmsetup remove -f`. Shortening
that grace would be a deactivation-path behavior change needing its own
justification, not a side effect of this design.

**Table 5 — Related existing constants** · `tbl_constants_related`

| Constant | Value | Defined in | Note |
|---|---|---|---|
| `LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT` | 60 s | `OpenEJovianDSS::Lock` | the hold cap every locked command must fit under (termination-ladder invariant above). |
| `LOCK_CLASS_MULTIPATH_DEFAULT_TYPE` | `node` | `OpenEJovianDSS::Lock` | default scope — host-local `flock`, no cluster round-trips. |
| `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` | 117 s | `OpenEJovianDSS::Common` | bounds each jdssc run inside the cycle (publish / unpublish / get-size). |
| `CFS_LOCK_TIMEOUT` | 120 s | pmxcfs (external) | the stale-reclaim window the per-command cooperation points keep the outer shared method lock inside. |

---

## New Functions
[New_Functions](#new-functions)

In `OpenEJovianDSS/Common.pm`:

- **`multipath_cmd($ctx, $cmd, $timeout, $outfunc)`** — the locked, TERM-first,
  clamped, logged chokepoint for every host device-layer command
  ([code above](#the-host-device-command-chokepoint)). Returns `{ exitcode, out }`
  (fixed shape, per the lock design's return convention). A command that
  survived its whole termination ladder surfaces as coreutils `timeout`'s exit
  codes in `->{exitcode}`; repair is the reactivation cycle's job
  ([Stale-cookie recovery](#stale-cookie-recovery)).
- **`_multipath_cookie_sweep($ctx)`** — the probe-then-sweep of
  [Stale-cookie recovery](#stale-cookie-recovery): read-only `dmsetup udevcookies`
  probe, then age-bounded `dmsetup -y udevcomplete_all` (nothing younger than
  `MULTIPATH_COOKIE_STALE_AGE` is touched; `-y` is load-bearing — a
  declined prompt still exits 0). Called from `volume_activate`'s
  failure branch — only while the 124/137 strand signature is armed
  (finding #14), before the teardown; best-effort; returns the number
  of outstanding cookies found (diagnostic); its own commands run through
  `multipath_cmd`.
- **`_volume_activate_attempt($ctx, $vmid, $volname, $snapname,
  $content_volume_flag, $tgname, $state, $cycle)`** — one full activation
  attempt (today's `eval` body — [code above](#the-reactivation-cycle)),
  recording in `$state` the reached-stage flags, the target coordinates
  (`targetname`, `lunid`, `hosts`, `scsiid`) the teardown's inverse steps
  need, and `content_volume_flag` (so the teardown's unpublish addresses the
  right target group — follow-up #5); fetches `volume_get_size` **before
  staging** and passes it into `volume_stage_iscsi` as the expected size
  (option A, finding #23 — the backend-export health check now lives in the
  iSCSI exit contract); runs the multipath staging with
  `$verify_map` set on **every** cycle (follow-ups #7, #12 — a leftover map
  from an earlier operation is never trusted on a bare `-b`); persists the
  LUN record with the authoritative size and returns — the strict
  post-staging `lun_record_update_device` verify loop is **retired** from
  activation (option A). Returns the block devices or dies.
- **`_iscsi_capacity_ok($ctx, $path, $expected)`** — the backend-export
  capacity health check (option A, finding #23): forces a fresh READ
  CAPACITY (write the underlying `sd`'s `/sys/.../device/rescan`, untainted
  from the resolved by-id symlink) then reads `blockdev --getsize64`, and
  returns true only for a non-zero size matching `$expected` (or any
  non-zero when `$expected` is undef). Rescan-then-read is load-bearing —
  reading the cache alone could miss a broken export (finding #23,
  measured). Read-only device/sysfs ops, deliberately not under the
  `multipath` lock.
- **`_multipath_map_has_active_path($ctx, $scsiid)`** — the staging exit
  contract's acceptance probe (finding #12,
  [code above](#staging-under-the-lock)); **two-stage** (finding #21):
  a locked `multipath -ll <wwid>` read (true when a path row shows dm
  state active; group rows ignored, a `faulty` checker disqualifies), and
  — when `-ll` returns **empty but the dm node exists** — a
  `dmsetup status <wwid>` A-flag fallback that reads device-mapper's own
  table instead of the `multipathd` socket. This is not optional hardening:
  the first live multipath activation (2026-07-04) proved `multipath -ll`
  returns exit-0-empty for a healthy map while the daemon is busy
  (reconfigure / concurrent-activation load), which failed the single-stage
  probe through all four cycles. Genuine absence (no dm node) still returns
  false, so a real zombie is still rejected — negative control verified
  live. Both parses were validated against live PVE 9.1 fixtures. Used by
  the activation fast path (`$verify_map`), the driving loop's loop-top
  acceptance and settle check, and Table 3's path-evidence row.
- **`_volume_deactivate_attempt($ctx, $vmid, $volname, $snapname, $tgname,
  $state, $cycle)`** — the complete inverse of one activation attempt
  (Table 2, [code above](#the-reactivation-cycle); named for symmetry with
  `_volume_activate_attempt`), run **once per failed cycle** (finding #15 —
  the pass-retry loop of earlier drafts was unreachable), each step
  best-effort;
  its `volume_unpublish` rung — **for every volume, not only snapshots** —
  fires only when `$cycle == VOLUME_ACTIVATE_CYCLE_ATTEMPTS − 1` (the teardown
  before the final attempt) **and** `$state->{targetname}` is defined (a
  mid-publish death leaves no coordinates to probe or detach —
  finding #19) **and** `_target_foreign_sessions` reports the
  target free of foreign initiators — the two-gate rule decided in Open
  Question #1; every other pass keeps today's snapshot-only unpublish. Every
  `volume_unpublish` call receives `$state->{content_volume_flag}`, so a
  content volume unpublishes against the content target group, not the VM
  group (follow-up #5).
- **`_target_foreign_sessions($ctx, $targetname)`** — the session-evidence
  gate for the recovery detach
  ([code above](#the-recovery-detach-and-its-session-gate)): fetches the
  target's active sessions via the
  existing `target_get_sessions` (`Common.pm:1637` — jdssc
  `pool <pool> target <iqn> sessions list`,
  [`jdssc-target-sessions.md`](jdssc-target-sessions.md)), filters out the
  node's own initiator
  (`get_local_initiator_name`, `Common.pm:1673`), and returns the arrayref of
  foreign initiator names (empty → safe to detach). Initiator comparison is
  **case-insensitive** (`lc` on both sides — IQNs are case-insensitive and
  RFC 3722 prescribes lowercase; guards against case drift between what the
  node's initiator sends and what the file records). Runs through
  `joviandss_cmd` like any jdssc call — a leaf under the method locks, never
  under the `multipath` lock — bounded by `TARGET_SESSIONS_QUERY_TIMEOUT` /
  `TARGET_SESSIONS_QUERY_RETRIES` (Table 4b). The caller treats a query
  failure like a non-empty result — *no evidence, no detach* — while its
  `eval` rethrows `lock_error_fatal` errors per the fatal-error
  classification.
- **`_volume_stage_multipath($ctx, $scsiid, $sd_devnames, $attempt, $last)`** —
  a single staging round with the escalation schedule preserved from current
  code minus its `%15` del-map recovery (superseded by the cycle's
  teardown — decided) ([code above](#staging-under-the-lock)); no loops, no
  sleeps, **no acceptance** — the driver's loop-top predicate alone returns
  maps (finding #12); its `-b` short-circuits only stop escalation and its
  return value is advisory. On the final round of a real ladder (`$last` —
  suppressed for an attempts bound of 1, the verify loop's gentle repair
  round, finding #16) every escalation fires regardless of its modulo gate.

In `OpenEJovianDSS/Lock.pm`:

- **`lock_error_acquire($err)`** — true when `$err` is an acquisition
  timeout. Implementation note (2026-07-03): the internal retry-friendly
  `acquire timeout` string is normally **consumed** by
  `_cluster_lock_path`'s own retry loop — the shapes that actually escape
  to callers are `got lock request timeout` (cluster backend, acquire
  budget spent) and `can't lock file '…' - got timeout` (node backend,
  `PVE::Tools::lock_file` — the multipath class default); the helper
  matches all three. The `can't lock file` prefix is required for the node
  shape: a bare `got timeout` is `run_command`'s process-timeout die and
  must never classify as lock contention. The cycle's **contention**
  class: retried without sweep or teardown
  ([The reactivation cycle](#the-reactivation-cycle), follow-up #9).
- **`lock_deadline_remaining($ctx)`** — seconds until the nearest hold
  deadline among the locks held in `$ctx->{_held_locks}` (undef when none
  is armed); read-only on the registry. Backs the cycle's pre-cycle budget
  check (`VOLUME_ACTIVATE_CYCLE_MIN_BUDGET`, follow-up #11.3).
- **`lock_error_fatal($err)`** — true when `$err` carries
  `LOCK_FATAL_ERROR_MARKER` (substring match — outer error prefixing
  survives): a lock-machinery die that must never be swallowed by best-effort
  machinery. Today that is the two hold-enforcement dies — `refresh_locks`'s
  hold-cap overrun and `run_bounded`'s hold alarm — which gain the marker
  prefix; any future must-not-swallow lock error joins by adopting it. Used by
  every `eval` the reactivation cycle introduces (see the fatal-error
  classification in [The reactivation cycle](#the-reactivation-cycle)).
  Returns false for acquire timeouts — those report contention for a lock not
  yet held and stay retryable.

---

## Changed Functions
[Changed_Functions](#changed-functions)

In `OpenEJovianDSS/Common.pm` unless noted:

- **`volume_activate`** — becomes the reactivation loop
  ([code above](#the-reactivation-cycle)); signature unchanged; classifies
  every caught error first — **fatal** (`lock_error_fatal`) rethrows
  immediately, no sweep, no teardown; **contention** (`lock_error_acquire`)
  re-attempts without sweep or teardown; everything else runs the
  stale-cookie sweep (only while the 124/137 strand signature is armed —
  set by the attempt or re-armed by the previous teardown's own hung
  command, finding #14; isolated from earlier `$ctx` use once, before the
  loop, never per cycle) and **one** teardown pass (finding #15 —
  convergence across step failures comes from the cycles themselves).
  Passes the cycle counter into
  `_volume_deactivate_attempt` (the pass before the final cycle is the
  only one that detaches — Open Question #1; `_volume_activate_attempt`
  keeps its copy for signature symmetry — staging map re-validation runs
  every cycle since finding #12), and checks the remaining hold
  budget (`lock_deadline_remaining` vs `VOLUME_ACTIVATE_CYCLE_MIN_BUDGET`)
  before starting another cycle.
- **`volume_stage_iscsi`** — gains `$expected_size` and folds a
  **backend-export capacity check** into its exit contract (option A,
  finding #23): the device-wait loop (and the top fast path) return only
  when the by-id device is present **and** `_iscsi_capacity_ok` confirms
  the right non-zero size — a forced READ CAPACITY (rescan) then
  `blockdev --getsize64`, so a broken SCST export (wrong/zero capacity) is
  caught at the raw-LUN layer and fails the attempt into the reactivation
  cycle. Also gains explicit
  `OpenEJovianDSS::Lock::refresh_locks($ctx)` cooperation ticks — every
  login attempt and every 10th device-wait tick — closing the iSCSI half of
  [the refresh gap](#the-refresh-gap-during-staging) (follow-up #4).
- **`volume_stage_multipath`** — gains `$attempts`, `$verify_map`, and the
  **exit contract** (finding #12): acceptance — node present **and** an
  active path (`_multipath_map_has_active_path`) — lives at the driving
  loop's top (after each inter-round sleep, the path checker's grace) and
  at the settle check, so only live maps are ever returned; a top fast-path
  (bare `-b` for the direct callers — no command, no lock; under
  `$verify_map`, set by the activation flow on every cycle, the existing
  map must also show an active path or the rounds rebuild/repair it —
  follow-ups #7, #12); extracts the single-round body (commands only, no
  acceptance) and passes `$last` so the final round of a real ladder runs
  the full escalation ladder (suppressed for an attempts bound of 1 — a
  gentle repair round, finding #16); keeps
  the VPD wait — a no-op in the activation flow (`volume_stage_iscsi` already
  waits for the same symlink as its exit condition), a real guard for the
  direct callers (`block_device_path_from_lun_rec`,
  `lun_record_update_device`) — and the register-paths-first order (whose
  comment documents the production failure it prevents); whitelists once
  before the VPD wait and
  re-asserts per round via CLI `multipath -a` under the chokepoint (decided —
  the TERM-first bound covers the kill hazard; `multipathd add wwid` stays
  optional hardening); all commands via
  `multipath_cmd`; loop bounds and sleeps from the constants; the per-site
  `eval {}` wrappers go (`multipath_cmd` reports failure via exitcode; lock
  failures propagate by design).
- **`volume_unstage_multipath`** — gains the two phase-bound parameters
  ([code above](#unstaging-under-the-lock)); the `Common.pm:3730` call site drops
  its literals.
- **`_volume_unstage_multipath_wait_unused`** — becomes a single per-tick body
  (`$tick` argument, returns the wait decision; loop and sleep live in
  `volume_unstage_multipath`); missing device node now means *done* (today's
  loop keeps waiting on it); `lsof` gains `noerr` so the clean "no users" case
  stops traveling through the error branch; the blocker warning is tick-gated;
  no public/private duplication.
- **`_volume_unstage_multipath_remove_device`** — becomes a single removal
  round (`$round` argument; loop and deferred fallback live in
  `volume_unstage_multipath`); command sequence unchanged, all via
  `multipath_cmd`; the deferred fallback's exit code now backs the caller's
  die, and a device gone by the fallback probe counts as removed (today's
  code misreads that as failure).
- **`lun_record_update_device`** — gains the trailing `$strict`: strict
  hard-fails verification on exhaustion (Table 3); lenient (default) keeps
  today's warn-and-return (follow-up #6). **Since option A (finding #23)
  the activation flow no longer calls this** — size verification moved to
  `volume_stage_iscsi` and the redundant path re-check is dropped; the sole
  remaining caller is the lenient `volume_update_size` resize flow. The
  function is otherwise unchanged: verification evidence is size
  **plus**, for multipath devices, an active path
  (`_multipath_map_has_active_path` — size alone cannot expose a
  dead-but-intact map, finding #12); its embedded map re-stage passes
  an attempts bound of **1** (the verify loop owns the retry cadence; the
  bound also suppresses the final-round escalation blast — finding #16 —
  and the call is eval-wrapped, so its die is a round failure, not a
  lenient-caller abort);
  `udevadm trigger -t all` replaced by the WWID-scoped trigger;
  `multipath reconfigure` corrected to `multipathd reconfigure`, gated to every
  5th round (Open Question #3 — decided); commands via
  `multipath_cmd`; loop bounds and sleeps from the constants. Its
  `$scsiid` (from the on-disk LUN record) is **untainted once via
  `safe_word`** at the top of the loop before it is used in argv
  (`udevadm ID_SERIAL`, the `-ll`/`dmsetup status` probe) or the
  `/dev/mapper` path (implementation, 2026-07-03 — the new direct uses the
  design added would otherwise exec-die on a tainted value). See findings
  #21/#22 in *Device verification* for the field diagnosis that the
  strict-path rescan/reconfigure churn is redundant with staging and is
  what blinds the path probe — a deferred simplification, made non-fatal
  by the probe's `dmsetup` fallback.
- **`get_device_mapper_name` / `_multipathd_map_exists` /
  `_dmsetup_device_exists`** — read-side probes move onto `multipath_cmd` (custom
  `$outfunc` for line parsing); logic unchanged. One implementation delta
  (2026-07-03): the chokepoint's fixed errfunc logs stderr at error level,
  where `_dmsetup_device_exists` previously suppressed the expected
  "device not found" chatter during removal polling — log noise only; an
  optional errfunc parameter on `multipath_cmd` is the fix if field logs
  prove bothersome.
- **`target_get_sessions`** — its jdssc invocation becomes
  `['pool', $pool, 'target', $targetname, 'sessions', 'list']`
  (`Common.pm:1652` — the pre-fix form omitted the `pool <pool>` prefix,
  which jdssc's CLI rejects, and the verb moves to the dedicated `sessions list`
  subcommand, [`jdssc-target-sessions.md`](jdssc-target-sessions.md)), and
  its `118, 5` bound literals give way to `TARGET_SESSIONS_QUERY_TIMEOUT` /
  `TARGET_SESSIONS_QUERY_RETRIES` (Table 4b), and the target name is
  **untainted** via `safe_word` (it arrives from parsed jdssc
  output — tainted under `-T`; an unsanitized exec dies and the gate would
  misread it as a permanently failed query — the `volume_unpublish` taint
  lesson, commit `5367fe8`; `safe_word`'s class covers every legal iSCSI
  name character: `a–z 0–9 . - :`; the pool needs nothing — `get_pool`
  untaints internally). Output parsing unchanged; the
  new `_target_foreign_sessions` gate depends on this fix. **Shipped
  2026-07-03** with the jdssc session-listing implementation.
- **`volume_deactivate_by_lun_record`** — its unstage call drops its ignored
  literals for the constants' defaults (today's effective bounds —
  finding #17); its own 3-attempt structure is untouched (non-goal).
- **`lock_properties()`** — gains the four `multipath_lock_*` property definitions
  (`type` enum `node`/`cluster`, `path`, `acquire_timeout`, `hold_timeout`),
  following the jdssc-class schema exactly.
- **`OpenEJovianDSSPlugin.pm` `options()`** — lists the four `multipath_lock_*`
  names. The NFS plugin does **not** list them (it never stages multipath; its
  `properties()` stays `{}` per the SectionConfig single-declaration rule).
- **`OpenEJovianDSS/Lock.pm`** — timeout value changes
  (`LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT`, `LOCK_CLASS_VM_HOLD_TIMEOUT`,
  `LOCK_CLASS_STORAGE_HOLD_TIMEOUT` — Table 4b); the two hold-enforcement
  dies (`refresh_locks` hold-cap overrun, `run_bounded` hold alarm) gain the
  `LOCK_FATAL_ERROR_MARKER` prefix; new `lock_error_fatal`,
  `lock_error_acquire` and `lock_deadline_remaining` helpers
  ([New Functions](#new-functions)). Otherwise structurally unchanged — the
  class shipped fully wired.

---

## Obsolete Functions
[Obsolete_Functions](#obsolete-functions)

None removed. The draft's duplicated
`volume_unstage_multipath_wait_unused` / `_volume_unstage_multipath_wait_unused`
pair collapses into the one per-tick private function (the loop lives in
`volume_unstage_multipath`) before it ever lands.

---

## Relationship to the draft
[Relationship_to_the_draft](#relationship-to-the-draft)

The raw code draft that previously occupied this file (copy: the untracked
`OpenEJovianDSS/multipath.pm`) prototyped the shape this design adopts —
single-round stage body + driving loop, parameterized unstage bounds — and is
**superseded by this document**. Known defects in it, all resolved by the specs
above rather than carried forward: a stale `$1` where the sanitized `$scsiid` is
meant; undeclared `$mpath` / `$clean_scsiid`; the duplicated wait-unused pair with
nested 60-tick loops; `$attempts` parameters accepted but shadowed by hardcoded
bounds; per-command timeout literals (now the
named timeout tiers of Table 4a); and the dropped VPD wait / register-paths-first
steps (both kept — register-paths-first for the under-load failure its comment
documents, the VPD wait as the direct callers' guard; in the activation flow it
is a no-op, see [Staging under the lock](#staging-under-the-lock)). Two draft
items that read as residue were intent, and both are adopted: the
`$last` parameter, unread in the draft body, becomes the final-round
full-escalation rule (real ladders only — an attempts bound of 1 stays a
gentle repair round, finding #16); and the draft's dropped `%15` del-map
recovery stays
dropped — the reactivation cycle's teardown supersedes it
([Staging under the lock](#staging-under-the-lock)). The scratch file is
deleted once implementation lands (Table 6).

---

## Relationship to Other Designs
[Relationship_to_Other_Designs](#relationship-to-other-designs)

- [`multi-layer-lock-design.md`](multi-layer-lock-design.md) — supplies the
  primitive: `with_lock`, the reserved `multipath` class, the leaf rule (its Open
  Question #1a), the hold-cap machinery, and the refresh brackets this design turns
  into staging-wide cooperation points. With this design's implementation
  (2026-07-03) its Table 3 `multipath` row flipped *reserved → active* and its
  Table 9b timeout values updated (the `multipath` acquire and the
  `vm`/`storage` hold rows — Table 4b), matching the shipped `Lock.pm`
  values. This design also marks that document's
  two hold-enforcement dies with `LOCK_FATAL_ERROR_MARKER` and adds
  `lock_error_fatal`, so the reactivation cycle's best-effort machinery can
  never absorb a hold-cap breach (the fatal-error classification in
  [The reactivation cycle](#the-reactivation-cycle)).
- [`cluster-lock-storage-design.md`](cluster-lock-storage-design.md) — the method
  locks the reactivation cycle runs under; the cycle budget is sized against their
  hold cap.
- [`jdssc-target-sessions.md`](jdssc-target-sessions.md) — makes the session
  query behind `_target_foreign_sessions` real: adds the dedicated
  `pool <pool> target <iqn> sessions list` subcommand over the per-target
  sessions endpoint (live-verified 2026-07-03; jdssc's REST and driver
  layers needed no change), and pins the output contract
  `target_get_sessions` parses. This design's detach gate fails safe
  (*no evidence, no detach*) until that one lands.
- [`volume-activation-review-followups.md`](volume-activation-review-followups.md)
  — the critical review's decision record (2026-07-03): findings 1–3 were
  resolved in the first round (session-gated recovery detach, fatal-error
  classification), findings 4–11 in the second (refresh ticks in
  `volume_stage_iscsi`, `content_volume_flag` through `$state`,
  strict/lenient verification, `$verify_map`, the signature-gated sweep, the
  contention class, the backstop margin, and the minor items), findings
  12–20 in the third (the staging exit contract with loop-top acceptance
  and `$verify_map` on every activation cycle, the strict-verification
  wiring and Table 3's path-evidence row, the strand-flag lifecycle, the
  single teardown pass, the gentle verify re-stage, unstage defaults
  preserving today's effective bounds, the contract's exception
  end-states, and the minors) — all folded
  into this document, with pointers there.
- `ISSUES.md` Issue 2 — the production hang this design's serialization +
  TERM-first bounding closes structurally; its fix note's SIGTERM claim is
  corrected by the finding in [The multipath semaphore](#the-multipath-semaphore).

---

## Risks & Backward Compatibility
[Risks_and_Backward_Compatibility](#risks--backward-compatibility)

### Preserved (low risk)

- **Public plugin behavior on success is unchanged** — same signatures, same return
  shapes, same lock nesting (`method → jdssc | multipath`, all component locks
  leaves).
- **The proven staging/unstaging sequences are preserved** — teardown logs out
  iSCSI before touching multipath (the resurrection hazard), staging keeps the VPD
  wait and register-paths-first order, removal keeps its escalation ladder and
  deferred-removal fallback.

### Risks

1. **The recovery detach (decided — Open Question #1, session-gated).** The
   teardown before the final activation cycle detaches the volume from its
   target (`volume_unpublish`) — for every volume, not only snapshots — where
   today activation failure never detaches non-snapshot volumes. The hazard —
   detaching a target a live-migration source is still using kills storage
   under the running source VM — is guarded by **two gates**: the rung fires
   only after `VOLUME_ACTIVATE_CYCLE_ATTEMPTS − 1` consecutive failed cycles,
   and only when `_target_foreign_sessions` shows **no foreign initiator** on
   the target (a failed query counts as foreign — no evidence, no detach; the
   skip is warned loudly with the initiators named). **Accepted residual:**
   the session check is point-in-time — a session appearing between the query
   and the `targets delete` slips through (a one-jdssc-call-wide window) —
   and initiator comparison assumes per-node-unique IQNs (the Proxmox
   default). The continuous session of a live-migration source is reliably
   caught; the cycle-position argument (three consecutive failures most
   likely mean the migration fails and the VM terminates anyway) remains as
   defense-in-depth.
2. **Verification hard-fail surfaces previously-silent successes.** Deployments
   that unknowingly ran on stale-size devices will now see loud activation failures
   (with recovery attempts) where they saw none. Desirable, but a visible behavior
   change.
3. **Serialized host-device commands add latency under parallel activations.** A
   node activating many volumes at once serializes their multipath commands; each
   hold is one command (bounded by the termination ladder), and the sleeps are
   outside the lock, so queues drain steadily — but a storm of activations is
   slower than today's free-for-all. That is the safety trade the lock class exists
   to make, and `multipath_lock_type` remains the operator's knob. A lost
   acquire race costs only a teardown-free re-attempt (the **contention**
   class), so contention never amplifies itself into logout/republish churn.
4. **A stranded semaphore is still possible, just much less likely — and now
   self-limiting.** SIGTERM bounding removes the routine SIGKILL path, but
   `run_command`'s last-resort kill (and OOM, and crashes) can still strand it.
   Difference from today: the commands are serialized (no concurrent pile-up),
   each later command fails loudly at its own bound instead of hanging forever,
   and the cycle's sweep — once per failed attempt while the 124/137
   strand signature is armed, before its teardown — completes the verified-stale
   cookie within minutes
   ([Stale-cookie recovery](#stale-cookie-recovery)) — where today the node stays
   broken until an operator intervenes. Residuals: a sweep firing while the
   strand is younger than `MULTIPATH_COOKIE_STALE_AGE` repairs nothing *yet*
   (that activation fails loud and a later sweep completes the cookie), and
   hangs outside an activation cycle — a standalone deactivation, a direct
   resolution flow — get no automatic sweep: they fail loud at their command
   bounds, and the next activation's sweep repairs the node.
5. **Longer worst-case activation.** Cycles multiply worst-case latency; bounded by
   the budget and, ultimately, the `vm` hold deadline (fail loud). PVE task
   timeouts see minutes-scale activations in the pathological case — the same order
   as today's 60-round stage loop. The deadline actually terminates the cycle:
   hold-cap dies are classified fatal and rethrown, never absorbed as attempt
   failures (the fatal-error classification in
   [The reactivation cycle](#the-reactivation-cycle)).
6. **A fatal lock error leaves stack residue behind.** On the fatal path the
   cycle rethrows without running the teardown — deliberately: teardown steps
   touch shared state, and a hold-cap breach means the locks protecting them
   can no longer be trusted (running them is the co-activation race). Whatever
   the attempt had built — session, map, records — stays; the next activation
   rebuilds or fast-paths over it, and a standalone `volume_deactivate` clears
   it manually. Both fail loud if the residue blocks them. The milder
   cousins — a final cycle failing as contention (no teardown ran) and a
   pre-cycle budget stop after the pre-final teardown (volume left
   detached) — are named in the cycle-completion contract (finding #18).
7. **Rolling upgrade.** The `multipath` lock is new — an un-upgraded node simply
   does not take it. The lock is node-scoped, so there is no cross-node exclusion
   to lose during a mixed-version window; on the un-upgraded node itself, commands
   simply stay unserialized until it upgrades. No path or name collides with
   anything an old node uses.

---

## Files That Would Change (when implemented)
[Files_That_Would_Change](#files-that-would-change-when-implemented)

*Implemented 2026-07-03 — every row below has landed.*

**Table 6 — Files that would change** · `tbl_files_changed`

| File | Change |
|---|---|
| `OpenEJovianDSS/Common.pm` | add `multipath_cmd` (with strand-signature recording) + the new constants (Table 4b); route every Table 1 site through it; restructure `volume_activate` into the reactivation cycle (`_volume_activate_attempt` / `_volume_deactivate_attempt`, three-way error classification, signature-gated sweep, pre-cycle budget check); refresh ticks in `volume_stage_iscsi`; **option A (finding #23): fold the backend-export capacity check into `volume_stage_iscsi` (new `_iscsi_capacity_ok`, `$expected_size` param) and drop the strict `lun_record_update_device` call from `_volume_activate_attempt`** — `lun_record_update_device` keeps its strict/lenient verification (targeted udev trigger, corrected reconfigure, single-round embedded re-stage) for the lenient `volume_update_size` caller only; parameterize stage/unstage (`volume_stage_multipath` + `$verify_map` + `_multipath_map_has_active_path`, extracted `_volume_stage_multipath`, `volume_unstage_multipath` + both private phases); drop the `Common.pm:3730` literals; carry `content_volume_flag` through `$state` (and fix the same latent bug at `Common.pm:3881`); add `_multipath_cookie_sweep` (age-bounded `dmsetup -y udevcomplete_all`, signature-gated); add `_target_foreign_sessions` (session-evidence gate for the recovery detach; its `target_get_sessions` backing **shipped** with `jdssc-target-sessions.md`); extend `lock_properties()` with the `multipath_lock_*` schema |
| `OpenEJovianDSS/Lock.pm` | timeout value changes: `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT`, `LOCK_CLASS_VM_HOLD_TIMEOUT`, `LOCK_CLASS_STORAGE_HOLD_TIMEOUT` (Table 4b); `LOCK_FATAL_ERROR_MARKER` prefixed to the `refresh_locks` / `run_bounded` hold-enforcement dies; new `lock_error_fatal`, `lock_error_acquire`, `lock_deadline_remaining` helpers |
| `OpenEJovianDSSPlugin.pm` | add the four `multipath_lock_*` names to `options()` |
| `OpenEJovianDSSNFSPlugin.pm` | no change (no multipath staging; the schema is registered once by the iSCSI plugin) |
| `docs/design/multi-layer-lock-design.md` | Table 3 `multipath` row *reserved → active*; Table 9b value updates (`multipath` acquire **and** the `vm`/`storage` hold rows — finding #20); pointer to this document |
| `ISSUES.md` | correct the Issue 2 fix note (`run_command` kills with SIGKILL, not SIGTERM; the TERM-first bound now lives in `multipath_cmd`) |
| `OpenEJovianDSS/multipath.pm` | **deleted** — scratch draft superseded by this document |
| `docs/design/volume-activation-with-reactivation.md` | this document (replaced the raw draft) |
