# Full code review — v1.0.0 (tag 170332f)

Date: 2026-07-28. Scope: entire repository (iSCSI plugin + Common.pm + Lock.pm,
NFS plugin + NFSCommon.pm, jdssc Python package, packaging/tooling/tests).
Method: four parallel review passes, findings cross-checked against code;
selected findings verified empirically on pve-91-1 and locally (marked
**VERIFIED**).

Caveats:
- Working tree was changing during review (uncommitted `volume_export_formats`
  hunk in OpenEJovianDSSPlugin.pm, empty `OpenEJovianDSS/ExportImport.pm`,
  root `.deb` files deleted mid-review). Findings reference the committed
  v1.0.0 state.
- Deployed code on pve-91-1 matches the repo for Common.pm / Lock.pm /
  NFSCommon.pm / NFS plugin; deployed iSCSI plugin lacks only the uncommitted
  `volume_export_formats` hunk.

---

## A. Security

### A1. HIGH — REST admin password exposed on argv — **VERIFIED live**
`OpenEJovianDSS/Common.pm:1082-1087` (also 1969-1981, 2013-2022);
`jdssc/bin/jdssc` (`--user-password`, `required=True`).
Every jdssc invocation passes `--user-password <pw>` on the command line.
Confirmed on pve-91-1: during a routine `pvesm status`, `ps -eo args` shows the
full jdssc command line including the plaintext admin password. jdssc calls can
run up to ~118 s and happen constantly (status, list, activate), so the window
is effectively permanent. Same exposure for `--chap-password` (targets.py:109,
TODO already acknowledges it) and `cifs ensure -p` (cifs.py:56).
Fix direction: pass secrets via env var, fd, or the already-supported `-c`
config YAML; drop `required=True` on `--user-password`.

### A2. HIGH — CHAP passwords can leak into world-readable log — perms **VERIFIED live**
`Common.pm:2039-2058` (`_iscsiadm_set_chap`) + `Common.pm:1181-1187` (cmd
logging) + `Common.pm:928` (log creation).
`ls -la /var/log/joviandss/` on pve-91-1: every log file is 0644 root:root,
dir 0755 — world-readable. `_iscsiadm_set_chap` puts the CHAP password in
iscsiadm argv and wires outfunc/errfunc to `cmd_log_output`, which logs the
full command line. Any stderr line from `iscsiadm -o update` logs at `error`
level (passes the gate regardless of `debug` setting) → password lands in a
world-readable file. Fix: 0600 logs (0750 dir) + redact `-v` values for
`auth.password` keys.

### A3. HIGH — shipped .deb has files owned by uid 1000 (root-escalation path)
`Makefile:21` — `dpkg-deb --build` without fakeroot/`--root-owner-group`.
Verified against the (since-deleted) v1.0.0 deb: `/usr/share/perl5/...*.pm`
and `/usr/local/bin/jdssc` recorded as `user/user` (uid 1000). On a target
host where uid 1000 exists, that unprivileged account owns code executed by
pvedaemon as root. Fix: `dpkg-deb --root-owner-group --build`.

### A4. LOW — install.pl remote path predictable
`install.pl:32,813` — scp to fixed `/tmp/joviandss-plugin.deb` on the remote
node (symlink-clobber risk), never cleaned up.

Positive: no command injection found anywhere — external commands are
array-exec'd, names sanitized (`safe_word`, `nas_sname`), NFS-side passwords
file-based 0600 under `/etc/pve/priv`.

---

## B. Correctness — iSCSI plugin / Common.pm / Lock.pm

### B1. HIGH — unlocked mutation path through `path()` bypasses cluster locking
`OpenEJovianDSSPlugin.pm:325-477, 1956-1968`; `Common.pm:2866-2876`.
`path()` / `qemu_blockdev_options()` take no vm/storage lock, yet `_path`'s
recovery branch performs full volume_deactivate + volume_activate (iSCSI
logout, multipath teardown, lun-record delete/create), and
`block_device_path_from_lun_rec` rewrites lun records / stages multipath when
upgrading a record. A `path()` racing a locked `_deactivate_volume` can
produce concurrent login/logout on the same target and dm-map churn — exactly
what Lock.pm exists to prevent. Every other mutating flow is serialized.

### B2. HIGH — `find_free_diskname` ignores `cluster_prefix` — **VERIFIED live**
`OpenEJovianDSSPlugin.pm:804-811` vs 813-837.
PVE core calls the 6-arg entry point; the `$cluster_prefix` 7th arg is only
passed internally. Confirmed on pve-91-1 (`jdss-Pool-2-ctest`): with
`vm-990001-disk-0` existing, `$plugin->find_free_diskname(...)` (PVE-core
signature) returned `vm-990001-disk-0` — a colliding name. GUI "Add disk" on a
cluster_prefix storage then fails at alloc ("already exists"; caller-specified
name disables the retry path, Plugin.pm:976-989).

### B3. MEDIUM — `delete_timeout` silently clamped to 117 s
`OpenEJovianDSSPlugin.pm:194-201`; `Common.pm:386-391, 1109-1117`.
Advertised default 600 / "increase if deletion takes longer", but
`joviandss_cmd` clamps every timeout to `PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX`
(117). User values >117 are discarded; long deletes fail despite the setting.

### B4. MEDIUM — rollback retry discards `snap:` tokens
`OpenEJovianDSSPlugin.pm:1256-1279`; `Common.pm:1149-1158`.
If the rollback jdssc call times out client-side after server-side completion,
the retry returns an empty deleted-blocker list → `remove_vm_snapshot_config`
never runs → VM config keeps `[snapX]` sections for snapshots destroyed on the
array.

### B5. MEDIUM — always-`--force-snapshots` TOCTOU + unlocked VM-config edit
`OpenEJovianDSSPlugin.pm:1240-1266`; `Common.pm:1460-1521`.
(a) A storage-side snapshot created between `volume_rollback_is_possible` and
`rollback do` is silently destroyed without the force-rollback tag.
(b) `remove_vm_snapshot_config` rewrites `/etc/pve/{qemu-server,lxc}/<vmid>.conf`
via `file_set_contents` without PVE's VM-config lock (concurrent write can be
lost) and leaves dangling `parent:` refs / orphaned vmstate volumes.

### B6. MEDIUM — portal match by unanchored substring
`Common.pm:2272-2276`. `refresh_sessions` matches `/\Q$host\E/`; with
`data_addresses 10.0.0.2,10.0.0.20`, a session to 10.0.0.20 satisfies the
check for 10.0.0.2 → login skipped → multipath silently single-path.

### B7. MEDIUM — timeout-retry of non-idempotent creates orphans zvols
`Common.pm:1149-1158`; `OpenEJovianDSSPlugin.pm:905-991, 720-800`.
Create succeeds server-side but times out client-side → retry hits "already
exists" → outer alloc retry picks a new name → first zvol orphaned.

### B8. MEDIUM — `free_image` detaches targets without foreign-session check
`OpenEJovianDSSPlugin.pm:1085-1094`. Unlike activation (three fail-fast
guards), server-side delete/detach proceeds even if another node still has
the device attached (e.g. after interrupted migration) → live device vanishes
on that node.

### B9. LOW (cluster)
- `Common.pm:3803-3822` — `lun_record_local_get_by_target`: dead and broken
  (tests a file with `-d`, appends `$volname` twice; can only return undef).
- `die $@ if $@` after every `with_lock` (9 sites in iSCSI plugin, 7 in NFS
  plugin) — dead pattern; `with_lock` already rethrows.
- `OpenEJovianDSSPlugin.pm:640-645` vs 823-829 — two asymmetric conventions
  for jdssc `getfreename` (`--cluster-prefix` returns bare name;
  prefix-embedded `--prefix` returns clustered name). Correct today, easy
  future double-prefix bug.
- `Common.pm:1292-1309` — `volume_snapshots_info` docs promise empty hash for
  missing volume; actually dies.
- `Lock.pm:148-151` — `vm_lock_*`/`storage_lock_*` properties wired but never
  registered in either plugin's `properties()`/`options()` — unreachable
  config.
- `OpenEJovianDSSPlugin.pm:888-899` — `if ('images' ne "${fmt}")` compares a
  format against a vtype; always true. Adjacent comment says "rounded down",
  code rounds up.
- `Lock.pm` M-note: with neither `shared 1` nor `path` set, lock resolution
  dies with a misleading "set up path property" error (`Lock.pm:243-250`,
  `Common.pm:289-306`).

---

## C. Correctness — NFS plugin / NFSCommon.pm

### C1. HIGH — `get_identity` can never succeed for NFS storages
`OpenEJovianDSSNFSPlugin.pm:246` calls `Common::get_pool($ctx)` which requires
`$scfg->{pool_name}` — not in this plugin's `options()` (100-136). The correct
value (`NFSCommon::pool_name_get`) is even computed two lines up. Latent (no
in-tree caller found) but contradicts
`docs/design/password-resolution-through-ctx.md` which claims it works.

### C2. MEDIUM — multi-disk VM snapshots: only first disk synced pre-snapshot
`OpenEJovianDSSNFSPlugin.pm:395-411`. The snapshot is dataset-wide named
`{vmid}_{snap}`; for disk-1, `create --ignoreexists` is a no-op and disk-1's
`sync` runs after the snapshot already exists → disk-1's cached writes at
snapshot time are missing; later rollback silently restores older data.

### C3. MEDIUM — `sync` failure/timeout silently swallowed
`OpenEJovianDSSNFSPlugin.pm:396-401` (also 887-893). `run_command` with 10 s
timeout inside `eval`, `$@` never checked → snapshot proceeds over unflushed
data.

### C4. MEDIUM — published clone/share is per-(vmid, snap) but lifecycle is per-volume
`NFSCommon.pm:623-694`; `OpenEJovianDSSNFSPlugin.pm:877-881`. Both disks of a
VM map to the same clone+share; deactivating one volume's snapshot
unconditionally unpublishes → share deleted under the other disk's active
mount → I/O errors + stale mount.

### C5. MEDIUM — IPv6 `server` cannot mount
`NFSCommon.pm:514-517` — bracketed `[addr]:path` is then rejected by
`safe_word` (charclass has no `[`/`]`); `snapshot_activate` (205) never
brackets at all. Any IPv6 configuration fails `activate_storage`
deterministically.

### C6. MEDIUM — server-side unpublish vs. remote stale hard mounts
`snapshot_unpublish` deletes the share regardless of other nodes' mounts
(driver.py:2393-2400); mount state is node-local. After node crash/failed
migration, ops on the old node stat through a dead hard NFS mount → D-state
hangs (`NFSCommon.pm:377` etc.).

### C7. LOW (cluster)
- `NFSCommon.pm:175-212` + 587 — wrong-source remount path unmounts, `rmdir`s
  the mountpoint, then mounts without recreating it (self-heals next attempt).
- Clone/share leak window: cleanup only enumerates local mount dirs
  (`NFSCommon.pm:337-360`); a crash between publish and `make_path` leaves an
  unenumerated clone+share (jdssc's `snapshots list --with-clones` could be
  the reaper — unused).
- `NFSCommon.pm:197-204` — `ro` intent overridable by user `rw` option (TODO
  acknowledges).
- `OpenEJovianDSSNFSPlugin.pm:55-65` — `api()` returns max version even when
  running APIVER < supported minimum.
- `volume_snapshot` takes no lock, unlike sibling ops (378-412).
- Design/ops note: every VM snapshot pins the whole dataset (all VMs' data,
  ISOs, backups) until deleted; rollback clones the entire dataset. Should be
  documented for users.

---

## D. Correctness — jdssc Python package

### D1. HIGH — transport retries/masks genuine storage errors
`rest_proxy.py:152-156, 184-188`. `except Exception` treats typed
`JDSSOSException`s raised by the `_handle_500` hook as connection failures:
retried 17×/host with 3 s sleeps, then surfaced as
`JDSSCommunicationFailure` — the real error (e.g. `ScstAdminError`) is lost
and Perl-side retries multiply the stall (minutes).

### D2. HIGH — `share delete` always crashes — **VERIFIED live**
`jdssc/share.py:132-133` passes `direct=name` to
`driver.delete_share(share_name, direct_mode=False)`. Confirmed on pve-91-1:
`pool Pool-2 share X delete` → `TypeError: ... unexpected keyword argument
'direct'`. Not called by the Perl plugins today, which is why it hasn't been
noticed.

### D3. HIGH — `_delete_snapshot` hidden-parent branch: UnboundLocalError / wrong object
`driver.py:952-961` (read-verified). The `else` at :961 uses `cvname`, bound
only inside the earlier clones loop; with no clones → `UnboundLocalError`;
with clones → cascade-deletes the last clone instead of the hidden parent
`pname`.

### D4. MEDIUM — `get_snapshot` direct/non-export branches broken
`driver.py:2434-2459` (read-verified). `direct_mode=True` never assigns
`data` → `UnboundLocalError` at :2455; non-export branch calls
`jcom.sname(snapshot_name)` missing required `vid` → `TypeError`.

### D5. MEDIUM — force-rollback blocker listing fails open
`driver.py:3040-3062, 3155-3178`. Missing/non-int `properties.creation` →
snapshot counted as blocker; missing target `creation` → *all* snapshots
counted. Result: `snap:` tokens printed for snapshots the REST rollback did
NOT delete → Perl removes valid Proxmox snapshot config entries while the
snapshots still exist. Plus inherent TOCTOU (snapshot created between listing
and rollback is deleted but never reported).

### D6. MEDIUM — NAS clone name asymmetry: created clones undeletable
`driver.py:2184` (`sname(snapshot, dataset)`) vs :2203
(`sname(snapshot, None)`) — `clones delete` hits a different snapshot path
and 404s. Related: `list --with-clones` (nas_snapshots.py:120-136 +
driver.py:2222) reconstructs names without the `proxmox_volume` component, so
published (`sp_`) snapshots are silently never reported (exception swallowed).

### D7. MEDIUM — `delete_share` direct-mode partial delete
`driver.py:3258-3263` — honors `direct_mode` for the share but calls
`delete_nas_volume(share_name, direct_mode=False)` → wrong dataset name →
error or orphaned dataset.

### D8. MEDIUM — `cifs` module entirely non-functional
`cifs.py` calls six `rest.py` methods that don't exist, miscalls
`create_nas_volume`/`create_share`, reads an undefined arg in `delete`.
Every `pool X cifs ...` invocation crashes. Dead-but-wired feature.

### D9. MEDIUM — exception constructor bugs — **VERIFIED locally**
`exception.py:287-292, 39-49, 246-260`. Confirmed by execution:
`JDSSSnapshotIsBusyException` prints literal `%(snapshot)s`;
`JDSSRESTProxyException` message is a stringified tuple;
`JDSSException("msg", {...})` 2-arg form used at driver.py:2344-2359
(`publish_nas_snapshot` failure path) raises `TypeError` instead of the
intended exception (and its unguarded cleanup can mask the real cause);
`JDSSRollbackIsBlocked` chunking uses `=` instead of `+=` (only last chunk of
>10 blockers shown).

### D10. MEDIUM — None-unsafe REST error handling
`rest.py` `attach_target_vol:945`, `delete_target:604-605`,
`delete_nas_volume:1711-1712`, `get_share:1728-1729` index `resp["error"]`
without None checks → `TypeError`/`KeyError` instead of mapped exceptions;
e.g. the unpublish poll loop (driver.py:2401-2412) then aborts cleanup and
leaks the clone.

### D11. MEDIUM — transport retry semantics resend non-idempotent requests
`rest_proxy.py:106-188, 206-208` — `_send` retried on JSONDecodeError,
host-cycling re-issues POSTs; replayed `attach_target_vol` maps to
`JDSSResourceIsBusyException` → spurious busy-resolution machinery. Also
`exit(1)` deep in the transport on SSLError/401 (`:140, :227`) bypasses all
driver-level cleanup.

### D12. LOW (cluster) — **typo items VERIFIED locally**
- `jdss_common.py:278` — `'_'.joint(...)` → AttributeError (function
  apparently unreferenced).
- `share.py:123-127, 139-151` — `share get -G` without `-s` prints nothing;
  `share resize --add` calls nonexistent `get_share`.
- `rest.py:234` — `errno == str(5)` never fires.
- `volumes.py:187-226` — dead Cinder-residue `clone()`/`get()` with wrong
  signatures.
- `cexception.py:44-57` — config-error exceptions render as empty string.
- `volume.py:95-99` — `volume clone --size` parsed, never forwarded (clones
  never resized by jdssc); latent wrong-exit-0 path in
  `create_cloned_volume` resize-failure cleanup (driver.py:724-737).
- `driver.py:848` — zombie-target GC on `random.randint(1,100)==7`
  (undocumented 1% amortization, untestable).
- `driver.py:2956` — `get_active_host()[0]` = first character (cosmetic).
- `rest_proxy.py:166-183` — legit `data: null` GET indistinguishable from
  storage bug → ~50 s spurious retry loop.

---

## E. Packaging / tooling / hygiene

- HIGH — deb ownership (see A3).
- HIGH — NFS plugin `$PLUGIN_VERSION = '0.7.0'` vs 1.0.0 everywhere else
  (`OpenEJovianDSSNFSPlugin.pm:44`). Root cause: version scripts only cover
  the iSCSI plugin, and the whole `scripts/` dir is gitignored (`.gitignore:2`
  bare `scripts` entry) — release tooling invisible to the repo.
- HIGH — `jdssc/Makefile:8` — `install -m 0645` (typo for 0755); works only
  because postinst `chmod +x` papers over it.
- MEDIUM — `debian/control` missing Depends: `python3-requests`,
  `python3-urllib3`, `open-iscsi`.
- MEDIUM — `debian/postinst:19-26` — LVM `global_filter` sed fails on
  conventional `global_filter = [` spacing yet prints success (silent no-op).
- MEDIUM — no `conffiles`: upgrades silently overwrite admin edits to
  `/etc/multipath/conf.d/open-e-joviandss.conf` and the udev rule.
- MEDIUM — `blockdevicemanager/`: tracked 316-line daemon + systemd unit that
  nothing ships or references; imports (`toml`, `inotify_simple`) undeclared.
  Its deps leaked into `jdssc/setup.py` `install_requires` (which meanwhile
  omits `requests`/`pyyaml`/`oslo.utils`).
- MEDIUM — `install.pl:596-684` — `--restart` skips `pvestatd` (also loads
  the plugin) → stale plugin code keeps running post-upgrade.
- LOW — install.pl release pagination (first 30 only); Makefile `uninstall`
  bare `rm` aborts midway; no `postrm` (leaves /etc/joviandss, logs, LVM
  filter edit); `/usr/local/bin` in a deb violates Debian policy (works).
- Hygiene: no `*.deb` gitignore pattern (build drops debs in repo root);
  stale `project-status.md` (says 0.10.14) and README (roadmap lists shipped
  CHAP; NFS plugin unmentioned); root `.swp`; empty `logs/`, `tmp/`,
  dead `tools/` tree; untracked notes in `OpenEJovianDSS/tmp/`; empty
  uncommitted `OpenEJovianDSS/ExportImport.pm`.

## F. Test posture

- Existing and passing: `tests/vm_tag_force_rollback_test.pl` (36/36),
  `tests/lock_rearm_test.pl` (30/30), jdssc pytest suite — **67/67 pass in
  0.16 s (verified this review)**.
- HIGH (posture): no `make test` target, no CI — nothing runs any suite
  automatically; a release can ship without executing them.
- Coverage gaps map exactly onto where the defects above live: Common.pm
  activation/multipath machinery, both plugin .pm files, NFSCommon.pm,
  rollback `snap:` stdout contract, all NAS/share/publish paths, rest_proxy
  retry semantics. `tests/testcases/*.yaml` are manual scenario descriptions
  (runner lives in separate pve-testing repo).

---

## Overall assessment

The iSCSI attach/detach core — Lock.pm's phase sequencer, activation error
classification, busy-resolution — is disciplined, well-documented, and is
also the only area with meaningful automated tests; no defects were found in
the locking machinery itself. Quality drops at the seams and in the
less-travelled code: credentials on argv and world-readable logs, an unlocked
recovery path through `path()`, config contracts that silently diverge from
documentation (`delete_timeout`, `cluster_prefix` naming), a fail-open
force-rollback blocker listing, the NFS shared-dataset consistency issues,
and a set of jdssc CLI paths (`share delete`/`resize`, `cifs`, NAS clone
delete, `snapshot get -d`) that crash unconditionally on first use. Packaging
has one genuine security defect (non-root deb ownership) and several
robustness gaps. Recommended order: A1-A3 security items; then B1/B2 and D1;
then the force-rollback token/fail-open pair (B4/D5) since it can silently
desync VM configs from storage; then the NFS multi-disk consistency pair
(C2/C4) before promoting the NFS plugin beyond 75%.
