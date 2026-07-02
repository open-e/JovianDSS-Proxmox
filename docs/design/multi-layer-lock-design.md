# Multi-Layer Lock — Design Document (PROPOSAL / DRAFT)

> **Status: proposal for review.** The lock itself is **not implemented yet**, but
> its NFS prerequisite now **is**: the credential unification and the full `$ctx`
> threading of the `NFSCommon` snapshot/mount helpers have landed (the fresh-`$ctx`
> `NFSCommon::joviandss_cmd` wrapper is retired), so one `$ctx` already threads from
> each NFS method through to `Common::joviandss_cmd`.
>
> This document proposes a **scope-typed lock primitive** (`with_lock`) and, built on
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
  - [Method_locks_are_just_names](#method-locks-are-just-names)
  - [Locking_configuration](#locking-configuration)
  - [Constants](#constants)
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
- [New_Functions](#new-functions)
- [Obsolete_Functions](#obsolete-functions)
- [Relationship_to_Other_Designs](#relationship-to-other-designs)
- [Risks_and_Backward_Compatibility](#risks--backward-compatibility)
- [Files_That_Would_Change](#files-that-would-change-when-implemented)
- [List_of_Tables](#list-of-tables)

## List of Tables
[List_of_Tables](#list-of-tables)

Each table carries a unique `tbl_*` tag, repeated verbatim in its caption. In vim, put
the cursor on a tag below and press `*` (or `#`) to jump straight to the table — and press
it again on the caption tag to jump back.

1. `tbl_lock_backends` — **Lock backends**: pmxcfs `mkdir` vs node `flock` — mechanism, reach, waitability, expiry.
2. `tbl_lock_scopes` — **Lock scopes**: what each of `vm`/`storage`/`node`/`cluster` serializes, its concurrency and backend.
3. `tbl_lock_classes` — **Lock classes**: what each class (`jdssc_cluster`/`jdssc_node`/`multipath`/`vm`/`storage`) protects and where it is taken.
4. `tbl_scope_resolution` — **Scope-to-path resolution**: how `_lock_resolve` maps a scope to `(backend, lock path)`.
5. `tbl_lock_properties` — **Per-class lock properties**: the three `<class>_lock_*` `storage.cfg` options.
6. `tbl_lock_defaults` — **Per-class lock defaults**: default scope, backend, path and timeout per class.
7. `tbl_tuning_constants` — **Tuning and bound constants**: the design's named constants.
8. `tbl_constants_related` — **Related existing constants**: pre-existing constants for context.
9. `tbl_refresh_by_backend` — **Refresh behavior by backend**: what `refresh_locks` does per held-lock backend.
10. `tbl_throughput` — **Scope throughput trade-off**: throughput impact of each jdssc-lock scope.
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
- The scope is **operator-tunable** (`node` / `storage` / `cluster`) with a safe
  default.
- The existing method locks keep their per-VM / per-storage **behavior**, folded into
  the same `with_lock` entry — their semantics are unchanged even though their call sites
  migrate onto it (the deliberate trade in value #4).

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
`OpenEJovianDSS::Common::joviandss_cmd` (`Common.pm:855`), now called directly on the
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
`with_lock($ctx, $name, …)`, takes only the lock **name**, reads its scope from a
**property** (`<class>_lock_type`), derives the backend + path, and runs a code block
under an exclusive lock. Every lock is a caller: `with_lock($ctx, 'jdssc_cluster', …)` /
`with_lock($ctx, 'jdssc_node', …)` (scope from `jdssc_cluster_lock_type` /
`jdssc_node_lock_type`), `with_lock($ctx, 'vm', $vmid, …)` for the method locks, a future
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
`storage`, `jdssc_cluster`, …), plus an optional `$id` sub-key for id-keyed classes
(`vm` + the vmid). It keys the `<class>_lock_*` properties and names *what* a lock protects
— as opposed to a scope, which says how wide it reaches. `vm` and `storage` name both a
class and its default scope.

**Table 3 — Lock classes** · `tbl_lock_classes`

| Class | Protects / serializes | Where the lock is taken | Default scope | Status |
|---|---|---|---|---|
| `jdssc_cluster` | JovianDSS REST API — jdssc commands that must serialize **cluster-wide** | inside `joviandss_cmd`, for cluster-scoped commands | `cluster` | planned |
| `jdssc_node` | JovianDSS REST API — jdssc commands safe to serialize **per host only** | inside `joviandss_cmd`, for node-scoped commands | `node` | planned |
| `multipath` | the host `multipath` service (system-wide device map + semaphore) | around each `multipath` call | `node` | reserved (follow-up) |
| `vm` | operations on one VM (per-vmid method lock) | method wrappers, `with_lock($ctx, 'vm', $vmid, …)` | `vm` | existing |
| `storage` | operations on one storeid (per-storage method lock) | method wrappers, `with_lock($ctx, 'storage', …)` | `storage` | existing |

**`jdssc_cluster` vs `jdssc_node`.** Not every jdssc command needs cluster-wide exclusion.
Rather than one `jdssc` lock whose scope is chosen per call, `joviandss_cmd` selects the lock
**class** per command: host-safe commands take `jdssc_node` (cheap — node-local `flock`, no
corosync), while commands that mutate shared backend state take `jdssc_cluster`. The two are
different lock **names** — hence different paths — so they do **not** serialize against each
other; every command needing cluster-wide exclusion must therefore use `jdssc_cluster`.
`joviandss_cmd` takes a `$lock_class` argument (default `jdssc_cluster`) and passes it
straight to the name-only `with_lock` (see
[Where and how it is acquired](#where-and-how-it-is-acquired)); each tier is tuned
independently via `jdssc_cluster_lock_type` / `jdssc_node_lock_type`.

Each jdssc lock class's scope follows its own `<class>_lock_type` (`jdssc_cluster` →
`cluster`, `jdssc_node` → `node` by default). The method locks — `with_lock($ctx, 'vm', $vmid, …)` /
`with_lock($ctx, 'storage', …)`, scope `vm` / `storage` — remain the **outer** locks;
the jdssc lock is always the **inner** one, taken inside `joviandss_cmd`.
Because everything funnels through `with_lock` → `_lock_exec`, *all* locks — method
and jdssc — share one `_held_locks` registry, refresh, and re-entry guard.

Since the jdssc lock is always innermost and only ever taken from inside
`joviandss_cmd` (a leaf), the ordering is fixed and cannot invert:

```
method lock (vm / storage)  →  jdssc lock (jdssc_node / jdssc_cluster)
```

### The lock API
[The_lock_API](#the-lock-api)

`with_lock` is the **single public entry point**. The caller passes the lock **class**
(and, for id-keyed classes, a separate **id**); the scope is read from a per-class
property, so no lock encodes its mechanism in a function name and adding a component is
configuration, not code:

```perl
# with_lock($ctx, $lock_class, $id, $timeout, $code, @param)
#   $lock_class  the lock class: 'jdssc_cluster' | 'jdssc_node' | 'multipath' | 'vm' | 'storage'
#   $id          sub-key within the class (the vmid for 'vm'); undef for singleton classes
#   $timeout     seconds, or undef → <lock_class>_lock_timeout → backend default
#   $code        coderef run while the lock is held (every held lock is auto-refreshed
#                around it via run_refreshed — the caller never refreshes manually)
#   @param       trailing args forwarded to $code
# All locks are exclusive. Returns the result of $code; dies on failure (acquisition or $code).
sub with_lock {
    my ($ctx, $lock_class, $id, $timeout, $code, @param) = @_;
    my $type     = get_lock_class_type($ctx, $lock_class);              # scope
    $timeout   //= get_lock_class_acquire_timeout($ctx, $lock_class);   # wait-to-acquire, per class
    my $max_hold = get_lock_class_hold_timeout($ctx, $lock_class);      # hold/run cap (SIGALRM)
    my ($backend, $path) = _lock_resolve($ctx, $type, $lock_class, $id);   # dir override applied inside
    return _lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param);
}
```

**Scope is a property, keyed by the lock's *class*** — passed directly, not parsed out of
a name. The `<class>_lock_type` property gives the scope; a per-class default applies when
the operator sets nothing, backed by a global default (`cluster`, the safest):

```perl
my %LOCK_DEFAULT_TYPE = (          # default scope per class
    jdssc_cluster => 'cluster',
    jdssc_node    => 'node',
    multipath     => 'node',
    vm            => 'vm',          # shared → pmxcfs, non-shared → flock
    storage       => 'storage',
);
my %LOCK_CLASS_ACQUIRE_TIMEOUT = ( # seconds to WAIT to acquire, per class
    jdssc_cluster => 600,          # = PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX
    jdssc_node    => 10,
    multipath     => 10,
    vm            => 600,
    storage       => 600,
);
my %LOCK_CLASS_HOLD_TIMEOUT = (    # seconds a class may HOLD/run before run_bounded aborts it
    jdssc_cluster => 115,          # ≤ PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX (117) < CFS_LOCK_TIMEOUT (120)
    jdssc_node    => 115,
    multipath     => 60,
    vm            => 600,
    storage       => 600,
);

# All four getters take ($ctx, $lock_class): the operator's <class>_lock_<attr> override
# from scfg, else the per-class default.
sub get_lock_class_type            { my ($ctx,$c)=@_; $ctx->{scfg}{"${c}_lock_type"}            // $LOCK_DEFAULT_TYPE{$c}          // 'cluster' }
sub get_lock_class_dir             { my ($ctx,$c)=@_; $ctx->{scfg}{"${c}_lock_path"} }                                              # undef → backend default dir
sub get_lock_class_acquire_timeout { my ($ctx,$c)=@_; $ctx->{scfg}{"${c}_lock_acquire_timeout"} // $LOCK_CLASS_ACQUIRE_TIMEOUT{$c} // 10 }
sub get_lock_class_hold_timeout    { my ($ctx,$c)=@_; $ctx->{scfg}{"${c}_lock_hold_timeout"}    // $LOCK_CLASS_HOLD_TIMEOUT{$c}    // 600 }
```

`_lock_resolve` is the one place that maps the resolved `(scope, class, id)` → `(backend,
path)` — composing the lockid from the class plus the optional id:

```perl
sub _lock_resolve {
    my ($ctx, $type, $lock_class, $id) = @_;

    # id-keyed classes: 'vm' is keyed by the vmid (passed as $id); 'storage' by the storeid
    # (intrinsic to $ctx). Singleton classes (jdssc_cluster/jdssc_node/multipath) have no id.
    my $key  = $lock_class eq 'storage' ? $ctx->{storeid} : $id;
    $key     = _sanitize_lockid($key) if defined $key;
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

`_lock_exec` is the private mechanism — the explicit-path primitive that dispatches by
backend, brackets the work with the re-entry guard, and wraps the body in
`run_refreshed` so every held lock is kept alive around it. The caller therefore never
invokes `run_refreshed` itself — taking the lock *is* what refreshes:

```perl
# _lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param)  — exclusive only.
sub _lock_exec {
    my ($ctx, $backend, $path, $timeout, $max_hold, $code, @param) = @_;

    _lock_enter($ctx, $backend, $path);     # re-entry guard + register in _held_locks

    # Run the body under two wrappers: run_bounded caps how long the lock may be *held*
    # (SIGALRM after $max_hold — the backstop for a hung holder), and run_refreshed keeps
    # every held lock alive around it (exception-safe, fires before and after the body).
    my $body = sub { run_bounded($max_hold, sub { run_refreshed($ctx, $code, @param) }) };

    my $res;
    my $ok = eval {
        if ($backend eq 'cluster') {
            $res = _cluster_lock_path($ctx, $path, $timeout, $body);   # mkdir + retry
        } else { # node
            $timeout ||= 10;   # last-resort fallback; per-class default already applied in with_lock
            $res = PVE::Tools::lock_file($path, $timeout, $body);      # flock LOCK_EX
            die $@ if $@;   # lock_file signals acquisition failure / $code die via $@, not by dying
        }
        1;
    };
    my $err = $@;
    _lock_leave($ctx, $path);               # unregister (backend has already released)
    die $err if !$ok;
    return $res;        # single scalar/ref — see "Return convention" below
}
```

`run_bounded` is the **holder-side execution cap**: once the lock is held it arms a
`SIGALRM` for `$max_hold` seconds, and if the body overruns it aborts with a `die`, so the
lock releases on unwind — `fd` close for node, `rmdir` for cluster. This is the backstop
for a hung-but-alive holder, which the node `flock` backend otherwise cannot break (flock
has no idle expiry):

```perl
# run_bounded($max_hold, $code, @param) — run the held body under a hold alarm. Overrun →
# die → lock releases on unwind. $max_hold 0/undef → no cap. Outer alarm saved/restored.
sub run_bounded {
    my ($max_hold, $code, @param) = @_;
    return $code->(@param) unless $max_hold;
    my $prev = alarm(0);                 # suspend any outer alarm
    my $res;
    my $ok = eval {
        local $SIG{ALRM} =
            sub { die "lock hold exceeded ${max_hold}s — aborting to release the lock\n" };
        alarm($max_hold);
        $res = $code->(@param);
        alarm(0);
        1;
    };
    my $err = $@;
    alarm(0);
    alarm($prev) if $prev;               # restore outer alarm (best-effort)
    die $err if !$ok;
    return $res;
}
```

Because the holder releases **its own** lock, this is **race-free** — unlike a waiter-side
"delete the stale lock file and recreate it," which swaps the inode under a still-live
holder and lets two processes hold the lock at once (never do that; it defeats the lock).
The cap is per class via `<class>_lock_max_hold` (default `%LOCK_CLASS_HOLD_TIMEOUT`). **Caveats:**
Perl uses safe signals (delivered between opcodes), so a body wedged in an *uninterruptible*
syscall may not abort until it returns — the ultimate backstop remains process death, which
the kernel-level flock release already covers. Each jdssc run is also already bounded by
`run_command`'s own `timeout`, so `run_bounded` mainly caps long-held **method** locks and
pure-Perl hangs.

`_cluster_lock_path` is a thin acquisition-timeout retry wrapper around the existing
`_cluster_lock_attempt` (which already takes an explicit `$lockpath`); it **replaces**
the retired name-building `_cluster_lock`. Path construction lives only in
`_lock_resolve` — callers pass a **class + id**, never a path or a scope.

#### Return convention — a locked block returns a fixed shape, never `wantarray`

The code block passed to `with_lock` is run through
`PVE::Tools::lock_file`, which invokes it in **scalar context**
(`$res = eval { &$code(@param) }`, `Tools.pm:267`). Any list a block returns is therefore
collapsed to a single value *inside* `lock_file`, before the lock layer ever sees it — so
a `wantarray ? @res : $res[0]` in `_lock_exec` / `run_refreshed` would advertise a list
contract the backend cannot honor (it could only ever yield one element). The lock
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
with_lock($ctx, 'jdssc_cluster', undef, $t, $code);   # REST/jdssc  — scope from jdssc_cluster_lock_type (cluster)
with_lock($ctx, 'jdssc_node',    undef, $t, $code);   # REST/jdssc  — scope from jdssc_node_lock_type (node)
with_lock($ctx, 'multipath',     undef, $t, $code);   # multipath   — scope from multipath_lock_type (default node)
```

For example, with `jdssc_cluster_lock_type` unset, `with_lock($ctx, 'jdssc_cluster', …)`
resolves to a cluster `mkdir` lock at `/etc/pve/priv/lock/joviandss-cluster-jdssc_cluster`,
while `with_lock($ctx, 'jdssc_node', …)` resolves to `/run/lock/joviandss-node-jdssc_node`
— host-local, so it serializes only jdssc on that Proxmox node. A `<class>_lock_path`
property overrides just the path (the backend still follows the type).

### Method locks are just names
[Method_locks_are_just_names](#method-locks-are-just-names)

There are **no dedicated method-lock functions**. The per-VM and per-storage locks are
ordinary `with_lock` calls keyed by class + id — `with_lock($ctx, 'vm', $vmid, …)` and
`with_lock($ctx, 'storage', undef, …)` — whose scope defaults to `vm` / `storage` (the
shared-dependent backend) via `%LOCK_DEFAULT_TYPE`, and which an operator can retune
with `vm_lock_type` / `storage_lock_type` like any other lock.

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

**Options.** Each lock *class* accepts the same three properties. This design only
*declares* the `jdssc_cluster_lock_*` / `jdssc_node_lock_*` triplets (so they are settable
today); the other classes are already honored by the generic getters and become settable
the moment their properties are declared — **no new resolution code**.

**Table 5 — Per-class lock properties** · `tbl_lock_properties`

| Property pattern | Values | Purpose |
|---|---|---|
| `<class>_lock_type` | `node` \| `cluster` \| `storage` \| `vm` | scope/backend of the class's lock |
| `<class>_lock_path` | absolute **directory** | override the lock *directory* (**must match the chosen type's backend**); the filename `joviandss-lock-<class>[-<id>]` is still appended |
| `<class>_lock_acquire_timeout` | seconds | hard **wait-to-acquire** timeout — dies on expiry (`undef` → per-class default) |
| `<class>_lock_hold_timeout` | seconds | hard **hold/run** cap — `run_bounded`'s `SIGALRM` aborts the body past this (`undef` → per-class default) |

Classes in play: `jdssc_cluster` / `jdssc_node` *(declared now)*, and the
generically-honored `vm`, `storage`, `multipath`.

**Defaults** applied when a property is unset — scope from `%LOCK_DEFAULT_TYPE`, path from
`_lock_resolve`, timeout from the resolved backend:

**Table 6 — Per-class lock defaults** · `tbl_lock_defaults`

| Class | Default scope | Resolved backend | Default lock path | Acquire timeout · Hold cap |
|---|---|---|---|---|
| `jdssc_cluster` | `cluster` | pmxcfs `mkdir` | `/etc/pve/priv/lock/joviandss-lock-jdssc_cluster` | retry ≤ 600 s then **die** · hold ≤ 115 s |
| `jdssc_node` | `node` | node-local `flock` | `/run/lock/joviandss-lock-jdssc_node` | 10 s · hold ≤ 115 s |
| `vm` (id=vmid) | `vm` | pmxcfs if `get_shared`, else `flock` | `/etc/pve/priv/lock/joviandss-lock-vm-<vmid>` · `<path>/private/lock/joviandss-lock-vm-<vmid>` | 600 s · hold ≤ 600 s |
| `storage` (id=storeid) | `storage` | pmxcfs if `get_shared`, else `flock` | `/etc/pve/priv/lock/joviandss-lock-storage-<storeid>` · `<path>/private/lock/joviandss-lock-storage-<storeid>` | 600 s · hold ≤ 600 s |
| `multipath` | `node` | `flock` | `/run/lock/joviandss-lock-multipath` | 10 s · hold ≤ 60 s |

- **Global fallback:** a class with no `%LOCK_DEFAULT_TYPE` entry falls back to `cluster`
  (the safest) — see `get_lock_class_type` (`// $LOCK_DEFAULT_TYPE{$class} // 'cluster'`).
- **Backend timeout defaults:** **cluster** = `undef` → the acquisition-timeout retry loop
  (waits under contention, then **dies** after `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX`
  = 600 s with `got lock request timeout` — bounded, not infinite); **node** = per-class
  `%LOCK_CLASS_ACQUIRE_TIMEOUT` via
  `get_lock_class_acquire_timeout($lock_class)` — `jdssc_node`/`multipath` **10 s**,
  `vm`/`storage` **600 s**.
- A `<class>_lock_path` override changes only the path; the **backend still follows the
  type**, so the override must point at a location that backend can use (a pmxcfs path for
  `cluster`, a local path for `node`).

**Choosing a class / scope:**

- **`jdssc_cluster` (default)** — one jdssc at a time cluster-wide, maximum stability;
  used by state-changing commands.
- **`jdssc_node`** — cheapest (no cluster round-trips), serializes only on one host;
  used by host-safe read commands.
- **Retuning a class to `storage` scope does not fully protect a backend** shared by two
  storeids (each serializes independently); keep `cluster` for strict backend safety.

Adding another component (e.g. `multipath`) is just declaring its `<class>_lock_*`
properties and a `%LOCK_DEFAULT_TYPE` entry — no new code. The method-lock classes
(`vm` / `storage`) would take the same knobs once declared, but default to their
structural scope and are not declared here (retuning them is unusual).

The properties are declared in each plugin's `sub properties` / `sub options`
(`OpenEJovianDSSPlugin.pm:143` / `285`, cf. `iscsi_change_lock_timeout` at line 180 — and
the same triplet in `OpenEJovianDSSNFSPlugin.pm`). Because the two plugins are PVE
siblings (each `use base PVE::Storage::Plugin`), that schema would otherwise be
**copy-pasted into both**, as today's shared properties (`control_addresses`, …) already
are. To avoid duplicating it, define the lock-property schema **once** — e.g. a
`lock_properties()` helper in `OpenEJovianDSS::Common` — and splice it into each plugin's
`properties()` / `options()`. The values are read by the **generic** getters
`get_lock_class_type` / `get_lock_class_dir` / `get_lock_class_acquire_timeout($ctx, $name)` (which derive the
class from the name), following the `iscsi_change_lock_timeout`
precedent (`Common.pm:279`).

### Constants
[Constants](#constants)

The tuning and bound values this design relies on, in one place. **Status:** *done* =
already in code; *proposed* = to add during implementation.

**Table 7 — Tuning and bound constants** · `tbl_tuning_constants`

| Constant | Value | Defined in | Status | Role |
|---|---|---|---|---|
| `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` | 117 s | `OpenEJovianDSS::Common` | **done** | Max per-call jdssc execution timeout for a **`jdssc_cluster`** (cluster-scope) hold — bounds how long the lock is **held**; keeps the hold (`run_command`'s `timeout + 1` = 118 s) under `CFS_LOCK_TIMEOUT` (see Risk #8). Does not apply to `jdssc_node` (node `flock` never expires). |
| `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX` | 600 s | `OpenEJovianDSS::Common` | proposed | Max total time a `cluster`-scope lock **acquisition** retries before dying with `got lock request timeout` — this is the **`jdssc_cluster`** acquire bound. Replaces the hardcoded `max_total = 1200` (`Lock.pm:180`); 600 s covers legitimate contention while failing well before a stuck holder reads as a permanent hang (Finding #13). |
| `CFS_LOCK_TIMEOUT` | 120 s | pmxcfs (external) | — | pmxcfs idle expiry for `mkdir` locks under `/etc/pve/priv/lock/`; the ceiling everything else stays below. |
| `PROXMOX_CLUSTER_POLL_BASE_SLEEP` | 0.3 s | `OpenEJovianDSS::Common` | proposed | Cluster poll-loop initial inter-poll sleep. |
| `PROXMOX_CLUSTER_POLL_BACKOFF_STEP` | 0.1 s | `OpenEJovianDSS::Common` | proposed | Added to the poll base each iteration (linear backoff). |
| `PROXMOX_CLUSTER_POLL_JITTER_MAX` | 5 s | `OpenEJovianDSS::Common` | proposed | Uniform jitter upper bound (`rand`). |
| `PROXMOX_CLUSTER_POLL_SLEEP_CAP` | 10 s | `OpenEJovianDSS::Common` | proposed | Max poll base sleep (caps the ramp). |
| `%LOCK_CLASS_ACQUIRE_TIMEOUT` | jdssc_node→10 s, multipath→10 s, vm→600 s, storage→600 s | `OpenEJovianDSS::Lock` | proposed | Per-class `flock` acquisition wait for node-scope locks (read via `get_lock_class_acquire_timeout($class)`, 10 s fallback). Method `vm`/`storage` keep ~600 s — operations legitimately hold 30–90 s; `jdssc_node`/`multipath` use 10 s (local, brief). `jdssc_cluster` is cluster-scope, so it uses the cluster acquire bound instead (row above), not this map. Resolves Finding #9: the bound is **per-class**, not one global node default. |
| `%LOCK_DEFAULT_TYPE` | jdssc_cluster→`cluster`, jdssc_node→`node`, multipath→`node`, vm→`vm`, storage→`storage` | `OpenEJovianDSS::Lock` | proposed | Default scope per lock class; global fallback `cluster`. |
| `%LOCK_CLASS_HOLD_TIMEOUT` | jdssc_cluster→115 s, jdssc_node→120 s, multipath→60 s, vm→600 s, storage→600 s | `OpenEJovianDSS::Lock` | proposed | Per-class hard cap on how long a locked body may run before `run_bounded`'s `SIGALRM` aborts it and releases the lock (read via `get_lock_class_hold_timeout($ctx,$lock_class)`; `<class>_lock_max_hold` overrides; `0`/unset → no cap). Backstop for a hung holder — the node `flock` backend has no idle expiry of its own. **Cluster-scope classes (e.g. `jdssc_cluster`) must stay ≤ `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` (117 s) — well under `CFS_LOCK_TIMEOUT` (120 s) — so the cap fires before another node could stale-reclaim the still-held lock.** Node/flock classes have no such ceiling. |

Related existing constants (context, not introduced here):

**Table 8 — Related existing constants** · `tbl_constants_related`

| Constant | Value | Note |
|---|---|---|
| `$default_jdssc_timeout` | 113 s | Existing default jdssc internal `--timeout`; reconcile with the #8 timeout simplification. |
| `JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX` | 115 s | Existing cap for the old iSCSI-target REST lock; its `--iscsi-change-lock-timeout` plumbing is retired with the REST lock (Risk #14). |

### Where and how it is acquired
[Where_and_how_it_is_acquired](#where-and-how-it-is-acquired)

Inside `joviandss_cmd` (`Common.pm:855`) the run today is (paraphrased,
`Common.pm:948–964`):

```perl
eval {
    my $jcmd = [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ];
    OpenEJovianDSS::Lock::touch_cluster_lock($ctx);          # refresh OUTER locks
    $exitcode = run_command( $jcmd, ..., timeout => $timeout + 1, noerr => 1 );
    OpenEJovianDSS::Lock::touch_cluster_lock($ctx);
};
```

The proposal wraps `run_command` in the jdssc lock. `with_lock` refreshes whatever is held
around the body automatically (it applies the exception-safe `run_refreshed` internally), so
the call site is just the command closure plus a **lock class**. A new trailing `$lock_class`
argument on `joviandss_cmd` names which jdssc lock class to take; **omitting it defaults to
`jdssc_cluster`** (the safest), so existing callers are unchanged:

```perl
# $lock_class — which jdssc lock class to take (new trailing arg). One of:
#   'jdssc_cluster'  → cluster-wide serialization (state-changing commands)  [default]
#   'jdssc_node'     → per-host serialization only (host-safe read commands)
$lock_class //= 'jdssc_cluster';
my $jrun = sub {
    my $jcmd = [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ];
    $exitcode = run_command( $jcmd, ..., timeout => $timeout + 1, noerr => 1 );
};
eval {
    # Plain name-only with_lock: the class's scope comes from its <class>_lock_type
    # property (default jdssc_cluster → cluster, jdssc_node → node). $id and $timeout
    # are both undef here (singleton class, default acquire timeout).
    OpenEJovianDSS::Lock::with_lock($ctx, $lock_class, undef, undef, $jrun);
};
# $@ / $exitcode are then inspected by joviandss_cmd's existing retry loop, exactly as
# today — with_lock dies on any failure (acquisition or the command), so the eval's $@
# is set and the loop sees a failed attempt and retries.
```

**Every jdssc call is locked; only the class varies — there is no unlocked path.** A caller
whose subcommand is cheap and safe to run widely concurrent passes `$lock_class =>
'jdssc_node'`: the high-frequency read paths (`list_images` `OpenEJovianDSSPlugin.pm:1074`,
`status`, `volume_size_info`) — which take **no method lock** today — take the node-scope
`jdssc_node` lock, so routine PVE stat polling serializes only against other jdssc on the
**same host** instead of paying a cluster-wide `mkdir`/corosync round-trip. State-changing
paths omit `$lock_class` and get `jdssc_cluster`. **Caveat:** `jdssc_node` and `jdssc_cluster`
are different lock **names** — hence different paths — so they do **not** serialize against
each other; a `jdssc_node` read is not blocked by a concurrent `jdssc_cluster` write. That is
acceptable for read-only list/size/status (a momentarily stale view self-corrects) and is why
`jdssc_node` is chosen per command, only for subcommands known to tolerate it.

- Taken **per `jdssc` invocation**, not once per method — each hold is short.
- Sits **inside** `joviandss_cmd`'s existing retry loop (`Common.pm:944`): the lock is
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
the cluster-assuming `touch_cluster_lock` / `_active_locks`.

`$ctx->{_held_locks}` is initialized to `[]` in `new_ctx`; records are pushed/popped
by `_lock_enter` / `_lock_leave` and have the form
`{ backend => 'cluster' | 'node', path => ..., acquired_at => <backtrace> }`.

```perl
sub refresh_locks {
    my ($ctx, $skip_path) = @_;                      # $skip_path: a lock being acquired right now
    for my $lock (@{ $ctx->{_held_locks} }) {
        next if defined $skip_path && $lock->{path} eq $skip_path;
        if ($lock->{backend} eq 'cluster') {
            utime(undef, undef, $lock->{path});      # pmxcfs: reset the CFS_LOCK_TIMEOUT idle timer
        }
        # 'node' (flock): no-op — never expires
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

**Table 9 — Refresh behavior by backend** · `tbl_refresh_by_backend`

| Held lock | backend | `refresh_locks` does |
|---|---|---|
| `cluster`, or `vm` / `storage` on shared storage | pmxcfs | `utime` refresh |
| `node`, or `vm` / `storage` on non-shared storage | `flock` | nothing (never expires) |

The refresh window is bounded by one `run_command` (≤ its timeout). Rather than refresh
*during* a long command (which would need a periodic timer conflicting with the execution
alarm), **`joviandss_cmd` clamps the per-call jdssc execution timeout `$timeout` to
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`**, so a single jdssc process — `run_command`'s
`timeout + 1` — stays under the pmxcfs `CFS_LOCK_TIMEOUT` idle expiry, leaving a safe
margin. With each hold bounded this way, the `run_refreshed` brackets `with_lock` applies
around the run keep every held lock inside that window without any mid-command refresh.
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` lives in `OpenEJovianDSS::Common` (read via
`get_proxmox_cluster_lock_timeout_max`), set below `CFS_LOCK_TIMEOUT` like
`JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX`. **Clamping centrally in `joviandss_cmd`** —
rather than editing each of the ~35 call sites — brings any over-cap literal into bounds
automatically: e.g. `list_images` passes `118` (`OpenEJovianDSSPlugin.pm:1074`), above the
`117` cap, and is clamped to `117` (a 118 s hard kill, ~2 s under `CFS_LOCK_TIMEOUT`). For
the clamp to actually bound the hold, the `+5` `process_timeout` floor
(`Common.pm:943–944`) must be dropped so `run_command` follows the clamped `$timeout`
directly — see [Finding #8](#implementation-findings-code-review--to-resolve).

### Lock release
[Lock_release](#lock-release)

Release mirrors acquisition, differs by backend, and **both are exception-safe** —
the lock drops whether `$code` returns or dies.

- **Cluster (pmxcfs `mkdir`):** the lock is a directory, released by `rmdir $lockpath`
  in `_cluster_lock_attempt`'s cleanup (after the `eval` around `$code`, so it fires
  on success and on die), followed by restoring the execution alarm. Because
  `refresh_locks` only runs *inside* `$code` (lock firmly held), no refresh can ever
  `utime` a just-released directory.
- **Node (`flock`):** no explicit unlock — `lock_file` holds the fd only for the
  duration of `$code`; on return or unwind the fd closes and the kernel drops the
  lock (also on process death).

**Guarantees (both backends):**

- Released on **every** exit path — success, `$code` die, or acquisition failure
  (nothing acquired → nothing to release).
- Nothing held is left behind once `with_lock` returns **or dies** — `_lock_exec` runs
  `_lock_leave` and the backend cleanup before re-raising, so the die path leaks nothing.
  The only lingering artifact is a pmxcfs lock directory from a **crashed** holder,
  reclaimed via the stale-lock path (a waiter's `utime(0,0)` after `CFS_LOCK_TIMEOUT`). A crashed
  `flock` holder needs no cleanup.
- `_held_locks` stays in sync (pushed at acquire, removed at release), so
  `refresh_locks` only ever touches currently-held locks.
- **Release always frees the lock that was acquired.** `with_lock` resolves backend +
  path **once, at acquire**, and reuses those exact values at release — never
  recomputes. So a lock whose path depends on mutable config (a `vm` / `storage` lock
  keyed off `get_shared($ctx)`) releases correctly even if that input flips
  **shared → non-shared** mid-flight. This is what makes `shared`-dependent paths safe.

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

sub _lock_enter {
    my ($ctx, $backend, $path) = @_;

    for my $lock (@{ $ctx->{_held_locks} }) {
        next if $lock->{path} ne $path;
        Carp::confess(
            "LOCK BUG: '$path' is already held — re-locking it is forbidden and "
          . "would deadlock; this must never happen, please report it to the dev "
          . "team.\n\n=== held since ===\n$lock->{acquired_at}\n"
          . "=== re-lock attempted here ===" );     # confess appends the current stack
    }

    push @{ $ctx->{_held_locks} },
        { backend => $backend, path => $path, acquired_at => Carp::longmess("acquired '$path'") };
}

sub _lock_leave {
    my ($ctx, $path) = @_;
    @{ $ctx->{_held_locks} } = grep { $_->{path} ne $path } @{ $ctx->{_held_locks} };
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
method lock and a `storage`-scoped jdssc lock — are distinct paths and coexist (see
rule 2).

Ordering rules that still apply:

1. **Consistent ordering.** The jdssc lock is only ever acquired inside `joviandss_cmd`
   (a leaf); it never wraps a method-lock acquisition, so the order is always
   `method → jdssc` and cannot invert.
2. **Distinct paths.** Method and jdssc locks never share a path, so the guard never
   false-positives between them.
3. **Multiple-lock ordering.** A job holding more than one `with_lock` lock must
   acquire them in a fixed order — the dual-VM methods take the two vmids in
   **ascending** order; a future job needing both a jdssc lock and another takes the
   other **outside** `joviandss_cmd`. (Open question #1.)

### Execution alarm and refresh interaction
[Execution_alarm_and_refresh_interaction](#execution-alarm-and-refresh-interaction)

(The **refresh** interaction here applies to the **cluster** backend — the node `flock`
backend has a no-op refresh — but the **hold cap** (`run_bounded`) now arms an execution
`SIGALRM` on **every** backend, node included.)

- `_cluster_lock_attempt` suspends the outer alarm on entry (`alarm(0)`, `Lock.pm:86`)
  and restores it on exit (`Lock.pm:141`), so taking the inner jdssc lock does not let
  the outer method lock's execution alarm fire while we wait for / hold it.
- While a cluster jdssc lock is held it is recorded with `backend => 'cluster'`, so the
  `refresh_locks` calls around `run_command` refresh **both** the outer method lock and
  the inner jdssc lock, keeping both inside the `CFS_LOCK_TIMEOUT` window. A `node`/`flock` entry is
  skipped — it never expires.
- The jdssc lock's own per-attempt execution alarm bounds a single `jdssc` run; since
  `run_command` already has `timeout => $timeout + 1`, the alarm just needs to be ≥
  that timeout.
- **Node acquisition alarm.** `lock_file` waits inside `run_with_timeout($timeout, …)`,
  which sets a temporary `alarm`. When a `node`-scope jdssc lock is taken *inside* an
  outer cluster method lock, confirm `run_with_timeout` saves/restores the outer alarm.
  (Open question #1.)
- **Hold cap (all backends — `run_bounded`).** Once the lock is held, `run_bounded` arms a
  `SIGALRM` for `<class>_lock_max_hold` s; on overrun the body dies and the lock releases on
  unwind. This is the backstop that bounds a **hung-but-alive node holder** — `flock` has no
  idle expiry, so without it a wedged process would pin the lock until death. It saves and
  restores any outer alarm, so it nests with the acquisition alarms above.

### Timeout and retry
[Timeout_and_retry](#timeout-and-retry)

- **Cluster backend** (`_cluster_lock_path`): `undef` timeout → retry loop (retrying only
  on *acquisition* timeout) **bounded by `PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX` (600 s)**;
  a busy cluster waits, then **dies** with `got lock request timeout` once the bound is hit —
  a bounded wait, not an infinite one.
- **Node backend** (`lock_file`): `with_lock` resolves the acquire wait **per class** via
  `get_lock_class_acquire_timeout($lock_class)` (map `%LOCK_CLASS_ACQUIRE_TIMEOUT`:
  `jdssc_node`/`multipath` **10 s**, `vm`/`storage` **600 s**); `_lock_exec` keeps a bare
  `$timeout ||= 10` only as a last-resort fallback. The short-lived `jdssc_node` locks are
  local and brief — a wait beyond ~10 s usually signals a stuck holder — while method locks
  (`vm`/`storage`) legitimately wait up to ~600 s. Tunable per class via
  `<class>_lock_timeout`.
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
  not let a lock this `$ctx` *already holds* go stale. `_lock_enter` has pushed the
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
  `SLEEP_CAP + JITTER_MAX`, well short of the `CFS_LOCK_TIMEOUT` `utime` window:

  ```perl
  # Cluster poll-loop tuning — named constants (in OpenEJovianDSS::Common, alongside
  # PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX):
  #   PROXMOX_CLUSTER_POLL_BASE_SLEEP   = 0.3  initial inter-poll sleep (s)
  #   PROXMOX_CLUSTER_POLL_BACKOFF_STEP = 0.1  added to the base each iteration (s)
  #   PROXMOX_CLUSTER_POLL_JITTER_MAX   = 5    uniform jitter upper bound (s)
  #   PROXMOX_CLUSTER_POLL_SLEEP_CAP    = 10   max base sleep (s)
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
caller needs only one `eval`. The backend conventions `_lock_exec` normalizes into that
die:

- **Cluster** (`_cluster_lock_attempt`): distinguishes lock-machinery errors (prefixed)
  from `$code` errors (re-raised as-is) via `$is_code_err`, and maps quorum loss to a
  clear message; it dies on failure.
- **Node** (`lock_file`): sets `$@ = "can't lock file '…' - …"` on acquisition
  failure/timeout, and leaves a `$code` error in `$@` too — it returns `undef` rather
  than dying. `_lock_exec` therefore does `die $@ if $@` after it, so the node path dies
  on failure like the cluster path.

Either way `with_lock` dies, so `joviandss_cmd`'s existing `eval` inside its retry loop
catches it and inspects `$@`/exit code — retrying or, once retries are exhausted, dying,
exactly as today. The lock is always released before the error propagates.

### Performance trade-off
[Performance_trade_off](#performance-trade-off)

**Table 10 — Scope throughput trade-off** · `tbl_throughput`

| Type | Throughput impact |
|---|---|
| `cluster` | strongest — all `jdssc` serializes cluster-wide, including different pools and nodes |
| `storage` | medium — `jdssc` per storeid (cluster-wide on shared storage, node-local on non-shared); different storeids parallel |
| `node` | lightest — only same-host `jdssc` serializes; cluster-wide concurrency preserved |

The method locks still keep Perl-side method work parallel; the jdssc lock only
serializes the brief windows where `jdssc` actually runs. The `cluster` default trades
throughput for stability; operators who hit a bottleneck can step down.

### Why these choices (rationale)
[Why_these_choices_rationale](#why-these-choices-rationale)

Each decision traces to a [project value](#project-values); disagree with a value and
the conclusion shifts:

- **Default `cluster`** ← *value #1 (safety first)*. The out-of-the-box behavior makes
  a backend collision impossible. An operator who values throughput over absolute
  safety (weakening value #1) would set `node` or `storage`.
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

1. **Lock nesting correctness** — (a) confirm the multiple-lock acquisition order once
   multipath (or other) `with_lock` callers exist (Re-entrancy rule 3); (b) confirm
   `run_with_timeout` (node acquisition) saves/restores the outer cluster lock's
   execution alarm.

*Already decided (folded into the design above):* the **cross-cluster gap is accepted** —
the `cluster` scope is a *single-Proxmox-cluster* lock (it lives in that one cluster's
pmxcfs and serializes only within it), so separate Proxmox clusters sharing a pool via
`cluster_prefix` are **not** serialized here; that protection, if a deployment needs it,
belongs on the JovianDSS appliance side (see Non-goals and Risk #5); the **lock body wraps
only
`run_command`** — the pure-Perl `connection_options` assembly stays outside the lock, so
the hold is as short as possible; the **timeout is per single jdssc execution** (one
`run_command` attempt, not the whole retry loop) and **must not exceed
`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` when the cluster lock is selected**, so the held
cluster lock never reaches the pmxcfs `CFS_LOCK_TIMEOUT` expiry (see the cap in
[Lock refresh](#lock-refresh-keep-alive)); the **Python
REST-level lock inside `jdssc` is removed entirely**, so this design *replaces* it and the
`--iscsi-target-lock-path` / `--iscsi-change-lock-timeout` plumbing (`Common.pm:933–942`)
is retired; the **property names and per-scope default paths** are
confirmed (`jdssc_cluster_lock_*` / `jdssc_node_lock_*` triplets, see
[Locking configuration](#locking-configuration)); lock **granularity** is per command —
`joviandss_cmd` picks `jdssc_cluster` (default) or `jdssc_node`, each operator-tunable;
**NFS parity** is **implemented** (the
fresh-`$ctx` wrapper is gone and the `NFSCommon` helper layer is fully `$ctx`-threaded
— see [Password Resolution Through `$ctx`](password-resolution-through-ctx.md)); and
the **single property-driven entry** is settled — one `with_lock($ctx, $name, …)`
whose scope is the `<class>_lock_type` property, with `lock_vm` / `lock_storage` removed
(no `lock_jdssc` introduced) and the method-lock call sites migrated. The `with_lock` /
`_lock_exec` / `get_lock_class_type` names still want a sign-off.

---

## Function Signature Change
[Function_Signature_Change](#function-signature-change)

The single public lock entry is `with_lock($ctx, $lock_class, $id, $timeout, $code, @param)`
— the caller passes the **class** and (for id-keyed classes like `vm`) a separate **id**,
never a composite name; the scope comes from the class's `<class>_lock_type` property.
`joviandss_cmd` gains **one** new trailing optional argument, `$lock_class`
(`joviandss_cmd($ctx, $cmd, $timeout, $retries, $force_debug_level, $lock_class)`): which
jdssc lock **class** to take — `'jdssc_cluster'` (default) or `'jdssc_node'` — passed
straight to the name-only `with_lock`, so each class's scope follows its own
`<class>_lock_type` property. The only signatures that go away are the method-lock entry
points (`lock_vm` / `lock_storage`); their removal and the call-site migration are covered
under [Obsolete Functions](#obsolete-functions) (and Risk #6).

---

## New Functions
[New_Functions](#new-functions)

In `OpenEJovianDSS/Lock.pm`:

- **`with_lock($ctx, $lock_class, $id, $timeout, $code, @param)`** — the single public entry
  point; `$id` is the sub-key (vmid for `vm`, `undef` for singleton classes), and scope comes
  from the class's `<class>_lock_type` property.
- **`get_lock_class_type($ctx, $lock_class)` / `get_lock_class_dir($ctx, $lock_class)` /
  `get_lock_class_acquire_timeout($ctx, $lock_class)`** + `%LOCK_DEFAULT_TYPE` — read
  `<lock_class>_lock_{type,path,timeout}`, with per-class defaults and a global fallback
  (`cluster`).
- **`_lock_resolve($ctx, $type, $lock_class, $id)`** — composes the lockid from class + id
  and maps the resolved scope → `(backend, path)`.
- **`_lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param)`** — the
  explicit-path primitive that dispatches by backend, brackets the re-entry guard, and wraps
  the body in `run_bounded` (hold cap) + `run_refreshed` (keep-alive) — so `with_lock`
  auto-caps and auto-refreshes; callers never do either manually.
- **`_cluster_lock_path($ctx, $path, $timeout, $code, @param)`** — path-based
  acquisition-timeout retry wrapper around `_cluster_lock_attempt`.
- **`_lock_enter($ctx, $backend, $path)` / `_lock_leave($ctx, $path)`** — the re-entry
  guard / registry over `$ctx->{_held_locks}` (`Carp::confess` on re-lock).
- **`refresh_locks($ctx, $skip_path)`** — backend-agnostic keep-alive; the shared
  primitive, called both by the poll loop and by `run_refreshed`.
- **`run_refreshed($ctx, $code, @param)`** — its exception-safe before/after wrapper,
  applied **automatically by `with_lock`** (via `_lock_exec`) around every locked body —
  an internal mechanism, not a caller-facing helper.
- **`run_bounded($max_hold, $code, @param)`** — holder-side execution cap: arms a `SIGALRM`
  for `$max_hold` s once the lock is held; on overrun the body dies and the lock releases on
  unwind. Applied automatically by `_lock_exec`; `0`/undef → no cap.
- **`get_lock_class_hold_timeout($ctx, $lock_class)`** + `%LOCK_CLASS_HOLD_TIMEOUT` — per-class hold cap
  (`<class>_lock_max_hold` override), with per-class defaults.
- **`get_lock_class_acquire_timeout($lock_class)`** + `%LOCK_CLASS_ACQUIRE_TIMEOUT` — per-class
  `flock` acquisition wait for node-scope locks (`jdssc_node`/`multipath` 10 s, `vm`/`storage`
  600 s; 10 s fallback).

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

---

## Relationship to Other Designs
[Relationship_to_Other_Designs](#relationship-to-other-designs)

- [`cluster-lock-storage-design.md`](cluster-lock-storage-design.md) — defines the
  per-VM / per-storage **method locks** this design nests inside. Those `lock_vm` /
  `lock_storage` entry points are **removed** here; method locks become
  `with_lock($ctx, 'vm', $vmid, …)` / `with_lock($ctx, 'storage', …)` calls, so the
  method and component locks share one registry, refresh, and re-entry guard.
- [Password Resolution Through `$ctx`](password-resolution-through-ctx.md) — the
  **prerequisite**, now **implemented**: retiring `NFSCommon::joviandss_cmd` and
  threading `$ctx` through the `NFSCommon` helpers is what lets the jdssc lock and the
  NFS method lock share one `$ctx->{_held_locks}`.
- **The Python REST-level lock inside `jdssc`** — this design **replaces** it: that lock
  is removed entirely, so the `--iscsi-target-lock-path` / `--iscsi-change-lock-timeout`
  plumbing (`Common.pm:933–942`) is retired. Serialization moves up to this Perl-side
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
- **Default preserves maximum safety.** `joviandss_cmd` defaults to the `jdssc_cluster`
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
   step down to `storage` or `node`.
4. **pmxcfs poll cost under contention.** Cluster-scope acquisition polls via FUSE +
   corosync; a poorly-tuned loop is expensive cluster-wide. Mitigated by the poll-loop
   rules (≥100–200 ms, jitter); `node` scope avoids polling entirely.
5. **Cross-cluster gap is unaddressed.** Separate Proxmox clusters sharing a pool via
   `cluster_prefix` are not serialized by any type (a non-goal here); deployments that
   need it must keep backend-side protection.
6. **Method-lock call-site migration.** Removing `lock_vm` / `lock_storage` moves the
   ~42 method-lock call sites to `with_lock`. Mechanical but broad — a missed or
   mis-named site is a bug. (Mitigated: the old function names vanish, so an un-migrated
   caller fails to compile loudly rather than silently locking the wrong path.)
7. **Nested-acquisition starvation → split-brain on a held lock (newly introduced).**
   Adding the inner `jdssc` lock creates a case absent today: a node can wait a long time
   to acquire it *while already holding* an outer `cluster` method lock. If that wait
   exceeds the `CFS_LOCK_TIMEOUT` pmxcfs idle window with nothing refreshing the outer lock, another
   node stale-reclaims it and both believe they hold it — corruption-class. Closed by
   **two** mechanisms: (a) the per-call jdssc execution timeout is capped at
   **`PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`** when the cluster lock is selected (a single jdssc
   process then runs for `timeout + 1` via `run_command`, staying under `CFS_LOCK_TIMEOUT`;
   see Risk #8 for the `+5`-floor caveat), so no *hold* reaches the pmxcfs expiry;
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
   **Resolution:** when the jdssc lock resolves to `cluster`, **reject/clamp any call whose
   `$timeout` exceeds `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`** — a single jdssc run, and thus the
   cluster-lock hold, then stays under `CFS_LOCK_TIMEOUT`. **Caveat that the guard depends
   on:** today `run_command`'s kill timeout is *not* `$timeout` but
   `max($timeout, get_jdssc_timeout + 5) + 1` (`Common.pm:941–943, 966`, with
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
   `%LOCK_CLASS_ACQUIRE_TIMEOUT` / `get_lock_class_acquire_timeout($lock_class)` — `vm`/`storage`
   keep ~600 s, `jdssc_node`/`multipath` use ~10 s; there is no single global node default.
10. **Poll-loop backoff breaks the per-attempt timeout accounting. _(medium)_**
    `_cluster_lock_attempt` deducts a hardcoded 1 s per sleep — `$timeout = alarm(0) - 1`
    with `sleep(1)` (`Lock.pm:101,109`, comment "sleep costs 1s"). The proposed variable
    backoff (`PROXMOX_CLUSTER_POLL_*`, up to ~15 s/iteration) makes that deduction wrong, so
    the per-attempt budget is mis-decremented (waits far longer or shorter than intended).
    **Fix:** track actual elapsed sleep, not a fixed `- 1`.
11. **Risk #7 mitigation (b) is unimplemented new code. _(medium)_** Today's poll loop only
    `utime(0,0)`s the *target* (`Lock.pm:108`); it does **not** refresh other held locks, so
    mitigation (b) is entirely new — each iteration must call `refresh_locks($ctx, $lockpath)`.
    Relatedly, the design needs `_lock_enter` to push **before** acquisition, whereas the
    current code pushes **after** `mkdir` (`Lock.pm:121`) and `pop`s LIFO (`:139`). If either
    change is missed, the starvation race is live.
12. **The re-entry guard flips currently-working `flock` re-entrancy into a die (extends
    Risk #1). _(medium)_** `PVE::Tools::lock_file` is re-entrant within a PID —
    `lock_file_full` "skips re-acquisition if the same file is already locked by the current
    process" (`Lock.pm:222–224`). The new guard `Carp::confess`es on re-lock, so any path
    that today benignly re-enters a held node lock now dies. **Fix/verify:** audit existing
    flock re-entry before shipping (Risk #1 is the general statement; this is the concrete
    `flock` case).
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
    `joviandss_cmd` is deleted. `jdssc` no longer needs the flags. **Remaining (deliberate):**
    the two `storage.cfg` properties `iscsi_change_lock_timeout` / `iscsi_target_global_lock_path`
    are kept as **inert, accepted-but-unused** options for backward compatibility — nothing
    reads their values now, but existing configs that set them still validate (only the schema
    `default`/`max` helpers and their constants remain). Dropping the properties themselves is
    a config-compat decision left for a later change.

---

## Files That Would Change (when implemented)
[Files_That_Would_Change](#files-that-would-change-when-implemented)

**Table 11 — Files that would change** · `tbl_files_changed`

| File | Change |
|---|---|
| `OpenEJovianDSS/Lock.pm` | add public `with_lock($ctx, $lock_class, $id, …)` (class + id, no composite name; scope from the `<class>_lock_type` property) + `get_lock_class_type` / `get_lock_class_dir` / `get_lock_class_acquire_timeout` + `%LOCK_DEFAULT_TYPE`, private `_lock_resolve` (composes the lockid from class + id) and `_lock_exec` (cluster → `_cluster_lock_path` = `_cluster_lock_attempt` + retry; node → `PVE::Tools::lock_file`); **remove** `lock_vm` / `lock_storage`; **retire** the name-building `_cluster_lock` / `_node_lock`; add the re-entry guard `_lock_enter` / `_lock_leave` over `$ctx->{_held_locks}`; rework `touch_cluster_lock` / `_active_locks` into `refresh_locks` + `run_refreshed`; add the per-class node acquire wait `%LOCK_CLASS_ACQUIRE_TIMEOUT` + `get_lock_class_acquire_timeout`; add the holder-side hold cap `run_bounded` + `%LOCK_CLASS_HOLD_TIMEOUT` + `get_lock_class_hold_timeout` |
| `OpenEJovianDSS/Common.pm` | wrap `run_command` in `joviandss_cmd` with `with_lock($ctx, $lock_class, …)` and add the trailing `$lock_class` arg (`jdssc_cluster` default, `jdssc_node` for host-safe reads); rename the `new_ctx` registry field `_active_locks => []` to `_held_locks => []` (the list the new keep-alive/guard share); add the `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` constant + `get_proxmox_cluster_lock_timeout_max` getter (**done**); **clamp `$timeout` to `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX` centrally in `joviandss_cmd`** so no single jdssc run exceeds the safe bound under a cluster lock (over-cap literals like `list_images`' 118 are bounded automatically — no per-call-site edits, and the `+5` `process_timeout` floor is dropped per Finding #8); add the cluster poll-loop tuning constants `PROXMOX_CLUSTER_POLL_BASE_SLEEP` / `_BACKOFF_STEP` / `_JITTER_MAX` / `_SLEEP_CAP` (used by the `_cluster_lock_attempt` poll loop); add a shared `lock_properties()` schema helper so the lock-property schema (the `jdssc_cluster_lock_*` / `jdssc_node_lock_*` triplets) is defined once and spliced into both plugins (rather than copy-pasted into each) |
| `OpenEJovianDSSPlugin.pm` | splice the shared lock-property schema (`lock_properties()`) into `properties` (143) and `options` (285) — exposing the `jdssc_cluster_lock_*` / `jdssc_node_lock_*` triplets without copy-pasting the schema; **migrate the method-lock call sites** (`lock_vm` / `lock_storage` → `with_lock($ctx, 'vm', $vmid, …` / `'storage', undef, …)`); pass `$lock_class => 'jdssc_node'` from the known-safe read call sites (`list_images`/`status`/`volume_size_info`) so routine polling uses the cheap host-scope jdssc lock (the central clamp already bounds their timeouts) |
| `OpenEJovianDSSNFSPlugin.pm` | splice the **same** shared `lock_properties()` schema into its `properties` / `options`, and the same method-lock migration. NFS jdssc calls already run on the threaded `$ctx` — the prerequisite [Password Resolution Through `$ctx`](password-resolution-through-ctx.md) work is **implemented** |
| `docs/design/multi-layer-lock-design.md` | this document |

The jdssc lock lives inside the shared `joviandss_cmd` path; the plugin files also
change — for the new config properties **and** the method-lock call-site migration.
