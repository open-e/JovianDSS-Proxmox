# Review Findings — Session 1 (updated 2026-05-07)

---

## 1. pve-testing/testcases/spec.md

### F-1 `fault_injection` vs `negative` — key name mismatch (critical)

The format template (line 118) uses `fault_injection:` as the YAML key.
Every actual test file and the spec's own "How to identify" example (line 259)
and the embedded YAML example (line 340) all use `negative:`.
The template is wrong. Canonical key in use is `negative`.

### F-2 `setup` field is undefined

Line 65 in the template shows `setup:` with no `< description >` placeholder.
In practice files use `setup: []` or a bare `setup:`. The spec never says what
goes here. Either define it (list of pre-test configuration steps, distinct from
`prerequisites`) or remove it.

### F-3 `references` — two incompatible formats in use

The template defines a list of objects (`name`, `type`, `text`). But:
- The embedded example (line 369) and `volume-activation-failure.yaml:78`
  use a plain string: `- OpenEJovianDSSPlugin.pm:336 - Fixed misleading error messages`
- `clone-with-preexisting-snapshot.yaml:170` uses the full object form

One canonical form should be chosen; the spec's own example should use it.

### F-4 `cleanup` steps lack `id` in template but use it in practice

The template shows cleanup steps with only `desc`, `cmd`, `rest`.
In `clone-with-preexisting-snapshot.yaml:199-215`, cleanup steps include `id:`.
The template should include `id` for cleanup steps.

### F-5 `steps` section defined twice

The field appears in the YAML format block (line 113) and again as a separate
`#### Steps` heading at line 163. The second block repeats and partially
contradicts the first. Merge them.

### F-6 `proof` bar inconsistent with examples

The spec says proof must be "mathematical or formal logical" (line 105).
Examples in actual test files are informal if/else logic. The description
overstates the requirement; "logical" alone is more accurate.

### F-7 `plugin/` subfolders missing `review.toon`

The spec requires every folder containing test files to have a `review.toon`.
All 15 subdirectories under `plugin/` have `.yaml` files but no `review.toon`.
The spec itself says `plugin/` is "abandoned and not used" — but files remain.
Clarify: maintained, deprecated in place, or scheduled for deletion?

### F-8 Conflict artifact file

`project-status (conflict_on_2026-04-21).md` exists alongside `project-status.md`
in the testcases root — leftover from a git merge conflict. Should be removed.

### F-9 `data.name` semantics unclear

The template says `name` is "Human friendly name of the variable" but actual
usage is lowercase-kebab identifiers (`pool-name`, `vm-id`) while `parameters.name`
is UPPER_SNAKE_CASE shell variable names (`VM_ID`, `JDSS_IP`). The relationship
between a `data` entry and its corresponding `parameter` is implicit and worth
one explicit sentence.

---

## 2. JovianDSS-Proxmox repository root

### F-10 Binary .deb artifacts committed

Four `.deb` files are in the repo root:
- `open-e-joviandss-proxmox-plugin-latest.deb`
- `open-e-joviandss-proxmox-plugin-v0.11.4-0-g3c21179.deb`
- `open-e-joviandss-proxmox-plugin-v0.11.4-2-g9ee8ea7.deb`
- `open-e-joviandss-proxmox-plugin-v0.11.4-4-gbff93c3.deb`

Build artifacts should not be in source control. They bloat the repo and are
not reproducible.

### F-11 Draft and temporary files in root

These should not be in the repo root:
- `joviandss-review-findings.md` — internal review document
- `proposal_patches_pl1_pl5.md` — internal patch proposals
- `notes` — unnamed notes file
- `volume_stage_iscsi_draft.pm` — draft Perl implementation file

The draft `.pm` file is particularly risky — it could be mistaken for production code.

### F-12 `spec.md` is underdeveloped

Only mentions iSCSI plugin, NFS plugin (one paragraph), and concurrent running.
No mention of: jdssc CLI, CHAP authentication, multipathing, or naming conventions.
The NFS section does not reflect current implementation. "Cuncurrent running" has
a typo.

### F-13 `project-status.md` is 954 lines and growing

Mixes implementation status, architecture notes, design decisions, timing
benchmarks, and a running dev diary in one file. Per the >1000-line rule, splitting
is warranted:
- Status checklist → stays in `project-status.md`
- Architectural learnings → `docs/design/`
- Timing/benchmark results → separate doc or ADR

---

## 3. JovianDSS-Proxmox docs/ — structural problems

### F-14 Two generations of docs, no clear canonical set

PascalCase files (`Quick-Start.md`, `Plugin-configuration.md`, `Networking.md`, …)
appear to be the wiki-mirrored generation. Lowercase-hyphen files
(`quick-start.md`, `plugin-installation-and-configuration.md`, `updating.md`, …)
are a second set covering overlapping topics. `Home.md` links to the GitHub wiki
(`github.com/.../wiki/…`), not to local files — so `docs/` may be a stale mirror.

### F-15 Duplicate content pairs

- `Snapshot-Rollback-and-HA.md` vs `Snapshot-Rollback-and-High-Availability.md`
  — nearly identical; only difference is one is missing a "Related Documentation" footer.
- `JovianDSS-recovery-from-a-major-storage-failure.md` vs
  `joviandss-recovery-from-a-major-storage-failure` (no extension)
- `network-configuration` (no extension) vs `Networking.md`
- `configuring-joviandss-lvm-plugin` (no extension) vs
  `joviandss-lvm-plugin-installation-and-configuration.md`

### F-16 Three files without `.md` extension

`configuring-joviandss-lvm-plugin`, `joviandss-recovery-from-a-major-storage-failure`,
`network-configuration` — GitHub and most markdown renderers will not treat these
as markdown.

---

## 4. JovianDSS-Proxmox docs/ — content problems

### F-17 `Home.md` is outdated

- Roadmap lists "CHAP authentication for iSCSI targets" as future work — CHAP
  is fully implemented and has its own doc.
- Feature table says "Rollback can be done to the latest snapshot only" —
  `force_rollback` with multi-snapshot deletion is implemented and tested.
- No mention of the NFS plugin.
- Overview says "via iSCSI" only.

### F-18 `gathering-logs.md` is vestigial

Title has a typo ("Bug?Mulfanction"). Entire content is one `journalctl` command.
Should be expanded or merged into an existing troubleshooting doc.

### F-19 `network-configuration` has a copy-paste bug

The `down` hook reads `ip route add` instead of `ip route del`:

```
iface vmbr0 inet static
        down /sbin/ip route add 192.168.21.100 dev vmbr0   ← should be 'del'
```

Content is also superseded by `Networking.md`.

### F-20 NFS plugin has no user-facing configuration documentation

`project-status.md` confirms 0%. `Quick-Start-NFS.md` exists but there is no
configuration reference equivalent to `Plugin-configuration.md` for the NFS plugin.

### F-21 Non-English file without explanation

`zasoby-do-diagnostyki-instalacji-i-działania-pluginu.md` is in Polish.
Comprehensive and useful, but nothing in the README or index acknowledges it.

---

## 5. JovianDSS-Proxmox docs/design and docs/adr

### F-22 ADR coverage is sparse

`docs/adr/` has one ADR (`0001-add-chap-auth.md`). Many architectural decisions
are documented only in `project-status.md` change log entries, not as proper ADRs:
- `force_rollback` mechanism and blocker handling
- NFS rollback clone-based approach
- Volume activation state model (stateless, no temp files)
- Cluster locking design (already in `docs/design/` but no ADR)

---

## 6. PL-5 — test scenario, reproduction script, and execution results

### Test scenario

**File:** `pve-testing/testcases/iscsi-plugin/concurrency/parallel-linked-clone-no-orphaned-snapshots.yaml`

Regression test for PL-5: parallel `_clone_object` calls with stale IDX create
a ZFS snapshot on the template volume before detecting that the target ZVOL
already exists. The leaked snapshot is not the origin of any active ZVOL and is
not removed by `qm destroy`.

**Verification logic:** after all clone VMs are destroyed, `GET /volumes/v_base-${TEMPLATE_VMID}-disk-{N}/snapshots`
must return `length == 0` for each of the three template disks. Any remaining
snapshot is an orphan.

**Negative test:** injects a sentinel snapshot via REST after clone destroy to
confirm the count check is not a no-op.

Full YAML text is in the session transcript.

### Reproduction script

**File:** `pve-testing/testcases/gen-scripts/run-parallel-linked-clone-no-orphaned-snapshots.sh`

Shell script following the style of `run-convert-stopped-vm-to-template.sh`
and `run-concurrent-template-conversion-10vms.sh`.

**Flow:**
1. Pre-flight: verify TEMPLATE_VMID and clone IDs are unused
2. Create VM with 3 disks (`--scsi0/1/2 ${STORAGE_ID}:1`)
3. `qm template` — convert to template
4. Launch `NUM_CLONES=4` parallel `qm clone --full 0` operations
5. Verify all clones exit 0 and VMs exist
6. `qm destroy --purge` all clones
7. REST query each template disk for snapshot count;
   print orphan names if count > 0

**Precondition:** BUG-1 (eval wrapper around `volume_unpublish` in
`_rename_volume`) must be fixed; otherwise `qm template` on a never-started
VM fails immediately because the iSCSI target does not exist on JovianDSS.

Full script text is in the session transcript.

### Test execution results (2026-05-07, pve-91-1)

Ran 3 times with `SKIP_CLEANUP=1` on pve-91-1 (single node, `jdss-Pool-0`,
`Pool-0`, `TEMPLATE_VMID=321`, `FIRST_CLONE_ID=5821`, `NUM_CLONES=4`).

**Results: 20/20 PASS on all runs. PL-5 not triggered.**

Root cause: the Proxmox joviandss lock `joviandss-jdss-Pool-0-vm-321` fully
serialises all parallel `qm clone` operations on a single node. The output shows
hundreds of `waiting for joviandss lock …` lines before each clone gets the lock;
all 4 clones ran sequentially despite being launched with `&`. No two
`_clone_object` calls ever executed concurrently, so the race cannot fire.

Additionally, clone VMIDs are pre-assigned (5821–5824), making ZVOL names
deterministic (`v-5821-disk-0`, etc.) — there is no IDX-based name collision
possible even if the lock were absent.

**Code confirmed unfixed:** `driver.py` lines 598–603 still raise
`JDSSVolumeExistsException` without cleaning up the orphan snapshot:
```python
except jexc.JDSSVolumeExistsException as jerr:
    if jcom.is_snapshot(cvname):
        LOG.debug(...)
    else:
        raise jerr   # ← snapshot created at line 574 is NOT deleted here
```
The `delete_snapshot` cleanup on lines 607–618 only executes for other
`JDSSException` subclasses, not for `JDSSVolumeExistsException`.

**To reproduce PL-5:** a multi-node scenario is required where two cluster nodes
clone the same template simultaneously without a shared lock preventing
concurrency at the `_clone_object` level, or a scenario where the lock window
is narrower than the create_snapshot+create_volume_from_snapshot pair.

---

## 7. Issue-8 — Silent partial template conversion under heavy REST load

### Summary

Under 20-VM × 4-disk concurrent `qm template` load, JovianDSS REST calls
occasionally time out. The volume rename (`vm-*` → `v_base-*`) fails silently,
but `qm template` still exits 0. The volume is left permanently unrenamed on
JovianDSS. The cleanup (`qm destroy --purge`) cannot find or delete it.

### Reproduction

**Script:** `pve-testing/testcases/gen-scripts/run-convert-stopped-vm-to-template-20vms.sh`

**Environment:** pve-91-1 (NODE1) + 172.28.143.18 (NODE2), `jdss-Pool-0`,
`Pool-0`, 20 VMs (IDs 350–369, 4 disks each, `--kvm 0`).

**Observed behaviour:**

Run 1 (2026-05-07): **155/180 — 25 FAIL**
- Multiple `JovianDSS command timed out after 0 retries` messages during
  concurrent `qm template` phase
- Affected VMs: 351 (disk 1-3), 353 (all disks), 354 (disk 1-3), 357 (all),
  359 (all), 360 (disk 1-3), 365 (all)
- Cleanup error: `Could not remove disk 'jdss-Pool-0:vm-351-disk-1', check
  manually: None of interfaces: 192.168.28.100 responded …`

Run 2 (2026-05-07): **179/180 — 1 FAIL**
- One `JovianDSS command timed out after 0 retries` message
- Affected: VM 352 disk-3 (`v_base-352-disk-3` missing; volume still
  named `v_vm-352-disk-3` on JovianDSS — confirmed via REST GET)
- Cleanup error: same "None of interfaces responded" for `v_vm-352-disk-3`

Confirmed orphaned volume after run 2:
```
GET /api/v4/pools/Pool-0/volumes/v_vm-352-disk-3
→ { "data": { "name": "v_vm-352-disk-3" }, "error": null }
```

### Key symptom

`JovianDSS command timed out after 0 retries` — the REST call timed out on the
first attempt and was not retried at all. This suggests either the retry count
is configured to 0, or the timeout threshold is too short under concurrent
REST load (80 simultaneous operations: 20 VMs × 4 disks).

### Impact

- `qm template` reports success (exit 0) on partial conversion — disks that
  timed out are silently skipped
- The converted VM's Proxmox config says `template: 1` but some disks still
  have the `vm-*` prefix instead of `v_base-*`
- Linked clones from this "template" would fail or produce corrupt VMs for
  the unconverted disks
- The unrenamed volume cannot be cleaned up by `qm destroy --purge` because
  Proxmox looks for `vm-*` names and the JovianDSS plugin also cannot reach
  it under load

### Code location to investigate

The timeout and retry logic is in:
- `jdssc/jdssc/jovian_common/rest.py` — REST client, timeout and retry config
- `OpenEJovianDSS/Common.pm` — `joviandss_cmd` wrapper; controls retry count
  and timeout passed to jdssc invocations
- The rename path: `OpenEJovianDSSPlugin.pm` → `_rename_volume` →
  `jdssc volume <volname> rename <newname> --idempotent` → REST PUT /volumes

The `"after 0 retries"` string indicates a code path that exhausts retries
immediately — worth checking whether the rename call uses a different (lower)
retry/timeout configuration than other operations.

### Suggested fix direction

1. In the plugin: after `qm template`, verify that every disk was actually
   renamed by querying `GET /volumes/v_base-<vmid>-disk-<N>` and fail loudly
   if any are missing.
2. In jdssc: ensure the rename command has an appropriate retry count and
   timeout matching other volume operations.
3. Longer term: make `_rename_volume` idempotent and retriable so that a
   transient timeout can be retried without side effects.
