# Test campaign 3 — jdss-nfs-Pool-2-data2 (NFS plugin), plugin 0.11.6

- Date: 2026-07-06 · Cluster: pve-91-1/2/3, PVE 9.1 · Agent-run, ~1.8 h wall
- Pre-checks: Common.pm/NFSCommon.pm/NFSPlugin.pm md5 repo == all 3 nodes
  (38ff1bab / 3498b890 / 0a7ccc09); quorate 3/3; storage active + NFSv3-mounted
  on all nodes; BS active. Plugin log = /var/log/joviandss/joviandss.log
  (code default; storage defines no log_file).
- Focus: full lifecycle on the NFS plugin + NFS-specific review scenarios
  (S-06 probe, E5 locking observation, snapshot/rollback mechanics).

## Results table

| Item | Tag | Result | Dur | Evidence (one line) |
|---|---|---|---|---|
| 1.1 hooks + pw file | C3-02 | PASS w/ FINDING | 0.78s set | pw file for storeid ABSENT after maintainer add → all REST dead ("JovianDSS REST user password is not provided."); repaired via `pvesm set --user_password` → 0600 file at canonical path, REST OK |
| 1.2 VM 990210 | — | PASS | s | format=raw (plugin default), sparse (4G/1K), images/990210/vm-990210-disk-0.raw, boots |
| 1.3 CT 990211 | — | PASS | s | rootfs raw file 2G/5.8M, running |
| 1.4 extra disks | — | PASS | s | scsi1 raw; mp0 auto-mkfs ext4, mounted /mnt/test (loop over NFS) |
| 1.5 vTPM | — | PASS | s | swtpm NVRAM manufactured on NFS file; VM restart OK |
| 1.6 fio in CT | — | PASS | 2×60s | randwrite 4k iod8: 33.0k IOPS / 129MiB/s err=0; seqread 1M: 3742MiB/s err=0 (cache-assisted); no OOM at 512M |
| 1.7 bus pass | C3-01 | PASS w/ FINDING | s | virtio0+sata0 attach/boot/detach OK; `unlink --force` leaves file (see C3-01) |
| 1.8 full clone | C3-01 | PASS (+leak) | 34s | independent sparse copy (1K/1K, no backing); boots; destroy leaked 3 files |
| 1.9 snap + 3× rollback | F-02 | PASS | snap 2.4–2.8s; RB 60/60/60s CT, 85s VM | markers restored 3×(rootfs+mp0); VM marker TAMPERED→SNAPBASE; boots |
| 1.10 clone from snap | — | PASS | 43s | works; snapshot share stayed published + RO-mounted until next deactivate (deferred cleanup observed working) |
| 1.11 template + linked | — | OBSERVED | 35s clone | linked clone REJECTED (by design: clone/template features=0); `qm template` marks config but does NOT base-ify files; full clone from template OK |
| 1.12 vzdump → BS | — | PASS | 24s CT / 28s VM | CT snapshot-mode used plugin snapshot 990211_vzdump (created+deleted); VM stop-mode 99% sparse |
| 1.13 thin/discard | — | OBSERVED | — | no reclaim path on NFSv3 (see Mechanics) |
| 1.14 purge | C3-01 | PASS (via pvesm) | s | file gone from mount+list; detach doesn't register unusedN (C3-01 ext.); template destroy leaked → hand-freed |
| 1.15 storage removal | — | SKIP-by-design | — | maintainer's storage retained |
| 1.16 extra content | — | PASS | ~20s | `--content images,rootdir,iso,vztmpl` ACCEPTED; pveam template landed in template/cache/ on NFS, checksum OK; content restored |
| 2.1 S-06 probe | S-06 | CONFIRMED | — | verbatim below; cfg md5 unchanged, pw intact, storage active |
| 2.2 E5 locking | E5 | OBSERVED | — | resize inherited/unlocked/no-REST/no-log; same-guest races serialized by PVE guest lock ("can't lock file '/var/lock/qemu-server/lock-990210.conf' - got timeout"); rename unreachable via std flows (no base-ify) |
| 2.3 snap→resize→rollback CT | F-04 | PASS | RB 63s | full revert: content + config size + file truncated back to 1G |
| 2.4 online VM resize | F-19 | PASS | 1.48s | 5G→6G single pass, config+file+qemu consistent |
| 2.5 4-guest storm | locks | PASS | ~60s | 2 VMs + 2 CTs, 3 nodes, 2 cycles, all RC=0; zero lock artifacts |
| 2.6 cross-node destroy | S-02 kin | OBSERVED | — | leftovers: active RO snap mount on A, array share+clone, dataset snapshot, leaked disk file; hand-cleaned via plugin APIs |
| 2.7 pvesm status | — | PASS | 3.17–4.90s | no regression vs campaign-2 3.0–5.3s despite 5 jdss storages (NFS status is df-based) |
| 3.1 CT restart-migrate | — | PASS | 11s+11s | data intact both directions |
| 3.2 VM offline migrate | — | PASS | 2s+1s | config-only move; boots on node2 |
| 3.3 VM online idle | — | PASS | 10s+10s | downtime 11/10ms; zero disk-transfer lines (shared/skip-disk) |
| 3.4 online under IO | KEY | PASS | 12s+11s | fio err=0 spanning both legs; guest dmesg clean; node journals: zero nfs error/stale hits |
| 4 teardown + audit | — | PASS | — | zero 9902xx leftovers anywhere; dataset usage back to baseline 6144K |

## Findings (new)

### C3-01 (agent name F-NFS-2) — MAJOR: `path()` drops PVE's list-context contract → qm-side deletions silently leak files
`OpenEJovianDSSNFSPlugin.pm` `sub path`/`_path` return a bare scalar; PVE core
expects `wantarray ? ($path, $owner, $vtype) : $path` (the iSCSI plugin does
exactly this, `OpenEJovianDSSPlugin.pm:325-335`). With `$owner`/`$vtype` undef
in list context, every ownership-gated core path skips deletion:
- (a) `qm destroy` leaks ALL VM disk files — reproduced 5× (990212/13/14/15
  sets, 990230/231/250);
- (b) `qm disk unlink --force` removes the config entry, file remains (3× repro);
- (c) plain detach doesn't even register `unusedN` (volume drops untracked);
- (d) "$vtype uninitialized" warnings in PVE Content.pm:488/498 on `pvesm free`.
`pct destroy` is unaffected (different path) — CT files freed correctly.
**Fix is one line in `path()`** (mirror the iSCSI plugin's wantarray mapping).

### C3-02 (agent name F-NFS-1) — setup/hook: fresh add left no password file → all REST ops dead
After the maintainer's `pvesm add`, `/etc/pve/priv/storage/joviandss-nfs/`
`jdss-nfs-Pool-2-data2.pw` did not exist → every REST op died: "JovianDSS REST
user password is not provided." Orphan sibling `jdss-nfs-01.pw` (same minute,
same array creds; storage id not in cfg) suggests an add-under-different-id
history. Repaired via update-hook (`pvesm set --user_password`); file 0600
root:www-data, password not in storage.cfg. The add-hook/password flow needs
hardening or validation (fail loud at add time if the pw file cannot be
written / is missing).

### Minor
- Clone-from-snapshot leaves the snapshot share published + RO-mounted until
  the next `deactivate_volume` (works, but a crash in the window strands the
  array-side clone+share — exactly what 2.6 demonstrated).
- Cross-node / post-destroy cleanup of an activated snapshot requires manual
  plugin calls: `qm destroy` neither deactivates snapshots nor (per C3-01)
  frees files.
- Empty `private/mounts` skeleton dirs accumulate.
- NFS server clock ~30 min behind nodes (cosmetic).

## S-06 exact behavior (2.1)
Solo `pvesm set --delete user_password` → RC=255 "update storage failed:
user_password cannot be cleared; provide a new value or remove the storage".
Bundled `--ssl_cert_verify 0 --delete user_password` → identical error,
RC=255, BOTH changes rejected (bundled-rejection cost confirmed); storage.cfg
md5 unchanged, pw file intact, storage active.

## Mechanics (observed, code-corroborated)
- **Format:** default raw, preallocation=off (sparse), plain files at
  `<mnt>/images/<vmid>/vm-<vmid>-disk-N.raw`; qcow2/vmdk allowed but nothing
  in std flows produces them.
- **Snapshots:** NOT qcow2-internal, NOT per-file — array-side ZFS snapshot of
  the ENTIRE NAS dataset (data2) per snapshot, named `{vmid}_{snap}` (log:
  "create snapshot 990211_snapA for NAS volume data2"), one REST call per
  guest volume deduped by `--ignoreexists`. Running-VM snapshots use the
  storage method (no qemu-internal state). Consequence: each guest snapshot
  pins blocks of ALL guests on the share until deleted.
- **Rollback:** publish snapshot as clone+share (`se_{vmid}_{snap}_XXXX`),
  RO NFS mount under `private/mounts/<vmid>/<volname>/<snap>/`, FULL file copy
  back (dd conv=sparse for raw at ~123MB/s, qemu-img convert for qcow2),
  unmount, delete share+clone. ~60 s per 3 G of volumes.
- **Linked clones:** none by design — clone/template features=0; no backing
  chains, no base-* renames; `qm template` only flips the config flag. Full
  copy is the only clone mode (incl. from snapshot).
- **Discard/thin:** NFSv3 mount → no hole punching (fallocate PUNCH_HOLE →
  "keep size mode is unsupported"); in-CT fstrim EPERM (unprivileged);
  `pct fstrim` → "discard operation is not supported" (loop over NFSv3).
  NOTHING reclaims from trim at file/dataset/pool level. Reclamation works
  ONLY via file deletion + dropping dataset snapshots (verified: dataset
  returned exactly to 6144K baseline after teardown). NFSv4.2 would be needed
  for trim-based reclaim.

## Numbers
- fio CT: randwrite 129 MiB/s / seqread 3.7 GiB/s (err=0); guest-under-migration
  fio 997 IOPS err=0.
- `pvesm status` 3.17–4.90 s (campaign 2: 3.0–5.3 s — flat, despite 5 jdss
  storages; NFS status is df-based).
- Full clone 4G/3-disk 34 s; 20G template clone (block→file) 102 s, sparse 3.14G.

## Leftover audit
No 9902xx guests/volumes/configs/snapshots/mounts on any node or the array;
images/ = pre-existing 103 only; dataset used = 6144K (baseline); storage.cfg
entry identical except cosmetic content-order flip (rootdir,images →
images,rootdir) from canonical pvesm rewrite. Persisting by design: repaired
pw file (C3-02), 2 PBS backups (ct/990211, vm/990210), alpine template on
node2/3 local (3MB each). Hand-cleaned during run: 14 leaked VM disk files via
`pvesm free` (C3-01), private/mounts skeletons, 990240 snapshot stack.
Untouched pre-existing: jdss-nfs-01.pw, ahaha/, vm-103, foreign NFS mounts on
n2/n3, lock/timeouttest. Final lock grep (all nodes, all joviandss logs,
today): 0 hits.

## Executive summary
The NFS plugin passes the full lifecycle: create/attach/vTPM/fio/backup/
snapshot + 3× rollback/clone/resize/migrations (incl. online under IO) and the
4-guest storm, with zero lock artifacts and no status-time regression —
functionally near parity with the block plugin. It is NOT release-parity due
to one major bug: `path()` drops PVE's `($path, $owner, $vtype)` list contract,
so every qm-side deletion (destroy, unlink, detach-tracking) silently leaks
disk files on the storage; the one-line wantarray fix used by the iSCSI plugin
resolves it (C3-01). Second setup-critical gap: the fresh add left no password
file, rendering all snapshot ops dead until repaired via update-hook — the
add-hook/password flow needs hardening or validation (C3-02). NFS-specific
items to document: dataset-wide snapshots (cross-guest block pinning),
full-copy rollbacks (~1 min/3G), no linked clones, and no trim reclamation on
NFSv3 (recommend NFSv4.2 or documenting file-deletion as the only reclaim
path). Deferred snapshot-share cleanup and post-destroy snapshot stranding
deserve a tightening pass.
