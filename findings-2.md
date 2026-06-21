# Code Review Findings — 2026-05-12

## Files Exceeding 1000-Line Limit

| File | Lines | Over by |
|------|-------|---------|
| `OpenEJovianDSS/Common.pm` | 3919 | +2919 — critical |
| `jdssc/jovian_common/driver.py` | 3062 | +2062 — critical |
| `OpenEJovianDSSPlugin.pm` | 1763 | +763 |
| `jdssc/jovian_common/rest.py` | 2088 | +1088 |
| `OpenEJovianDSSNFSPlugin.pm` | 1146 | +146 |

`Common.pm` and `driver.py` are the highest priority for refactoring.

---

## Bugs

### 1. 4-tuple unpack of a 5-tuple return (runtime crash)

`_acquire_taget_volume_lun` returns a 5-tuple since `scsi_id` was added:
`(target_name, lun_id, volume_attached, new_target, scsi_id)`

Two callers still unpack only 4 values and will raise `ValueError` when reached:

- `driver.py:808` — `remove_export`
- `driver.py:849` — `remove_export_snapshot`

Fix: add `_` for the unused scsi_id element.

### 2. Type mismatch in new-target index selection

`driver.py:1308–1315` — `related_targets_indexes` is built with `m.group('id')`
which returns `str`. The loop at `driver.py:1357` compares these against `int`:

```python
for i in range(len(related_targets_indexes) + 1):
    if i not in related_targets_indexes:   # int vs str — always True
```

In Python 3 `0 not in ['0']` is `True`, so the check never skips known indexes.
The function "works" because the fallback `ra.get_target()` call catches existing
targets, but it makes N unnecessary REST calls per invocation when targets are
full. Fix: convert to `int` before the comparison.

---

## Duplicate Export

`Common.pm:97` — `get_debug` is listed twice in `@EXPORT_OK`. Remove one.

---

## SRP Violations

**`Common.pm`** — Single file acts as config getter, password manager, REST
command wrapper, LUN record manager, volume lifecycle, snapshot manager, HA
state, and VM config editor. Should be split into ~4 modules (~800 lines each).

**`OpenEJovianDSSPlugin.pm::path()`** — ~130 lines covering LUN lookup,
activation fallback, path resolution, device detection, and error diagnostics.
Extract `activate_if_needed()` and `get_device_path()`.

**NFS rollback in `OpenEJovianDSSNFSPlugin.pm`** (lines 405–637) — 130+ lines
doing publish, activate, copy, deactivate, unpublish. Extract
`_snapshot_copy()` and `_snapshot_cleanup()`.

---

## Security

No issues found. All shell commands use array refs, no hardcoded secrets,
passwords via `/etc/pve/priv/storage/joviandss/` files.

---

## Missing Input Validation

- `nas_snapshot.py:115–146` — dataset/snapshot names not checked for empty
- `nasvolume.py:66–68` — `nas_volume_name` not checked before use

---

## Test Coverage

Only `jdssc/tests/test_rest.py` (99 lines) covering basic iSCSI REST calls.
Missing: NAS snapshot tests, rollback tests, clone tests, any Perl module tests.
Per `spec.md` completion criteria: unit tests (80%) and system tests (90%) are
both at 0% for NFS features.

---

## Pending Work (matches project-status.md)

- `clone_image` for NFS (VM cloning) — not started
- NFS plugin documentation — not started
- `install.pl` NFS support — not started
- Empty dirs after rollback in `private/mounts/{vmid}/` — cosmetic, open

---

## Minor Issues

- `nas_snapshots.py:142` — redundant `s.get('creation')` check
- `TODO` comment left in `OpenEJovianDSSNFSPlugin.pm:667`
- 4 Python lines exceed 100 chars in `driver.py` and `rest.py`
- NFS plugin uses `my ($a, $b)` style; iSCSI uses `my ( $a, $b )` (cosmetic)
