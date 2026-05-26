# jdssc iSCSI Target Lock — Design Document

---

## Problem

Under heavy load, multiple jdssc processes issue iSCSI target modification
requests concurrently. The JovianDSS iSCSI target system does not support
concurrent modification — only one change request may be in flight at a time.

---

## Approach

Serialize individual write-path REST calls using a cluster-wide exclusive lock
on pmxcfs. The lock is a directory created with `os.mkdir()` under
`/etc/pve/priv/lock/`. pmxcfs makes `mkdir` atomically cluster-wide — the same
primitive used by the existing `OpenEJovianDSS::Lock`.

**Lock scope — per REST call, not per jdssc invocation.**
The lock is acquired immediately before each write-path HTTP request and
released immediately after. Read-only calls are not locked. Concurrent
high-level operations on different VMs proceed in parallel; their individual
REST calls are interleaved but each is serialized under the lock.

**Configurable lock path, single global default.**
One lock covers all JovianDSS iSCSI write-path REST calls across all storage
instances and all VMs:

```
/etc/pve/priv/lock/joviandss-iscsi-target-global-lock
```

A per-resource lock would require proving that specific pairs of operations
commute. A single lock eliminates all races without that analysis.

**Global process timeout.**
When `--timeout` is provided, it bounds the total lifetime of the jdssc process.
A dedicated alarm handler releases the lock directly if it fires while a lock is
held, then exits. This prevents a hung REST call from blocking the cluster lock
indefinitely. When `--timeout` is omitted, jdssc runs unconstrained.

---

## Algorithm

```
jdssc starts
    │
    ├─ parse args, load config, setup logging
    │
    ├─ if --timeout provided:
    │     set _alarm_deadline = now + --timeout
    │     set signal.alarm(--timeout)
    │       alarm handler: release _active_lock if set, then raise JDSSLockExecutionTimeout
    │
    ├─ construct JovianDSSDriver (lock config flows via config dict)
    │
    └─ dispatch subcommand
           │
           └─ driver method (e.g. ensure_target_volume)
                  │
                  └─ REST method (e.g. create_target)
                         │
                         ├─ acquire lock:
                         │     if _alarm_deadline set and time_remaining < lock_timeout:
                         │       raise JDSSNotEnoughTimeForOperation
                         │     poll os.mkdir(lock_path) until acquired
                         │       on each failure: os.utime(lock_path, (0,0))
                         │                        sleep(random.uniform(0.1, 0.5))
                         │       on --iscsi-change-lock-timeout exceeded: raise JDSSLockAcquireTimeout
                         │     set _active_lock = lock_path
                         │
                         ├─ HTTP request to JovianDSS
                         │     if --timeout fires at any point:
                         │       alarm handler (if _active_lock set): release_target_lock(_active_lock)
                         │       alarm handler (always):              raise JDSSLockExecutionTimeout
                         │
                         └─ finally (only if try block was entered):
                               release_target_lock(lock_path)
                                   clear _active_lock = None
                                   retry up to 3 times on transient OSError
                                   FileNotFoundError → silent return (idempotent)
                                   all retries exhausted → raise JDSSLockReleaseError
```

**Stale lock recovery.**
The lock is held per-REST-call — acquired immediately before the HTTP request
and released immediately after. A single jdssc invocation may acquire and
release the lock multiple times (once per write-path REST call).

On each failed `os.mkdir` attempt during lock acquisition, `acquire_target_lock`
calls `os.utime(lock_path, (0, 0))`. This is the pmxcfs trigger for stale-lock
removal: pmxcfs deletes the directory if it has been inactive for more than
120 seconds (`CFS_LOCK_TIMEOUT` in `memdb.c:42`). Since the lock is held only
for the duration of a single HTTP request (typically well under 1 s), a
well-behaved jdssc process always removes the lock itself long before the
120 s threshold. The stale-lock mechanism is the fallback for three edge cases:

- **SIGKILL or hardware fault** — process dies before `release_target_lock` runs.
- **`JDSSLockReleaseError` in the alarm handler** — release failed during timeout
  handling; error is swallowed and `JDSSLockExecutionTimeout` is raised instead.
- **Race window in `acquire_target_lock`** — if the alarm fires after `os.mkdir`
  succeeds but before `_active_lock = path` is assigned, the alarm handler sees
  `_active_lock = None` and does not release. The `rest.py` finally block also
  cannot release because `lock_path` has not yet been returned. The lock directory
  persists until the stale-lock timeout fires.

**`iscsi_change_lock_timeout` must be less than 120 s (`CFS_LOCK_TIMEOUT`).**
Each `os.utime` call during acquisition polling resets the pmxcfs 120 s inactivity
timer. If a waiter polls for 120 s or longer while making these calls, it keeps the
dead lock directory alive and stale-lock recovery never fires. The maximum for
`iscsi_change_lock_timeout` is therefore set to `MAX_ISCSI_CHANGE_LOCK_TIMEOUT` — below the 120 s
threshold — to ensure pmxcfs can always reclaim a stale lock within a bounded time.

---

## Exception Handling

Four lock exceptions are defined in `exception.py`, following the existing
`JDSSException` style (inherit from `JDSSException`, set `self.message` and
`self.errcode`):

| Exception | errcode | When raised |
|---|---|---|
| `JDSSLockAcquireTimeout` | 9 | Lock directory could not be created within `--iscsi-change-lock-timeout` seconds |
| `JDSSLockExecutionTimeout` | 10 | Process did not complete within `--timeout` seconds |
| `JDSSLockReleaseError` | 11 | Lock directory could not be removed after all retries |
| `JDSSNotEnoughTimeForOperation` | 12 | Time remaining before process alarm is less than `--iscsi-change-lock-timeout`; lock acquisition would exhaust the timeout |

All four propagate to the top-level handler in `bin/jdssc`:

```python
if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        LOG.error(err, exc_info=True)
        sys.exit(1)
```

The error message is written to stderr unconditionally (via the stderr handler
added in `setup_logging`) and jdssc exits with code 1.

**Behavior in `joviandss_cmd` (Perl).**
`joviandss_cmd` runs jdssc via `PVE::Tools::run_command` with `noerr => 1`.
On exit code 1, stderr is accumulated in `$err` and `die "${err}\n"` is called.
None of the four error strings match `/got timeout/`, so the existing
`run_command` timeout retry loop does not trigger for lock errors.

`joviandss_cmd` already retries on `run_command`-level timeouts (Proxmox
infrastructure kills the process and sets `$rerr =~ /got timeout/`). Analogous
handlers are added for three jdssc lock errors that are safe to retry.

**`JDSSLockExecutionTimeout`** — process self-cleaned (alarm handler released the
lock) or the lock will stale-clear within 120 s. Safe to retry:

```perl
if ( $err && $err =~ /jdssc process timed out/ ) {
    $retry_count++;
    $msg = '';
    $err = undef;
    sleep( 3 + int( rand( 5 ) ) );
    next;
}
```

**`JDSSNotEnoughTimeForOperation` and `JDSSLockAcquireTimeout`** — both mean the
lock was never acquired; the next invocation starts with fresh timeouts and a new
acquisition window. The two error strings are matched by a single handler:

```perl
if ( $err && $err =~ /(?:Not enough time to acquire|Could not acquire) iSCSI target lock/ ) {
    $retry_count++;
    $msg = '';
    $err = undef;
    sleep( 3 + int( rand( 5 ) ) );
    next;
}
```

| Error | Lock state on exit | Perl action |
|---|---|---|
| `JDSSLockAcquireTimeout` | Not held — never acquired | **Retry** after random delay |
| `JDSSLockExecutionTimeout` | Released by alarm handler if possible; may persist up to 120 s if release failed | **Retry** after random delay |
| `JDSSLockReleaseError` | Directory may persist up to 120 s | Propagate; stale lock self-clears |
| `JDSSNotEnoughTimeForOperation` | Not held — never acquired | **Retry** after random delay |

---

## Command Line Arguments

Three arguments are added to the top-level parser in `bin/jdssc` alongside the
existing global options:

| Argument | Type | Default | Constraint | Description |
|---|---|---|---|---|
| `--iscsi-target-lock-path <path>` | string | `DEFAULT_LOCK_PATH` | — | pmxcfs lock directory path. Defaults to the standard joviandss lock path. |
| `--iscsi-change-lock-timeout <seconds>` | int | `MAX_ISCSI_CHANGE_LOCK_TIMEOUT` | `> 0`, `<= MAX_ISCSI_CHANGE_LOCK_TIMEOUT` | Seconds to wait for lock acquisition before raising `JDSSLockAcquireTimeout`. Also the pre-check threshold: if remaining process time is less than this value, raises `JDSSNotEnoughTimeForOperation` instead of attempting acquisition. Hard maximum of `MAX_ISCSI_CHANGE_LOCK_TIMEOUT` enforced by jdssc — must stay below the pmxcfs stale-lock timeout (120 s) to ensure stale-lock recovery can fire. |
| `--timeout <seconds>` | int | — | `> --iscsi-change-lock-timeout + 5` (when provided) | Maximum total process lifetime. When provided, sets a SIGALRM that releases any held lock and exits on expiry. When omitted, jdssc runs unconstrained. Always provided by `joviandss_cmd` via `jdssc_timeout` storage property. |

Locking is always active. The default lock path is used unless a different path
is specified via `--iscsi-target-lock-path`.

When `--timeout` is provided, the `run_command` timeout in `joviandss_cmd` must satisfy:

```
run_command_timeout > --timeout
```

`joviandss_cmd` derives lock args from `$ctx->{scfg}` — lock path from
`iscsi_target_global_lock_path`, lock timeout from `iscsi_change_lock_timeout`,
process timeout from `jdssc_timeout` (passed directly, not calculated):

```
run_command_timeout = jdssc_timeout + 6
```

(`run_command` receives `$timeout + 1` where `$timeout` is floored to `jdssc_timeout + 5`)

| `run_command` timeout | `--timeout` (`jdssc_timeout`) | `--iscsi-change-lock-timeout` |
|---|---|---|
| $default_jdssc_timeout + 6 | $default_jdssc_timeout (default) | JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX (default) |

---

## Implementation Placement

### `jdssc/jdssc/jovian_common/exception.py`

Add four exceptions following the existing pattern:

```python
class JDSSLockAcquireTimeout(JDSSException):
    def __init__(self, path, timeout):
        self.message = (
            "Could not acquire iSCSI target lock '%(path)s' within %(timeout)d seconds"
            % {'path': path, 'timeout': timeout}
        )
        super().__init__(self.message)
        self.errcode = 9

class JDSSLockExecutionTimeout(JDSSException):
    def __init__(self, timeout):
        self.message = (
            "jdssc process timed out after %(timeout)d seconds" % {'timeout': timeout}
        )
        super().__init__(self.message)
        self.errcode = 10

class JDSSLockReleaseError(JDSSException):
    def __init__(self, path, reason):
        self.message = (
            "Failed to release iSCSI target lock '%(path)s': %(reason)s"
            % {'path': path, 'reason': reason}
        )
        super().__init__(self.message)
        self.errcode = 11

class JDSSNotEnoughTimeForOperation(JDSSException):
    def __init__(self, lock_timeout, remaining):
        self.message = (
            "Not enough time to acquire iSCSI target lock: "
            "%(remaining).1f s remaining, %(lock_timeout)d s needed"
            % {'remaining': remaining, 'lock_timeout': lock_timeout}
        )
        super().__init__(self.message)
        self.errcode = 12
```

### `jdssc/jdssc/lock.py`

New module. Owns `_active_lock` — the global flag readable by the alarm handler:

```python
import logging
import os
import time

from jdssc.jovian_common.exception import (
    JDSSLockAcquireTimeout,
    JDSSLockReleaseError,
    JDSSNotEnoughTimeForOperation,
)

LOG = logging.getLogger(__name__)

DEFAULT_LOCK_PATH             = '/etc/pve/priv/lock/joviandss-iscsi-target-global-lock'
MAX_ISCSI_CHANGE_LOCK_TIMEOUT = 115  # must stay below pmxcfs CFS_LOCK_TIMEOUT (120 s)

_RELEASE_RETRIES = 3
_RELEASE_RETRY_DELAY = 0.5  # seconds between release attempts

_active_lock = None    # path of the currently held lock, or None
_alarm_deadline = None # monotonic timestamp when process alarm fires, or None


def acquire_target_lock(path, timeout):
    """Poll os.mkdir until acquired or timeout. Sets _active_lock on success."""
    global _active_lock
    LOG.debug("Acquiring iSCSI target lock '%s' (timeout %d s)", path, timeout)
    if _alarm_deadline is not None:
        remaining = _alarm_deadline - time.monotonic()
        if remaining < timeout:
            LOG.warning(
                "Not enough time to acquire iSCSI target lock '%s': "
                "%.1f s remaining, %d s needed",
                path, remaining, timeout,
            )
            raise JDSSNotEnoughTimeForOperation(timeout, remaining)
    deadline = time.monotonic() + timeout

    while True:
        try:
            os.mkdir(path)
            _active_lock = path
            LOG.debug("iSCSI target lock '%s' acquired", path)
            return path
        except FileExistsError:
            pass
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            LOG.warning(
                "Timed out waiting for iSCSI target lock '%s' after %d s",
                path, timeout,
            )
            raise JDSSLockAcquireTimeout(path, timeout)
        LOG.debug(
            "iSCSI target lock '%s' held by another process, waiting (%.1f s remaining)",
            path, remaining,
        )
        try:
            os.utime(path, (0, 0))
        except OSError:
            pass
        time.sleep(random.uniform(0.1, 0.5))


def release_target_lock(path):
    """Remove lock directory. Idempotent. Retries on transient errors.

    Clears _active_lock immediately so the alarm handler does not attempt
    a concurrent release during the retry loop.
    """
    global _active_lock
    _active_lock = None
    LOG.debug("Releasing iSCSI target lock '%s'", path)

    for attempt in range(_RELEASE_RETRIES):
        try:
            os.rmdir(path)
            LOG.debug("iSCSI target lock '%s' released", path)
            return
        except FileNotFoundError:
            LOG.debug("iSCSI target lock '%s' already released (idempotent)", path)
            return
        except OSError as exc:
            if attempt < _RELEASE_RETRIES - 1:
                LOG.debug(
                    "Failed to release iSCSI target lock '%s' (attempt %d/%d): %s, retrying",
                    path, attempt + 1, _RELEASE_RETRIES, exc,
                )
                time.sleep(_RELEASE_RETRY_DELAY)
            else:
                LOG.error(
                    "Failed to release iSCSI target lock '%s' after %d attempts: %s",
                    path, _RELEASE_RETRIES, exc,
                )
                raise JDSSLockReleaseError(path, exc)
```

### `jdssc/bin/jdssc`

Add the three arguments to the global parser. Set the alarm handler in `main()`
before driver construction:

```python
import time
import jdssc.lock as jlock

def main():
    args, uargs = parse_args()
    config = load_config(args)
    config = unify_config_options(args, config)
    setup_logging(args, config)

    def _alarm_handler(signum, frame):
        import jdssc.lock as _lock
        if _lock._active_lock is not None:
            try:
                _lock.release_target_lock(_lock._active_lock)
            except JDSSLockReleaseError:
                pass  # lock may persist; stale-lock will self-clear after 120 s
        raise JDSSLockExecutionTimeout(args.timeout)

    if args.timeout is not None:
        jlock._alarm_deadline = time.monotonic() + args.timeout
        signal.signal(signal.SIGALRM, _alarm_handler)
        signal.alarm(args.timeout)

    try:
        jdss = JovianDSSDriver(config)
        dispatch(args, uargs, jdss)
    finally:
        signal.alarm(0)
        jlock._alarm_deadline = None
```

### `jdssc/jdssc/jovian_common/rest.py`

Each write-path REST method acquires and releases the lock around the HTTP
request via a shared `_lock()` helper. The caller (driver) is unaware of locking:

```python
import jdssc.lock as jlock

def _lock(self):
    """Acquire iSCSI target lock. Returns lock path.

    iscsi_target_lock_path must always be present in configuration —
    bin/jdssc sets it unconditionally via unify_config_options. If it is
    absent, someone removed a required part of the locking setup.
    """
    lock_path = self.configuration.get('iscsi_target_lock_path')
    if not lock_path:
        raise RuntimeError(
            "iscsi_target_lock_path missing from configuration; "
            "iSCSI target locking has been misconfigured or disabled"
        )
    return jlock.acquire_target_lock(
        lock_path,
        self.configuration.get('lock_timeout', jlock.MAX_ISCSI_CHANGE_LOCK_TIMEOUT),
    )

def create_target(self, target_name, ...):
    lock_path = self._lock()
    try:
        return self._request('POST', '/targets', ...)
    finally:
        jlock.release_target_lock(lock_path)
```

Methods requiring the lock:

| Method | HTTP | Endpoint |
|---|---|---|
| `create_target` | POST | `/san/iscsi/targets` |
| `delete_target` | DELETE | `/san/iscsi/targets/<target_name>` |
| `create_target_user` | POST | `/san/iscsi/targets/<target_name>/incoming-users` |
| `delete_target_user` | DELETE | `/san/iscsi/targets/<target_name>/incoming-users/<user_name>` |
| `set_target_incoming_users_active` | PUT | `/san/iscsi/targets/<target_name>` |
| `set_target_assigned_vips` | PUT | `/san/iscsi/targets/<target_name>` |
| `attach_target_vol` | POST | `/san/iscsi/targets/<target_name>/luns` |
| `detach_target_vol` | DELETE | `/san/iscsi/targets/<target_name>/luns/<lun_name>` |

Methods that do not require the lock: all GET requests (`get_target`, `get_targets`,
`get_target_luns`, `get_target_lun`, `get_target_user`, `get_target_sessions`,
`is_target`, `is_target_lun`, `get_target_by_lun_name`, `get_targets_page`).

### `OpenEJovianDSS/Common.pm`

Add the lock path constant (used as the default value):

```perl
use constant JOVIANDSS_ISCSI_LOCK_PATH                => '/etc/pve/priv/lock/joviandss-iscsi-target-global-lock';
use constant JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX  => 115;  # must stay below pmxcfs CFS_LOCK_TIMEOUT (120 s)
```

Add getter functions following the existing pattern:

```perl
sub get_default_iscsi_target_global_lock_path { return JOVIANDSS_ISCSI_LOCK_PATH }

sub get_iscsi_target_global_lock_path {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return $scfg->{iscsi_target_global_lock_path} || JOVIANDSS_ISCSI_LOCK_PATH;
}

sub get_max_iscsi_change_lock_timeout         { return JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX }

sub get_default_iscsi_change_lock_timeout { return $default_iscsi_change_lock_timeout }

sub get_iscsi_change_lock_timeout {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return int( $scfg->{iscsi_change_lock_timeout} || $default_iscsi_change_lock_timeout );
}

sub get_default_jdssc_timeout { return $default_jdssc_timeout }

sub get_jdssc_timeout {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return int( $scfg->{jdssc_timeout} || $default_jdssc_timeout );
}
```

### `OpenEJovianDSS/Lock.pm`

Provides cluster-wide (pmxcfs mkdir) and node-local (POSIX flock) storage and
per-VM locks. All public and private functions receive `$ctx` as their first
argument so that active lock paths can be stored in the request context rather
than in module-level globals.

**Exported functions:**

```perl
use OpenEJovianDSS::Lock qw(lock_storage lock_vm touch_cluster_lock);
```

**Signatures:**

```perl
# Storage-level lock — serializes all operations on a given storage instance.
sub lock_storage {
    my ($ctx, $storeid, $path, $shared, $timeout, $code, @param) = @_;
    ...
}

# Per-VM lock — serializes operations that target the same VM's volumes.
sub lock_vm {
    my ($ctx, $storeid, $path, $shared, $vmid, $timeout, $code, @param) = @_;
    ...
}
```

`$ctx` is threaded through `_cluster_lock` → `_cluster_lock_attempt` so every
layer can read and write `$ctx->{_active_locks}`.

**Lock tracking in `_cluster_lock_attempt`:**

After the cluster lock directory is successfully created (`mkdir $lockpath`)
and before `$code` is invoked, the lock path is appended to the active-locks
array:

```perl
push @{$ctx->{_active_locks}}, $lockpath;    # track for touch_cluster_lock
$is_code_err = 1;
$res = &$code(@param);
```

Before releasing the lock (`rmdir $lockpath`), the path is removed from the
array:

```perl
pop @{$ctx->{_active_locks}} if $got_lock;  # remove before releasing
rmdir $lockpath if $got_lock;
```

`pop` is used because nested `lock_vm` calls push in LIFO order — the innermost
lock is always at the tail of the array.

**`touch_cluster_lock($ctx)`:**

```perl
sub touch_cluster_lock {
    my ($ctx) = @_;
    for (@{$ctx->{_active_locks}}) {
        utime(undef, undef, $_);
        OpenEJovianDSS::Common::debugmsg($ctx, 'debug', "touch cluster lock '$_'");
    }
}
```

Iterates every path in `$ctx->{_active_locks}` and calls `utime(undef, undef,
$_)` — equivalent to `touch` — which resets pmxcfs's 120 s inactivity timer for
each held cluster lock. No-op when the array is empty (e.g. node-local storage,
or calls made outside a `lock_vm`/`lock_storage` block).

Storing the array in `$ctx` (not in a module-level variable) ensures there are
no forking hazards: each request context owns its own lock list, and a forked
child cannot accidentally touch or release a parent's locks.

`_active_locks` is explicitly initialized to `[]` in `new_ctx` (Common.pm) so
that no caller needs to know about Perl auto-vivification and the field is
always present and defined from context creation.

**No change to `joviandss_cmd`'s signature or call sites.**
Lock arguments are derived inside `joviandss_cmd` from `$ctx->{scfg}` and
pushed onto `$connection_options` before the subcommand, transparently to all
callers. The signature remains:

```perl
sub joviandss_cmd {
    my ( $ctx, $cmd, $timeout, $retries, $force_debug_level, $password ) = @_;
```

Inside the function, after the connection options are assembled and before
`run_command` is called, add:

```perl
    my $lock_path        = get_iscsi_target_global_lock_path($ctx);
    my $lock_timeout     = get_iscsi_change_lock_timeout($ctx);
    my $process_timeout  = get_jdssc_timeout($ctx);

    # Use process_timeout as the run_command base when caller did not specify one.
    $timeout //= $process_timeout;

    # Ensure run_command does not kill jdssc before the alarm handler exits.
    $timeout = $process_timeout + 5
        if $timeout < $process_timeout + 5;

    push @$connection_options,
        '--iscsi-target-lock-path',    $lock_path,
        '--iscsi-change-lock-timeout', $lock_timeout,
        '--timeout',                   $process_timeout;
```

`$process_timeout` is read directly from `jdssc_timeout` storage property.
When `$timeout` is not provided by the caller, it defaults to `$process_timeout`
and is then floored to `$process_timeout + 5` (so `run_command` receives
`$process_timeout + 6`). Callers that pass a timeout larger than
`$process_timeout + 5` are unaffected by the floor.

**Touching the per-VM cluster lock around jdssc execution.**
The pmxcfs cluster lock (per-VM mkdir lock held by `OpenEJovianDSS::Lock`) expires
after 120 s of inactivity. `joviandss_cmd` calls
`OpenEJovianDSS::Lock::touch_cluster_lock()` immediately before and after each
`run_command` invocation to reset the pmxcfs inactivity timer, keeping the cluster
lock alive across jdssc calls regardless of how long each call takes:

```perl
    OpenEJovianDSS::Lock::touch_cluster_lock($ctx);
    $exitcode = run_command( $jcmd,
        outfunc => $output,
        errfunc => $errfunc,
        timeout => $timeout + 1,
        noerr   => 1
    );
    OpenEJovianDSS::Lock::touch_cluster_lock($ctx);
```

`touch_cluster_lock($ctx)` is a no-op when no cluster lock is currently held (e.g.
for jdssc calls that run outside a `lock_vm`/`lock_storage` block). Active lock
paths are stored in `$ctx->{_active_locks}` — an array owned by the request context,
not a module-level global. This avoids any forking hazard and keeps lock state
isolated per context. `touch_cluster_lock` calls `utime(undef, undef, $_)` on
**every** path in that array, resetting pmxcfs's 120 s inactivity timer for each.
This is necessary for nested `lock_vm` calls (e.g. clone/rename across two VMIDs),
where two different lock files are held simultaneously and both must be kept alive.

The assembled command for any jdssc call becomes:

```
/usr/local/bin/jdssc
    [connection options]
    --iscsi-target-lock-path /etc/pve/priv/lock/joviandss-iscsi-target-global-lock
    --iscsi-change-lock-timeout JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX
    --timeout $default_jdssc_timeout
    pool Pool-2 targets delete ...
```

jdssc acquires the lock only inside write-path REST methods (`create_target`,
`delete_target`, etc.). Read-only jdssc invocations receive the lock arguments
but never trigger lock acquisition, so there is no performance impact.

---

## Reference

### Lock Path Naming

The lock path is configurable via the `iscsi_target_global_lock_path` storage
property. The default is:

```
/etc/pve/priv/lock/joviandss-iscsi-target-global-lock
```

No per-storeid or per-tgname component in the default. The lock guards REST API
access, not a specific resource. Two concurrent write-path calls for completely
different targets can still interfere at the API level (e.g. both scanning for
a free LUN slot). A single lock eliminates all such races without requiring
analysis of which operations commute.

#### Granularity comparison

| Granularity | Lock name | Problem |
|---|---|---|
| Per-plugin type | `joviandss-iscsi-target-global-lock` | **Chosen approach.** All write-path calls queue. |
| Per-storage instance | `joviandss-iscsi-<storeid>` | Two pools can race on shared LUN slots |
| Per-target-group | `joviandss-iscsi-<tgname>` | Two VMs on different pools can still race |
| Per-volume | `joviandss-iscsi-<tgname>-<volname>` | Races still occur within the target |

#### Collision avoidance with the per-VM cluster lock

Per-VM cluster lock paths have the form `joviandss-<storeid>-vm-<vmid>`.
The constant `joviandss-iscsi-target-global-lock` does not match any such
pattern — storeids contain pool names and never equal `iscsi`. No collision
is possible.

| Lock | Path |
|---|---|
| VM cluster lock (example) | `joviandss-jdss-Pool-2-vm-107` |
| iSCSI REST lock | `joviandss-iscsi-target-global-lock` |

#### Diagnostic value

```bash
ls /etc/pve/priv/lock/ | grep '^joviandss-'

# Example output during concurrent activations:
joviandss-jdss-Pool-2-vm-107       <- Perl cluster lock (pvedaemon)
joviandss-iscsi-target-global-lock <- iSCSI REST lock (jdssc subprocess)
```

### Concurrency Model

Multiple high-level jdssc operations targeting **different** VMs may run in
parallel. Each operates on its own target and LUN slot. Their REST calls
interleave under the lock but each individual call is safe when serialized:

```
node-1: ensure_target_volume(vm-101)          node-2: ensure_target_volume(vm-102)
  └─► rest.create_target(target-101)            └─► rest.create_target(target-102)
        [acquire lock]                                 [waiting]
        POST /targets → JovianDSS
        [release lock]                           ←     [acquire lock]
                                                       POST /targets → JovianDSS
  └─► rest.attach_lun(target-101, lun-0)               [release lock]
        [acquire lock]
        POST /targets/target-101/luns
        [release lock]
```

The lock does not make a sequence of REST calls within one driver operation
atomic as a group. Between any two consecutive REST calls another jdssc process
can acquire the lock. This is acceptable: high-level operations work on
independent targets and LUN slots.

### Data Flow

```
pvesm <storeid> deactivate vm-107-disk-0
        |
        +-> volume_deactivate (OpenEJovianDSSPlugin.pm)
              |
              +-> lock_vm("vm-107")
                    [mkdir joviandss-jdss-Pool-2-vm-107]       <- cluster lock
                    |
                    +-> _deactivate_volume(...)
                          |
                          +-> volume_deactivate_by_lun_record(...)
                                |
                                +-> volume_unpublish(...)
                                      |
                                      +-> joviandss_cmd(
                                            $cmd = ['pool', 'Pool-2',
                                                    'targets', 'delete', ...],
                                            timeout = 55)
                                              |
                                              | (lock args derived from $ctx->{scfg}
                                              |  inside joviandss_cmd: lock_timeout=$default_iscsi_change_lock_timeout,
                                              |  process_timeout=$default_jdssc_timeout, run_cmd_timeout=$default_jdssc_timeout+6)
                                              |
                                              +-> jdssc
                                                    --iscsi-target-lock-path
                                                      /etc/pve/priv/lock/joviandss-iscsi-target-global-lock
                                                    --iscsi-change-lock-timeout $default_iscsi_change_lock_timeout
                                                    --timeout $default_jdssc_timeout
                                                    pool Pool-2 targets delete
                                                    ...
                                                      |
                                                      signal.alarm(args.timeout)
                                                      |
                                                      +-> Targets.delete()
                                                            |
                                                            +-> driver.remove_export(...)
                                                                  |
                                                                  +-> rest.detach_lun(...)
                                                                  |     [mkdir lock]
                                                                  |     DELETE /luns/...
                                                                  |     [rmdir lock]
                                                                  |
                                                                  +-> rest.delete_target(...)
                                                                        [mkdir lock]
                                                                        DELETE /targets/...
                                                                        [rmdir lock]
```

### Lock Timeout Configuration

When `iscsi_change_lock_timeout` is not set in `storage.cfg`, jdssc receives
`--iscsi-change-lock-timeout $default_iscsi_change_lock_timeout` (50 s by default). Since
the lock is held per-REST-call (typically well under 1 s), this default provides
sufficient headroom. Any value up to `MAX_ISCSI_CHANGE_LOCK_TIMEOUT` is valid.

Three `storage.cfg` properties control the lock:

```perl
# OpenEJovianDSSPlugin.pm — properties()
iscsi_target_global_lock_path => {
    description => 'Path to the pmxcfs lock directory used to serialize iSCSI REST calls.',
    type        => 'string',
    default     => OpenEJovianDSS::Common::get_default_iscsi_target_global_lock_path(),
},
iscsi_change_lock_timeout => {
    description => 'Timeout in seconds to wait for the iSCSI REST serialization lock.',
    type        => 'integer',
    minimum     => 5,
    maximum     => OpenEJovianDSS::Common::get_max_iscsi_change_lock_timeout(),
    default     => OpenEJovianDSS::Common::get_default_iscsi_change_lock_timeout(),
},
jdssc_timeout => {
    description => 'Maximum total jdssc process lifetime in seconds.',
    type        => 'integer',
    minimum     => 10,
    default     => OpenEJovianDSS::Common::get_default_jdssc_timeout(),
},
```

`--timeout` (`jdssc_timeout`) has one constraint enforced at jdssc startup:

```
--timeout > --iscsi-change-lock-timeout + 5   # ensures at least one REST call can complete
```

There is no upper bound on `jdssc_timeout`. The stale-lock mechanism is
governed by how long the lock is held per-REST-call (the HTTP request
duration), not by the total process lifetime. A jdssc invocation may make
multiple REST calls — each acquires and releases the lock independently and
briefly.

`iscsi_change_lock_timeout` has no direct relationship to `jdssc_timeout`, but
it is bounded above by the pmxcfs stale-lock timeout. During acquisition
polling, every failed `os.mkdir` attempt calls `os.utime(path, (0,0))`, which
resets the pmxcfs 120 s inactivity timer. If polling continues for 120 s or
longer, the waiter prevents pmxcfs from reclaiming a dead lock. The maximum
is therefore `MAX_ISCSI_CHANGE_LOCK_TIMEOUT` — a margin below `CFS_LOCK_TIMEOUT` (120 s, `memdb.c:42`).

The `JDSSNotEnoughTimeForOperation` pre-check in `acquire_target_lock` provides
per-call protection — it aborts immediately if remaining time is less than
`--iscsi-change-lock-timeout`, preventing a polling attempt that the alarm
would cut short.

**Key constants — single source of truth.**
Lock path and lock timeout constants exist in both Python and Perl and must be
kept in sync when changed. `jdssc_timeout` has no Python-side default — `--timeout`
has no argparse default and is always provided explicitly by `joviandss_cmd`:

| Location | Symbol | Value |
|---|---|---|
| `jdssc/jdssc/lock.py` | `DEFAULT_LOCK_PATH` | `/etc/pve/priv/lock/joviandss-iscsi-target-global-lock` |
| `OpenEJovianDSS/Common.pm` | `JOVIANDSS_ISCSI_LOCK_PATH` | `/etc/pve/priv/lock/joviandss-iscsi-target-global-lock` |
| `jdssc/jdssc/lock.py` | `MAX_ISCSI_CHANGE_LOCK_TIMEOUT` | 115 |
| `OpenEJovianDSS/Common.pm` | `JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX` | 115 |
| `OpenEJovianDSS/Common.pm` | `$default_iscsi_change_lock_timeout` | 50 |
| `OpenEJovianDSS/Common.pm` | `$default_jdssc_timeout` | 113 |

`MAX_ISCSI_CHANGE_LOCK_TIMEOUT` (115 s) is the hard upper bound — enforced by
jdssc's `--iscsi-change-lock-timeout` validation and used as the fallback in
`rest.py` (`self.configuration.get('lock_timeout', jlock.MAX_ISCSI_CHANGE_LOCK_TIMEOUT)`).
The Perl/storage.cfg default is `$default_iscsi_change_lock_timeout` (50 s) —
a conservative value well below the maximum. When `iscsi_change_lock_timeout`
is not set in `storage.cfg`, `joviandss_cmd` passes
`--iscsi-change-lock-timeout $default_iscsi_change_lock_timeout` (50 s) to jdssc.
In practice the `rest.py` fallback is never reached because `unify_config_options`
always writes `cfg['lock_timeout'] = args.iscsi_change_lock_timeout` before the
driver is constructed.

On the Perl side, `$default_iscsi_change_lock_timeout` and `$default_jdssc_timeout`
in `Common.pm` are used by their respective getters and as defaults in
`OpenEJovianDSSPlugin.pm`'s `properties()` block. There is no automatic link
between the two languages — if any value is changed, both files must be
updated together.

### Files

| File | Change |
|---|---|
| `jdssc/jdssc/jovian_common/exception.py` | Add `JDSSLockAcquireTimeout` (9), `JDSSLockExecutionTimeout` (10), `JDSSLockReleaseError` (11), `JDSSNotEnoughTimeForOperation` (12) |
| `jdssc/jdssc/lock.py` | New module: `DEFAULT_LOCK_PATH`, `MAX_ISCSI_CHANGE_LOCK_TIMEOUT`, `_active_lock`, `_alarm_deadline`, `acquire_target_lock`, `release_target_lock` |
| `jdssc/jdssc/jovian_common/rest.py` | Add lock acquire/release around write-path methods |
| `jdssc/bin/jdssc` | Add three CLI arguments; set alarm handler in `main()` |
| `OpenEJovianDSS/Common.pm` | Add `JOVIANDSS_ISCSI_LOCK_PATH`, `JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX` constants; add getters; inject lock args and `touch_cluster_lock($ctx)` calls inside `joviandss_cmd`; set `$default_jdssc_timeout = 113`, `$default_iscsi_change_lock_timeout = 50`; wrap both `File::Find::find` traversals in eval to tolerate concurrent directory removal |
| `OpenEJovianDSS/Lock.pm` | Add `$ctx` as first param to all functions; push/pop `$ctx->{_active_locks}` in `_cluster_lock_attempt`; export `touch_cluster_lock($ctx)` |
| `OpenEJovianDSSPlugin.pm` | Add `iscsi_target_global_lock_path`, `iscsi_change_lock_timeout`, and `jdssc_timeout` properties and options entries; add `$ctx` as first arg to all `lock_vm`/`lock_storage` call sites; explicit `joviandss_cmd` timeouts set to 118 |
| `OpenEJovianDSSNFSPlugin.pm` | Add `$ctx` as first arg to all `lock_vm`/`lock_storage` call sites (was missing, causing runtime crash when NFS storage operations ran concurrently with iSCSI operations) |

No changes to `driver.py` — locking is fully contained in `lock.py` and `rest.py`.

### Open Questions

1. ~~**Which REST methods need the lock?**~~ — **Resolved.** Write-path only:
   `create_target`, `delete_target`, `create_target_user`, `delete_target_user`,
   `set_target_incoming_users_active`, `set_target_assigned_vips`,
   `attach_target_vol`, `detach_target_vol`.

2. ~~**Lock path**~~ — **Resolved.** Configurable via `iscsi_target_global_lock_path`
   storage property; defaults to `/etc/pve/priv/lock/joviandss-iscsi-target-global-lock`.

3. ~~**Lock timeout tuning**~~ — **Resolved.** `iscsi_change_lock_timeout` storage property
   implemented with `minimum => 5`, `maximum => JOVIANDSS_ISCSI_CHANGE_LOCK_TIMEOUT_MAX` (below pmxcfs `CFS_LOCK_TIMEOUT` of 120 s), `default => $default_iscsi_change_lock_timeout` (50 s).
