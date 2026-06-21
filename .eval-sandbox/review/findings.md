# Code Review: rollback-semaphor branch

## Files Reviewed
- [x] OpenEJovianDSS/Common.pm
- [x] OpenEJovianDSS/Lock.pm
- [x] OpenEJovianDSSPlugin.pm
- [x] jdssc/bin/jdssc
- [x] jdssc/jdssc/lock.py (new)
- [x] jdssc/jdssc/jovian_common/driver.py
- [x] jdssc/jdssc/jovian_common/rest.py
- [x] jdssc/jdssc/jovian_common/exception.py
- [x] jdssc/jdssc/volumes.py
- [x] jdssc/jdssc/targets.py
- [x] jdssc/jdssc/target.py
- [x] jdssc/jdssc/volume.py
- [ ] OpenEJovianDSS/NFSCommon.pm (not changed in this branch)
- [ ] OpenEJovianDSSNFSPlugin.pm (changed, not yet reviewed)

## Summary
**REQUEST_CHANGES** — One critical bug in the Python alarm handler, plus a significant
architectural concern: the iSCSI target lock inside jdssc has all call-sites
commented out, leaving the REST API unprotected from concurrent multi-node access.

---

## Critical Issues (Must Fix)

- [ ] `jdssc/bin/jdssc:413` — `_alarm_handler` references `args['timeout']`
  but `args` is still an `argparse.Namespace` at handler registration time.
  `vars(args)` (which makes `args` a dict) is called *inside* the try block,
  after `signal.signal()` is set. If the SIGALRM fires before line
  `args = vars(args)` (possible during slow JovianDSSDriver init), the
  handler crashes with `TypeError: 'Namespace' object is not subscriptable`
  instead of cleanly raising `JDSSLockExecutionTimeout`.
  **Fix**: capture `_timeout_val = args.timeout` before `signal.signal()`,
  use `_timeout_val` inside the handler.

- [ ] `jdssc/jdssc/jovian_common/rest.py` — All `_lock()` / `release_target_lock()`
  call sites inside REST methods (create_target, delete_target, add_credentials,
  set_incoming_users_active, set_target_addresses) are commented out. The new
  `lock.py` module and `rest.py._lock()` method are therefore dead code.
  Without the per-operation lock, two concurrent `jdssc` processes from different
  PVE nodes (each holding different VM-level or storage-level Perl cluster locks)
  can race on iSCSI target REST API calls — exactly the scenario this locking
  was designed to prevent. Either re-enable the locking or document clearly that
  the higher-level Perl cluster lock already provides full exclusion.

---

## Suggestions (Should Consider)

- `jdssc/jdssc/jovian_common/driver.py:828` — `random.randint(1, 100) == 7`
  zombie cleanup runs with 1% probability on every `remove_export` call.
  A deterministic condition (e.g. every N calls, or on error) is more
  predictable and testable.

- `OpenEJovianDSSPlugin.pm:565` — `#TODO: Lock file have to be updated here`
  inside `_rename_volume`. This is unresolved work. Needs a follow-up task or
  comment explaining what "lock file" needs updating and why.

- `jdssc/jdssc/jovian_common/driver.py` — `deleted` in `_delete_volume` retry
  loop is set to `True` in the `JDSSResourceIsBusyException` branch even though
  the volume was not actually deleted. Rename to `handled` to reduce confusion.

- `jdssc/jdssc/volumes.py:264` — `data = self.jdss.get_volume(vd)` result is
  never used. The assignment can be dropped (`self.jdss.get_volume(vd)` only).

- `jdssc/jdssc/volumes.py:252-253` — Commented-out suffix code should be
  removed or tracked in a task.

- `OpenEJovianDSS/Lock.pm:117` — The 119 s execution alarm inside
  `_cluster_lock_attempt` will be overridden by PVE::Tools::run_command
  whenever `joviandss_cmd` is called, because `run_command` sets its own
  `alarm($timeout)` and cancels it on return. The real stale-lock protection
  comes from `touch_cluster_lock` (before/after each run_command), not from
  this alarm. The alarm comment should reflect this, or the alarm value should
  be reconsidered.

---

## Nitpicks (Optional)

- `jdssc/jdssc/jovian_common/rest.py:587-600` — Five identical
  `# lock_path = self._lock() / try: / finally: release` comment blocks
  clutter the code. Either remove them or add a single inline note like
  `# locking now delegated to Perl cluster lock (see Common.pm:joviandss_cmd)`.

- `jdssc/jdssc/targets.py:260` — Logging `LOG.error` for a normal delete
  request is misleading; should be `LOG.debug` or `LOG.info`.

---

---

## Deep Analysis: Python iSCSI Lock Architecture (step-02)

### A. Alarm handler `args['timeout']` — race window and consequences

**Code path:** `bin/jdssc:397-420`

The race window is:
```
signal.alarm(args.timeout)    # timer starts — args is Namespace
# ... no conversion yet ...
try:
    jdss = driver.JovianDSSDriver(config)  # ← network call, can be slow
    args = vars(args)                      # ← args becomes dict HERE
```

If SIGALRM fires before `args = vars(args)`, the handler executes:
```python
raise JDSSLockExecutionTimeout(args['timeout'])
# TypeError: 'Namespace' object is not subscriptable
```

The closure captures `args` by reference, not by value.  Because Python
closures bind late, before line 417 `args` is still a Namespace; after
line 417 it is a dict and `args['timeout']` would work.  The alarm
window is exactly the duration of `JovianDSSDriver.__init__()`, which
opens TCP connections to the JovianDSS REST API — potentially several
seconds on a slow network.

**Downstream consequence:** `TypeError` propagates to `__main__`'s
generic `except Exception` handler, which logs it and exits 1.
Perl's `joviandss_cmd` at Common.pm:948 checks:
```perl
if ( $err && $err =~ /jdssc process timed out/ ) { retry }
```
The TypeError message does **not** match, so Perl does **not** retry and
instead escalates the error — defeating the timeout-and-retry mechanism
that the whole `--timeout` / `JDSSLockExecutionTimeout` design was
intended to provide.

**Secondary finding inside the handler:** The handler does
`import jdssc.lock as _lock` although `jlock` is already imported at
module level (`import jdssc.lock as jlock`, top of file).  While safe
(cached via `sys.modules`), the re-import inside a signal handler is
unnecessary and surprising.

**Fix (minimal):**
```python
_timeout_val = args.timeout          # capture BEFORE signal.signal()
def _alarm_handler(signum, frame):
    if jlock._active_lock is not None:
        try:
            jlock.release_target_lock(jlock._active_lock)
        except JDSSLockReleaseError:
            pass
    raise JDSSLockExecutionTimeout(_timeout_val)
```

### B. iSCSI REST lock commented out — scope and safety assessment

**Commented sites in `rest.py`:** 8 operation methods —
`create_target` (587), `delete_target` (620), `create_target_user`
(656), `set_incoming_users_active` (726), `set_target_assigned_vips`
(763), `delete_target_user` (872), `create_target_lun` (975),
`detach_target_vol` (1022).

**Is the Perl cluster lock sufficient?**

`joviandss_cmd` in Common.pm:
1. Passes `--iscsi-target-lock-path /etc/pve/priv/lock/joviandss-iscsi-target-global-lock`
   and `--timeout` to every jdssc invocation.
2. Wraps the entire `run_command(jdssc …)` call with `touch_cluster_lock`
   before and after.
3. The pmxcfs cluster lock serialises ALL callers across all PVE nodes.

The Perl cluster lock path (`JOVIANDSS_ISCSI_LOCK_PATH`) is a **global**
lock — not per-VM, not per-storage — so it covers all iSCSI target
mutations regardless of which VM or storage triggered them.  If all
iSCSI target changes go through `joviandss_cmd`, the Perl lock provides
full serialisation and the Python `lock.py` layer is redundant.

**Remaining risk:** Direct invocation of `jdssc` (e.g. by a sysadmin,
a test, or future code path that bypasses `joviandss_cmd`) would be
unprotected.  The `_lock()` method still works — its path comes from
`--iscsi-target-lock-path` which jdssc receives — so re-enabling the
commented sites would re-add the Python-level guard at zero cost.

**Dead code inventory:**
- `lock.py`: `acquire_target_lock()`, `release_target_lock()` — never
  called from rest.py or anywhere else in the current branch.
- `rest.py._lock()`: callable but never called.
- Alarm handler's `if _lock._active_lock is not None` cleanup: correct
  but always a no-op because the lock is never acquired.

**Action required:** Either:
1. Re-enable the lock at all 8 sites (recommended — defence in depth,
   cheap, already wired); OR
2. Delete `lock.py`, `rest.py._lock()`, and the 40+ comment lines, and
   document in `Common.pm:joviandss_cmd` that the Perl cluster lock
   provides full iSCSI serialisation.

Leaving the code in its current state (active lock module, commented
call sites, no documentation of intent) is the worst option — the next
reader cannot tell whether this was a deliberate decision or an
incomplete merge.

---

## Positive Notes

- `touch_cluster_lock` design is solid: touching the pmxcfs lock dir before
  and after each `run_command` call prevents stale-lock expiry without
  requiring knowledge of jdssc's internal timing.
- `vm_tag_force_rollback_is_set` retry-then-die pattern is correct: a transient
  pvesh failure must never silently downgrade a force_rollback to blocked.
- `on_add_hook` returning `undef` for PVE 9.x `result 'config'` check is the
  right minimal fix.
- `JDSSCfgParserException` retry in `_delete_volume` addresses a real race with
  stale iSCSI target references.
- The new `jdssc/tests/` suite is a welcome addition and the `_acquire_taget_volume_lun`
  fast-path tests cover the 5-tuple return contract well.
- `get_pool` and `get_target_prefix` now both run through `safe_word()`, good
  input hardening.
- `getfreename` double-check (list + REST GET) correctly closes the race where
  a volume appears between list and name selection.
