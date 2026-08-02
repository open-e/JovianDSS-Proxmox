# Test campaign 1 — jdss-Pool-2 (iSCSI plugin, plain), plugin 0.11.6

- Date: 2026-07-05/06 · Cluster: pve-91-1/2/3, PVE 9.1.11 · Agent-run, ~2.2 h
- Pre-verify: installed Common.pm md5 `38ff1bab9b9831f5c01578555ac56e6a` identical
  repo vs all 3 nodes; quorate; all 4 jdss storages + PBS `BS` active.
- Basis: Proxmox custom-storage-plugin testing recommendations + review-findings
  scenarios from `docs/design/code-review-4e6281d.md`.

## Results table

| Item | Finding | Result | Duration | Evidence |
|---|---|---|---|---|
| 1.1 temp storage jdss-test-f | — | PASS | ~1m | created w/ prefix iqn.2026-07.testf:, 1G vol alloc/activate (2 sessions, both portals)/free clean; creds reused from /etc/pve/priv/storage/joviandss/jdss-Pool-2.pw |
| 1.2 VM 990010 | — | PASS | ~1m | running (needed `--kvm 0`, nested node); mapper path + 2 sessions |
| 1.3 CT 990011 | — | PASS | ~2m | alpine-3.22 downloaded; rootfs jdss-Pool-2:4; running |
| 1.4 extra disks | — | PASS | ~1m | scsi1 hotplug OK; mp0 mkfs+mounted /mnt/test; see artifact A1 |
| 1.5 vTPM | — | PASS | ~1m | tpmstate0 4M on mapper 26562313537303732, swtpm manufactured, VM running |
| 1.6 fio in CT | — | PASS | 2m | randwrite 41.0k IOPS/160MiB/s; seqread 4143MiB/s >> 10MB/s bar |
| 1.7 bus types | — | PASS | ~5m | virtio0+scsi2+sata0+ide0 all attached one boot (host_device mappers in `info block`); lsi controller boot OK; all freed |
| 1.8 full clone | — | PASS | ~1m | 990012 booted, destroyed, vols freed |
| 1.9 snapshot+rollback | F-02 | PASS | ~4m | CT: markers (rootfs+mp0) gone after RB1, pre-snap fio files back; RB2+RB3 OK; VM snap(incl tpmstate)+rollback+boot OK |
| 1.10 clone from snapshot | — | PASS | ~1m | 990013 from s1 booted, destroyed |
| 1.11 template+linked clone | F-03 | PASS | ~2m | base-990015-disk-{0,1,2} on array; explicit rename log lines; linked clone 990014 booted |
| 1.12 backup | — | PASS | ~2m | vzdump CT (snapshot mode) + VM to PBS `BS`: both "job finished successfully" |
| 1.13 thin/discard | — | PASS | ~3m | host-side scratch vol: used 527,544,320 → 466,944 B after rm+fstrim |
| 1.14 purge unused0 | — | PASS | ~1m | first unlink correctly blocked by VM snap ref; after delsnapshot freed; gone from pvesm AND array |
| 1.15 remove jdss-test-f | — | PASS | <1m | pvesm remove clean, hook log normal |
| 1.16 ISO on jdss | — | SKIP | — | content types images,rootdir only (block storage) |
| 2.1 resize vs snapshot | F-04 | PASS | ~5m | CT rollback-after-resize OK (3G→back to 2G); VM clone from presnap first-cycle (0 "Re-activating"); frozen size 4294967296 (live vol 6G) |
| 2.2 third rollback | F-02 | PASS | in 1.9 | RB2_RC=0, RB3_RC=0 same snapshot |
| 2.3 online resize | F-19 | PASS | 7.0s | running VM scsi0 6G→7G one pass; 0 "attempt error" lines |
| 2.4 concurrency storm | F-05/F-01 | PASS | ~4m | 6 VMs 990030-35 (2/node) started simultaneously → all running, BLOCKDEV-OK; simultaneous stop; 0 lock artifacts |
| 2.5 pvesm status ×5/node | F-12 | OBSERVED | — | worst 5.09s. Blackhole variant not testable live |
| 2.6 cross-node free | F-08 | OBSERVED | ~3m | see Known-open probes |
| 2.7 cross-node destroy w/ snap export | S-02 | OBSERVED (reproduced) | ~5m | see Known-open probes |
| 2.8 zombie targets | F-10 | OBSERVED | — | 990xxx zombie targets: 0 |
| 2.9 rename not silent | F-03 | PASS | — | verbatim lines below |
| 3.1 CT restart-migrate | — | PASS | 21s + 21s | 1→2 running w/ mp0, back |
| 3.2 VM offline migrate | — | PASS | 2s + 1s | 1→2, start-check OK, back |
| 3.3 VM online migrate idle | — | PASS | 17s | 7.2MiB state; n1 sessions released; blockdev on n2 |
| 3.4 online migrate under IO | — | PASS | 15s + 15s | template-101 clone; fio in-guest err=0 across BOTH live migrations 2→3 and 3→2; dmesg 0 IO errors; no reboot; ssh unbroken |
| P4 teardown+audit | — | PASS | ~5m | all 990xxx guests/vols/configs/sessions/state gone; quorate; storages active |

## Artifacts (verbatim)

Mandated patterns (`joviandss-lock-fatal`, `got lock request timeout`, `stale`,
`LOCK BUG`): **none** on any node in any joviandss log for the whole window
(swept after each phase + final full sweep).

Other artifacts observed:
- A1 (node1, during `pct set 990011 -mp0`, 2026-07-05 ~23:20):
  `Use of uninitialized value in numeric gt (>) at /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm line 1604.`
  — the `$current_size > $lr->{size}` comparison in the activate path (→ review N-16).
- F-03 evidence (node1 jdss-Pool-2 log):
  `2026-07-05 23:54:09.426 ... driver - DEBUG - [0d7f6e7f] Rename volume vm-990015-disk-0 to base-990015-disk-0`
  (+ identical lines for disk-1 at 23:54:19.700, disk-2 at 23:54:31.415).
- Node1 jdss-Pool-2 log rotated mid-campaign (~2.1); offsets re-based.

## Numbers
- fio 1.6 (CT, mp0 on jdss-Pool-2): randwrite 4k iodepth8 60s = 41.0k IOPS, 160 MiB/s; seqread 1M 60s = 4143 MiB/s (page-cache assisted; threshold 10 MB/s).
- fio 3.4 (Debian guest, TCG, direct=1 4k iodepth4): during-migration err=0, 4249 KiB/s (~1060 IOPS), io=622MiB/150s; post-migration control 979 IOPS err=0.
- pvesm status ×5 (s): n1 5.09/3.23/3.71/4.60/3.58, n2 3.40/3.48/3.33/4.70/3.60, n3 4.39/3.65/4.84/3.27/3.65. Worst 5.09s.
- Thin/discard: AFTER_DD used=527,544,320 → AFTER_TRIM used=466,944 (99.9% reclaimed ~30s after fstrim). Pool-2 storages have no `thin_provisioning` flag yet zvols are created sparse (`usedbyrefreservation=0`); in-CT fstrim is EPERM in unprivileged CT (loop ioctl) — host-side path proves plugin discard.

## Known-open probes
- 2.6 [F-08]: `pvesm free` from node2 of a node1-active volume: RC=0 and the array volume WAS genuinely deleted (differs from the finding's "false success + array leftover") — but node1 retained stale iSCSI sessions + stale by-id device. Cleanup: `deactivate_volumes` on node1 succeeded gracefully on the nonexistent volume and removed sessions. Array clean.
- 2.7 [S-02] REPRODUCED: destroy from node B while node A held a snapshot export: base vol deleted, but leaked array-side `se_ssnap_OZWS2OJZGAYDIMBNMRUXG2ZNGA------` clone + target `...vm-990040-0` + node-A sessions/mapper. Manual clean: node-A `deactivate_volumes(volid,'ssnap')` removed local state AND the array se_ clone AND target. Residue: the promoted clone later resurfaced as standalone `vm-990040-disk-0` (is_clone=False, origin=None) — caught in Phase 4 audit, freed via pvesm. Total leak artifacts: 2.
- 2.8 [F-10]: 990xxx zombie targets after all deletions: 0. Non-campaign observations: pre-existing `se_snap3_OZWS2MJQGYWWI2LTNMWTE---` (vm-106 era) untouched; targets `vm-101-0` (orphan) and `vm-10001-0` (live n1 sessions) appeared mid-campaign — attributed to maintainer's template-101 prep, off-limits, left in place.

## Leftover audit
Hand-removed: resurrected `vm-990040-disk-0` (S-02 residue). Everything else self-cleaned: 0 990xxx volumes on any jdss storage, 0 990xxx array volumes/targets, 0 990 iSCSI sessions, 0 campaign WWIDs in /dev/mapper, 0 990xxx records under /etc/joviandss/state, 0 990xxx configs, jdss-test-f removed. PBS `BS` retains the two 1.12 backups (keep-all datastore, intentional). Cluster quorate, off-limits guests untouched.

## Executive summary
Release-ready: yes, with caveats — all mandatory items PASS (F-04, locks/F-05/F-01, F-02 triple rollback, F-19 single-pass online resize, F-03 non-silent rename), full VM/CT lifecycle, all 5 disk buses, backups, discard, and 4 migration modes incl. live migration under IO all clean; zero lock artifacts across 3 nodes for the entire campaign.
Top 3 issues:
1. S-02 (open, reproduced): cross-node destroy with an active snapshot export leaks an se_ clone+target and later a promoted zombie volume; needs orphan GC or destroy-time cluster-wide export teardown.
2. F-08 (half-fixed behavior): cross-node free now deletes array-side correctly but leaves stale sessions/devices on the activating node — needs remote-node deactivation or defensive session GC.
3. Minor: uninitialized-value warning at OpenEJovianDSSPlugin.pm:1604 (N-16); `pvesm status` worst-case 5.1s with 4 jdss storages.
