# Cluster Lock Storage — Design Document

## Overview

This document describes the custom per-VM locking mechanism implemented for the
JovianDSS Proxmox plugin. It replaces the default `PVE::Storage::Plugin`
storage-level lock with finer-grained locking that allows concurrent operations on
different VMs within the same storage instance.

The implementation lives in `OpenEJovianDSS/Lock.pm` and is used by both the iSCSI
plugin (`OpenEJovianDSSPlugin.pm`) and the NFS plugin (`OpenEJovianDSSNFSPlugin.pm`).

---

## Problem with the Default Proxmox Lock

`PVE::Storage::Plugin::cluster_lock_storage` acquires a single lock per storage
instance, serializing all operations regardless of which VM or volume they target.
Under concurrent workloads (e.g. 7 simultaneous VM clones) this creates unnecessary
queuing — operations on `vm-101` block operations on `vm-102` even though they are
fully independent.

---

## Lock Backend

### Cluster-wide lock (shared storage)

Uses pmxcfs atomic `mkdir`. The pmxcfs FUSE filesystem guarantees that `mkdir(2)` is
cluster-wide atomic — the same primitive used internally by every
`PVE::Cluster::cfs_lock_*` function.

Lock directory: `/etc/pve/priv/storage/joviandss/<storeid>/locks/`
Lock entry: a subdirectory `<lockid>` created by `mkdir`, removed by `rmdir`.

pmxcfs automatically releases lock directories not touched for ~120s. A 60s hard
execution timeout is imposed after acquiring the lock to stay safely within that
window (matching the PVE::Cluster convention).

**The cluster mkdir lock is not re-entrant.** A second `mkdir` on the same path from
the same process blocks forever. This has direct consequences for the locking
architecture — see below.

### Node-local lock (non-shared storage)

Uses `PVE::Tools::lock_file` (`pve-common/src/PVE/Tools.pm:271`) — a wrapper
around `lock_file_full` that acquires an exclusive `flock(2)` on a regular file.
Re-entrant within the same process: `lock_file_full` tracks open handles per PID
in `$lock_handles->{$$}` and skips re-acquisition if the same file is already
locked by the current process.

Lock directory: `<path>/private/lock/`
Lock file:      `<path>/private/lock/<lockid>`

Example: if the storage path is `/mnt/pve/jdss-Pool-2`, locks are placed at
`/mnt/pve/jdss-Pool-2/private/lock/vm-101`.

`<path>` is the value of the `path` property in `storage.cfg`
(see `docs/Plugin-configuration.md` — the `path` property). It is the mount
point of the storage on the local node, e.g. `/mnt/pve/jdss-Pool-2`.

Using the storage path rather than a global system directory (e.g.
`/var/lock/pve-manager/`) keeps lock files co-located with the data they protect
and avoids name collisions between different storage instances.

---

## Lock Entry Naming

Lock entries (subdirectories for cluster locks, files for node-local locks) follow
a consistent naming scheme across both backends.

### Sanitization

Any character outside `[a-zA-Z0-9\-_]` is replaced with `_` before use in a lock
name. In practice all inputs (vmid, volname) are already safe, but sanitization
ensures no path separator or special character can appear.

### Name format

| Granularity | Pattern | Example input | Lock name |
|---|---|---|---|
| Per-storage | `storage` | — | `storage` |
| Per-VM | `vm-<vmid>` | vmid `101` | `vm-101` |

### Full paths

**Cluster-wide** (`/etc/pve/priv/storage/joviandss/<storeid>/locks/`):

```
/etc/pve/priv/storage/joviandss/jdss-Pool-2/locks/storage
/etc/pve/priv/storage/joviandss/jdss-Pool-2/locks/vm-101
```

Each entry is a **directory** created by `mkdir` and removed by `rmdir`.
Each storage instance has its own subdirectory, isolating lock namespaces
between storage instances.

**Node-local** (`<path>/private/lock/`):

```
/mnt/pve/jdss-Pool-2/private/lock/storage
/mnt/pve/jdss-Pool-2/private/lock/vm-101
```

Each entry is a **file** held open with an exclusive `flock`. The `private/`
prefix follows the Proxmox convention for plugin-private directories that should
not be exposed to users.

---

## Lock Granularity

Two levels, from finest to coarsest:

| Level | Lock ID | When used |
|---|---|---|
| Per-VM | `vm-<vmid>` | all operations |
| Per-storage | `storage` | fallback for any unlisted operation |

Concurrent operations on different VMs proceed independently.
Concurrent operations on the same VM are serialized.

---

## Architecture: Per-Method Locking

Each plugin method that requires locking is split into three functions:

```
alloc_image              ← public, called by PVE::Storage                      [plugin file]
  │
  └─► _alloc_image_lock  ← calls Lock::lock_vm(...)                            [plugin file]
            │
            └─► Lock::lock_vm   ← picks backend from $shared flag              [Lock.pm]
                      │
                      ├─ $shared=1 → _cluster_lock                             [Lock.pm]
                      │               mkdir /etc/pve/priv/storage/joviandss/<storeid>/locks/vm-101
                      │               cfs_update()
                      │               └─► _alloc_image                         [plugin file]
                      │               rmdir /etc/pve/priv/storage/joviandss/<storeid>/locks/vm-101
                      │
                      └─ $shared=0 → _node_lock                                [Lock.pm]
                                      flock /mnt/pve/jdss-Pool-2/private/lock/vm-101
                                      └─► _alloc_image                         [plugin file]
```

`_alloc_image` is not calling `_cluster_lock` or `_node_lock` — it is called
**by** them. The lock wraps the work, not the other way around.

The lock wrapper `_alloc_image_lock` lives in the plugin file and has direct
access to all named arguments. It constructs the lock key (e.g. `$vmid`) and
delegates to `Lock::lock_vm` or `Lock::lock_storage` (fallback). `Lock.pm` then
selects the backend (`_cluster_lock` for shared storage, `_node_lock` for
non-shared) based on the `$shared` flag from `$scfg`.

### cluster_lock_storage becomes a strict no-op

`PVE::Storage` still calls `cluster_lock_storage` to wrap certain operations.
Because locking is now handled inside the plugin methods themselves,
`cluster_lock_storage` must be a pure pass-through with no locking:

```perl
sub cluster_lock_storage {
    my ($class, $storeid, $shared, $timeout, $func, @param) = @_;
    return $func->(@param);
}
```

**This is a hard requirement.** If `cluster_lock_storage` were to acquire a
lock, and the plugin method it calls also tries to acquire the same lock, the
process deadlocks. Here is why:

Both `cluster_lock_storage` and `_alloc_image_lock` would try to acquire the
**same** lock for the same VM — e.g. `vm-101` when `vdisk_alloc` is called for
VM 101:

```
1. PVE::Storage::vdisk_alloc(vmid=101)
   └─► cluster_lock_storage acquires lock_vm("vm-101")
         └─► mkdir /etc/pve/.../locks/vm-101   ← SUCCESS, directory created

2. cluster_lock_storage calls $func->()
   └─► alloc_image(vmid=101)
         └─► _alloc_image_lock calls lock_vm("vm-101")
               └─► mkdir /etc/pve/.../locks/vm-101   ← FAILS, directory already exists
                   sleeps 1s, retries...
                   sleeps 1s, retries...
                   ... until 60s execution alarm fires and kills the task
```

The root cause is that `mkdir` on pmxcfs is **not re-entrant**. Unlike
`flock`, which the OS tracks per file-descriptor and allows the same process to
re-acquire, pmxcfs has no concept of "this process already holds this lock".
It simply sees the directory exists and refuses to create it again, regardless
of who created it.

The node-local `flock` backend does **not** have this problem because
`PVE::Tools::lock_file_full` explicitly tracks held locks per PID in
`$lock_handles->{$$}` and skips re-acquisition if the same process already
holds the lock. pmxcfs has no equivalent mechanism.

---

## Call Flow

### Shared storage (cluster-wide lock)

```
PVE::Storage::vdisk_alloc($cfg, $storeid, $vmid=101, ...)
  │
  └─► plugin->cluster_lock_storage(...)   [no-op pass-through]
        │
        └─► $func->()
              │
              └─► plugin->alloc_image($storeid, $scfg, $vmid=101, ...)
                    │
                    └─► _alloc_image_lock($storeid, $scfg, $vmid=101, ...)
                          │  lock_vm($storeid, $path, $shared=1, $vmid=101, $timeout, ...)
                          │
                          └─► _cluster_lock($storeid, "vm-101", ...)
                                mkdir /etc/pve/priv/storage/joviandss/<storeid>/locks/vm-101
                                PVE::Cluster::cfs_update()
                                _alloc_image(...)
                                rmdir /etc/pve/priv/storage/joviandss/<storeid>/locks/vm-101
```

### Non-shared storage (node-local lock)

```
              └─► _alloc_image_lock($storeid, $scfg, $vmid=101, ...)
                    │  lock_vm($storeid, $path, $shared=0, $vmid=101, $timeout, ...)
                    │
                    └─► _node_lock($path, "vm-101", ...)
                          flock /mnt/pve/jdss-Pool-2/private/lock/vm-101
                          _alloc_image(...)
```

---

## Method Split Table

| Public method | Lock wrapper | Lock type | Key source |
|---|---|---|---|
| `alloc_image` | `_alloc_image_lock` | per-VM | `$vmid` |
| `free_image` | `_free_image_lock` | per-VM | parse vmid from `$volname` |
| `clone_image` | `_clone_image_lock` | per-VM | `$vmid` |
| `create_base` | `_create_base_lock` | per-VM | parse vmid from `$volname` |
| `rename_volume` | `_rename_volume_lock` | per-VM | `$target_vmid` |
| `rename_snapshot` | `_rename_snapshot_lock` | per-VM | parse vmid from `$volname` |
| `activate_volume` | `_activate_volume_lock` | per-VM | parse vmid from `$volname` |
| `deactivate_volume` | `_deactivate_volume_lock` | per-VM | parse vmid from `$volname` |

`activate_volume` and `deactivate_volume` are called directly by
`PVE::Storage::activate_volumes` / `deactivate_volumes` — they never go through
`cluster_lock_storage`. Per-method locking is the only way to protect them.


---

## Conformance with Proxmox `$cfs_lock`

`_cluster_lock` is modelled on the private `$cfs_lock` closure in
`PVE::Cluster` (`pve-cluster/src/PVE/Cluster.pm:601`). This section describes
three areas where our implementation diverges or extends Proxmox's behaviour,
and how each should look in the final implementation.

---

### 1. Acquisition timeout and retry strategy (JovianDSS extension)

**Background:** Proxmox's own `$cfs_lock` (`pve-cluster/src/PVE/Cluster.pm:601`)
uses a single acquisition attempt with a 10s default timeout — adequate for
fast filesystem operations. JovianDSS operations are significantly slower: a
single volume allocation or clone involves REST API calls, iSCSI target
creation, and session establishment, each of which can take several seconds.
Under concurrent workloads with many VMs, the lock may be legitimately held for
30–90 seconds, causing a 10s acquisition timeout to fire even though the system
is healthy and the lock will become available shortly.

The previous plugin addressed this in `cluster_lock_storage` by wrapping
`SUPER::cluster_lock_storage` in a retry loop: if acquisition timed out, it
retried rather than failing immediately. Since `cluster_lock_storage` is now a
no-op, this retry logic must move into `_cluster_lock` itself.

**Why retry is safe:** a lock acquisition timeout means the lock was never
acquired and no code ran inside it. There is no risk of double execution —
retrying is identical to a fresh attempt.

**How it should work:**

- **Explicit `$timeout` provided** — single attempt, no retry. The caller has
  expressed a specific deadline and is responsible for handling failure.
- **No `$timeout` provided** — retry loop with the following parameters:
  - `$per_attempt = 120s` — each acquisition attempt budget
  - `$max_total = 600s` — total wall-clock cap across all attempts
  - If remaining time drops below 10s, give up and return error
  - If an attempt times out during acquisition → retry
  - If an attempt fails for any other reason (code error, execution timeout,
    quorum loss) → propagate immediately, do not retry

```
if explicit $timeout:
    single acquisition attempt up to $timeout seconds

else:
    $start = now
    loop:
        $remaining = 600 - (now - $start)
        return error if $remaining <= 10
        $attempt = min(120, $remaining)
        result = _cluster_lock_attempt($attempt, ...)
        return result       if success
        retry               if acquisition timeout error
        return error        if any other error
```

See **Reference Implementation: Retry Loop** below for the full Perl code.

---

### 2. Quorum check on lock failure (Proxmox conformance)

**Problem:** when lock acquisition fails our implementation always reports a
generic timeout error, even when the real cause is a lost cluster quorum
(split-brain). This makes diagnosis harder.

**How it should work:** after the `eval` block, if the lock was never acquired,
check whether the cluster has quorum. If not, replace whatever error was
produced with the clearer `"no quorum!\n"` message. Quorum is detected the same
way Proxmox does it — by testing the write-permission bit on `/etc/pve/local`,
which pmxcfs clears when the node loses quorum:

```perl
my $err = $@;

# If we never got the lock, check whether quorum was lost.
# pmxcfs clears the write bit on /etc/pve/local when quorum is lost,
# so a failed lstat or a non-writable mode means no quorum.
if (!$got_lock) {
    my $st = File::stat::lstat("/etc/pve/local");
    my $quorate = ($st && (($st->mode & 0200) != 0));
    $err = "no quorum!\n" if !$quorate;
}

rmdir $lockpath if $got_lock;
alarm($prev_alarm);
```

---

### 3. Error classification and return convention (Proxmox conformance)

**Problem:** our implementation unconditionally `die`s on any error. Proxmox's
convention — followed by all PVE storage callers — is to return `undef` and
set `$@` on failure. Additionally, Proxmox prefixes errors from the locking
machinery itself with `"cfs-lock '$lockid' error: ..."` to make them
distinguishable from errors thrown by the code running inside the lock.

**How it should work:** use an `$is_code_err` flag set to `1` immediately
before calling `$code`. After the `eval`, if `$is_code_err` is set the error
came from inside the user's code and is re-raised as-is; otherwise it came from
the locking machinery and is prefixed. In both cases set `$@` and return
`undef` rather than `die`ing, so callers can use the standard PVE pattern of
checking the return value and inspecting `$@`.

See **Reference Implementation: `_cluster_lock_attempt`** below for the full code.

---

## Reference Implementations

### `_cluster_lock` — Retry Loop

The primary purpose of `_cluster_lock` is to implement the retry strategy
described in section 1. It does not touch the filesystem or alarms directly —
all of that is delegated to `_cluster_lock_attempt`. It only decides whether
to retry or propagate based on the error type.

```perl
# _cluster_lock($storeid, $lockid, $timeout, $code, @param)
#
# Acquires a cluster-wide pmxcfs mkdir lock for $lockid scoped to $storeid.
# If $timeout is undef, retries on acquisition timeout up to 600s total.
# If $timeout is defined, makes a single attempt with that timeout.
# Returns result of $code on success; returns undef and sets $@ on failure.
sub _cluster_lock {
    my ($storeid, $lockid, $timeout, $code, @param) = @_;

    my $lockdir  = _cluster_lockdir($storeid);
    my $lockpath = "$lockdir/$lockid";

    my $explicit    = defined $timeout;
    my $max_total   = 600;
    my $per_attempt = 120;
    my $start       = time();

    while (1) {
        my $attempt;
        if ($explicit) {
            $attempt = $timeout;
        } else {
            my $remaining = $max_total - (time() - $start);
            if ($remaining <= 10) {
                $@ = "joviandss-lock '$lockid' error: got lock request timeout\n";
                return undef;
            }
            $attempt = ($per_attempt < $remaining) ? $per_attempt : int($remaining);
        }

        my $res = _cluster_lock_attempt($lockdir, $lockpath, $lockid, $attempt, $code, @param);

        # Success: $@ is undef (set by _cluster_lock_attempt on success).
        return $res if !$@;

        my $err = $@;

        # Acquisition timeout without explicit deadline → safe to retry.
        next if !$explicit && $err =~ /acquire timeout/;

        # Anything else (code error, execution timeout, quorum loss,
        # explicit-deadline expiry) → propagate immediately.
        return undef;
    }
}
```

---

### `_cluster_lock_attempt` — Single Acquisition Attempt

Implements the actual pmxcfs mkdir lock: acquire → run code → release.
Modelled on `$cfs_lock` in `pve-cluster/src/PVE/Cluster.pm:601` with three
additions: retry-friendly error string for acquisition timeout, quorum check
on lock failure, and `$is_code_err` flag for error classification.

```perl
# Single attempt: tries to acquire lockpath within $timeout seconds,
# runs $code while holding the lock, then releases.
# Returns result on success ($@ = undef).
# Returns undef and sets $@ on any failure.
sub _cluster_lock_attempt {
    my ($lockdir, $lockpath, $lockid, $timeout, $code, @param) = @_;

    my $prev_alarm  = alarm(0);    # suspend any outer alarm
    my $got_lock    = 0;
    my $is_code_err = 0;
    my $res;

    eval {
        make_path($lockdir);
        die "pve cluster filesystem not online\n" if !-d $lockdir;

        my $timeout_err = sub { die "joviandss lock '$lockid' acquire timeout\n" };
        local $SIG{ALRM} = $timeout_err;

        while (1) {
            alarm($timeout);
            $got_lock = mkdir($lockpath);    # atomic on pmxcfs
            $timeout  = alarm(0) - 1;       # deduct elapsed; sleep costs 1s

            last if $got_lock;

            $timeout_err->() if $timeout <= 0;

            print STDERR "waiting for joviandss lock '$lockid' ...\n";
            utime(0, 0, $lockpath);          # signal pmxcfs to release stale lock
            sleep(1);
        }

        # Hard execution timeout: pmxcfs drops locks not touched for ~120s.
        # We use 60s to stay safely within that window (matching PVE::Cluster).
        local $SIG{ALRM} = sub {
            die "joviandss lock '$lockid' execution timed out\n";
        };
        alarm(60);

        PVE::Cluster::cfs_update();          # ensure latest cluster state

        $is_code_err = 1;                    # errors from here on are from $code
        $res = &$code(@param);

        alarm(0);
    };

    my $err = $@;

    # If we never got the lock, check whether quorum was lost.
    # pmxcfs clears the write bit on /etc/pve/local when quorum is lost.
    # Ref: PVE::Cluster::check_cfs_quorum (pve-cluster/src/PVE/Cluster.pm:116)
    if (!$got_lock) {
        my $st = File::stat::lstat("/etc/pve/local");
        my $quorate = ($st && (($st->mode & 0200) != 0));
        $err = "no quorum!\n" if !$quorate;
    }

    rmdir $lockpath if $got_lock;            # release lock; safe even on error
    alarm($prev_alarm);                      # restore outer alarm

    if ($err) {
        # Code errors are re-raised as-is; lock machinery errors are prefixed.
        # Mirrors $cfs_lock error handling (pve-cluster/src/PVE/Cluster.pm:662).
        if (ref($err) eq 'PVE::Exception' || $is_code_err) {
            $@ = $err;
        } else {
            $@ = "joviandss-lock '$lockid' error: $err";
        }
        return undef;
    }

    $@ = undef;
    return $res;
}
```

---

### `_node_lock` — Node-local flock

Wraps `PVE::Tools::lock_file` (`pve-common/src/PVE/Tools.pm:271`), which
itself wraps `lock_file_full` (`pve-common/src/PVE/Tools.pm:200`). The
underlying implementation:

- Opens or creates the lock file with `IO::File->new(">>")`
- Attempts non-blocking `flock(LOCK_EX | LOCK_NB)` first
- Falls back to blocking `flock(LOCK_EX)` inside `run_with_timeout($timeout)`
- Retries on `EINTR` (signal interruption, see PVE bug #273)
- Re-entrant within the same process: tracks open handles per PID in
  `$lock_handles->{$$}` using a weak reference; a second call from the same
  process on the same file skips acquisition and runs `$code` directly
- Returns `undef` and sets `$@` on failure; returns `$code` result on success

```perl
# _node_lock($path, $lockid, $timeout, $code, @param)
#
# $path    — storage mount path (value of `path` property in storage.cfg)
# $lockid  — lock name (e.g. "vm-101")
# $timeout — seconds to wait for flock acquisition (undef → PVE default 10s)
sub _node_lock {
    my ($path, $lockid, $timeout, $code, @param) = @_;

    my $lockdir  = "$path/private/lock";
    make_path($lockdir);

    my $lockfile = "$lockdir/$lockid";

    my $res = PVE::Tools::lock_file($lockfile, $timeout, $code, @param);
    return undef if $@;    # $@ already set by lock_file; caller checks it
    return $res;
}
```

---

## Concurrency Guarantee

```
VM 101 alloc  ──── lock vm-101 ──────────────────── release vm-101 ──►
VM 102 alloc  ──────────── lock vm-102 ──────────────────── release vm-102 ──►
VM 101 free   ─────────────────── (waits for vm-101 lock) ── lock ── release ──►
```

Operations on different VMs proceed in parallel. Operations on the same VM are
serialized. The storage-level lock is available as a fallback for any operation
not covered by the method split table.

---

## Trade-offs vs cluster_lock_storage Approach

The per-method approach was chosen over a single `cluster_lock_storage` override
that uses `PadWalker` + `caller()` dispatch. Key differences:

| | `cluster_lock_storage` approach | Per-method approach |
|---|---|---|
| PadWalker dependency | Required | Not needed |
| Dispatch table | Required | Not needed |
| `activate`/`deactivate` locking | Not possible | Possible |
| Re-entrancy deadlock risk | None | Present if `cluster_lock_storage` not neutered |
| Future PVE methods (unknown callers) | Fallback lock applied | Run unlocked |
| Code volume | One entry point | N×3 functions |
| Readability per method | Opaque (generic dispatch) | Explicit |

The per-method approach eliminates all fragile introspection at the cost of requiring
`cluster_lock_storage` to be a strict no-op and accepting that any future unknown
PVE::Storage caller will run without locking.

---

## Error Handling

### How Proxmox callers handle errors

Understanding the calling conventions in `PVE::Storage` is essential for choosing
the right error handling in `_method_lock` wrappers.

**`vdisk_alloc` (`pve-storage/src/PVE/Storage.pm:1150`)**

```perl
# Inside the closure passed to cluster_lock_storage:
my $volname = eval { $plugin->alloc_image($storeid, $scfg, $vmid, $fmt, $name, $size) };
my $err = $@;
umask $old_umask;
die $err if $err;
```

`alloc_image` is called inside `eval { }`. If the plugin method **dies**, the
`eval` catches it, `$@ = <the error>`, `$err` is truthy, and `die $err` re-raises
it up the stack — correct behavior.

If instead the plugin method **returns undef and sets `$@`** (without dying), the
`eval` block completes without an exception: `$@ = ""` after the eval, `$err = ""`
(falsy), no re-raise. The caller then concatenates `"$storeid:"` with the undef
volname and returns a broken string. **The error is silently swallowed.**

**`vdisk_clone` (`pve-storage/src/PVE/Storage.pm:1078`)**

`clone_image` is called directly inside the closure (no `eval` wrapper). Any die
from the plugin propagates naturally.

**`vdisk_free` (`pve-storage/src/PVE/Storage.pm:1186`)**

`free_image` is called inside the closure. Return value and `$@` are not checked
after the call — errors are silently swallowed in both Proxmox's implementation and
ours.

---

### Required error convention for `_method_lock` wrappers

Given the above, `_method_lock` wrappers **must die on failure**, not return
`undef`+`$@`. This preserves the die-on-failure contract expected by `vdisk_alloc`'s
closure and all other PVE::Storage callers that use `eval { $plugin->method() }`.

The correct pattern:

```perl
sub alloc_image {
    my ($class, $storeid, $scfg, $vmid, $fmt, $name, $size) = @_;
    return _alloc_image_lock($storeid, $scfg, $vmid, $fmt, $name, $size);
}

sub _alloc_image_lock {
    my ($storeid, $scfg, $vmid, $fmt, $name, $size) = @_;

    my $shared  = $scfg->{shared};
    my $path    = $scfg->{path};

    my $res = OpenEJovianDSS::Lock::lock_vm(
        $storeid, $path, $shared, $vmid, undef,
        sub { _alloc_image($storeid, $scfg, $vmid, $fmt, $name, $size) },
    );
    die $@ if $@;    # re-raise: die expected by eval { $plugin->alloc_image() }
    return $res;
}
```

`die $@ if $@` after `lock_vm` covers two failure modes:
- Lock machinery error (timeout, quorum loss) — set by `_cluster_lock_attempt`
- Code error from `_alloc_image` — re-raised as-is by `_cluster_lock_attempt` when
  `$is_code_err = 1`

In both cases the error propagates as a die, which is what `vdisk_alloc`'s
`eval { }` + `die $err if $err` pattern expects.

---

### Error handling for lock timeout

| | Proxmox `$cfs_lock` | Our `_cluster_lock` |
|---|---|---|
| Timeout behavior | Single attempt, 10s default | Retry loop, 600s total |
| On timeout | Returns `undef`, sets `$@ = "cfs-lock '$lockid' error: got lock request timeout\n"` | Returns `undef`, sets `$@ = "joviandss-lock '$lockid' error: got lock request timeout\n"` |
| Caller receives | `lock_vm` returns `undef`; `die $@ if $@` re-raises | Same |
| User sees | Proxmox task error with the message above | Same, after up to 600s wait |

The extended timeout is intentional: JovianDSS operations (REST calls, iSCSI
target creation, session establishment) can legitimately hold a lock for 30–90s
under concurrent load. Proxmox's 10s default would cause spurious failures.

---

### Summary: error propagation paths

```
_alloc_image dies
  → eval in _cluster_lock_attempt catches it ($is_code_err=1)
  → $@ = the original error (re-raised as-is, not prefixed)
  → _cluster_lock_attempt returns undef
  → _cluster_lock sees $@, propagates undef
  → lock_vm returns undef + $@ set
  → _alloc_image_lock: die $@ if $@   ← re-raises as die
  → vdisk_alloc eval catches it
  → die $err re-raises up the task stack

_cluster_lock_attempt lock timeout (acquisition)
  → $@ = "joviandss-lock '...' error: got lock request timeout\n"
  → _cluster_lock retries if no explicit timeout; otherwise propagates
  → Eventually: lock_vm returns undef + $@ set
  → _alloc_image_lock: die $@ if $@   ← re-raises as die
  → vdisk_alloc eval catches it
  → Task fails with timeout message

_cluster_lock_attempt execution timeout (60s alarm while holding lock)
  → $@ = "joviandss-lock '...' error: joviandss lock '...' execution timed out\n"
  → Lock is released (rmdir), _cluster_lock propagates immediately (not retried)
  → Same path as lock timeout above

No quorum
  → $@ = "joviandss-lock '...' error: no quorum!\n"
  → Propagates immediately (not retried)
```

---

## Public API of Lock.pm

All public functions accept `$path` (the storage mount path) and `$shared` to
select the backend. Signatures:

```perl
lock_storage($storeid, $path, $shared, $timeout, $code, @param)
lock_vm     ($storeid, $path, $shared, $vmid,    $timeout, $code, @param)
```

- `$storeid` — storage id, used to construct the cluster lock directory path
- `$path`    — value of the `path` property from `storage.cfg` (e.g. `/mnt/pve/jdss-Pool-2`);
               used to construct the node-local lock file path; obtained from `$scfg->{path}`
- `$shared`  — if true, use `_cluster_lock`; otherwise use `_node_lock`
- `$timeout` — cluster lock: if defined, single attempt; if undef, retry loop (see section 1).
               node-local lock: passed directly to `PVE::Tools::lock_file`; undef → 10s default

---

## Files

| File | Role |
|---|---|
| `OpenEJovianDSS/Lock.pm` | `_cluster_lock`, `_cluster_lock_attempt`, `_node_lock`, `lock_vm`, `lock_storage` |
| `OpenEJovianDSSPlugin.pm` | Per-method lock wrappers; `cluster_lock_storage` no-op |
| `OpenEJovianDSSNFSPlugin.pm` | Same; NFS-specific timeouts in lock wrappers |

## Dependencies

| Module | Used in | Source |
|---|---|---|
| `PVE::Cluster` | `cfs_update()` in `_cluster_lock_attempt` | `pve-cluster/src/PVE/Cluster.pm` |
| `PVE::Tools` | `lock_file()` in `_node_lock` | `pve-common/src/PVE/Tools.pm:271` |
| `File::Path` | `make_path()` to create lock directories | CPAN |
| `File::stat` | `lstat()` for quorum check in `_cluster_lock_attempt` | Perl core |
