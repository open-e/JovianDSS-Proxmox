# Multi-Layer Lock — Design Document (ACCEPTED)

> **Status: accepted (2026-07-02) — implemented (2026-07-02), pending cluster
> verification.** All open questions are resolved and the naming, constants, and
> timeout ladder are signed off; see [Open Questions](#open-questions) for the decision
> record. The lock is **implemented** on branch `rollback-semaphor` — every Table 11
> row and every finding landed; see [Implementation Notes](#implementation-notes) for
> what was built, how it was verified, and the deltas decided during implementation.
> The NFS prerequisite had already landed: the credential unification and the full
> `$ctx` threading of the `NFSCommon` snapshot/mount helpers (the fresh-`$ctx`
> `NFSCommon::joviandss_cmd` wrapper is retired), so one `$ctx` threads from
> each NFS method through to `Common::joviandss_cmd`.
>
> This document specifies a **scope-typed lock primitive** (`with_lock`) and, built on
> it, a configurable **jdssc execution lock** taken around every `jdssc` invocation,
> shared by the iSCSI and NFS plugins. "Multi-layer" because the same primitive backs
> several nested layers: the existing per-VM / per-storage *method* locks (outer) and
> the new jdssc lock (inner), with a single registry, refresh, and re-entry guard
> across all of them.

## Table of Contents

- [Problem_Statement](#problem-statement)
- [Background_and_Research](#background-and-research)
  - [The_locks_that_exist_today](#the-locks-that-exist-today)
  - [The_two_lock_backends](#the-two-lock-backends)
  - [The_single_chokepoint](#the-single-chokepoint)
  - [Constraints_and_failure_modes](#constraints-and-failure-modes)
- [Project_Values](#project-values)
- [Options_Considered](#options-considered)
- [Recommended_Solution](#recommended-solution)
  - [The_layered_lock_model](#the-layered-lock-model)
  - [The_lock_API](#the-lock-api)
  - [Method_locks_are_just_classes](#method-locks-are-just-classes)
  - [Locking_configuration](#locking-configuration)
  - [Where_and_how_it_is_acquired](#where-and-how-it-is-acquired)
  - [Lock_refresh_keep_alive](#lock-refresh-keep-alive)
  - [Lock_release](#lock-release)
  - [Re_entrancy_and_deadlock](#re-entrancy-and-deadlock)
  - [Execution_alarm_and_refresh_interaction](#execution-alarm-and-refresh-interaction)
  - [Timeout_and_retry](#timeout-and-retry)
  - [Cluster_backend_poll_loop](#cluster-backend-poll-loop)
  - [Error_propagation](#error-propagation)
  - [Performance_trade_off](#performance-trade-off)
  - [Why_these_choices_rationale](#why-these-choices-rationale)
- [Open_Questions](#open-questions)
- [Function_Signature_Change](#function-signature-change)
- [New_Constants](#new-constants)
- [New_Functions](#new-functions)
- [Obsolete_Functions](#obsolete-functions)
- [Relationship_to_Other_Designs](#relationship-to-other-designs)
- [Risks_and_Backward_Compatibility](#risks--backward-compatibility)
- [Files_That_Would_Change](#files-that-would-change-when-implemented)
- [Implementation_Notes](#implementation-notes)
- [List_of_Tables](#list-of-tables)

## List of Tables
[List_of_Tables](#list-of-tables)

Each table carries a unique `tbl_*` tag, repeated verbatim in its caption. In vim, put
the cursor on a tag below and press `*` (or `#`) to jump straight to the table — and press
it again on the caption tag to jump back.

1. `tbl_lock_backends` — **Lock backends**: pmxcfs `mkdir` vs node `flock` — mechanism, reach, waitability, expiry.
2. `tbl_lock_scopes` — **Lock scopes**: what each of `vm`/`storage`/`node`/`cluster` serializes, its concurrency and backend.
3. `tbl_lock_classes` — **Lock classes**: what each class (`jdssc_general`/`jdssc_info`/`multipath`/`vm`/`storage`) protects and where it is taken.
4. `tbl_scope_resolution` — **Scope-to-path resolution**: how `_lock_resolve` maps a scope to `(backend, lock path)`.
5. `tbl_lock_properties` — **Per-class lock properties**: the four `<class>_lock_*` `storage.cfg` options.
6. `tbl_lock_defaults` — **Per-class lock defaults**: default scope, backend and lock path per class, split by shared/non-shared where it matters (timeouts follow the `LOCK_CLASS_<CLASS>_*` pattern).
7. `tbl_refresh_by_backend` — **Refresh behavior by backend**: what `refresh_locks` does per held-lock backend.
8. `tbl_throughput` — **Scope throughput trade-off**: throughput impact of each jdssc-lock scope.
9. `tbl_constants_desc` — **Constant descriptions** (Table 9a): every constant this design introduces — what it is for. `tbl_constants_values` — **Constant values** (Table 9b): value · denomination · location, the single point of truth for values.
10. `tbl_constants_related` — **Related existing constants**: pre-existing constants for context.
11. `tbl_files_changed` — **Files that would change**: files touched when implemented.

---

## Problem Statement
[Problem_Statement](#problem-statement)

**What's wrong.** The plugin drives external components that are **not safe to call
concurrently** — concurrent access provokes races and failures *inside those
components*, not in the plugin's own Perl. Two are known today:

- **The JovianDSS REST API**, reached by every `jdssc` invocation. Two `jdssc`
  processes touching the same backend object at once collide inside JovianDSS (a
  shared iSCSI target group, a snapshot/clone chain). The Python-side iSCSI-target
  lock that used to serialize this was removed — it made log rotation hard to implement
  on the Python side (commented out in `rest.py`) — so nothing guards it now.
- **The host `multipath` service.** Concurrent `multipath` invocations contend on a
  single system-wide device map and a Linux IPC semaphore; a killed holder can leave
  that semaphore stuck, hanging every later `multipath` call — a known hazard on this
  plugin (it caused a live-migration hang; see `ISSUES.md`).

The plugin's existing per-VM / per-storage *method* locks are the wrong tool: they
scope concurrency to a Proxmox VM or storeid (so `vm-101` and `vm-102` proceed in
parallel — correct for *Proxmox* operations) but do nothing to serialize access to
these shared, unreliable components underneath.

**Desired behavior change.** A **flexible locking mechanism** that serializes access to
non-concurrency-safe components — preventing the races *inside* them — and that can be
**extended to isolate further components or services** as they are identified. Each
lock's reach must be **operator-configurable**, because the right scope depends on the
component and the deployment: one may need cluster-wide exclusion, another only
per-node.

**What success looks like.**
- Access to each unreliable component is serialized at a chosen scope, so concurrent
  callers **wait rather than collide**. The first two applications are the REST API
  (via `jdssc`) and the `multipath` service.
- The serialization is **one general, well-tested mechanism** that any component reuses
  by naming a scope — not a bespoke lock grown per component.
- The scope is **operator-tunable** (`node` / `cluster` for the component locks) with a
  safe default.
- The existing method locks keep their per-VM / per-storage **behavior**, folded into
  the same `with_lock` entry, with **one deliberate change**: the `vm` lock is keyed by
  the **vmid alone** — one lock per VM cluster-wide, where today's cluster lock name also
  embeds the storeid (decided; see
  [Method locks are just classes](#method-locks-are-just-classes)). Their call sites
  migrate onto the single entry (the deliberate trade in value #4).

**Non-goals (explicitly not solving here).**
- **Cross-Proxmox-cluster serialization.** Under `cluster_prefix`, several Proxmox
  clusters can share one JovianDSS pool; no lock scope here serializes across them
  (see [Constraints](#constraints-and-failure-modes)). That protection, if needed,
  belongs on the JovianDSS side.
- **The `multipath` integration itself.** This document designs the *mechanism* and
  reserves a scope for `multipath`; wiring the actual `multipath` calls through it is a
  separate follow-up.
- **A new low-level lock backend.** The two existing backends — pmxcfs `mkdir` and node
  `flock`, both already in production — are reused unchanged; we do not invent a new
  lock primitive. (This is *not* "just a parameterized entry point": the `Lock.pm`
  *layer* over those backends is reworked — a new scope-typed entry point is added, the
  method-lock functions are removed (their call sites migrate to the entry), and the
  keep-alive / name-building helpers are reworked or retired. That rework is in scope;
  see [Recommended Solution](#recommended-solution).)

---

## Background and Research
[Background_and_Research](#background-and-research)

A reader who does not live in this code should be able to follow the rest of the
document from here.

### The locks that exist today
[The_locks_that_exist_today](#the-locks-that-exist-today)

The JovianDSS plugins serialize work with **per-VM** (and fallback **per-storage**)
*method* locks, described in
[`cluster-lock-storage-design.md`](cluster-lock-storage-design.md). A method such as
`alloc_image` is wrapped by `_alloc_image_lock`, which takes a `lock_vm` lock for the
whole method. These locks scope concurrency to a Proxmox VM or storeid — they answer
"may these two *Proxmox operations* run at once" — and say nothing about the `jdssc`
processes underneath.

### The two lock backends
[The_two_lock_backends](#the-two-lock-backends)

`OpenEJovianDSS/Lock.pm` already implements two lock backends; this design adds no
third:

**Table 1 — Lock backends** · `tbl_lock_backends`

| Backend | Mechanism | Reach | Waitable? | Expiry |
|---|---|---|---|---|
| **pmxcfs** | `mkdir` a directory under `/etc/pve/priv/lock/` | whole Proxmox cluster | **no** — must poll | **120 s idle** (`CFS_LOCK_TIMEOUT`) |
| **flock** | `flock(LOCK_EX)` on a file under `/run/lock/` | one physical node | yes — kernel blocks/wakes | never (held by an open fd) |

> **Verified on `pve-91-1`:** `PVE::Tools::lock_file($file, $timeout, $code, …)`
> (`Tools.pm:272`) is `lock_file_full($file, $timeout, 0, …)` — `$shared = 0` →
> `flock(LOCK_EX)` (`Tools.pm:201,206`). `_cluster_lock_attempt($ctx, $lockdir,
> $lockpath, $lockid, …)` (`Lock.pm:83`) already takes an **explicit `$lockpath`**.

pmxcfs locks survive across nodes but expire if not refreshed; `flock` locks are
node-local but free automatically on fd close or process death. Today the keep-alive
is `touch_cluster_lock` / `_active_locks`, which **assume** a cluster (pmxcfs) lock is
held — a mismatch once a held lock might be `flock`.

### The single chokepoint
[The_single_chokepoint](#the-single-chokepoint)

Every `jdssc` call from **both** plugins funnels through
`OpenEJovianDSS::Common::joviandss_cmd` (`Common.pm:850`), now called directly on the
caller's threaded `$ctx` — the NFS-side `NFSCommon::joviandss_cmd` wrapper that used
to build a fresh `$ctx` has been retired, and the `NFSCommon` helper layer is fully
`$ctx`-threaded (see
[Password Resolution Through `$ctx`](password-resolution-through-ctx.md)). Wrapping
that one function therefore covers both plugins on one threaded `$ctx`.

### Constraints and failure modes
[Constraints_and_failure_modes](#constraints-and-failure-modes)

- **pmxcfs is not waitable.** There is no blocking primitive and no reliable wakeup
  (inotify on the FUSE mount is not dependable across nodes), so a cluster lock
  *must* poll. Each `mkdir`/`utime` goes through FUSE and can involve corosync
  round-trips, so a tight poll loop is expensive **cluster-wide**, not just locally.
- **Stale-lock reclaim is waiter-driven.** pmxcfs only reclaims a lock from a crashed
  holder when a *waiter* calls `utime(mtime=0)` **and** the lock has been idle >
  `CFS_LOCK_TIMEOUT`.
  A `flock` from a crashed holder needs no cleanup — the kernel drops it on death.
- **Locks are non-reentrant.** A second pmxcfs `mkdir` on a held directory polls
  until timeout; a `flock` re-taken on a new fd by the same process blocks forever.
- **Cross-cluster blind spot.** pmxcfs is scoped to one Proxmox cluster; nothing here
  serializes separate Proxmox clusters sharing a pool via `cluster_prefix`.

---

## Project Values
[Project_Values](#project-values)

In priority order — these decide the tradeoffs below:

1. **Component safety / correctness first.** The default must make concurrent access to
   an unreliable component (the REST API, `multipath`) impossible, and lock bugs must
   **fail loud** rather than silently deadlock or corrupt.
2. **Operator-tunable performance.** Deployments differ; the operator — not the code
   — should choose how much concurrency to trade for safety, with a safe default.
3. **One reusable mechanism.** A single, well-tested scope-typed primitive beats
   several ad-hoc locks that each re-derive paths, refresh, and cleanup.
4. **Uniformity over churn-avoidance.** One lock entry, with each lock's scope a
   property keyed on its name — no scope baked into a function name, and a new component
   added by configuration, not code. We accept migrating the existing method-lock call
   sites to that single entry as the price.
5. **Robustness under failure.** Acquire/refresh/release must be exception-safe — a
   dying `jdssc` run must never leave a lock un-released or un-refreshed.

---

## Options Considered
[Options_Considered](#options-considered)

**Option A — Rely on the (removed) Python REST-level lock.** Let `jdssc` serialize
itself inside the REST layer, as it used to. *Rejected:* the Python REST-level locking
is what makes **log rotation hard to implement on the Python (`jdssc`) side**, and it
was removed for exactly that reason. Moving serialization up into the Perl plugin (this
design) is what frees the Python side to rotate logs cleanly — so reviving the REST
lock would bring the log-rotation problem straight back. (It also only guarded the REST
path — not `multipath` or other host-side work — and could not be tuned per
deployment.)

**Option B — One fixed cluster-wide lock around `jdssc`.** Always take a single
pmxcfs lock for every `jdssc` run. *Honest tradeoff:* maximal safety and minimal code,
but worst-case throughput (all `jdssc` everywhere serialized, including unrelated
pools and nodes) with **no** operator control — violates value #2. It is, however,
exactly the *default* behavior of Option C.

**Option C — A configurable, scope-typed lock primitive (chosen).** One function,
`with_lock($ctx, $lock_class, $id, …)`, takes only the lock **class** (plus a separate
id for id-keyed classes), reads its scope from a **property** (`<class>_lock_type`),
derives the backend + path, and runs a code block under an exclusive lock. Every lock is a caller: `with_lock($ctx, 'jdssc_general', …)` /
`with_lock($ctx, 'jdssc_info', …)` (scope from `jdssc_general_lock_type` /
`jdssc_info_lock_type`), `with_lock($ctx, 'vm', $vmid, …)` for the method locks, a future
`with_lock($ctx, 'multipath', …)`. No scope is baked into a
function name, and adding a component is configuration, not code. *Tradeoff:* more
moving parts than Option B (a resolver, a re-entry guard, backend-agnostic refresh),
and it migrates the existing method-lock call sites onto the one entry — but it
satisfies values #2, #3, and #4 and folds every lock into the same machinery.

We considered, and rejected, **ad-hoc per-purpose locks** (a jdssc lock here, a
multipath lock there, each with its own path-building and refresh): it duplicates the
hard parts (poll loop, stale reclaim, exception-safe release) and drifts — directly
against value #3.

---

## Recommended Solution
[Recommended_Solution](#recommended-solution)

**Option C.** Build the scope-typed primitive `with_lock` over the two existing
backends, route the new jdssc lock and the existing method locks through it, and wrap
the single `jdssc` chokepoint with it. The rationale is collected in
[Why these choices](#why-these-choices-rationale); the mechanics follow.

### The layered lock model
[The_layered_lock_model](#the-layered-lock-model)

The jdssc execution lock is **orthogonal to** and **nested inside** the existing
method locks:

```
_method_lock wrapper (e.g. _alloc_image_lock)            [OUTER]
  └─ with_lock($ctx, 'vm', $vmid, …)        method lock, held for the whole method
        └─ _alloc_image
              └─ joviandss_cmd(...)           (called possibly several times)
                    └─ with_lock($ctx, $lock_class, …)   ← NEW, INNER, held only around
                          └─ run_command(/usr/local/bin/jdssc ...)   one jdssc run
```

Locks differ in **scope** — the set of operations that serialize together. The
primitive names the scope directly. From most concurrent (narrowest) to least:

**Table 2 — Lock scopes** · `tbl_lock_scopes`

| Scope | Serializes | Concurrency | Backend |
|---|---|---|---|
| **vm** | operations on the same VM | highest — different VMs run in parallel | pmxcfs (shared storage) / `flock` (non-shared) |
| **storage** | operations on the same storeid | high — different storeids run in parallel | pmxcfs (shared storage) / `flock` (non-shared) |
| **node** | everything sharing this lock on **one physical PVE server** | medium — one per server, servers run in parallel | node-local `flock` |
| **cluster** | everything sharing this lock **anywhere in the cluster** | lowest — one at a time, cluster-wide | pmxcfs `mkdir` |

A **class** is the other axis: the value passed as `$lock_class` to `with_lock` (`vm`,
`storage`, `jdssc_general`, …), plus an optional `$id` sub-key for id-keyed classes
(`vm` + the vmid). It keys the `<class>_lock_*` properties and names *what* a lock protects
— as opposed to a scope, which says how wide it reaches. `vm` and `storage` name both a
class and its default scope.

**Table 3 — Lock classes** · `tbl_lock_classes`

| Class | Protects / serializes | Where the lock is taken | Default scope | Status |
|---|---|---|---|---|
| `jdssc_general` | JovianDSS REST API — jdssc commands that must serialize **cluster-wide** | inside `joviandss_cmd`, for cluster-scoped commands | `cluster` | planned |
| `jdssc_info` | JovianDSS REST API — jdssc commands safe to serialize **per host only** | inside `joviandss_cmd`, for node-scoped commands | `node` | planned |
| `multipath` | the host `multipath` service (system-wide device map + semaphore) | inside `multipath_cmd`, around each single `multipath` / `multipathd` / `udevadm` / `dmsetup` invocation | `node` | **active** — wired by [`volume-activation-with-reactivation.md`](volume-activation-with-reactivation.md) (implemented 2026-07-03) |
| `vm` | operations on one VM (per-vmid method lock) | method wrappers, `with_lock($ctx, 'vm', $vmid, …)` | `vm` | existing |
| `storage` | operations on one storeid (per-storage method lock) | method wrappers, `with_lock($ctx, 'storage', undef, …)` | `storage` | existing |

**`jdssc_general` vs `jdssc_info`.** Not every jdssc command needs cluster-wide exclusion.
Rather than one `jdssc` lock whose scope is chosen per call, `joviandss_cmd` selects the lock
**class** per command: host-safe commands take `jdssc_info` (cheap — node-local `flock`, no
corosync), while commands that mutate shared backend state take `jdssc_general`. The two are
different lock **names** — hence different paths — so they do **not** serialize against each
other; every command needing cluster-wide exclusion must therefore use `jdssc_general`.
`joviandss_cmd` takes a `$lock_class` argument (default `jdssc_general`) and passes it
straight to `with_lock` (see
[Where and how it is acquired](#where-and-how-it-is-acquired)); each tier is tuned
independently via `jdssc_general_lock_type` / `jdssc_info_lock_type`.

Each jdssc lock class's scope follows its own `<class>_lock_type` (`jdssc_general` →
`cluster`, `jdssc_info` → `node` by default). The method locks — `with_lock($ctx, 'vm', $vmid, …)` /
`with_lock($ctx, 'storage', undef, …)`, scope `vm` / `storage` — remain the **outer** locks;
the jdssc lock is always the **inner** one, taken inside `joviandss_cmd`.
Because everything funnels through `with_lock` → `_lock_exec`, *all* locks — method
and jdssc — share one `_held_locks` registry, refresh, and re-entry guard.

Since the jdssc lock is always innermost and only ever taken from inside
`joviandss_cmd` (a leaf), the ordering is fixed and cannot invert:

```
method lock (vm / storage)  →  jdssc lock (jdssc_info / jdssc_general)
```

### The lock API
[The_lock_API](#the-lock-api)

`with_lock` is the **single public entry point**. The caller passes the lock **class**
(and, for id-keyed classes, a separate **id**); the scope is read from a per-class
property, so no lock encodes its mechanism in a function name and adding a component is
configuration, not code:

```perl
# with_lock($ctx, $lock_class, $id, $timeout, $code, @param)
#   $lock_class  the lock class: 'jdssc_general' | 'jdssc_info' | 'multipath' | 'vm' | 'storage'
#   $id          sub-key within the class (the vmid for 'vm'); undef for singleton classes
#   $timeout     seconds, or undef → <lock_class>_lock_acquire_timeout → per-class default
#   $code        coderef run while the lock is held (every held lock is auto-refreshed
#                around it via run_refreshed — the caller never refreshes manually)
#   @param       trailing args forwarded to $code
# All locks are exclusive. Returns the result of $code; dies on failure (acquisition or $code).
sub with_lock {
    my ($ctx, $lock_class, $id, $timeout, $code, @param) = @_;
    die "unknown lock class '$lock_class'\n"                            # fail loud — the
        if !exists LOCK_DEFAULT_TYPE->{$lock_class};                    # maps have no fallbacks
    my $type     = get_lock_class_type($ctx, $lock_class);              # scope
    $timeout   //= get_lock_class_acquire_timeout($ctx, $lock_class);   # wait-to-acquire, per class
    my $max_hold = get_lock_class_hold_timeout($ctx, $lock_class);      # hold cap (alarm + deadline)
    my ($backend, $path) = _lock_resolve($ctx, $type, $lock_class, $id);   # dir override applied inside
    return _lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param);
}
```

**Scope is a property, keyed by the lock's *class*** — passed directly, not parsed out of
a name. The `<class>_lock_type` property gives the scope; a per-class default applies when
the operator sets nothing. The class itself is validated **up front**: `with_lock` dies on
a `$lock_class` without a `LOCK_DEFAULT_TYPE` row — a typo'd or half-added class fails
loud at first use instead of silently running under a mis-tuned fallback:

```perl
# Every per-class value is a FLAT, individually named constant — greppable,
# referenceable directly, compile-time checked where used by name. Their VALUES are
# specified in ONE place only: Table 9b in [New Constants](#new-constants), the single
# point of truth. This block shows the shape — one constant per class × attribute:
#
#   use constant LOCK_CLASS_<CLASS>_DEFAULT_TYPE    => <scope,   per Table 9b>;
#   use constant LOCK_CLASS_<CLASS>_ACQUIRE_TIMEOUT => <seconds, per Table 9b>;
#   use constant LOCK_CLASS_<CLASS>_HOLD_TIMEOUT    => <seconds, per Table 9b>;
#
# for <CLASS> ∈ JDSSC_GENERAL, JDSSC_INFO, MULTIPATH, VM, STORAGE.

# class-key → constant wiring, used by the getters for runtime dispatch. The maps exist
# because the class arrives as a runtime variable and needs a lookup — they define NO
# values, only reference the flat constants. LOCK_DEFAULT_TYPE's key set doubles as the
# valid-class list (with_lock dies on any other key):
use constant LOCK_DEFAULT_TYPE => {
    jdssc_general => LOCK_CLASS_JDSSC_GENERAL_DEFAULT_TYPE,
    jdssc_info    => LOCK_CLASS_JDSSC_INFO_DEFAULT_TYPE,
    multipath     => LOCK_CLASS_MULTIPATH_DEFAULT_TYPE,
    vm            => LOCK_CLASS_VM_DEFAULT_TYPE,
    storage       => LOCK_CLASS_STORAGE_DEFAULT_TYPE,
};
use constant LOCK_CLASS_ACQUIRE_TIMEOUT => {
    jdssc_general => LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT,
    # ... one wiring row per class, same pattern ...
};
use constant LOCK_CLASS_HOLD_TIMEOUT => {
    jdssc_general => LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT,
    # ... one wiring row per class, same pattern ...
};

# Explicit lock-class property names — NO runtime "${class}_lock_*" key building. Every
# storage.cfg property a class understands is spelled out here, so each name is greppable and
# adding a class is a deliberate row, not a key conjured from string interpolation.
use constant LOCK_CLASS_PROPERTY => {
    jdssc_general => { type => 'jdssc_general_lock_type', dir => 'jdssc_general_lock_path',
                       acquire => 'jdssc_general_lock_acquire_timeout', hold => 'jdssc_general_lock_hold_timeout' },
    jdssc_info    => { type => 'jdssc_info_lock_type',    dir => 'jdssc_info_lock_path',
                       acquire => 'jdssc_info_lock_acquire_timeout',    hold => 'jdssc_info_lock_hold_timeout' },
    multipath     => { type => 'multipath_lock_type',     dir => 'multipath_lock_path',
                       acquire => 'multipath_lock_acquire_timeout',     hold => 'multipath_lock_hold_timeout' },
    vm            => { type => 'vm_lock_type',            dir => 'vm_lock_path',
                       acquire => 'vm_lock_acquire_timeout',            hold => 'vm_lock_hold_timeout' },
    storage       => { type => 'storage_lock_type',       dir => 'storage_lock_path',
                       acquire => 'storage_lock_acquire_timeout',       hold => 'storage_lock_hold_timeout' },
};

# Read a class's explicit scfg property for one attribute (undef if the class declares
# none). Two-step lookup on purpose: a one-step ->{$lock_class}{$attr} on an unknown
# class would AUTOVIVIFY an empty hash inside the shared LOCK_CLASS_PROPERTY constant.
sub _lock_class_scfg {
    my ($ctx, $lock_class, $attr) = @_;

    my $props = LOCK_CLASS_PROPERTY->{$lock_class} or return undef;
    my $prop  = $props->{$attr}                    or return undef;

    return $ctx->{scfg}{$prop};
}

# Each getter resolves one attribute for a class: the operator's explicit
# <class>_lock_<attr> override from storage.cfg (looked up by literal name via
# LOCK_CLASS_PROPERTY), else the class's flat default constant via the wiring map.
# No trailing global fallbacks: with_lock has already validated the class against
# LOCK_DEFAULT_TYPE, and the LOCK_* maps are key-complete by invariant
# (unit-testable: identical key sets across all the maps).

sub get_lock_class_type {
    my ($ctx, $lock_class) = @_;

    my $type = _lock_class_scfg($ctx, $lock_class, 'type')
            // LOCK_DEFAULT_TYPE->{$lock_class};

    # 'vm' / 'storage' are structural to their namesake classes (the class id keys
    # the lock name); component classes accept 'node' / 'cluster' only.
    die "invalid ${lock_class}_lock_type '$type'\n"
        unless $type eq 'node' || $type eq 'cluster' || $type eq $lock_class;

    return $type;
}

sub get_lock_class_dir {
    my ($ctx, $lock_class) = @_;

    return _lock_class_scfg($ctx, $lock_class, 'dir');    # undef → backend default dir
}

sub get_lock_class_acquire_timeout {
    my ($ctx, $lock_class) = @_;

    return _lock_class_scfg($ctx, $lock_class, 'acquire')
        // LOCK_CLASS_ACQUIRE_TIMEOUT->{$lock_class};
}

sub get_lock_class_hold_timeout {
    my ($ctx, $lock_class) = @_;

    return _lock_class_scfg($ctx, $lock_class, 'hold')
        // LOCK_CLASS_HOLD_TIMEOUT->{$lock_class};
}
```

**Allowed types are per-class.** The `vm` / `storage` scopes are structural to their
namesake classes — it is the class's **id** (vmid / storeid) that keys the lock name, so
a *component* class set to `storage` would still resolve to one class-named path, not a
per-storeid lock. `get_lock_class_type` therefore validates the operator's value: the
component classes (`jdssc_general` / `jdssc_info` / `multipath`) accept `node` /
`cluster` only, and an invalid `<class>_lock_type` dies loudly.

`_lock_resolve` is the one place that maps the resolved `(scope, class, id)` → `(backend,
path)` — composing the lockid from the class plus the optional id:

```perl
sub _lock_resolve {
    my ($ctx, $type, $lock_class, $id) = @_;

    # id-keyed classes: 'vm' is keyed by the vmid (passed as $id); 'storage' by the storeid
    # (intrinsic to $ctx). Singleton classes (jdssc_general/jdssc_info/multipath) have no id.
    my $key  = $lock_class eq 'storage' ? $ctx->{storeid} : $id;
    # Sanitize the id before it becomes a filename component: trim + strip non-ascii,
    # then whitelist-validate (dies on forbidden symbols). Reuses the existing
    # Common::clean_word / Common::safe_word helpers rather than a bespoke sanitizer.
    $key     = OpenEJovianDSS::Common::safe_word(
                   OpenEJovianDSS::Common::clean_word($key), "lock id") if defined $key;
    my $name = defined $key ? "joviandss-lock-${lock_class}-${key}"
                            : "joviandss-lock-${lock_class}";

    # Directory is set by the resolved backend; node = this host's local /run/lock tmpfs
    # (already per-PVE-server), cluster = pmxcfs, non-shared vm/storage = the storage's own dir.
    my ($backend, $default_dir) =
          $type eq 'node'    ? ('node',    '/run/lock')
        : $type eq 'cluster' ? ('cluster', _cluster_lockdir())                # /etc/pve/priv/lock
        : get_shared($ctx)   ? ('cluster', _cluster_lockdir())                # vm/storage on shared storage
        :                      ('node',    get_path($ctx) . '/private/lock'); # vm/storage on non-shared

    my $dir = get_lock_class_dir($ctx, $lock_class) // $default_dir;          # <class>_lock_path override (a DIR)
    return ($backend, "$dir/$name");
}
```

**Table 4 — Scope-to-path resolution** · `tbl_scope_resolution`

Filename is always `joviandss-lock-<class>` (+ `-<id>` for id-keyed classes: `vm` → vmid,
`storage` → storeid). The directory is set by the resolved backend (or the
`<class>_lock_path` directory override):

| resolved scope | backend | directory · resulting lock path |
|---|---|---|
| `cluster` | pmxcfs `mkdir` | `/etc/pve/priv/lock/` · `/etc/pve/priv/lock/joviandss-lock-<class>[-<id>]` |
| `node` | `flock` (always) | `/run/lock/` (host-local, one per PVE server) · `/run/lock/joviandss-lock-<class>[-<id>]` |
| `vm` / `storage` | pmxcfs if `get_shared($ctx)` else `flock` | shared → `/etc/pve/priv/lock/…` · non-shared → `<path>/private/lock/…` (filename e.g. `joviandss-lock-vm-101`, `joviandss-lock-storage-<storeid>`) |

`_lock_exec` is the private mechanism — the **phase sequencer** (refactored
2026-07-05; see the delta record in [Implementation Notes](#implementation-notes)).
Two nested brackets, each with a single owner: OUTER bookkeeping
(`_lock_ctx_commission` → `_lock_ctx_decommission`, the latter a never-dying
finalizer that runs on every path) and INNER ownership (`_lock_acquire` →
`_lock_divest` — divest runs explicitly for both anticipated outcomes, success
and body death, so the finalizer's divest branch stays a pure anomaly
tripwire). All timing policy is frozen into the registry record at commission;
every later phase reads the record and is never handed a number. The caller
never caps or refreshes anything itself — taking the lock *is* what caps and
refreshes:

```perl
# _lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param)  — exclusive only.
sub _lock_exec {
    my ($ctx, $backend, $path, $timeout, $max_hold, $code, @param) = @_;

    # registry + re-entry guard; commissioned = registered, NOT owned
    my $lock_id = _lock_ctx_commission($ctx, $backend, $path, $timeout, $max_hold);

    my $res;
    my $ok = eval {
        # the backend flips owned=1 at the instant of mkdir/flock success, so
        # ANY later die in this eval — the id cross-check, a signal landing
        # between acquire and run_bounded's alarm suspension, cfs_update,
        # the body, a hold-cap death — routes through the one divest below
        my $lock_id_acquired = _lock_acquire($ctx, $lock_id);
        Carp::confess( "LOCK BUG: acquired '" . ( $lock_id_acquired // 'undef' )
                     . "' != commissioned '$lock_id'" )
            if !defined($lock_id_acquired) || $lock_id_acquired ne $lock_id;

        $res = run_bounded($ctx, $lock_id,
                 sub { run_refreshed($ctx, $code, @param) });
        1;
    };
    my $err = $@;                        # capture BEFORE divest can clobber $@

    # Unconditional: the ONE release site for every outcome. The owned-guard
    # inside is load-bearing — after a failed acquisition it is a no-op, and
    # it must be (the lock dir/flock belongs to the CURRENT holder).
    _lock_divest($ctx, $lock_id);

    _lock_ctx_decommission($ctx, $lock_id);   # FINALIZER — never dies; a divest
                                              # in there means an impossible path

    die $err if !$ok;
    return $res;        # single scalar/ref — see "Return convention" below
}
```

The path walk: **success** → commission, acquire, body, divest, decommission.
**Acquire failure** → never owned; divest is a no-op by the owned-guard (it
must be — the lock belongs to the current holder); decommission removes the
record; the acquisition error propagates natively — acquisition and body
errors can never be confused, because acquisition errors originate in a frame
where no body has ever run (this removes the old `_cluster_lock_path` retry
wrapper's `$@`-regex classification and the body-re-run hazard it carried).
**Body / hold-cap death, id-mismatch confess, or a stray signal anywhere
after ownership** → the same unconditional divest releases, then rethrow —
the finalizer stays silent on all of these. Its divest branch is reachable
only through the one irreducible residual: a die landing on the single
assignment between the backend's syscall succeeding and the `owned` flip
(accepted; stale reclaim / process death back it up).

The hold cap is enforced by **two cooperating mechanisms** driven by the one per-class
value (resolution of Open question #2), both reading the **record** frozen at
commission. `run_bounded` is the **pure-Perl-hang backstop**: once the lock is held it
arms a `SIGALRM` for the record's `alarm_cap` (the class cap, ceilinged on the cluster
backend at commission), and if un-suspended Perl execution overruns it aborts with a
`die`, so the lock releases on unwind — `fd` close for node, `rmdir` for cluster.
Nested alarm users (`run_command`'s inline save/restore in `PVE::Cmd::run`, and
`run_with_timeout` under the node acquire wait) *suspend* that alarm, so its reach is
exactly the hang class safe signals can catch: a Perl loop or hang outside any command.
The **wall-clock** bound is the companion **deadline check**: `_lock_acquire` records
`time() + max_hold` on the record as its final act, and `refresh_locks` dies when any
owned lock is past its deadline — enforced at every cooperation point (before and after
each jdssc run, and each poll-loop iteration), i.e. between commands, never
mid-command. On the **cluster** backend the alarm cap is **ceilinged at
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`** regardless of the class cap — even `0`
(Finding #15): a wedged pure-Perl holder reaches no cooperation point, so only the
alarm can stop it, and on pmxcfs it must die before a waiter could stale-reclaim at
`CFS_LOCK_TIMEOUT`. Together they bound a hung-but-alive holder, which the node `flock`
backend otherwise cannot break (flock has no idle expiry):

```perl
# run_bounded($ctx, $lock_id, $code, @param) — pure-Perl-hang backstop for the section
# holding $lock_id: the alarm cap AND the diagnostic label are read from the record
# (alarm_cap 0 → no alarm section; no cap/record skew is possible). Overrun → die
# (naming the lock) → lock releases on unwind. Nested alarm users (run_command,
# run_with_timeout waits) suspend this alarm — the wall-clock hold bound is the
# deadline check in refresh_locks, not this.
#
# The alarm budget is SINCE THE LAST COOPERATION POINT, not since acquisition (re-arm
# delta, 2026-07-05; registry-derived since the acquire/divest refactor): every
# refresh_locks re-arms the innermost armed section — the LAST registry record that is
# owned with a nonzero alarm_cap — because a refresh proves the holder is not wedged
# and has just utime'd every owned cluster dir, so the alarm and the stale-reclaim
# clocks restart from the same epoch. On exit the ENCLOSING armed section (same
# derivation, excluding the exiting id — its record is still owned at that instant) is
# re-armed to its full cap: exiting a section is a cooperation point, and restoring the
# remainder frozen at entry would leave the outer alarm stale-depleted after a long,
# cooperative inner section. With no enclosing section, the suspended foreign alarm
# (e.g. PVE core's own run_with_timeout) is restored untouched. Sections nest in
# commission order because _lock_exec is run_bounded's sole caller — a load-bearing
# invariant.
#
# Deliberately NO kill here: this wrapper owns no process (a runaway jdssc is killed by
# run_command's own timeout — kill(9) in PVE::Cmd::run); its enforcement is the die,
# whose unwind is what releases the lock.
sub run_bounded {
    my ($ctx, $lock_id, $code, @param) = @_;
    my $lock = _lock_record($ctx, $lock_id)
        or Carp::confess("LOCK BUG: run_bounded('$lock_id') without a commissioned record");
    my $cap = $lock->{alarm_cap};
    return $code->(@param) unless $cap;
    my $prev = alarm(0);                 # suspend any outer/foreign alarm
    my $res;
    my $ok = eval {
        local $SIG{ALRM} =
            sub { die "lock '$lock_id' hold exceeded ${cap}s — aborting to release it\n" };
        alarm($cap);
        $res = $code->(@param);
        alarm(0);
        1;
    };
    my $err = $@;
    alarm(0);
    my $enclosing = _lock_alarm_innermost($ctx, $lock_id);
    if    ($enclosing) { alarm( $enclosing->{alarm_cap} ) }  # exit = cooperation point
    elsif ($prev)      { alarm($prev) }                      # foreign alarm untouched
    die $err if !$ok;
    return $res;
}
```

Because the holder releases **its own** lock, this is **race-free** — unlike a waiter-side
"delete the stale lock file and recreate it," which swaps the inode under a still-live
holder and lets two processes hold the lock at once (never do that; it defeats the lock).
The cap is per class via `<class>_lock_hold_timeout` (default: the class's flat
`LOCK_CLASS_<CLASS>_HOLD_TIMEOUT` constant); the one value drives **both** the alarm and
the deadline. **Division of labor and
caveats:** a body wedged **inside** a single external command is reached by *neither*
mechanism until that command returns — that window belongs to `run_command`'s own kill
(`timeout + 1`), and the ultimate backstop remains process death (kernel flock release,
pmxcfs stale reclaim). The alarm catches pure-Perl hangs (safe signals are delivered
between opcodes, so a Perl loop is reachable; an uninterruptible syscall is not). The
deadline catches a hold that runs long **across** commands — the case the alarm
structurally cannot see, because every nested alarm user suspends it. One
accepted sharp edge (fail-loud, value #1): a deadline can expire just after useful work
completed, failing the operation at the post-run check even though its last command
succeeded — the same trade any hold cap makes.

Acquisition itself is one function pair (acquire/divest refactor, 2026-07-05 —
decision record in [Implementation Notes](#implementation-notes)):
**`_lock_acquire($ctx, $lock_id)`** looks up the commissioned record (confess
without one — an unregistered cluster lock would never be refreshed), runs a
`refresh_locks($ctx)` **cooperation point** — a wait the enclosing hold budget has
already outlived dies before it starts, with the true hold-cap fatal rather than a
doomed wait's disguised contention error, and the node backend enters its blind
kernel block with every outer clock freshly reset — then dispatches to
`_lock_acquire_cluster` (the pmxcfs `mkdir` poll loop with deadline accounting,
stale-poke, held-outer-lock refresh, jittered backoff, quorum check, and
`cfs_update`) or `_lock_acquire_node` (exclusive `flock(LOCK_EX)` taken directly,
bounded by `PVE::Tools::run_with_timeout`) — each of which flips `owned=1` at the
instant its syscall succeeds, so any later die routes through the sequencer's
unconditional divest — then arms the deadline. It **dies on any failure** with a
canonical error — cluster:
`joviandss-lock '<id>' error: got lock request timeout` (deliberately not the
literal "got timeout": cluster contention stays out of `joviandss_cmd`'s
timeout-retry class); node: `can't lock file '<path>' - got timeout` (the exact
shape `lock_error_acquire` always matched, now emitted by our own code instead of
depended on in PVE's). **`_lock_divest($ctx, $lock_id)`** ends ownership — an
alarm-guarded `rmdir` (`LOCK_DIVEST_GUARD_TIMEOUT`: a wedged FUSE call must not
hang the unwind) or an fh close — never dies, and is idempotent via the record's
`owned` flag. `PVE::Tools::lock_file` is no longer used: it is a run-callback
wrapper that cannot express a separable acquire, its per-PID re-entry counter is
unreachable behind our guard, and its internal 10 s timeout default is unreachable
behind `with_lock`'s per-class resolution. Path construction still lives only in
`_lock_resolve` — callers pass a **class + id**, never a path or a scope. The old
hardcoded 119 s execution alarm of the retired `_cluster_lock_attempt` remains
superseded by the cluster-backend alarm ceiling (Finding #15).

#### Return convention — a locked block returns a fixed shape, never `wantarray`

The lock brackets (`run_bounded` → `run_refreshed`) invoke the block in **scalar
context** (`$res = eval { $code->(@param) }`). Any list a block returns is therefore
collapsed to a single value before the caller sees it — so a
`wantarray ? @res : $res[0]` in `_lock_exec` / `run_refreshed` would advertise a list
contract the machinery cannot honor (it could only ever yield one element). The lock
primitives consequently pass a **single scalar straight through** (`return $res`) and do
**not** branch on `wantarray`.

**Rule for callers:** a block executed under the lock must return a **fixed shape** — a
single scalar, or a **reference** (arrayref/hashref) when it needs to hand back several
values — and must not rely on `wantarray`. The caller unpacks the reference after
`with_lock` returns. This is the same convention the codebase applies to internal `_`
helpers and `Common` / `Lock` functions generally: they return a fixed shape, and only
the **top-level** PVE-facing method organizes `wantarray`. The reference example is
`path` → `_path`: `_path` returns a fixed `[$path, $vmid, $vtype]` arrayref (no
`wantarray`), and the public `path` maps it onto PVE's `wantarray` contract. The same
discipline keeps any future locked block safe from silent list-to-scalar collapse.

**Every lock is just a class.** There is no per-lock function (`lock_jdssc`, `lock_vm`,
`lock_storage` all go away); the same entry serves all of them, scope coming from the
class's `<class>_lock_type` property:

```perl
with_lock($ctx, 'vm',            $vmid, $t, $code);   # method lock — scope from vm_lock_type (default 'vm')
with_lock($ctx, 'storage',       undef, $t, $code);   # method lock — scope from storage_lock_type
with_lock($ctx, 'jdssc_general', undef, $t, $code);   # REST/jdssc  — scope from jdssc_general_lock_type (cluster)
with_lock($ctx, 'jdssc_info',    undef, $t, $code);   # REST/jdssc  — scope from jdssc_info_lock_type (node)
with_lock($ctx, 'multipath',     undef, $t, $code);   # multipath   — scope from multipath_lock_type (default node)
```

For example, with `jdssc_general_lock_type` unset, `with_lock($ctx, 'jdssc_general', …)`
resolves to a cluster `mkdir` lock at `/etc/pve/priv/lock/joviandss-lock-jdssc_general`,
while `with_lock($ctx, 'jdssc_info', …)` resolves to `/run/lock/joviandss-lock-jdssc_info`
— host-local, so it serializes only jdssc on that Proxmox node. A `<class>_lock_path`
property overrides just the path (the backend still follows the type).

### Method locks are just classes
[Method_locks_are_just_classes](#method-locks-are-just-classes)

There are **no dedicated method-lock functions**. The per-VM and per-storage locks are
ordinary `with_lock` calls keyed by class + id — `with_lock($ctx, 'vm', $vmid, …)` and
`with_lock($ctx, 'storage', undef, …)` — whose scope defaults to `vm` / `storage` (the
shared-dependent backend) via `LOCK_DEFAULT_TYPE`, and which an operator can retune
with `vm_lock_type` / `storage_lock_type` like any other lock.

**The `vm` lock is per-vmid, storage-independent (decided).** `_lock_resolve` keys the
`vm` class by the vmid alone — `joviandss-lock-vm-<vmid>` — whereas today's cluster
method lock also embeds the storeid (`joviandss-<storeid>-vm-<vmid>`, `Lock.pm:176`).
One VM therefore has **one** lock cluster-wide: concurrent operations on the same VM
serialize even when they target different JovianDSS storages. (On non-shared storage the
lock file lives under the storage's own `<path>/private/lock`, so the reach stays
per-storage there — unchanged.) The `storage` class keeps its storeid key
(`joviandss-lock-storage-<storeid>`) and is unaffected.

This **removes `lock_vm` / `lock_storage`** (and there is no `lock_jdssc` to begin with):
the ~42 existing method-lock call sites **migrate** to `with_lock`. That migration is the deliberate
cost of a single, uniform, property-driven entry — no lock hides its scope in a
function name (see [Function Signature Change](#function-signature-change)).

So **every** lock — method, jdssc, multipath — flows through `with_lock` →
`_lock_exec`, registering in `_held_locks`, passing the re-entry guard, with one
uniform refresh/release.

### Locking configuration
[Locking_configuration](#locking-configuration)

A lock's scope (and optional path / timeout) is operator-tunable through **per-class
`storage.cfg` properties**; all are optional, and **leaving everything unset yields the
safe defaults below**, so an upgraded site behaves identically until an operator opts in.

**Options.** Each lock *class* accepts the same four properties. This design only
*declares* the `jdssc_general_lock_*` / `jdssc_info_lock_*` property sets (so they are settable
today). The generic getters resolve any class through the **explicit `LOCK_CLASS_PROPERTY`
map** (class + attribute → literal property name — no `"${class}_lock_*"` string building),
so a class becomes settable once (a) its four property names are listed in
`LOCK_CLASS_PROPERTY` and (b) the properties are declared in the `storage.cfg` schema. Both
are one-line additions per class — **no new resolution logic**.

**Table 5 — Per-class lock properties** · `tbl_lock_properties`

| Property pattern | Values | Purpose |
|---|---|---|
| `<class>_lock_type` | component classes (`jdssc_general` / `jdssc_info` / `multipath`): `node` \| `cluster` · method classes: additionally their structural `vm` / `storage` | scope/backend of the class's lock |
| `<class>_lock_path` | absolute **directory** | override the lock *directory* (**must match the chosen type's backend**); the filename `joviandss-lock-<class>[-<id>]` is still appended |
| `<class>_lock_acquire_timeout` | seconds | hard **wait-to-acquire** timeout — dies on expiry (`undef` → per-class default) |
| `<class>_lock_hold_timeout` | seconds | hard **hold** cap — enforced by `run_bounded`'s `SIGALRM` (pure-Perl hangs) and the `refresh_locks` wall-clock deadline (`undef` → per-class default; on the cluster backend the alarm is ceilinged at `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` — Finding #15) |

Classes in play: `jdssc_general` / `jdssc_info` *(declared now)*, and the
generically-honored `vm`, `storage`, `multipath`.

**Defaults** applied when a property is unset — scope, acquire wait and hold cap from the
class's flat `LOCK_CLASS_<CLASS>_*` constants (values defined once in
[New Constants](#new-constants), Table 9b), path from `_lock_resolve`. This table is a
**derived view** resolving scope, backend and path per class; the timeout pattern
follows in the note below:

**Table 6 — Per-class lock defaults** · `tbl_lock_defaults`

| Class | Default scope | Resolved backend | Default lock path |
|---|---|---|---|
| `jdssc_general` | `cluster` | pmxcfs `mkdir` | `/etc/pve/priv/lock/joviandss-lock-jdssc_general` |
| `jdssc_info` | `node` | node-local `flock` | `/run/lock/joviandss-lock-jdssc_info` |
| `multipath` | `node` | node-local `flock` | `/run/lock/joviandss-lock-multipath` |
| `vm` (id = vmid), shared storage | `vm` | pmxcfs `mkdir` | `/etc/pve/priv/lock/joviandss-lock-vm-<vmid>` |
| `vm` (id = vmid), non-shared | `vm` | node-local `flock` | `<path>/private/lock/joviandss-lock-vm-<vmid>` |
| `storage` (id = storeid), shared storage | `storage` | pmxcfs `mkdir` | `/etc/pve/priv/lock/joviandss-lock-storage-<storeid>` |
| `storage` (id = storeid), non-shared | `storage` | node-local `flock` | `<path>/private/lock/joviandss-lock-storage-<storeid>` |

Timeout defaults follow one pattern for every class: acquire wait
`LOCK_CLASS_<CLASS>_ACQUIRE_TIMEOUT`, hold cap `LOCK_CLASS_<CLASS>_HOLD_TIMEOUT`
(values: Table 9b); a cluster-backend acquisition retries until its bound, then
**dies**.

- **Unknown classes die — no global fallbacks.** `with_lock` dies on a `$lock_class`
  that is not a `LOCK_DEFAULT_TYPE` key, so a typo'd class (or one added without its map
  rows) fails loud at first use instead of silently running under a mis-tuned lock.
  Adding a class therefore means defining its flat `LOCK_CLASS_<CLASS>_*` value
  constants and wiring them into **every** `LOCK_*` map (`LOCK_DEFAULT_TYPE`,
  `LOCK_CLASS_ACQUIRE_TIMEOUT`, `LOCK_CLASS_HOLD_TIMEOUT`, `LOCK_CLASS_PROPERTY`) —
  key-set equality across the maps is a unit-testable invariant.
- **Backend timeout defaults:** the wait-to-acquire timeout comes from
  `get_lock_class_acquire_timeout($ctx, $lock_class)` for **every** class — the operator's
  `<class>_lock_acquire_timeout`, else the class's flat `LOCK_CLASS_<CLASS>_ACQUIRE_TIMEOUT`
  constant. For `jdssc_general` that is `LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT`
  (= `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX`): the acquisition-timeout retry loop waits under
  contention, then **dies** with `got lock request timeout` — bounded, not infinite. The node
  classes use `LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT` / `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT`;
  the method classes `LOCK_CLASS_VM_ACQUIRE_TIMEOUT` / `LOCK_CLASS_STORAGE_ACQUIRE_TIMEOUT`.
- A `<class>_lock_path` override changes only the path; the **backend still follows the
  type**, so the override must point at a location that backend can use (a pmxcfs path for
  `cluster`, a local path for `node`).

**Choosing a class / scope:**

- **`jdssc_general` (default)** — one jdssc at a time cluster-wide, maximum stability;
  used by state-changing commands.
- **`jdssc_info`** — cheapest (no cluster round-trips), serializes only on one host;
  used by host-safe read commands.
- The jdssc classes accept **`node` / `cluster` only** — `jdssc_general` is **one lock
  for the entire cluster**; there is no per-storage jdssc scope (the lock name carries
  no storeid, so a `storage` type could not deliver per-storeid serialization anyway —
  see *Allowed types are per-class* above). Keep `cluster` for strict backend safety.

Adding another component (e.g. `multipath`) is just its flat `LOCK_CLASS_<CLASS>_*`
value constants, their wiring rows in **each** `LOCK_*` map (`LOCK_CLASS_PROPERTY` —
the four explicit property names — plus `LOCK_DEFAULT_TYPE`,
`LOCK_CLASS_ACQUIRE_TIMEOUT`, `LOCK_CLASS_HOLD_TIMEOUT`), and the matching
`storage.cfg` schema — no new resolution logic; a class missing its rows dies loudly in
`with_lock`. The method-lock classes
(`vm` / `storage`) would take the same knobs once declared, but default to their
structural scope and are not declared here (retuning them is unusual).

`PVE::SectionConfig` registers property names **globally**: the iSCSI plugin declares
every JovianDSS property in its `properties()` (`OpenEJovianDSSPlugin.pm:143`), and the
NFS plugin's `properties()` deliberately returns `{}` — re-declaring a shared name is a
**duplicate property error** when both plugins are loaded (see the comment at
`OpenEJovianDSSNFSPlugin.pm:92–98`); a plugin only *enables* a property by listing it in
its `options()`. The lock schema follows that model: define it **once** — e.g. a
`lock_properties()` helper in `OpenEJovianDSS::Common` — splice it into the **iSCSI
plugin's** `properties()` only, and list the property names in **both** plugins'
`options()`. The values are read by the **generic** getters
`get_lock_class_type` / `get_lock_class_dir` / `get_lock_class_acquire_timeout($ctx, $lock_class)`
(each takes the class directly), following the `get_jdssc_timeout` precedent
(`Common.pm:285`).

### Where and how it is acquired
[Where_and_how_it_is_acquired](#where-and-how-it-is-acquired)

Inside `joviandss_cmd` (`Common.pm:850`) the run today is (paraphrased,
`Common.pm:938–956`):

```perl
eval {
    my $jcmd = [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ];
    OpenEJovianDSS::Lock::touch_cluster_lock($ctx);          # refresh OUTER locks
    $exitcode = run_command( $jcmd, ..., timeout => $timeout + 1, noerr => 1 );
    OpenEJovianDSS::Lock::touch_cluster_lock($ctx);
};
```

The design wraps `run_command` in the jdssc lock. `with_lock` refreshes whatever is held
around the body automatically (it applies the exception-safe `run_refreshed` internally), so
the call site is just the command closure plus a **lock class**. A new trailing `$lock_class`
argument on `joviandss_cmd` names which jdssc lock class to take; **omitting it defaults to
`jdssc_general`** (the safest), so existing callers are unchanged:

```perl
# $lock_class — which jdssc lock class to take (new trailing arg). One of:
#   'jdssc_general'  → cluster-wide serialization (state-changing commands)  [default]
#   'jdssc_info'     → per-host serialization only (host-safe read commands)
$lock_class //= 'jdssc_general';
my $jrun = sub {
    my $jcmd = [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ];
    $exitcode = run_command( $jcmd, ..., timeout => $timeout + 1, noerr => 1 );
};
eval {
    # Plain with_lock call: the class's scope comes from its <class>_lock_type
    # property (default jdssc_general → cluster, jdssc_info → node). $id and $timeout
    # are both undef here (singleton class, default acquire timeout).
    OpenEJovianDSS::Lock::with_lock($ctx, $lock_class, undef, undef, $jrun);
};
# $@ / $exitcode are then inspected by joviandss_cmd's existing retry handling, exactly
# as today — with_lock dies on any failure (acquisition or the command), so the eval's
# $@ is set; timeout-class failures retry, anything else propagates immediately.
```

**Every jdssc call is locked; only the class varies — there is no unlocked path.** A caller
whose subcommand is cheap and safe to run widely concurrent passes `$lock_class =>
'jdssc_info'`: the high-frequency read paths (`list_images` `OpenEJovianDSSPlugin.pm:1070`,
`status`, `get_identity`, `volume_size_info`) — which take **no method lock** today — take the node-scope
`jdssc_info` lock, so routine PVE stat polling serializes only against other jdssc on the
**same host** instead of paying a cluster-wide `mkdir`/corosync round-trip. State-changing
paths omit `$lock_class` and get `jdssc_general`. **Caveat:** `jdssc_info` and `jdssc_general`
are different lock **names** — hence different paths — so they do **not** serialize against
each other; a `jdssc_info` read is not blocked by a concurrent `jdssc_general` write. That is
acceptable for read-only list/size/status (a momentarily stale view self-corrects) and is why
`jdssc_info` is chosen per command, only for subcommands known to tolerate it.

- Taken **per `jdssc` invocation**, not once per method — each hold is short.
- Sits **inside** `joviandss_cmd`'s existing retry loop (`Common.pm:935`): the lock is
  taken **per single jdssc execution** (one `run_command` attempt), not once per retry
  loop — decided.
- The refresh `with_lock` applies covers **whatever** is held — the outer method lock
  *and* the inner jdssc lock — dispatching by backend. If everything held is `flock`,
  the refresh is simply a no-op.

### Lock refresh (keep-alive)
[Lock_refresh_keep_alive](#lock-refresh-keep-alive)

pmxcfs locks expire after **`CFS_LOCK_TIMEOUT`** idle; `flock` locks never expire. So refresh is
**backend-agnostic**: each held lock records how to keep it alive in
`$ctx->{_held_locks}`, and `refresh_locks` dispatches per backend. This **replaces**
the cluster-assuming `touch_cluster_lock` / `_active_locks`. `refresh_locks` also
doubles as the **wall-clock hold-cap enforcement point** (Open question #2 resolution):
each call first checks every held lock's `deadline` and dies on overrun.

`$ctx->{_held_locks}` is initialized to `[]` in `new_ctx`; one record per lock,
added by `_lock_ctx_commission` (before acquisition) and removed **by path** by
`_lock_ctx_decommission` (never a LIFO `pop` — see Finding #11). The record is the
single store every phase enriches:
`{ backend, path, acquire_timeout, max_hold, alarm_cap, owned, fh, deadline,
acquired_at }` — commission freezes the timing policy (including the
cluster-ceilinged `alarm_cap`), `_lock_acquire` flips `owned`, parks the node `fh`
and arms `deadline` as its final act, `_lock_divest` clears them. The deadline is
**never** armed at commission, which precedes the acquisition wait: arming early
would charge a contended acquisition (up to
`LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT` — several times the hold cap) against
`LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT` and kill the operation on its first
refresh. An uncapped class (`hold_timeout` 0) keeps `deadline` undef.

```perl
sub refresh_locks {
    my ($ctx, $skip_path) = @_;                      # $skip_path: the poll loop's own target
    for my $lock (@{ $ctx->{_held_locks} }) {
        next if !$lock->{owned};                     # in-flight target keeps its stale-poke;
        next if defined $skip_path && $lock->{path} eq $skip_path;   # divested: nothing to keep alive

        # Wall-clock hold cap (Open question #2 resolution (b)): every cooperation
        # point checks the deadline armed at acquisition; overrun → die → the normal
        # exception-safe unwind releases everything held.
        die "lock '$lock->{path}' held past its hold cap — aborting to release it\n"
            if $lock->{deadline} && time() > $lock->{deadline};

        if ($lock->{backend} eq 'cluster') {
            utime(undef, undef, $lock->{path});      # pmxcfs: reset the CFS_LOCK_TIMEOUT idle timer
        }
        # 'node' (flock): no-op — never expires
    }

    # Re-arm the innermost armed alarm section (see run_bounded): a refresh is
    # proof of cooperation — the wedge budget restarts from the same epoch as
    # the stale-reclaim clocks just reset above. Skipped for poll-loop calls
    # ($skip_path set): during a cluster acquisition the poll owns the alarm.
    if ( !defined $skip_path ) {
        my $inner = _lock_alarm_innermost($ctx);
        alarm( $inner->{alarm_cap} ) if $inner;
    }
}
```

`with_lock` wraps every locked body in `run_refreshed`, so the caller never invokes it
directly. It must be exception-safe — the post-refresh has to run even if the body dies,
otherwise a held lock is left un-refreshed right before the retry sleep:

```perl
sub run_refreshed {
    my ($ctx, $code, @param) = @_;
    refresh_locks($ctx);
    my $res;
    my $ok  = eval { $res = $code->(@param); 1 };
    my $err = $@;
    refresh_locks($ctx);              # guaranteed
    die $err if !$ok;
    return $res;                      # single scalar/ref — see "Return convention"
}
```

Refresh fires in **two** places: (1) `with_lock` brackets every locked body with
`run_refreshed` (above), so it fires around each `jdssc` run; and (2) once per iteration
of the **cluster poll loop** while a *nested* lock is being acquired (see
[Cluster-backend poll loop](#cluster-backend-poll-loop)). The poll-loop call passes the
in-flight path as `$skip_path`, so it refreshes only the already-held outer locks and
leaves the lock being acquired to its `utime(0,0)` stale-poke. Together they guarantee a
held lock is never left un-refreshed long enough to be reclaimed while alive.

**Table 7 — Refresh behavior by backend** · `tbl_refresh_by_backend`

| Held lock | backend | `refresh_locks` does |
|---|---|---|
| `cluster`, or `vm` / `storage` on shared storage | pmxcfs | `utime` refresh |
| `node`, or `vm` / `storage` on non-shared storage | `flock` | nothing (never expires) |

The refresh window is bounded by one `run_command` (≤ its timeout). Rather than refresh
*during* a long command (which would need a periodic timer conflicting with the execution
alarm), **`joviandss_cmd` clamps the per-call jdssc execution timeout `$timeout` — for
every call, whatever the lock class — to
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`**, so a single jdssc process — `run_command`'s
`timeout + 1` — stays under the pmxcfs `CFS_LOCK_TIMEOUT` idle expiry, leaving a safe
margin. With each hold bounded this way, the `run_refreshed` brackets `with_lock` applies
around the run keep every held lock inside that window without any mid-command refresh.
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` lives in `OpenEJovianDSS::Common` (read via
`get_proxmox_cluster_lock_timeout_max`), set below `CFS_LOCK_TIMEOUT` like
`JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX`. **Clamping centrally in `joviandss_cmd`** —
rather than editing each of the ~35 call sites — brings any over-cap literal into bounds
automatically: e.g. `list_images` passes `118` (`OpenEJovianDSSPlugin.pm:1083`), above the
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` cap, and is clamped to it (a
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX + 1` hard kill, just under `CFS_LOCK_TIMEOUT`). For
the clamp to actually bound the hold, the `+5` `process_timeout` floor
(`Common.pm:930–931`) must be dropped so `run_command` follows the clamped `$timeout`
directly — see [Finding #8](#implementation-findings-code-review--to-resolve).

### Lock release
[Lock_release](#lock-release)

Release is one function, `_lock_divest($ctx, $lock_id)` — **never dies** (it runs on
unwind paths where a die would mask the original error), **idempotent** via the
record's `owned` flag, and called from exactly two places: **unconditionally** in
`_lock_exec` after the single eval (the one release site for every outcome — the
owned-guard makes it a no-op after a failed acquisition, which is load-bearing:
the lock belongs to the current holder), and by the `_lock_ctx_decommission`
finalizer as the anomaly tripwire.

- **Cluster (pmxcfs `mkdir`):** `rmdir` of the lock directory, **alarm-guarded** by
  `LOCK_DIVEST_GUARD_TIMEOUT` — a wedged FUSE call must not hang the unwind at
  exactly the moment things are already failing; on expiry or failure the dir is
  warned about and left to the waiters' normal `utime(0,0)` stale reclaim. Because
  `refresh_locks` skips non-owned records, no refresh can ever `utime` a
  just-released directory.
- **Node (`flock`):** the fh parked in the record is closed; the kernel drops the
  lock (also on process death).

**Guarantees (both backends):**

- Released on **every** exit path — success, body die, acquisition failure (nothing
  acquired → `owned` never set → nothing to release), and even impossible paths
  (the finalizer divests anything still owned, loudly).
- Nothing held is left behind once `with_lock` returns **or dies** — `_lock_exec`
  runs `_lock_divest` and `_lock_ctx_decommission` before re-raising, so the die
  path leaks nothing. The only lingering artifact is a pmxcfs lock directory from a
  **crashed** holder, reclaimed via the stale-lock path (a waiter's `utime(0,0)`
  after `CFS_LOCK_TIMEOUT`). A crashed `flock` holder needs no cleanup.
- `_held_locks` stays in sync (record created at commission before acquisition,
  removed by path at decommission on every exit), so `refresh_locks` only ever
  touches locks this operation owns.
- **Release always frees the lock that was acquired.** The backend and path are
  frozen into the record **once, at commission**, and divest reuses those exact
  values — never recomputes. So a lock whose path depends on mutable config (a
  `vm` / `storage` lock keyed off `get_shared($ctx)`) releases correctly even if
  that input flips **shared → non-shared** mid-flight. This is what makes
  `shared`-dependent paths safe.

### Re-entrancy and deadlock
[Re_entrancy_and_deadlock](#re-entrancy-and-deadlock)

**JovianDSS locks are non-reentrant by design.** A second pmxcfs `mkdir` on a held
directory polls until timeout; a `flock` re-taken on a new fd blocks forever. Rather
than rely on either failure mode — or silently re-enter, as `PVE::Tools::lock_file`
does — **re-locking a held path is treated as a bug and dies immediately, with a
backtrace.** The guard lives in `$ctx->{_held_locks}` (the same list `refresh_locks`
uses):

```perl
use Carp ();

sub _lock_ctx_commission {
    my ($ctx, $backend, $path, $timeout, $max_hold) = @_;

    for my $lock (@{ $ctx->{_held_locks} }) {
        next if $lock->{path} ne $path;
        Carp::confess(
            "LOCK BUG: '$path' is already held — re-locking it is forbidden and "
          . "would deadlock; this must never happen, please report it to the dev "
          . "team.\n\n=== held since ===\n$lock->{acquired_at}\n"
          . "=== re-lock attempted here ===" );     # confess appends the current stack
    }

    my $alarm_cap = $max_hold;                      # resolve-and-freeze: the cluster
    if ( $backend eq 'cluster' ) {                  # ceiling is applied HERE, once
        my $ceiling = OpenEJovianDSS::Common::PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX();
        $alarm_cap = $ceiling if !$alarm_cap || $alarm_cap > $ceiling;
    }

    push @{ $ctx->{_held_locks} },
        { backend         => $backend,
          path            => $path,
          acquire_timeout => $timeout,
          max_hold        => $max_hold,
          alarm_cap       => $alarm_cap,
          owned           => 0,       # flipped by _lock_acquire
          fh              => undef,   # node backend: parked by _lock_acquire
          deadline        => undef,   # armed by _lock_acquire at ownership
          acquired_at     => Carp::longmess("commissioned '$path'") };

    return $path;    # the lock id IS the resolved path (unique per the guard)
}

sub _lock_ctx_decommission {           # the FINALIZER — never dies; a divest
    my ($ctx, $lock_id) = @_;          # here means an impossible path executed

    my $lock = _lock_record($ctx, $lock_id) or return;
    if ($lock->{owned}) {
        # warn loudly (best-effort) and release anyway
        _lock_divest($ctx, $lock_id);
    }
    @{ $ctx->{_held_locks} } =
        grep { $_->{path} ne $lock_id } @{ $ctx->{_held_locks} };
}
```

On a re-lock, `Carp::confess` prints the bug message plus **two** backtraces — where
the path was first acquired and where the re-lock was attempted — pinpointing both
ends with no reproduction guesswork. Because the method locks are now `with_lock`
calls too, the guard covers method-vs-method re-entry: any path that re-takes a lock a
nested call already holds dies loudly instead of deadlocking — a structural check in
place of the ad-hoc avoidance used today (e.g. the plugin's `cluster_lock_storage` is
kept a **no-op pass-through** specifically so PVE core's per-storage lock does not nest a
second pmxcfs `mkdir` on top of the method locks; the guard now enforces that invariant
directly rather than by convention).

Storing the guard in `$ctx` (not a process-global) unifies it with the refresh list,
at the cost of one **invariant**:

- **`$ctx` is threaded through a locked operation** — do not build a fresh `$ctx` via
  `new_ctx` while holding a lock. The operation's `$ctx` is created once at the top-level
  entry point and propagated down. The 7 helpers that previously re-`new_ctx`'d (5 of
  them under a held lock) have been fixed by the `_path` / `_find_free_diskname` split —
  see Risk #2 — so this now holds; it remains a coding rule for new helpers.

**The guard keys on path: re-acquiring an already-held path always dies.** Within one
operation `$ctx` is bound to a single storeid, so a given `(scope, class, id)` resolves to a
**fixed** path — *except* `vm`, whose `$id` (the vmid) varies. So an operation may
legitimately hold several `vm` locks at once (distinct vmids → distinct paths), e.g.
the dual-VM `clone_image` / `rename_volume` locks. What dies is re-taking a path
already held: a second `vm` lock for the **same** vmid, or a second lock of the same
`storage` / `cluster` / `node` class. Locks of *different* classes — e.g. a `storage`
method lock and the `jdssc_general` lock — are distinct paths and coexist (see
rule 2).

Ordering rules that still apply:

1. **Consistent ordering.** The jdssc lock is only ever acquired inside `joviandss_cmd`
   (a leaf); it never wraps a method-lock acquisition, so the order is always
   `method → jdssc` and cannot invert.
2. **Distinct paths.** Method and jdssc locks never share a path, so the guard never
   false-positives between them.
3. **Multiple-lock ordering.** A job holding more than one `with_lock` lock must
   acquire them in a fixed order — the dual-VM methods take the two vmids in
   **ascending** order. **Component locks (`jdssc_general` / `jdssc_info` /
   `multipath`) are leaves:** a body running under one must not take another
   `with_lock` lock, so component locks never nest inside one another and the only
   chains are `method → one component lock`; a job needing both a jdssc lock and
   another lock takes the other **outside** `joviandss_cmd`. (Resolved — Open
   question #1a.)

### Execution alarm and refresh interaction
[Execution_alarm_and_refresh_interaction](#execution-alarm-and-refresh-interaction)

(The **refresh** interaction here applies to the **cluster** backend — the node `flock`
backend has a no-op refresh — but the **hold cap** applies on **every** backend, node
included: `run_bounded` arms its `SIGALRM` and the deadline is armed regardless of
backend.)

- `_cluster_lock_attempt` suspends the outer alarm on entry (`alarm(0)`, `Lock.pm:86`)
  and restores it on exit (`Lock.pm:141`), so taking the inner jdssc lock does not let
  the outer method lock's hold-cap alarm fire while we wait for / hold it.
- While a cluster jdssc lock is held it is recorded with `backend => 'cluster'`, so the
  `refresh_locks` calls around `run_command` refresh **both** the outer method lock and
  the inner jdssc lock, keeping both inside the `CFS_LOCK_TIMEOUT` window. A `node`/`flock` entry is
  skipped — it never expires.
- The jdssc classes' hold cap must be **≥ `run_command`'s kill**
  (`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX + 1` after the Finding #8 clamp) so that neither
  the deadline check at the post-run refresh nor the alarm can fail a legitimate
  maximal-length run — and **< `CFS_LOCK_TIMEOUT`**, so the cap fires before a waiter
  could stale-reclaim. Hence the invariant (values: Table 9b):
  `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX + 1 < LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT <
  CFS_LOCK_TIMEOUT`.
- **Node acquisition alarm — verified.** `lock_file` waits inside
  `run_with_timeout($timeout, …)`, which sets a temporary `alarm`. Confirmed in the
  `pve-common` source: `run_with_timeout` saves any outer alarm on entry
  (`my $prev_alarm = alarm 0;`, `Tools.pm:139`) and restores it on exit
  (`alarm $prev_alarm;`, `Tools.pm:162`), so a `node`-scope jdssc lock taken *inside*
  an outer cluster method lock cannot let the outer hold-cap alarm fire mid-wait.
  (The restore resumes the alarm's *remaining* seconds — the inner wait does not count
  against it — which is fine: the outer pmxcfs lock is kept alive by refresh, not by
  its alarm; see Open question #1b.)
- **Hold cap (all backends — two mechanisms; Open question #2 resolved).** Once the lock
  is held, `<class>_lock_hold_timeout` is enforced twice over: `run_bounded`'s `SIGALRM`
  catches **pure-Perl** hangs (it saves/restores any outer alarm, so it nests with the
  acquisition alarms above — and, symmetrically, every nested alarm user suspends
  *it*, so it cannot fire while a command is in flight), and the **deadline check in
  `refresh_locks`** supplies the **wall-clock** bound, firing at the first cooperation
  point past expiry. On either trigger the body dies and the lock releases on unwind.
  This is what bounds a **hung-but-alive node holder** (`flock` has no idle expiry): a
  pure-Perl wedge → the alarm; a hold running long across commands → the deadline; a
  wedge inside one external command → that command's own `run_command` kill. On the
  cluster backend the alarm is ceilinged at `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`
  (Finding #15), so the pure-Perl case always dies before `CFS_LOCK_TIMEOUT`
  stale-reclaim.

### Timeout and retry
[Timeout_and_retry](#timeout-and-retry)

- **Cluster backend** (`_lock_acquire_cluster`): the acquire wait is frozen into the
  record at commission via `get_lock_class_acquire_timeout($ctx, $lock_class)` — for
  `jdssc_general` that is **`LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT`** (kept equal
  to `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX`, the named cluster-acquire bound
  that replaces the old hardcoded `max_total = 1200` — Finding #13) — and drives the
  poll loop's deadline accounting; a busy cluster waits, then **dies** with
  `got lock request timeout` once the bound is hit — a bounded wait, not an
  infinite one, raised directly by the acquire (no retry wrapper exists: since the
  acquire/divest refactor an acquisition error can never be anything else, so
  there is nothing to classify or re-attempt).
- **Node backend** (`_lock_acquire_node`): same freeze, per class —
  `LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT` / `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT`,
  `LOCK_CLASS_VM_ACQUIRE_TIMEOUT` / `LOCK_CLASS_STORAGE_ACQUIRE_TIMEOUT`
  (preserving the old `_node_lock` default — Finding #9); the `flock` wait is
  bounded by `PVE::Tools::run_with_timeout`, and there is **no fallback anywhere**:
  a caller bypassing `with_lock`'s resolution reaches `run_with_timeout` with an
  unusable bound and fails loud immediately. The short-lived `jdssc_info` locks are
  local and brief — a wait beyond `LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT` usually
  signals a stuck holder — while method locks (`vm`/`storage`) legitimately wait up
  to their much larger acquire bound. Tunable per class via
  `<class>_lock_acquire_timeout`.
- A failed acquisition is **re-raised as a die** by `_lock_exec` (it rethrows the
  backend's `$@`), so it flows into `joviandss_cmd`'s existing retry/`die` handling like
  any other error — no special-casing at the call site.

### Cluster-backend poll loop
[Cluster_backend_poll_loop](#cluster-backend-poll-loop)

Because pmxcfs is not waitable, the `_cluster_lock_attempt` poll loop should follow
these rules (the `flock` backend needs none of this — the kernel blocks the waiter):

- **The `utime(0,0,$lockpath)` poke is mandatory each iteration.** It is what lets
  pmxcfs reclaim a dead holder's lock after `CFS_LOCK_TIMEOUT`; skip it and a stale lock is
  never reclaimed. A `utime` must therefore fire well inside the `CFS_LOCK_TIMEOUT` window.
- **Refresh the already-held *outer* locks each iteration.** A long acquisition wait must
  not let a lock this `$ctx` *already holds* go stale. `_lock_ctx_commission` has pushed the
  in-flight target onto `_held_locks` before the loop starts, so each iteration also calls
  `refresh_locks($ctx, $lockpath)` — refreshing every other held lock (e.g. the outer
  method lock) to `now`, while **skipping `$lockpath`** so the target keeps its
  `utime(0,0)` stale-poke (`refresh_locks` sets mtime to `now` — the opposite of the poke
  above, so refreshing the target would defeat stale-reclaim). Without this, queuing
  behind several holders of a contended (default
  `cluster`) jdssc lock for > `CFS_LOCK_TIMEOUT` would let the outer method lock be stale-reclaimed by
  another node while it is still alive — split-brain on the method lock (Risk #7).
- **Never busy-spin.** Each `mkdir`/`utime` can involve corosync round-trips, so a
  tight loop is expensive **cluster-wide**. Keep **≥ ~100–200 ms** between attempts.
- **Jitter + linear backoff.** Today the loop uses a flat `sleep(1)`; under contention
  nodes poll in lockstep (mini thundering-herd) and a held lock keeps every node polling
  at the same rate. Fix both with **a base that grows each attempt plus random jitter**,
  all driven by named constants (no magic numbers): the base starts at
  `PROXMOX_CLUSTER_POLL_BASE_SLEEP` and rises by `PROXMOX_CLUSTER_POLL_BACKOFF_STEP` per
  iteration, capped at `PROXMOX_CLUSTER_POLL_SLEEP_CAP`, with up to
  `PROXMOX_CLUSTER_POLL_JITTER_MAX` of jitter added — so a single wait never exceeds
  `PROXMOX_CLUSTER_POLL_SLEEP_CAP + PROXMOX_CLUSTER_POLL_JITTER_MAX`, well short of the
  `CFS_LOCK_TIMEOUT` `utime` window:

  ```perl
  # Cluster poll-loop tuning — named constants (in OpenEJovianDSS::Common, alongside
  # PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX); values in Table 9b (New Constants):
  #   PROXMOX_CLUSTER_POLL_BASE_SLEEP     initial inter-poll sleep
  #   PROXMOX_CLUSTER_POLL_BACKOFF_STEP   added to the base each iteration
  #   PROXMOX_CLUSTER_POLL_JITTER_MAX     uniform jitter upper bound
  #   PROXMOX_CLUSTER_POLL_SLEEP_CAP      max base sleep
  my $base = PROXMOX_CLUSTER_POLL_BASE_SLEEP;     # local to this acquisition
  # ... inside the poll loop, after each failed mkdir + utime poke:
  select(undef, undef, undef, $base + rand(PROXMOX_CLUSTER_POLL_JITTER_MAX));
  $base += PROXMOX_CLUSTER_POLL_BACKOFF_STEP;
  $base  = PROXMOX_CLUSTER_POLL_SLEEP_CAP if $base > PROXMOX_CLUSTER_POLL_SLEEP_CAP;
  ```

  `rand(PROXMOX_CLUSTER_POLL_JITTER_MAX)` is a continuous float, so any value in the band
  can occur (0.5, 1.0, 1.2, 4.8, …) — fine granularity is what spreads contending nodes
  out (the **cheapest real win under contention**; the plugin already jitters elsewhere
  with `sleep(1 + rand(3))`).
  Early polls stay quick (low latency on the common short-hold case) while a long-held
  lock backs the loop off toward the cap, lightening cluster-wide `mkdir`/corosync load.
- **The ramp is per-acquisition — drop it once the lock is taken.** `$base` is local to
  one `with_lock` poll loop; the moment `mkdir` succeeds the loop exits and the protected
  operation runs, so the backoff is discarded, not carried forward. The next `with_lock`
  starts fresh at `PROXMOX_CLUSTER_POLL_BASE_SLEEP` — a single slow acquisition never
  penalizes the following ones.
- **Sub-second sleeps:** Perl's `sleep` is integer-only; use `Time::HiRes::sleep` or
  `select(undef, undef, undef, $frac)`.

### Error propagation
[Error_propagation](#error-propagation)

`with_lock` **dies on any failure** — it never returns a failure silently — so the
caller needs only one `eval`. Since the acquire/divest refactor there is nothing to
normalize: every phase **dies natively** in its own frame.

- **Acquisition errors** originate in `_lock_acquire_*`, where no caller code has
  ever run — machinery errors are prefixed (`joviandss-lock '<id>' error: …`),
  quorum loss is mapped to `no quorum!`, and `PVE::Exception` objects are re-raised
  as-is. No undef+`$@` convention, no `die $@ if $@` bridges, and no possibility of
  confusing an acquisition error with a body error (the old `_cluster_lock_path`
  wrapper's `$@`-regex retry filter — and the body-re-run hazard it carried — is
  gone with the wrapper).
- **Body errors** propagate through `_lock_exec`'s inner eval, after the explicit
  `_lock_divest`; hold-cap deaths carry `LOCK_FATAL_ERROR_MARKER`.
- **Release never contributes errors**: `_lock_divest` and the decommission
  finalizer are never-dying by contract — a failure there is warned, not thrown,
  because it would otherwise mask the original error mid-unwind.

Either way `with_lock` dies, so `joviandss_cmd`'s existing `eval` inside its retry loop
catches it and inspects `$@`/exit code — retrying or, once retries are exhausted, dying,
exactly as today. The lock is always released before the error propagates.

### Performance trade-off
[Performance_trade_off](#performance-trade-off)

**Table 8 — Scope throughput trade-off** · `tbl_throughput`

| Type | Throughput impact |
|---|---|
| `cluster` | strongest — all `jdssc` serializes cluster-wide, including different pools and nodes |
| `node` | lightest — only same-host `jdssc` serializes; cluster-wide concurrency preserved |

These are the only two types the jdssc classes accept (see *Allowed types are
per-class* under [The lock API](#the-lock-api)); the method classes' `vm` / `storage`
parallelism comes from the class id in the lock name, not from a jdssc-tunable scope.

The method locks still keep Perl-side method work parallel; the jdssc lock only
serializes the brief windows where `jdssc` actually runs. The `cluster` default trades
throughput for stability; operators who hit a bottleneck can step down.

### Why these choices (rationale)
[Why_these_choices_rationale](#why-these-choices-rationale)

Each decision traces to a [project value](#project-values); disagree with a value and
the conclusion shifts:

- **Default `cluster`** ← *value #1 (safety first)*. The out-of-the-box behavior makes
  a backend collision impossible. An operator who values throughput over absolute
  safety (weakening value #1) would set `node`.
- **Configurable scope at all** ← *value #2 (operator-tunable)*. If we did not value
  per-deployment tuning, Option B (one fixed cluster lock) would be simpler and
  sufficient.
- **One `with_lock` primitive, method locks folded in** ← *value #3 (one mechanism)*.
  If we tolerated duplication, ad-hoc per-purpose locks would avoid the resolver and
  the unified registry.
- **Scope is a property, not a function name; one entry for everything** ← *value #4
  (uniformity)*. No lock encodes its scope in its name; `lock_vm` / `lock_storage` are
  removed (and no `lock_jdssc` is introduced), and the ~42 method-lock call sites migrate
  to `with_lock`. The churn is the accepted price of one uniform, config-driven entry.
- **Fail-fast re-entry guard + exception-safe refresh/release** ← *values #1 and #5*.
  A re-lock dies loudly instead of deadlocking; a dying `jdssc` run never leaks a lock.

---

## Open Questions
[Open_Questions](#open-questions)

1. **Lock nesting correctness — resolved.**
   (a) **Component locks are leaves.** A body running under a component lock
   (`jdssc_general` / `jdssc_info` / `multipath`) must not take another `with_lock`
   lock. The jdssc classes already satisfy this structurally (taken only around
   `run_command` inside `joviandss_cmd`); the same rule binds the future `multipath`
   caller — wrap only the bare `multipath` invocation, never a code path that calls
   `joviandss_cmd`. So the only multi-lock chains are
   `method (vm / storage) → one component lock`, component locks never nest inside one
   another, and no ordering conflict between them can arise (Re-entrancy rule 3 now
   states this as the invariant).
   (b) **Verified in the `pve-common` source** (`src/PVE/Tools.pm`):
   `run_with_timeout` saves any outer alarm on entry (`my $prev_alarm = alarm 0;`,
   `Tools.pm:139`) and restores it on exit (`alarm $prev_alarm;`, `Tools.pm:162`) —
   the same convention `_cluster_lock_attempt` uses. One caveat: `alarm` restores the
   outer alarm with its **remaining** seconds, so wall-clock time spent waiting for the
   inner node lock does not count against the outer hold-cap alarm. That is acceptable:
   what actually protects the outer *pmxcfs* lock is refresh (`run_refreshed` brackets
   plus the poll-loop refresh), and the inner node wait is itself bounded
   (by `LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT` — far under `CFS_LOCK_TIMEOUT`).

2. **`run_bounded` hold cap vs nested alarm suspension — resolved: (a) + (b), folded
   into the design above.** The problem: every nested alarm user **suspends** the
   hold-cap alarm — `run_command` (`PVE::Cmd::run`) saves it inline on entry
   (`$oldtimeout = alarm($timeout)`, `Cmd.pm:198`) and re-arms it only on exit
   (`alarm($oldtimeout)`, `Cmd.pm:311`), and `lock_file`'s acquisition wait does the
   same via `run_with_timeout` (`Tools.pm:139`/`:162`) — so the hold-cap `SIGALRM`
   cannot fire while a command is in flight and measures only *un-suspended* pure-Perl
   time — never wall-clock hold. (One nuance: `Cmd.pm` restores the alarm *before* its
   timeout-kill (`:311` vs `kill(9)`/`waitpid` at `:314–316`), so if the kill fails to
   reap a D-state child the alarm **is** armed during the blocking `waitpid` — but with
   its budget **reset** to the value captured at command start, so it fires
   ~`max_hold` *after* the failed kill, far past `CFS_LOCK_TIMEOUT` — not a usable
   backstop either.) **Resolution:** (a) the guarantees are reworded throughout —
   `run_bounded` is the **pure-Perl-hang backstop** (the one hang class safe signals
   reliably reach); a wedged external command is bounded by `run_command`'s own kill;
   and (b) the **wall-clock** hold bound is a **deadline check**: `_lock_arm_deadline`
   records `time() + max_hold` on the lock's `_held_locks` entry at **acquisition** (not
   at `_lock_enter`, which precedes the acquisition wait), and `refresh_locks` dies when
   any held lock is past its deadline — enforced at every cooperation point
   (before/after each jdssc run, each cluster-poll iteration), i.e. between commands,
   never mid-command, unwinding through the normal exception-safe release.
   **Ruled out — (c) `PVE::Tools::run_fork_with_timeout` (`Tools.pm:507`), orphan
   hazard:** it SIGKILLs only its immediate child (`kill('KILL', $child)`,
   `Tools.pm:583`, no process group), so a cap firing mid-`run_command` orphans the
   running `jdssc`, which keeps mutating the backend while the parent releases the lock
   and retries — the lock machinery itself would produce the concurrent-jdssc collision
   it exists to prevent (`run_command`'s own timeout `kill(9, $pid)`s the binary,
   `Cmd.pm:314–315`); a safe fork variant would need `setsid` + process-group kill —
   heavier than what it replaces — and a D-state child defeats `SIGKILL` and wedges the
   parent in `waitpid` (FIXME in `Tools.pm`). **Residual, accepted:** a body wedged in a
   single uninterruptible syscall is reached by neither alarm nor deadline until the
   syscall returns; process death and pmxcfs stale reclaim remain the ultimate
   backstops.

*Already decided (folded into the design above):* the **cross-cluster gap is accepted** —
the `cluster` scope is a *single-Proxmox-cluster* lock (it lives in that one cluster's
pmxcfs and serializes only within it), so separate Proxmox clusters sharing a pool via
`cluster_prefix` are **not** serialized here; that protection, if a deployment needs it,
belongs on the JovianDSS appliance side (see Non-goals and Risk #5); the **lock body wraps
only
`run_command`** — the pure-Perl `connection_options` assembly stays outside the lock, so
the hold is as short as possible; the **timeout is per single jdssc execution** (one
`run_command` attempt, not the whole retry loop) and **must not exceed
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` — clamped for every call**: under a cluster lock that
keeps the hold below the pmxcfs `CFS_LOCK_TIMEOUT` expiry, and on any backend it keeps
`run_command`'s kill strictly below every class's hold cap (see the cap in
[Lock refresh](#lock-refresh-keep-alive)); the **Python
REST-level lock inside `jdssc` is removed entirely**, so this design *replaces* it and the
`--iscsi-target-lock-path` / `--iscsi-change-lock-timeout` plumbing (already removed from
`joviandss_cmd`) is retired; the **property names and per-scope default paths** are
confirmed (`jdssc_general_lock_*` / `jdssc_info_lock_*` property sets, see
[Locking configuration](#locking-configuration)); lock **granularity** is per command —
`joviandss_cmd` picks `jdssc_general` (default) or `jdssc_info`, each operator-tunable;
**NFS parity** is **implemented** (the
fresh-`$ctx` wrapper is gone and the `NFSCommon` helper layer is fully `$ctx`-threaded
— see [Password Resolution Through `$ctx`](password-resolution-through-ctx.md)); and
the **single property-driven entry** is settled — one `with_lock($ctx, $lock_class, $id, …)`
whose scope is the `<class>_lock_type` property, with `lock_vm` / `lock_storage` removed
(no `lock_jdssc` introduced) and the method-lock call sites migrated. The `with_lock` /
`_lock_exec` / `get_lock_class_type` names are **signed off** (2026-07-02).
**Rename (2026-07-05):** both jdssc tiers, originally named after their default
scopes, were renamed — the strong tier to **`jdssc_general`** and the host-safe
read tier to **`jdssc_info`** (constants `LOCK_CLASS_JDSSC_GENERAL_*` /
`LOCK_CLASS_JDSSC_INFO_*`, properties `jdssc_general_lock_*` / `jdssc_info_lock_*`,
lock names `joviandss-lock-jdssc_general` / `joviandss-lock-jdssc_info`) — a class
names the **command tier** it serializes, never its scope: the old names baked the
default scopes into the classes and read as promises that the `<class>_lock_type`
knob could silently break. The scope *values* `node` / `cluster` and both classes'
default scopes are unchanged. Renamed before any release shipped the old property
names, so no storage.cfg migration exists. Per-class
default values are defined as **flat, individually named constants**
(`LOCK_CLASS_<CLASS>_<ATTR>`, e.g. `LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT`), and the
`LOCK_*` hash maps only **wire** those constants to their class keys (decided
2026-07-02): the class arrives as a runtime variable, so a map is required for the
lookup, but no value is ever defined inside a map (`LOCK_CLASS_PROPERTY` excepted — its
values *are* the literal `storage.cfg` property names). Typo safety on the class key
itself comes from `with_lock`'s **up-front unknown-class die** — the maps carry no
global fallbacks and are key-complete by invariant. Finally, the **timeout ladder
stands as specified** (decided 2026-07-02):
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX + 1` (`run_command`'s kill) `<
LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT < CFS_LOCK_TIMEOUT` — the hold cap deliberately
sits **above** the kill (at or below it, the post-run deadline check would fail
legitimate maximal-length runs), and the narrow margin to `CFS_LOCK_TIMEOUT` is
acceptable because a live holder's refresh brackets keep the pmxcfs mtime fresh
regardless.

---

## Function Signature Change
[Function_Signature_Change](#function-signature-change)

The single public lock entry is `with_lock($ctx, $lock_class, $id, $timeout, $code, @param)`
— the caller passes the **class** and (for id-keyed classes like `vm`) a separate **id**,
never a composite name; the scope comes from the class's `<class>_lock_type` property.
`joviandss_cmd` gains **one** new trailing optional argument, `$lock_class`
(`joviandss_cmd($ctx, $cmd, $timeout, $retries, $force_debug_level, $lock_class)`): which
jdssc lock **class** to take — `'jdssc_general'` (default) or `'jdssc_info'` — passed
straight to `with_lock`, so each class's scope follows its own
`<class>_lock_type` property. The only signatures that go away are the method-lock entry
points (`lock_vm` / `lock_storage`); their removal and the call-site migration are covered
under [Obsolete Functions](#obsolete-functions) (and Risk #6).

---

## New Constants
[New_Constants](#new-constants)

Constants introduced by this design, split over two tables: **Table 9a** says what each
constant is *for* (key — description); **Table 9b** says what each is *worth*
(key — value — denomination — location). All are **proposed** (to add during
implementation) except `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` (**done** — already in code)
and `CFS_LOCK_TIMEOUT` (external — pmxcfs's own).

**Single point of truth.** Constant **values are specified in this section only** —
Table 9b (and Table 10 for pre-existing constants). Code snippets
elsewhere show mechanism and reference constants **by name**: the flat-constant block in
[The lock API](#the-lock-api) shows only the shape, the wiring maps define no values,
and the poll-loop comment lists names only. Prose likewise refers to constants by name,
and relations between them are argued **symbolically** — e.g.
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX + 1` (`run_command`'s kill) `<
LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT < CFS_LOCK_TIMEOUT` — never with bare numerals.
Numeric literals outside this section appear only when quoting **current code** or an
**external system's** behavior (call-site literals, `Lock.pm` hardcodes, pmxcfs facts —
including the findings section, which reviews current code). Map-lookup syntax
(`LOCK_*->{...}`) appears only inside code blocks.

**Table 9a — Constant descriptions** · `tbl_constants_desc`

| Constant | Description |
|---|---|
| `CFS_LOCK_TIMEOUT` | *(external)* pmxcfs idle expiry for `mkdir` locks under `/etc/pve/priv/lock/`; the ceiling everything else stays below. |
| `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` | (**done**) the master pmxcfs-hold bound, worn two ways: (1) clamp for the per-call jdssc execution timeout of **every** call — under a cluster lock it keeps `run_command`'s kill (`timeout + 1`) under `CFS_LOCK_TIMEOUT`, and on any backend below every class's hold cap (Finding #8; [Lock refresh](#lock-refresh-keep-alive)); (2) the **cluster-backend alarm ceiling** — `_lock_exec` caps `run_bounded`'s alarm at this constant for any cluster-backend lock (Finding #15). |
| `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX` | max total time a `cluster`-scope acquisition retries before dying with `got lock request timeout`; replaces the hardcoded `max_total = 1200` (`Lock.pm:180`, Finding #13). |
| `PROXMOX_CLUSTER_POLL_BASE_SLEEP` | cluster poll-loop initial inter-poll sleep. |
| `PROXMOX_CLUSTER_POLL_BACKOFF_STEP` | added to the poll base each iteration (linear backoff). |
| `PROXMOX_CLUSTER_POLL_JITTER_MAX` | uniform jitter upper bound (`rand`). |
| `PROXMOX_CLUSTER_POLL_SLEEP_CAP` | max poll base sleep (caps the ramp). |
| `LOCK_CLASS_JDSSC_GENERAL_DEFAULT_TYPE` | default scope of the `jdssc_general` class. |
| `LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT` | `jdssc_general` wait-to-acquire bound; kept equal to `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX`. |
| `LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT` | `jdssc_general` hold cap (bracket note below the tables). |
| `LOCK_CLASS_JDSSC_INFO_DEFAULT_TYPE` | default scope of the `jdssc_info` class. |
| `LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT` | `jdssc_info` wait-to-acquire — local and brief; a longer wait usually signals a stuck holder. |
| `LOCK_CLASS_JDSSC_INFO_HOLD_TIMEOUT` | `jdssc_info` hold cap (bracket note below the tables). |
| `LOCK_CLASS_MULTIPATH_DEFAULT_TYPE` | default scope of the `multipath` class (active since the volume-activation design). |
| `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT` | `multipath` wait-to-acquire — raised by the volume-activation design to outlast one full worst-case hold of `multipath_cmd`'s TERM-first termination ladder with headroom; a deeper queue times out into that design's contention class (retried without teardown). |
| `LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT` | `multipath` hold cap. |
| `LOCK_CLASS_VM_DEFAULT_TYPE` | default scope of the `vm` method-lock class (shared → pmxcfs, non-shared → `flock`). |
| `LOCK_CLASS_VM_ACQUIRE_TIMEOUT` | `vm` wait-to-acquire — method operations legitimately hold 30–90 s, so waiters wait long (Finding #9). |
| `LOCK_CLASS_VM_HOLD_TIMEOUT` | `vm` hold cap. |
| `LOCK_CLASS_STORAGE_DEFAULT_TYPE` | default scope of the `storage` method-lock class (shared → pmxcfs, non-shared → `flock`). |
| `LOCK_CLASS_STORAGE_ACQUIRE_TIMEOUT` | `storage` wait-to-acquire (as `vm` — Finding #9). |
| `LOCK_CLASS_STORAGE_HOLD_TIMEOUT` | `storage` hold cap. |
| `LOCK_DIVEST_GUARD_TIMEOUT` | alarm bound on the cluster-backend `rmdir` in `_lock_divest`: release runs on unwind paths where a wedged FUSE call would otherwise hang the process while it still believes it holds the lock; on expiry the dir is warned about and left for the waiters' `utime(0,0)` stale reclaim. |
| `LOCK_DEFAULT_TYPE` | wiring map, class key → its flat `LOCK_CLASS_<CLASS>_DEFAULT_TYPE` constant; its key set defines the **valid classes** — `with_lock` dies on any other. Defines no values. |
| `LOCK_CLASS_ACQUIRE_TIMEOUT` | wiring map, class key → its flat `LOCK_CLASS_<CLASS>_ACQUIRE_TIMEOUT` constant; read via `get_lock_class_acquire_timeout` (scfg `<class>_lock_acquire_timeout` override; no global fallback). Resolves Finding #9 — **per-class**, not one global default. Defines no values. |
| `LOCK_CLASS_HOLD_TIMEOUT` | wiring map, class key → its flat `LOCK_CLASS_<CLASS>_HOLD_TIMEOUT` constant; read via `get_lock_class_hold_timeout` (scfg `<class>_lock_hold_timeout` override; explicit `0` → no deadline — the cluster-backend alarm ceiling of Finding #15 still applies). One value drives **both** hold-cap mechanisms — `run_bounded`'s alarm and the `refresh_locks` deadline (see [Execution alarm](#execution-alarm-and-refresh-interaction), Open question #2). Defines no values. |
| `LOCK_CLASS_PROPERTY` | class + attribute → the four literal `<class>_lock_*` `storage.cfg` property names, read via `_lock_class_scfg` — no runtime `"${class}_lock_*"` key building; adding a class = one row. (Deliberate exception: its values *are* the literal property names.) |

**Table 9b — Constant values** · `tbl_constants_values`

| Constant | Value | Denomination | Location |
|---|---|---|---|
| `CFS_LOCK_TIMEOUT` | 120 | seconds | pmxcfs (external) |
| `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` | 117 | seconds | `OpenEJovianDSS::Common` |
| `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX` | 600 | seconds | `OpenEJovianDSS::Common` |
| `PROXMOX_CLUSTER_POLL_BASE_SLEEP` | 0.3 | seconds | `OpenEJovianDSS::Common` |
| `PROXMOX_CLUSTER_POLL_BACKOFF_STEP` | 0.1 | seconds | `OpenEJovianDSS::Common` |
| `PROXMOX_CLUSTER_POLL_JITTER_MAX` | 5 | seconds | `OpenEJovianDSS::Common` |
| `PROXMOX_CLUSTER_POLL_SLEEP_CAP` | 10 | seconds | `OpenEJovianDSS::Common` |
| `LOCK_CLASS_JDSSC_GENERAL_DEFAULT_TYPE` | `cluster` | scope | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT` | 600 (= `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX`) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT` | 119 | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_JDSSC_INFO_DEFAULT_TYPE` | `node` | scope | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT` | 40 (was 10; raised 2026-07-05 — a waiter must outlast one full worst-case command hold with headroom) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_JDSSC_INFO_HOLD_TIMEOUT` | 119 | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_MULTIPATH_DEFAULT_TYPE` | `node` | scope | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT` | 60 (was 10; raised by `volume-activation-with-reactivation.md`) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT` | 60 | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_VM_DEFAULT_TYPE` | `vm` | scope | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_VM_ACQUIRE_TIMEOUT` | 600 | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_VM_HOLD_TIMEOUT` | 1320 (was 600; raised by `volume-activation-with-reactivation.md` — the reactivation-cycle budget) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_STORAGE_DEFAULT_TYPE` | `storage` | scope | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_STORAGE_ACQUIRE_TIMEOUT` | 600 | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_CLASS_STORAGE_HOLD_TIMEOUT` | 1320 (was 600; in step with the `vm` class) | seconds | `OpenEJovianDSS::Lock` |
| `LOCK_DIVEST_GUARD_TIMEOUT` | 5 | seconds | `OpenEJovianDSS::Lock` |

The wiring maps (`LOCK_DEFAULT_TYPE`, `LOCK_CLASS_ACQUIRE_TIMEOUT`,
`LOCK_CLASS_HOLD_TIMEOUT`) and `LOCK_CLASS_PROPERTY` define no values, so they have no
Table 9b row.

**Value notes.** The jdssc hold caps (119 s) sit just above `run_command`'s kill
(`timeout + 1` = 118 s under the Finding #8 clamp) — so hold-cap enforcement never trips
a legitimate maximal run — and below `CFS_LOCK_TIMEOUT` (120 s), so a still-held cluster
lock is never stale-reclaimed. `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX` (600 s) covers
legitimate contention while failing well before a stuck holder reads as a permanent hang
(Finding #13).

Related existing constants (context, not introduced here):

**Table 10 — Related existing constants** · `tbl_constants_related`

| Constant | Value | Defined in | Note |
|---|---|---|---|
| `DEFAULT_JDSSC_TIMEOUT` | 113 s | `OpenEJovianDSS::Common` | Default **per-call execution timeout** when a `joviandss_cmd` caller passes none (clamped like any other; `run_command` kills at `timeout + 1`). **Reconciled with Finding #8 (decided 2026-07-02):** jdssc's internal `--timeout` flag is no longer passed — the binary runs unconstrained (`bin/jdssc` defaults it to `None`) and the plugin-side kill is the sole process bound; the now-unreachable `jdssc process timed out` stderr retry branch is removed with it. |
| `DEFAULT_ISCSI_CHANGE_LOCK_TIMEOUT` | 50 s | `OpenEJovianDSS::Common` | **⚠ Marked for deletion.** Was the default acquire wait for the retired iSCSI-target REST lock; backed the inert `iscsi_change_lock_timeout` property. Delete with its getter `get_default_iscsi_change_lock_timeout` (`Common.pm:211`) and the property (Finding #14). |
| `JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX` | 115 s | `OpenEJovianDSS::Common` | **⚠ Marked for deletion.** Was the `maximum` for the retired REST lock's `iscsi_change_lock_timeout` property. Delete with its getter `get_max_iscsi_change_lock_timeout` (`Common.pm:209`) and the property's `maximum` (`OpenEJovianDSSPlugin.pm:185`) — see Finding #14. |
| `JOVIANDSS_ISCSI_LOCK_PATH` | `/etc/pve/priv/lock/joviandss-iscsi-target-global-lock` | `OpenEJovianDSS::Common` | **⚠ Marked for deletion.** Was the default path for the retired REST lock; backed the inert `iscsi_target_global_lock_path` property. Delete with its getter `get_default_iscsi_target_global_lock_path` (`Common.pm:213`) and the property (Finding #14). |
| `LOCK_EX` | Fcntl exclusive-lock flag | `Fcntl` (Perl core) | Flag passed to `flock()` for the node backend (Table 1; `_lock_acquire_node` since the acquire/divest refactor — previously reached indirectly through `PVE::Tools::lock_file`). Imported from Fcntl, not defined by the plugin. |

---

## New Functions
[New_Functions](#new-functions)

In `OpenEJovianDSS/Lock.pm`:

- **`with_lock($ctx, $lock_class, $id, $timeout, $code, @param)`** — the single public entry
  point; `$id` is the sub-key (vmid for `vm`, `undef` for singleton classes), and scope comes
  from the class's `<class>_lock_type` property. Validates `$lock_class` against
  `LOCK_DEFAULT_TYPE` up front — an unknown class dies.
- **`get_lock_class_type($ctx, $lock_class)` / `get_lock_class_dir($ctx, $lock_class)`**
  + `LOCK_DEFAULT_TYPE` — read `<lock_class>_lock_type` / `<lock_class>_lock_path`, with a
  per-class default scope; no global fallback — `with_lock` dies up front on a class
  missing from `LOCK_DEFAULT_TYPE`, and `get_lock_class_type` dies on an invalid type
  value (component classes: `node` / `cluster` only; `vm` / `storage` only for their
  namesake classes).
- **`_lock_class_scfg($ctx, $lock_class, $attr)`** + `LOCK_CLASS_PROPERTY` — the explicit
  class+attribute → literal `storage.cfg` property-name lookup all four getters share (no
  runtime `"${class}_lock_*"` key building); returns `undef` for a class that declares no
  such property.
- **`_lock_resolve($ctx, $type, $lock_class, $id)`** — composes the lockid from class + id
  and maps the resolved scope → `(backend, path)`.
- **`_lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param)`** — the
  **phase sequencer**: commission → acquire (+ id cross-check) → `run_bounded` →
  `run_refreshed` → body → explicit divest → decommission finalizer; one eval per
  bracket, one error capture, release guaranteed on every path — so `with_lock`
  auto-caps and auto-refreshes; callers never do either manually.
- **`_lock_ctx_commission($ctx, $backend, $path, $timeout, $max_hold)` →
  `$lock_id`** — registry + re-entry guard (`Carp::confess` on re-lock) and the
  **resolve-and-freeze point**: the record carries all timing policy (acquire
  budget, hold cap, cluster-ceilinged `alarm_cap` — Finding #15); commissioned =
  registered, NOT owned.
- **`_lock_ctx_decommission($ctx, $lock_id)`** — the never-dying FINALIZER: divests
  anything still owned (anomaly tripwire — both anticipated outcomes divest
  explicitly) and removes the record.
- **`_lock_acquire($ctx, $lock_id)` → `$lock_id`** — blocks per the record taking
  exclusive ownership; **dies on any failure** (canonical, classifiable errors);
  its entry is a `refresh_locks` **cooperation point** (an expired enclosing
  budget dies here, before any wait starts); the backends flip `owned=1` at the
  instant of syscall success (and park the node fh); the dispatcher then arms
  the hold deadline. Dispatches to **`_lock_acquire_cluster`** (pmxcfs mkdir poll loop:
  deadline accounting, stale-poke, held-outer-lock refresh, jittered backoff,
  quorum check, `cfs_update`) or **`_lock_acquire_node`** (direct
  `flock(LOCK_EX)` bounded by `PVE::Tools::run_with_timeout`).
- **`_lock_divest($ctx, $lock_id)`** — ends ownership: alarm-guarded `rmdir`
  (`LOCK_DIVEST_GUARD_TIMEOUT`) or fh close; **never dies**, idempotent via the
  `owned` flag.
- **`_lock_record($ctx, $lock_id)`** — the registry accessor (one record per
  commissioned lock).
- **`refresh_locks($ctx, $skip_path)`** — backend-agnostic keep-alive **and
  wall-clock hold-cap enforcement** (dies if any owned lock is past its
  `deadline`), and the alarm **re-arm point** (innermost armed section via
  `_lock_alarm_innermost`); the shared primitive, called both by the poll loop
  and by `run_refreshed`. Only owned records participate.
- **`_lock_alarm_innermost($ctx, $exclude_id)`** — the innermost armed alarm
  section: last registry record owned with a nonzero `alarm_cap`, optionally
  excluding one id (run_bounded's exit uses it to find its enclosing section).
- **`run_refreshed($ctx, $code, @param)`** — its exception-safe before/after wrapper,
  applied **automatically by `with_lock`** (via `_lock_exec`) around every locked body —
  an internal mechanism, not a caller-facing helper.
- **`run_bounded($ctx, $lock_id, $code, @param)`** — the **pure-Perl-hang backstop**
  for the section holding `$lock_id`: alarm cap and diagnostic label read from the
  record (`alarm_cap` 0 → no alarm section); on overrun the body dies (naming the
  lock) and the lock releases on unwind. Nested alarm users suspend the alarm, so it
  cannot fire while a command is in flight — the wall-clock bound is the
  `refresh_locks` deadline check. The budget is measured **since the last
  cooperation point** (refresh re-arms the innermost armed section; section exit
  re-arms the enclosing one in full — re-arm delta 2026-07-05, registry-derived
  since the acquire/divest refactor).
- **`get_lock_class_hold_timeout($ctx, $lock_class)`** + `LOCK_CLASS_HOLD_TIMEOUT` — per-class hold cap
  (`<class>_lock_hold_timeout` override), with per-class defaults; the one value drives
  both the `run_bounded` alarm and the `refresh_locks` deadline.
- **`get_lock_class_acquire_timeout($ctx, $lock_class)`** + `LOCK_CLASS_ACQUIRE_TIMEOUT` —
  per-class **wait-to-acquire** timeout for **every** class: scfg `<class>_lock_acquire_timeout`,
  else the class's flat `LOCK_CLASS_<CLASS>_ACQUIRE_TIMEOUT` constant via the wiring map; no
  global fallback (class validity is enforced up front in `with_lock`).

---

## Obsolete Functions
[Obsolete_Functions](#obsolete-functions)

In `OpenEJovianDSS/Lock.pm`:

- **`_cluster_lock` / `_node_lock`** (the name-building lock helpers) — **retired**.
  Their acquisition-timeout retry becomes `_cluster_lock_path`; their path-building is
  consolidated into `_lock_resolve` (callers now pass a class + id, not a path).
- **`touch_cluster_lock` / `_active_locks`** (the cluster-assuming keep-alive) —
  **reworked** into the backend-agnostic `refresh_locks` + `run_refreshed`, so a held
  `flock` lock is handled correctly (as a no-op) instead of being mis-assumed to be a
  pmxcfs lock.
- **`lock_vm` / `lock_storage`** (the per-VM / per-storage method-lock entry points) —
  **removed**. Method locks become plain `with_lock($ctx, 'vm', $vmid, …)` /
  `with_lock($ctx, 'storage', undef, …)` calls; the ~42 call sites migrate accordingly.

Retired by the acquire/divest refactor (2026-07-05):

- **`_cluster_lock_attempt` / `_cluster_lock_path`** — the callback-hosting
  acquisition pair. Body execution moved out of the acquisition frame entirely
  (`_lock_acquire_cluster` acquires and returns), which deletes the `$is_code_err`
  disentangling flag, the undef+`$@` signalling convention, and the outer wrapper's
  `$@`-regex retry filter together with the body-re-run hazard it carried (review
  finding L7, fixed by construction).
- **`_lock_enter` / `_lock_leave`** — renamed and extended into
  `_lock_ctx_commission` / `_lock_ctx_decommission` (naming decided 2026-07-05:
  "enter/leave" read as taking/releasing the lock, which they never did;
  commissioned = registered + guarded, not owned, and decommission is the
  never-dying finalizer).
- **`_lock_arm_deadline`** — folded into `_lock_acquire` as its final act
  ("armed at acquisition" is now literal).
- **`PVE::Tools::lock_file`** (external, no longer imported) — a run-callback
  wrapper that cannot express a separable acquire; its per-PID re-entry counter is
  unreachable behind our guard and its internal 10 s default is unreachable behind
  `with_lock`'s per-class resolution. The node backend takes `flock(LOCK_EX)`
  directly (Fcntl — Table 10), with `PVE::Tools::run_with_timeout` still bounding
  the wait and the error wording kept byte-identical, now emitted by our code.

---

## Relationship to Other Designs
[Relationship_to_Other_Designs](#relationship-to-other-designs)

- [`cluster-lock-storage-design.md`](cluster-lock-storage-design.md) — defines the
  per-VM / per-storage **method locks** this design nests inside. Those `lock_vm` /
  `lock_storage` entry points are **removed** here; method locks become
  `with_lock($ctx, 'vm', $vmid, …)` / `with_lock($ctx, 'storage', undef, …)` calls, so the
  method and component locks share one registry, refresh, and re-entry guard.
- [Password Resolution Through `$ctx`](password-resolution-through-ctx.md) — the
  **prerequisite**, now **implemented**: retiring `NFSCommon::joviandss_cmd` and
  threading `$ctx` through the `NFSCommon` helpers is what lets the jdssc lock and the
  NFS method lock share one `$ctx->{_held_locks}`.
- **The Python REST-level lock inside `jdssc`** — this design **replaces** it: that lock
  is removed entirely, so the `--iscsi-target-lock-path` / `--iscsi-change-lock-timeout`
  plumbing (already removed from `joviandss_cmd`) is retired. Serialization moves up to this Perl-side
  jdssc lock.

---

## Risks & Backward Compatibility
[Risks_and_Backward_Compatibility](#risks--backward-compatibility)

### Preserved (low risk)

- **The underlying lock backends are unchanged.** pmxcfs `mkdir` and node `flock` —
  both already in production — are reused as-is; no new low-level lock mechanism is
  introduced. (The `Lock.pm` *layer* over them **is** reworked — new entry point,
  removed method-lock functions, retired/reworked helpers — so this is a real change to
  the locking code, not a drop-in; Risks #1, #2, #6 cover what that rework introduces.)
- **Default preserves maximum safety.** `joviandss_cmd` defaults to the `jdssc_general`
  class (scope `cluster`), so an un-configured storage gets the strongest serialization,
  not a weaker one.

### Risks

1. **The re-entry guard turns previously-silent re-entry into a loud death.** If any
   existing path *did* re-lock a held path, it used to deadlock or silently re-enter; it
   now `Carp::confess`es. (No current path is known to do this — `cluster_lock_storage`,
   the one historical nesting hazard, is already a no-op pass-through — but the guard would
   catch any that slipped in.) That's the intent (fail loud), but it is a **behavior
   change** that may surface latent bugs on first run — desirable, but expect noise.
2. **The `$ctx`-threading invariant — _audited and fixed_.** The guard and refresh live
   in `$ctx->{_held_locks}`, so a fresh `new_ctx` *while a lock is held* would split the
   registry: the inner jdssc lock would register on a different `$ctx` than the outer
   method lock, and the poll-loop refresh (Risk #7 fix b) would never see — and so never
   keep alive — the outer lock. An audit of both drivers found **7 re-init sites** where a
   helper called `new_ctx` instead of threading the operation's `$ctx`; **5 of them ran
   under a held method lock** (`_rename_volume`, `_clone_image`, `_alloc_image` →
   `find_free_diskname`; `_volume_snapshot_rollback`, `_deactivate_volume` → `path`).
   **Resolved (current-code cleanup, not part of the lock work):** `path` and
   `find_free_diskname` were split into thin public entry points (`path` /
   `find_free_diskname`, which `new_ctx` once for PVE core) plus internal
   `_path($ctx, …)` / `_find_free_diskname($ctx, …)` bodies; every internal caller now
   threads its existing `$ctx`. With that, the operation's `$ctx` is created **exactly
   once at the top level** and propagated down, so the registry is shared across the whole
   nesting (both drivers re-verified `perl -c` clean). The same split also moved the
   `wantarray` handling to the top: `_path` now returns a **fixed `[$path, $vmid, $vtype]`
   arrayref** (obeying the *Return convention* above), and the public `path` maps that onto
   PVE's `wantarray` contract — so an internal caller of `_path` always gets the same shape
   regardless of context. The remaining obligation is a
   **coding rule, not a live gap**: the `_` variants must be called with the `$ctx` of the
   volume's own storage (a comment at each public def records this), and no new helper may
   `new_ctx` under a lock.
3. **Performance regression from the `cluster` default.** Cluster-wide serialization of
   all `jdssc` can bottleneck busy multi-pool deployments. Mitigation is built in:
   step down to `node` (or route host-safe commands through `jdssc_info`).
4. **pmxcfs poll cost under contention.** Cluster-scope acquisition polls via FUSE +
   corosync; a poorly-tuned loop is expensive cluster-wide. Mitigated by the poll-loop
   rules (≥100–200 ms, jitter); `node` scope avoids polling entirely.
5. **Cross-cluster gap is unaddressed.** Separate Proxmox clusters sharing a pool via
   `cluster_prefix` are not serialized by any type (a non-goal here); deployments that
   need it must keep backend-side protection.
6. **Method-lock call-site migration.** Removing `lock_vm` / `lock_storage` moves the
   ~42 method-lock call sites to `with_lock`. Mechanical but broad — a missed or
   mis-named site is a bug. (Mitigated: the old function names vanish, so an un-migrated
   caller fails to compile loudly rather than silently locking the wrong path.) The lock
   **names** also change (`joviandss-<storeid>-vm-<vmid>` → `joviandss-lock-vm-<vmid>`,
   `joviandss-<storeid>-storage` → `joviandss-lock-storage-<storeid>`), so during a
   rolling upgrade an old-plugin node and a new-plugin node take **different pmxcfs
   paths** and do not exclude each other; upgrade nodes promptly, or keep storage
   operations quiet until the whole cluster runs the new plugin. One **behavior change**
   also rides on the new `vm` name (per-vmid, no storeid — decided, see
   [Method locks are just classes](#method-locks-are-just-classes)): operations on the
   same VM targeting *different* JovianDSS storages serialize on shared storage where
   today they run in parallel — safe, but a source of new (correct) waiting under
   multi-storage workloads.
7. **Nested-acquisition starvation → split-brain on a held lock (newly introduced).**
   Adding the inner `jdssc` lock creates a case absent today: a node can wait a long time
   to acquire it *while already holding* an outer `cluster` method lock. If that wait
   exceeds the `CFS_LOCK_TIMEOUT` pmxcfs idle window with nothing refreshing the outer lock, another
   node stale-reclaims it and both believe they hold it — corruption-class. Closed by
   **two** mechanisms: (a) the per-call jdssc execution timeout is capped at
   **`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`** for every call (a single jdssc
   process then runs for `timeout + 1` via `run_command`, staying under `CFS_LOCK_TIMEOUT`;
   see Finding #8 for the `+5`-floor caveat), so no *hold* reaches the pmxcfs expiry;
   and (b) the cluster poll loop calls
   `refresh_locks($ctx, $lockpath)` **each iteration**, keeping every already-held outer
   lock fresh during the wait (skipping the in-flight target). Both are required: (a)
   bounds each holder, (b) bounds a waiter queued behind several holders. The refresh
   invariant from Risk #2 (`$ctx` threaded through the whole nesting) is what makes (b)
   reach the right locks.

### Implementation findings (code review — to resolve)

These came out of reviewing the design against the current `Lock.pm` and `joviandss_cmd`;
they are gaps between what the doc specifies and what the code does, to be closed before
or during implementation.

8. **Single-jdssc-execution timeout must bound the held cluster lock. _(critical —
   resolution agreed)_** The `$timeout` argument to `joviandss_cmd` is the execution
   timeout of **one** jdssc call, and it is what bounds how long the `jdssc` lock is held.
   **Resolution:** **clamp every call whose `$timeout` exceeds
   `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`** — unconditionally, not only when the cluster lock
   is selected: under a cluster lock the clamp keeps a single jdssc run, and thus the
   hold, under `CFS_LOCK_TIMEOUT`; for the node classes it keeps `run_command`'s kill
   (`$timeout + 1`) strictly **below their hold caps** (an unclamped call-site literal of
   118 would otherwise produce a kill equal to `LOCK_CLASS_JDSSC_INFO_HOLD_TIMEOUT`, and
   a maximal run would trip the post-run deadline check). **Caveat that the guard depends
   on:** today `run_command`'s kill timeout is *not* `$timeout` but
   `max($timeout, get_jdssc_timeout + 5) + 1` (`Common.pm:928–931, 952`, with
   `get_jdssc_timeout = scfg{jdssc_timeout} || 113`). That `+5` floor is driven by the
   independent `scfg jdssc_timeout` property, so clamping only the per-call arg leaves the
   floor free to re-inflate the real hold — 119 s by default, and **126 s if an operator
   sets `jdssc_timeout = 120`**, i.e. past `CFS_LOCK_TIMEOUT` (the exact split-brain Risk #7
   guards). **Fix:** simplify the timeout handling so `run_command` follows the clamped
   `$timeout` directly (`$timeout + 1`), dropping the `+5` / `process_timeout` massaging;
   `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX = 117` then gives a 118 s hard kill, ~2 s under
   `CFS_LOCK_TIMEOUT`.
9. **Method-lock node-acquisition timeout regresses 600 s → 10 s. _(high — resolved)_** A
   method lock on non-shared storage today uses `_node_lock`, which defaults `$timeout //= 600`
   (`Lock.pm:234`) because operations legitimately hold 30–90 s. A single global node default
   would push the jdssc-oriented **10 s** onto method locks too, so a waiter for a normally-held
   method lock would fail after 10 s instead of ~600 s → spurious `can't lock file` errors under
   ordinary contention. **Resolved:** the node acquire wait is **per-class** via
   `LOCK_CLASS_ACQUIRE_TIMEOUT` / `get_lock_class_acquire_timeout($ctx, $lock_class)` — `vm`/`storage`
   keep ~600 s, `jdssc_info`/`multipath` use ~10 s; there is no single global node default.
10. **Poll-loop backoff breaks the per-attempt timeout accounting. _(medium — resolution
    agreed)_** `_cluster_lock_attempt` deducts a hardcoded 1 s per sleep — `$timeout =
    alarm(0) - 1` with `sleep(1)` (`Lock.pm:101,109`, comment "sleep costs 1s"). The
    proposed variable backoff (`PROXMOX_CLUSTER_POLL_SLEEP_CAP` +
    `PROXMOX_CLUSTER_POLL_JITTER_MAX`, up to ~15 s/iteration) makes that deduction wrong,
    so the per-attempt budget is mis-decremented (waits far longer or shorter than
    intended). **Resolution: deadline-based accounting, no per-sleep bookkeeping.**
    Compute `my $deadline = time() + $timeout;` once before the loop; each iteration
    derives `my $remaining = $deadline - time();`, fires `$timeout_err->()` when
    `$remaining <= 0`, and arms `alarm($remaining)` around the `mkdir` attempt. Any
    sleep — fixed, backed-off, or jittered — then charges itself against the budget
    automatically, and the `- 1` hack disappears.
11. **Risk #7 mitigation (b) is unimplemented new code. _(medium — spec'd above; verify at
    implementation)_** Today's poll loop only `utime(0,0)`s the *target* (`Lock.pm:108`); it
    does **not** refresh other held locks, so mitigation (b) is entirely new — each iteration
    must call `refresh_locks($ctx, $lockpath)`. Relatedly, the design needs `_lock_enter` to
    push **before** acquisition, whereas the current code pushes **after** `mkdir`
    (`Lock.pm:121`) and `pop`s LIFO (`:139`). Both behaviors are already specified in this
    document (`_lock_exec` calls `_lock_enter` before backend dispatch and the grep-based
    `_lock_leave` after; the [poll-loop rules](#cluster-backend-poll-loop) require the
    per-iteration `refresh_locks($ctx, $lockpath)`), so nothing is left to decide — this
    finding stays as the **implementation checklist**: (a) `_lock_enter` before acquisition,
    (b) `_lock_leave` by path (not `pop`) on every exit path, (c) `refresh_locks($ctx,
    $lockpath)` in each poll iteration, (d) the hold deadline armed by `_lock_arm_deadline`
    at the top of the locked body — **never** at `_lock_enter`, or a contended cluster
    acquisition (whose acquire bound far exceeds its hold cap) dies on its first
    refresh. If (a)–(c) are missed, the starvation race is live.
12. **The re-entry guard flips currently-working `flock` re-entrancy into a die (extends
    Risk #1). _(medium — resolved: audited, no re-entrant path)_** `PVE::Tools::lock_file`
    is re-entrant within a PID — `lock_file_full` "skips re-acquisition if the same file is
    already locked by the current process" (`Lock.pm:222–224`). The new guard
    `Carp::confess`es on re-lock, so any path that today benignly re-enters a held node lock
    would now die. **Audit (2026-07-02, both plugins): no such path exists.**
    - Every `_*_lock` method wrapper is called exactly once, from its own public entry
      point — no wrapper runs inside another (grep over `OpenEJovianDSSPlugin.pm` /
      `OpenEJovianDSSNFSPlugin.pm`).
    - No implementation body calls back into a public locked method (`$class->alloc_image`,
      `$class->free_image`, `$class->deactivate_volume`, … — zero hits across both plugins,
      `Common.pm` and `NFSCommon.pm`).
    - The only nested locking is the dual-VM `_clone_image_lock` / `_rename_volume_lock`
      pattern, and every such site takes a **single** lock when the two vmids are equal or
      one is unknown, and acquires distinct vmids in **ascending** order
      (`OpenEJovianDSSPlugin.pm:504,694`, `OpenEJovianDSSNFSPlugin.pm:1133`) — distinct
      paths, never a re-lock.
    - `cluster_lock_storage` is a strict no-op pass-through in both plugins, so PVE core
      cannot stack a lock on top of the method locks; and no code outside `Lock.pm` takes a
      `flock`/`lock_file` at all.
    Residual note: the guard lives in `$ctx->{_held_locks}`, so it only sees re-entry within
    one operation's `$ctx` — exactly the scope the Risk #2 threading invariant guarantees;
    a cross-`$ctx` re-entry cannot occur once `$ctx` is created only at the top level.
13. **A heavily contended cluster lock can block one operation before failing. _(low —
    resolved)_** The `_cluster_lock` retry loop was bounded at a hardcoded `max_total = 1200` s
    (`Lock.pm:180`) — a single `pvesm`/`qm` op could wait up to ~20 min on a contended cluster
    jdssc lock, enough to trip Proxmox task timeouts and read as a hang. **Resolved:** the bound
    is now the named `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX` = **600 s**; on expiry the
    acquisition **dies** with `got lock request timeout` — a bounded wait, not infinite. The
    doc no longer claims "never spuriously fails"; cluster acquisition is bounded and fails loud.
14. **REST-lock removal — jdssc-arg coupling and dead retry branch. _(low — mostly
    resolved)_** **Done:** `--iscsi-target-lock-path` / `--iscsi-change-lock-timeout` are
    fully retired end-to-end — `joviandss_cmd` no longer builds or passes them, `bin/jdssc`
    no longer declares them (nor maps them in `unify_config_options`), the Python `lock.py`
    module and `rest.py._lock()` (plus its commented call sites) are deleted, the runtime
    getters `get_iscsi_change_lock_timeout` / `get_iscsi_target_global_lock_path` are removed,
    and the now-unreachable "Could not acquire iSCSI target lock" retry branch in
    `joviandss_cmd` is deleted. `jdssc` no longer needs the flags. **Remaining — marked for
    deletion:** the last inert remnants are slated to be removed, not kept. That is the two
    `storage.cfg` properties `iscsi_change_lock_timeout` / `iscsi_target_global_lock_path`
    (`OpenEJovianDSSPlugin.pm:180,195` + `options` `:297,299` — the NFS plugin never
    declared them, so there is nothing to remove there), their
    schema helpers `get_default_iscsi_change_lock_timeout` / `get_max_iscsi_change_lock_timeout`
    / `get_default_iscsi_target_global_lock_path` (`Common.pm:209,211,213` + the exports at
    `:57,59`), and the backing constants `DEFAULT_ISCSI_CHANGE_LOCK_TIMEOUT` /
    `JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX` / `JOVIANDSS_ISCSI_LOCK_PATH` (all Table 10, each
    tagged **⚠ Marked for deletion**). Removing the properties drops backward-compat validation
    for configs that still set them, so those keys must be documented as obsolete in the release
    notes.
15. **Retiring the internal execution alarm would un-protect wedged-Perl holders of
    cluster locks. _(medium — resolution decided)_** Today **every** cluster-backend body
    runs under `_cluster_lock_attempt`'s hardcoded `alarm(119)` (`Lock.pm:116–117`), so a
    continuous pure-Perl wedge holding a shared method lock dies *before* the
    `CFS_LOCK_TIMEOUT` stale-reclaim. Retiring that alarm in favor of the per-class hold
    cap alone would reopen the window for `vm` / `storage` cluster locks: their cap
    (`LOCK_CLASS_VM_HOLD_TIMEOUT` / `LOCK_CLASS_STORAGE_HOLD_TIMEOUT`) far exceeds
    `CFS_LOCK_TIMEOUT`, the deadline cannot fire (a wedge reaches no cooperation point),
    and nothing refreshes the mtime — a waiter would stale-reclaim while the wedged
    holder is still alive and running: a split-brain absent today. **Resolution
    (decided):** cluster-backend locks get an **unconditional alarm ceiling — the
    constant `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` used directly**: `_lock_exec` arms
    `run_bounded` with the class hold cap unless the backend is `cluster` and the cap
    is `0` or exceeds the constant, in which case the constant is the alarm value (the
    ceiling is a pmxcfs-correctness invariant — value #1 — not a class property; `0`
    disables only the wall-clock deadline). The pure-Perl alarm then always fires before a waiter could stale-reclaim,
    restoring today's protection by design. The ceiling never trips a legitimate run,
    on two grounds: the alarm is suspended during every *timed* command, and (re-arm
    delta, 2026-07-05) its budget restarts at every cooperation point — `refresh_locks`
    re-arms the innermost armed section, derived from the registry
    (`_lock_alarm_innermost`: last record owned with a nonzero `alarm_cap`) — so the
    ceiling bounds un-suspended Perl time **since the last refresh**, never a long,
    cooperating hold (the volume-activation waits under a shared `vm` lock run to their
    full 1320 s deadline). A wedge still dies within the ceiling of the epoch in which
    every owned cluster dir was last `utime`'d — i.e. before any waiter can stale-reclaim.
    The ≥-`run_command`-kill constraint applies to the **deadline**, which keeps the
    full per-class value.

---

## Files That Would Change (when implemented)
[Files_That_Would_Change](#files-that-would-change-when-implemented)

**Table 11 — Files that would change** · `tbl_files_changed`

| File | Change |
|---|---|
| `OpenEJovianDSS/Lock.pm` | add public `with_lock($ctx, $lock_class, $id, …)` (class + id, no composite name; scope from the `<class>_lock_type` property) + `get_lock_class_type` / `get_lock_class_dir` / `get_lock_class_acquire_timeout` + `LOCK_DEFAULT_TYPE` + the explicit `LOCK_CLASS_PROPERTY` property-name map read via `_lock_class_scfg` (no runtime `"${class}_lock_*"` key building), private `_lock_resolve` (composes the lockid from class + id, sanitizing it via `Common::clean_word`/`safe_word`) and `_lock_exec` (cluster → `_cluster_lock_path` = `_cluster_lock_attempt` + retry; node → `PVE::Tools::lock_file`); **remove** `lock_vm` / `lock_storage`; **retire** the name-building `_cluster_lock` / `_node_lock`; add the re-entry guard `_lock_enter` / `_lock_leave` over `$ctx->{_held_locks}`; rework `touch_cluster_lock` / `_active_locks` into `refresh_locks` + `run_refreshed`; add the per-class node acquire wait `LOCK_CLASS_ACQUIRE_TIMEOUT` + `get_lock_class_acquire_timeout` (all `LOCK_*` maps wiring the flat `LOCK_CLASS_<CLASS>_*` value constants); add the two-part hold cap — `run_bounded` (pure-Perl backstop, cluster-backend alarm ceiling `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` per Finding #15) + the wall-clock deadline (`_lock_arm_deadline`, checked in `refresh_locks`) + `LOCK_CLASS_HOLD_TIMEOUT` + `get_lock_class_hold_timeout` |
| `OpenEJovianDSS/Common.pm` | wrap `run_command` in `joviandss_cmd` with `with_lock($ctx, $lock_class, …)` and add the trailing `$lock_class` arg (`jdssc_general` default, `jdssc_info` for host-safe reads); rename the `new_ctx` registry field `_active_locks => []` to `_held_locks => []` (the list the new keep-alive/guard share); add the `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` constant + `get_proxmox_cluster_lock_timeout_max` getter (**done**) and the `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX` cluster-acquire bound; **clamp `$timeout` to `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` centrally in `joviandss_cmd`** so no single jdssc run exceeds the safe bound under a cluster lock (over-cap literals like `list_images`' 118 are bounded automatically — no per-call-site edits, and the `+5` `process_timeout` floor is dropped per Finding #8); add the cluster poll-loop tuning constants `PROXMOX_CLUSTER_POLL_BASE_SLEEP` / `PROXMOX_CLUSTER_POLL_BACKOFF_STEP` / `PROXMOX_CLUSTER_POLL_JITTER_MAX` / `PROXMOX_CLUSTER_POLL_SLEEP_CAP` (used by the `_cluster_lock_attempt` poll loop); add a shared `lock_properties()` schema helper so the lock-property schema (the `jdssc_general_lock_*` / `jdssc_info_lock_*` property sets) is defined once and spliced into both plugins (rather than copy-pasted into each); **delete the retired iSCSI-lock remnants** — constants `DEFAULT_ISCSI_CHANGE_LOCK_TIMEOUT` / `JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX` / `JOVIANDSS_ISCSI_LOCK_PATH`, their getters `get_default_iscsi_change_lock_timeout` / `get_max_iscsi_change_lock_timeout` / `get_default_iscsi_target_global_lock_path`, and the `:57,59` exports (Finding #14) |
| `OpenEJovianDSSPlugin.pm` | splice the shared lock-property schema (`lock_properties()`) into `properties` (143) and `options` (285) — exposing the `jdssc_general_lock_*` / `jdssc_info_lock_*` property sets without copy-pasting the schema; **migrate the method-lock call sites** (`lock_vm` / `lock_storage` → `with_lock($ctx, 'vm', $vmid, …` / `'storage', undef, …)`); pass `$lock_class => 'jdssc_info'` from the known-safe read call sites (`list_images`/`status`/`get_identity`/`volume_size_info`) so routine polling uses the cheap host-scope jdssc lock (the central clamp already bounds their timeouts); **remove the retired iSCSI-lock properties** `iscsi_change_lock_timeout` (`:180`, `options` `:297`) / `iscsi_target_global_lock_path` (`:195`, `options` `:299`) (Finding #14) |
| `OpenEJovianDSSNFSPlugin.pm` | list the lock property names in its `options()` **only** — its `properties()` stays `{}` (property names are registered globally by the iSCSI plugin; re-declaring is a duplicate-property error, see [Locking configuration](#locking-configuration)) — and the same method-lock migration. NFS jdssc calls already run on the threaded `$ctx` — the prerequisite [Password Resolution Through `$ctx`](password-resolution-through-ctx.md) work is **implemented**. (It never declared the retired iSCSI-lock properties, so no removal is needed here.) |
| `docs/design/multi-layer-lock-design.md` | this document |

The jdssc lock lives inside the shared `joviandss_cmd` path; the plugin files also
change — for the new config properties **and** the method-lock call-site migration.
**Every row above has landed — see [Implementation Notes](#implementation-notes).**

---

## Implementation Notes
[Implementation_Notes](#implementation-notes)

Implemented 2026-07-02 on branch `rollback-semaphor`. Every Table 11 row and every
finding (#8, #10, #11 a–d, #13, #14, #15) landed as specified; the migration moved all
**42** method-lock call sites (26 iSCSI + 16 NFS) with the dual-VM
equal-vmid/ascending-order structure preserved.

### Deltas decided during implementation

All user-approved; where they touch the spec, the spec sections were updated in place:

- **Hold-alarm re-arm at cooperation points (2026-07-05).** The alarm originally armed
  once per section and counted *cumulative* un-suspended Perl time since acquisition,
  while the hazard it guards (pmxcfs stale-reclaim) is measured *since the last
  refresh* — so the sleep-wait loops the volume-activation design placed under shared
  `vm` locks (240×`sleep(1)` device wait, login polls, plus untimed `iscsiadm`
  `run_command` calls that do not suspend the alarm) burned the 117 s ceiling ~2 min
  into a legitimate activation and killed it with a spurious lock-fatal, making the
  1320 s reactivation budget unreachable on shared storage. Fix: `refresh_locks`
  re-arms the innermost armed section after refreshing (skipped for poll-loop calls,
  which own the alarm for their mkdir bound); section exit re-arms the *enclosing*
  section to its full cap (exit follows the body's guaranteed post-refresh) instead
  of restoring the remainder frozen at entry, and hands a suspended foreign alarm
  back untouched only when no armed section remains. First implemented with a
  dedicated `$ctx->{_alarm_caps}` stack; the acquire/divest refactor (below)
  dissolved the stack — the registry record's `owned` flag plus its
  commission-frozen `alarm_cap` make the innermost armed section derivable from
  `_held_locks` directly (`_lock_alarm_innermost`), removing the duplicated state.
  Invariant preserved at any nesting depth: exactly one alarm is armed (the
  innermost section's), every cooperation point `utime`s all owned cluster dirs, so
  a wedge dies within the ceiling of the same epoch the reclaim clocks started from.

- **Acquire/divest refactor + phase renames (2026-07-05).** Acquisition was a
  callback host (`_cluster_lock_path` → `_cluster_lock_attempt(... $body ...)` /
  `PVE::Tools::lock_file(... $body ...)`), which fused body and machinery errors
  into one `$@` channel — the undef+`$@` convention, the `$is_code_err` flag, and
  the retry wrapper's `$@`-regex filter (with its body-re-run hazard, review
  finding L7) all existed to un-fuse them. `_lock_exec` is now a **phase
  sequencer**: `_lock_ctx_commission` (registry + guard + resolve-and-freeze of
  all timing policy into the record; returns the lock id) → one eval holding
  `_lock_acquire` (dies-or-owns; cluster mkdir poll / direct `flock(LOCK_EX)`
  under `run_with_timeout` — `PVE::Tools::lock_file` dropped, wording kept
  byte-identical) and `run_bounded($ctx, $lock_id, …)` (cap and label from the
  record — no skew possible) → **unconditional** `_lock_divest` (never dies;
  alarm-guarded rmdir, `LOCK_DIVEST_GUARD_TIMEOUT`; the owned-guard makes it a
  no-op after failed acquisition — load-bearing, the lock belongs to the
  current holder) → `_lock_ctx_decommission`, the never-dying finalizer whose
  divest branch is a pure anomaly tripwire. The eval was collapsed to one
  (decided 2026-07-05, replacing an intermediate two-eval form): the backends
  flip `owned=1` at the instant of syscall success and acquire sits inside the
  guarded region, so a die anywhere after ownership — including a signal
  landing between acquire and `run_bounded`'s alarm suspension (the enclosing
  alarm is live there, freshly re-armed by the acquire-entry cooperation
  point) or `cfs_update` failing after `mkdir` (the internal rollback-rmdir
  was removed) — routes through the one divest; the finalizer's only
  reachable trigger is the irreducible single assignment between syscall
  success and the flag flip. Naming decided 2026-07-05: commissioned =
  registered + guarded, NOT owned (the old `_lock_enter`/`_lock_leave` names
  read as taking/releasing the lock, which they never did). L7 is fixed by
  construction — acquisition errors originate in a frame where no body has
  ever run. `_lock_acquire`'s entry is additionally a `refresh_locks`
  cooperation point (decided 2026-07-05): a nested wait whose enclosing hold
  budget is already exhausted dies before it starts, with the true hold-cap
  fatal — predictive "enough time for the worst-case wait" gating was
  considered and rejected (it would refuse healthy operations whose typical
  wait is ~0, and a clamped variant would misclassify hold-cap exhaustion as
  retryable contention). Functional coverage: `tests/lock_rearm_test.pl`
  (30 cases: full happy path on a real flock, forked contended-acquire with
  canonical error classification, cooperating-hold re-arm, named-lock wedge
  death, nested-exit full re-arm, skip-path non-re-arm, deadline enforcement,
  finalizer tripwire, both confess guards, foreign-alarm handoff, the
  doomed-wait cooperation point at acquire entry, and two `_lock_exec`
  end-to-end cases proving instant re-acquirability after success and after
  body death).

- **The Finding #8 clamp is unconditional** — every `joviandss_cmd` call is clamped to
  `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`, not only cluster-class ones: an unclamped
  call-site literal of 118 under `jdssc_info` would have produced a `run_command` kill
  equal to `LOCK_CLASS_JDSSC_INFO_HOLD_TIMEOUT`, tripping the post-run deadline check on
  a legitimate maximal run (Finding #8 records the reasoning).
- **`get_identity` joined the `jdssc_info` read set** — it issues the identical
  `pool get` command as `status`. The full `jdssc_info` set is: `list_images`, `status`,
  `get_identity`, and `volume_size_info`'s size read.
- **`volume_get_size` stays on the `jdssc_general` default** — its callers
  (`_volume_resize`, `_activate_volume`, `volume_activate`) are all state-changing
  flows; resize serializes cluster-wide.
- **jdssc's internal `--timeout` flag is no longer passed** (Table 10,
  `DEFAULT_JDSSC_TIMEOUT`): `bin/jdssc` defaults it to `None` (unconstrained), so
  `run_command`'s kill (`timeout + 1`) is the sole process bound. The now-unreachable
  `jdssc process timed out` stderr retry branch was removed, and the `jdssc_timeout`
  property description now states the real semantics (default per-call execution
  timeout). **Behavioral note for cluster testing:** every jdssc timeout now ends in a
  hard `SIGKILL` — the old Python-side graceful self-abort no longer exists.
- **Node-backend lock directories are created on demand** — `_lock_exec`'s node branch
  `make_path`s the lock directory before `lock_file` (the retired `_node_lock` used to;
  without it, non-shared `vm`/`storage` locks under `<path>/private/lock/` would fail
  to open). Found by the functional tests.
- **Cross-module constants are called with explicit parens**
  (`OpenEJovianDSS::Common::PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX()`, poll constants):
  `Lock.pm` deliberately does not `use` `Common` (Common already calls into Lock), so
  the parenless form would be a bareword under `strict`.

### How failures feed `joviandss_cmd`'s retry handling

`with_lock` failures flow into the pre-existing `/got timeout/` retry check unchanged:
a `run_command` timeout retries (as before); a contended **node** acquisition
(`can't lock file … got timeout`) also retries — timeout-class; the **cluster** acquire
bound (`got lock request timeout`), hold-cap deadline deaths, and `run_bounded` aborts
all propagate immediately (Finding #13's fail-loud bound).

### Verification performed

- `perl -c` clean on `Lock.pm`, `Common.pm`, both plugins and `NFSCommon.pm` (via stub
  `PVE::*`/CPAN modules — this environment lacks the real ones).
- A 32-case functional suite exercising the **node backend with real `flock`**:
  map key-set equality, getter resolution (defaults, scfg overrides, invalid-type and
  unknown-class dies), `_lock_resolve` paths per Table 6 (including the
  `<class>_lock_path` override), acquire/release, body-die release and
  re-acquirability, re-entry `confess` with registry cleanup, distinct-vmid `vm` locks
  coexisting, deadline enforcement at a cooperation point, `hold_timeout = 0`
  semantics, `run_bounded` overrun and no-cap, and `refresh_locks` `$skip_path`.

### Outstanding

- **Cluster integration testing** (`pve-91-1` / `tests/testcases`): pmxcfs
  stale-reclaim, quorum handling, poll-loop behavior under real contention, and PVE
  core interplay — none of which stubs can exercise. Flip this document's status to
  *verified* once it passes.
- **Release notes** (Finding #14): document `iscsi_change_lock_timeout` and
  `iscsi_target_global_lock_path` as obsolete `storage.cfg` keys — removing their
  declarations drops backward-compat validation for configs that still set them.
