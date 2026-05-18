import os
import time

from jdssc.jovian_common.exception import (
    JDSSLockAcquireTimeout,
    JDSSLockReleaseError,
    JDSSNotEnoughTimeForOperation,
)

DEFAULT_LOCK_PATH             = '/etc/pve/priv/lock/joviandss-iscsi-target-global-lock'
MAX_ISCSI_CHANGE_LOCK_TIMEOUT = 115  # must stay below pmxcfs CFS_LOCK_TIMEOUT (120 s)

_RELEASE_RETRIES = 3
_RELEASE_RETRY_DELAY = 0.5

_active_lock = None    # path of the currently held lock, or None
_alarm_deadline = None # monotonic timestamp when process alarm fires, or None


def acquire_target_lock(path, timeout):
    """Poll os.mkdir until acquired or timeout. Sets _active_lock on success."""
    global _active_lock
    if _alarm_deadline is not None:
        remaining = _alarm_deadline - time.monotonic()
        if remaining < timeout:
            raise JDSSNotEnoughTimeForOperation(timeout, remaining)
    deadline = time.monotonic() + timeout

    while True:
        try:
            os.mkdir(path)
            _active_lock = path
            return path
        except FileExistsError:
            pass
        if time.monotonic() >= deadline:
            raise JDSSLockAcquireTimeout(path, timeout)
        try:
            os.utime(path, (0, 0))
        except OSError:
            pass
        time.sleep(1)


def release_target_lock(path):
    """Remove lock directory. Idempotent. Retries on transient errors.

    Clears _active_lock immediately so the alarm handler does not attempt
    a concurrent release during the retry loop.
    """
    global _active_lock
    _active_lock = None

    for attempt in range(_RELEASE_RETRIES):
        try:
            os.rmdir(path)
            return
        except FileNotFoundError:
            return
        except OSError as exc:
            if attempt < _RELEASE_RETRIES - 1:
                time.sleep(_RELEASE_RETRY_DELAY)
            else:
                raise JDSSLockReleaseError(path, exc)
