# Test campaign 2 — jdss-Pool-2-ctest (iSCSI plugin, cluster_prefix `ctest`), plugin 0.11.6

- Date: 2026-07-06 · Cluster: pve-91-1/2/3, PVE 9.1 · Agent-run, ~9.7 h wall
- Pre-checks: Common.pm md5 `38ff1bab9b9831f5c01578555ac56e6a` = repo copy on all
  3 nodes; quorate 3/3; jdss-Pool-2, jdss-Pool-2-ctest, pytest-jdss-Pool-2, BS active.
- Focus: the name-translation layer (array-side `ctest_`/`tstf_` prefixes, bare
  names PVE-side) across the full lifecycle + review-finding scenarios.

## Results table

| Item | Tag | Result | Dur | Evidence (one line) |
|---|---|---|---|---|
| 1.1 temp storage jdss-test-cp (`tstf`, iqn.2026-07.testcp:) | prefix | PASS | ~2m | array `tstf_vm-990100-disk-0`; 2 sessions to `iqn.2026-07.testcp:vm-990100-0`; free clean |
| 1.2 VM 990110 scsi0 | prefix | PASS | ~1m | array `ctest_vm-990110-disk-0`; dm-11 4G, 2 paths A/A |
| 1.3 CT 990111 rootfs | prefix | PASS | ~1m | `ctest_vm-990111-disk-0`, CT running |
| 1.4 scsi1 + mp0 | prefix | PASS | ~2m | 4 array vols `ctest_`-prefixed, PVE list bare; mp0 mounted /mnt/test |
| 1.5 vTPM tpmstate0 | — | PASS | ~1m | `ctest_vm-990110-disk-2` 4M; swtpm manufactured; VM restarted |
| 1.6 fio in CT | — | PASS | 2×60s | randwrite 40.2k IOPS avg; seqread 3578 MiB/s (bar >10MB/s) |
| 1.7 virtio0+sata0 | — | PASS | ~2m | disk-3/4 created, booted, freed; array count restored |
| 1.8 full clone 990112 | — | PASS | 1m45s | booted; destroyed; 0 residue |
| 1.9 CT snap + 3× rollback; VM s1 | F-02 | PASS | ~4m | 3 consecutive rollbacks OK; markers `presnap` rootfs+mp0; junk gone; VM rollback+boot OK |
| 1.10 clone from snapshot 990113 | — | PASS | ~2m | 3 `ctest_vm-990113-*` created, destroyed clean |
| 1.11 template + linked clone | F-03 KEY | PASS | ~4m | array `ctest_base-990115-disk-0/1/2`; rename lines below; linked 990114 instant (only 4M tpmstate copied), booted |
| 1.12 vzdump CT+VM → BS | — | PASS | ~2m | both "Backup job finished successfully" |
| 1.13 thin/discard | — | PASS | ~2m | used 57344 → 527171584 (500M dd) → 57344 after blkdiscard |
| 1.14 detach→unused→free; destroy template | — | PASS | ~2m | disk-1 gone from pvesm AND array; template 0 residue |
| 1.15 remove jdss-test-cp | hooks | PASS | ~10s | storage gone; `jdss-test-cp.pw` auto-removed by delete hook |
| 2.1 same-vmid coexistence | PREFIX KEY | **FAIL** | ~5m | cross-talk: deactivating plain vol logged out shared target; ctest vol's mapper vanished while active (→ NEW finding C2-02) |
| 2.2 free-name independence | prefix | PASS | ~3m | ctest auto-alloc got disk-0 then disk-1 with plain disk-0 coexisting; + NEW bug C2-01 (below) |
| 2.3 snap→resize→rollback; clone from pre-resize snap | F-04 | PASS | ~6m | rollback-over-resize 5G→4G OK both sides; snap-export first-cycle activation OK; clone dest sized 5G by PVE-core current-size semantics (content frozen) |
| 2.4 online resize +1G | F-19 | PASS | 7.1s | single pass, exactly one "Verify round 1/10", no retry storm |
| 2.5 lock storm 4 guests / 3 nodes | locks | PASS | ~3m | simultaneous start/stop all OK; zero lock artifacts on any node |
| 2.6 snapshot-export leak probe | S-02 prefix | OBSERVED (leak reproduced) | ~8m | destroy-from-B with live export on A leaks volume+se_ clone+target+node-A session/mapper/lunrec; prescribed cleanup → residue NONE |
| 2.7 pvesm status ×3/node | — | PASS | — | 3.0–5.3s |
| 3.1 CT restart-migrate 1→2→1 | — | PASS | 21s+21s | running both ends; /mnt/test marker intact |
| 3.2 VM offline migrate + boot | — | PASS | 2s+2s | booted on node2, returned |
| 3.3 VM online migrate idle | — | PASS | 17s+18s | running after both legs |
| 3.4 online migrate under fio IO | KEY | PASS | 2×180s | fio err=0 both legs; migrations 16s/17s; 0 guest dmesg IO errors |
| 4 teardown + audit | — | PASS | ~10m | array volume & target lists byte-identical to baseline; 0 sessions/mappers/state |

## Verbatim artifacts

1.11 rename lines (ctest log, node1):
```
2026-07-06 01:41:40.554 - jdssc.jovian_common.driver - DEBUG - [bfad35b1] Rename volume ctest_vm-990115-disk-0 to ctest_base-990115-disk-0
2026-07-06 01:41:50.955 - jdssc.jovian_common.driver - DEBUG - [171bd4f5] Rename volume ctest_vm-990115-disk-1 to ctest_base-990115-disk-1
2026-07-06 01:42:02.646 - jdssc.jovian_common.driver - DEBUG - [6d73b6ec] Rename volume ctest_vm-990115-disk-2 to ctest_base-990115-disk-2
```

2.1 cross-talk (jdss-Pool-2 log, node1) — plain deactivate kills shared target with ctest LUN 1 live:
```
02:09:41.632 - plugin - DEBUG - [64561d22] Deleting local lun record for target iqn.2025-04.proxmox.joviandss.iscsi:vm-990120-0 lun 0 volume vm-990120-disk-0
02:09:41.712 - plugin - DEBUG - [64561d22] CMD '/usr/bin/iscsiadm' ... '--logout' output Logging out of session [sid: 378, target: iqn.2025-04.proxmox.joviandss.iscsi:vm-990120-0, ...]
```
Array LUN list in same window: `{'name': 'v_vm-990120-disk-0', 'lun': 0}, {'name': 'v_ctest_vm-990120-disk-0', 'lun': 1}`; after logout: `dmsetup status 23034643439363832` → "Device does not exist", dd → "No such file or directory". Root cause: target name carries no cluster prefix + LUN records are per-storeid, so storage A cannot see storage B's LUNs on the shared target. Array-side detach was correctly per-LUN; the damage is host-side session logout. Workaround verified: distinct `target_prefix` per storage avoids collision entirely (→ NEW finding C2-02).

2.6 S-02 delete failure (node2 ctest log):
```
10:02:41.698 - jdssc.jovian_common.rest - WARNING - [66df3999] volume v_ctest_vm-990140-disk-0 is busy
10:02:41.698 - jdssc.jovian_common.driver - DEBUG - [66df3999] unable to conduct direct volume v_ctest_vm-990140-disk-0 deletion
10:02:41.739 - plugin - DEBUG - [66df3999] Deleting volume vm-990140-disk-0 format raw done   (silent success; qm destroy RC=0)
```

C2-01 (NEW): `pvesm alloc jdss-Pool-2-ctest 990121 "" 1G` → `successfully created 'jdss-Pool-2-ctest:'` — created array zvol literally named `v_ctest_` (empty translated name), invisible to `pvesm list`; second attempt errors on collision. The pre-existing baseline mystery volume (empty name, 1G, creation 1773674989) is this bug's unprefixed twin. API path (`vdisk_alloc` name=undef) works correctly.

Known N-16 (`line 1604` warning) seen ~6×, not re-reported. Lock-artifact greps (`joviandss-lock-fatal|got lock request timeout|stale|LOCK BUG`): zero hits all phases, all nodes, incl. rotated files.

## fio + status numbers
- CT (1.6): randwrite 4k iodepth8 60s: avg 40213 IOPS, 154 MiB/s; seqread 1M 60s: 3578 MiB/s (array cache). CT memory raised 512→1024M after cgroup OOM killed first attempt (loop page-cache accounting).
- Migration-under-IO (3.4): leg 2→3 err=0, 4388 KiB/s, io=772MiB/180s; leg 3→2 err=0, 4312 KiB/s, io=758MiB/180s.
- `time pvesm status`: n1 3.04/5.26/3.63s; n2 3.67/5.21/3.58s; n3 4.46/3.63/4.60s.

## Prefix-verification evidence (names actually seen on array)
`tstf_vm-990100-disk-0` · `ctest_vm-990110-disk-0/1/2/3/4` · `ctest_vm-990111-disk-0/1` · `ctest_base-990115-disk-0/1/2` · `ctest_vm-990114-disk-*` (linked) · `ctest_vm-990150-disk-0` (20G template clone) · coexisting REST pair `v_vm-990120-disk-0` + `v_ctest_vm-990120-disk-0` · se-clone `se_s2_MN2GK43UL53G2LJZHEYDCNBQFVSGS43LFUYA----` origin `Pool-2/v_ctest_vm-990140-disk-0@s_s2`. Real zvol names are `v_<prefix><bare>`; PVE side always showed bare names; error paths also translated correctly (`JDSS resource volume ctest_vm-990110-disk-1 does not exist`).

## S-02-under-prefix outcome
Reproduced with guest on node B, export live on node A: destroy succeeds (RC=0) but leaves on array `v_ctest_vm-990140-disk-0` + `se_s2_…----` clone + target `…vm-990140-0`, and on node A live sessions/mapper/lun-record. Differs from campaign 1: no promoted-clone resurface — the "busy" refusal comes earlier, so the original volume survives alongside the still-parented se_ clone. Prescribed cleanup (node-A `deactivate_volumes(volid,'s2')` + `pvesm free`) → residue NONE. Same procedure also cleaned 2.3's lingering `se_preresize_*` exports.

## Leftover audit / hand-cleaned
Final array volume AND target lists byte-identical to pre-campaign baselines; no `ctest_*9901*`/`tstf_*`/bare `*9901*` anywhere; no 9901xx guests, sessions, mappers, or state files on any node; jdss-test-cp + its .pw gone; campaign PBS backups deleted. Hand-cleaned: `v_ctest_` orphan zvol (C2-01, campaign's own) via jdssc; dangling `unusedN` refs in 990110.conf via sed; empty `/etc/joviandss/state/jdss-test-cp` dirs on 3 nodes via rmdir; helper script + alpine template copies removed. Pre-existing artifacts untouched (se_snap3, orphan target vm-101-0 — its stale node1 session was logged out by the plugin itself during sanctioned clone-source deactivate; vm-10001 target; empty-name 1G volume; ctest_vm-102-disk-0).

## Executive summary
The name-translation layer holds everywhere data-path correctness depends on it: create/attach/snapshot/rollback/resize/template-rename/linked-clone/backup/discard/migrate all produced correctly `ctest_`/`tstf_`-prefixed array objects, bare PVE names, correct translation even in error messages, and live migration under direct IO was flawless. The layer does NOT extend to iSCSI target naming: same-vmid volumes on prefixed+unprefixed storages of one pool share one target, and per-storeid LUN records make one storage's deactivate log out the other's live device (2.1 FAIL — the campaign's one real defect; distinct target_prefix is a working mitigation → C2-02). New minor bug C2-01: empty-filename `pvesm alloc` mints an invisible `v_<prefix>` orphan zvol. S-02 leak reproduces under prefix in a busy-refusal variant, fully recoverable by the documented node-A cleanup. Zero lock artifacts across all phases; cluster and array returned to byte-identical baseline.
