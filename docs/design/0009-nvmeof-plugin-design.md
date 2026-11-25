# NVMe-oF Plugin — Design Document (PROPOSED)

> **Status: proposed (2026-09-22).** Adds a third storage plugin type,
> **`joviandss-nvmeof`**, that serves Proxmox `images`/`rootdir` volumes over
> **NVMe over Fabrics** instead of iSCSI. It is the iSCSI plugin's design with
> the transport swapped: the same per-volume zvols, the same snapshot-as-clone
> export, the same LUN-record state, the same lock and reactivation machinery —
> but on the appliance side each volume gets an **NVMe-oF subsystem** (the
> JovianDSS `nvmet` resource) instead of an iSCSI target + LUN, and on the host
> side `nvme-cli` replaces `iscsiadm` + dm-multipath. Two shapes are drafted in
> full — [Variant A](#variant-a--thin-plugin-over-a-transport-dispatched-common)
> (transport dispatch inside `Common.pm`, thin plugin subclass) and
> [Variant B](#variant-b--standalone-plugin-with-its-own-nvmecommon)
> (standalone plugin + `NVMeCommon.pm`, the NFS shape) — with **A
> recommended**. The appliance API this design targets is documented in the
> `jdss-rest-api-spec` repository (`jdss2/nvme-of-rest-api.md`); several of
> its behaviors are unverified against a live appliance and are tracked in
> [Open Questions](#open-questions). Out of scope, tracked there too: NVMe
> in-band authentication (the API exposes none), RDMA transport qualification,
> and a connected-hosts query for the recovery-detach gate.

## Table of Contents
[Table_of_Contents](#table-of-contents)

- [Overview](#overview)
- [Background](#background)
  - [The_iSCSI_data_path_today](#the-iscsi-data-path-today)
  - [The_NVMe_oF_appliance_API](#the-nvme-of-appliance-api)
  - [The_host_side](#the-host-side)
- [Problem](#problem)
- [Key_Observation](#key-observation)
- [Design](#design)
  - [Plugin_type_and_transport](#plugin-type-and-transport)
  - [Variant_A](#variant-a--thin-plugin-over-a-transport-dispatched-common)
  - [Variant_B](#variant-b--standalone-plugin-with-its-own-nvmecommon)
  - [Choosing_between_them](#choosing-between-them)
  - [Shared_contract](#shared-contract-both-variants)
    - [Configuration_properties](#configuration-properties)
    - [Subsystem_naming](#subsystem-naming)
    - [Export_creation](#export-creation--one-subsystem-per-volume)
    - [jdssc_nvmet_resource](#jdssc-the-nvmet-resource)
    - [Publish_and_unpublish](#publish-and-unpublish)
    - [Stage_and_unstage](#stage-and-unstage)
    - [Device_identity_and_path](#device-identity-and-path)
    - [Capacity_check](#capacity-check)
    - [LUN_records](#lun-records)
    - [Activation_cycle_deltas](#activation-cycle-deltas)
    - [Snapshots_and_clones](#snapshots-and-clones)
    - [Volume_delete_and_resize](#volume-delete-and-resize)
    - [Locks](#locks)
- [Alternatives_Considered](#alternatives-considered)
- [Consequences](#consequences)
- [Risks_and_Backward_Compatibility](#risks--backward-compatibility)
- [Files_That_Would_Change](#files-that-would-change)
- [New_Constants](#new-constants)
- [New_Functions](#new-functions)
- [Testing](#testing)
- [Relationship_to_Other_Work](#relationship-to-other-work)
- [Open_Questions](#open-questions)

## Overview
[Overview](#overview)

The plugin family today serves block volumes over **iSCSI** (`joviandss`) and
files over **NFS** (`joviandss-nfs`). JovianDSS also exports zvols over
**NVMe-oF** (NVMe/TCP, optionally NVMe/RDMA) through its `nvmet` REST resource.
This design adds a plugin that uses it.

The change spans the three layers the iSCSI plugin spans — the **Perl plugin**
(a new type, a transport-specific staging path), **jdssc** (a new `nvmet` CLI
resource over the `/pools/<pool>/nvmet` endpoints) — plus the **host** (the
`nvme-cli` initiator and the kernel's native NVMe multipath in place of
`iscsiadm` + dm-multipath). Everything that is *not* transport — volume
allocation, naming, cluster prefix, snapshots and clones, credentials, locks,
the reactivation cycle, LUN records — is reused unchanged.

---

## Background
[Background](#background)

### The iSCSI data path today
[The_iSCSI_data_path_today](#the-iscsi-data-path-today)

One activation attempt ([`_volume_activate_attempt`](../../OpenEJovianDSS/Common.pm#L4790))
runs four stages; the teardown
([`_volume_deactivate_attempt`](../../OpenEJovianDSS/Common.pm#L4917)) inverts
them. The **transport-specific** column is what this design replaces; the rest
is shared.

**Table 1 — iSCSI activation stages and their transport content** · `tbl_iscsi_stages`

| #  | Stage (function)                                                                                                                                 | Backend / host action                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                | Transport-specific?                             |
|----|--------------------------------------------------------------------------------------------------------------------------------------------------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------|
| 1  | publish — [`volume_publish`](../../OpenEJovianDSS/Common.pm#L2280)                                                                               | jdssc `targets create` ([`:2287-2291`](../../OpenEJovianDSS/Common.pm#L2287-L2291)) → driver [`ensure_target_volume`](../../jdssc/jdssc/jovian_common/driver.py#L1476): pick/create a target `<target_prefix><group>-<n>` holding up to `luns_per_target` LUNs, attach the zvol as a LUN, restrict the target to the VIPs matching `data_addresses` ([`_get_conforming_vips`](../../jdssc/jdssc/jovian_common/driver.py#L1559) → [`create_target`](../../jdssc/jdssc/jovian_common/rest.py#L539)), set CHAP. Returns `target lun ip,ip wwid` ([`targets.py:318`](../../jdssc/jdssc/targets.py#L318)) | **yes** — target/LUN/group/CHAP model           |
| 2  | stage — [`volume_stage_iscsi`](../../OpenEJovianDSS/Common.pm#L2660)                                                                             | `iscsiadm -o new` + CHAP node-DB + `--login` per portal ([`:2768-2867`](../../OpenEJovianDSS/Common.pm#L2768-L2867)); wait for `/dev/disk/by-id/scsi-<wwid>` with a forced READ CAPACITY ([`_iscsi_capacity_ok`](../../OpenEJovianDSS/Common.pm#L2957))                                                                                                                                                                                                                                                                                                                                              | **yes** — initiator, node DB, sd rescan         |
| 3  | multipath — [`volume_stage_multipath`](../../OpenEJovianDSS/Common.pm#L3010)                                                                     | dm-multipath map over the per-portal `sd` paths, every command under the `multipath` lock ([0007](0007-volume-activation-with-reactivation.md))                                                                                                                                                                                                                                                                                                                                                                                                                                                      | **yes** — dm-multipath                          |
| 4  | record — [`lun_record_local_create`](../../OpenEJovianDSS/Common.pm#L4036)                                                                       | JSON at `/etc/joviandss/state/<storeid>/<target>/<lun>/<volname>` ([`:4046-4060`](../../OpenEJovianDSS/Common.pm#L4046-L4060)) with `scsiid`, `hosts`, `multipath`, `shared`                                                                                                                                                                                                                                                                                                                                                                                                                         | keyed by target/LUN, field names iSCSI-flavored |
| —  | path — [`_path`](../../OpenEJovianDSSPlugin.pm#L406)                                                                                             | no record → [`block_device_path_from_rest`](../../OpenEJovianDSS/Common.pm#L3267) (`volume get -i` → `scsi-2<eui64>` [`id_serial_from_rest`](../../OpenEJovianDSS/Common.pm#L3528)); record → [`block_device_path_from_lun_rec`](../../OpenEJovianDSS/Common.pm#L3278) → `/dev/disk/by-id/scsi-<id>` or `/dev/mapper/<id>` ([`:3262-3264`](../../OpenEJovianDSS/Common.pm#L3262-L3264))                                                                                                                                                                                                              | **yes** — identity derivation                   |
| ↓1 | unstage — [`volume_unstage_iscsi_device`](../../OpenEJovianDSS/Common.pm#L3582) / [`volume_unstage_iscsi`](../../OpenEJovianDSS/Common.pm#L3627) | `/sys/block/<sd>/device/delete` per path; `--logout` + `-o delete` once the target's last LUN record is gone ([`lun_record_local_delete:4525`](../../OpenEJovianDSS/Common.pm#L4525))                                                                                                                                                                                                                                                                                                                                                                                                                | **yes**                                         |
| ↓3 | unpublish — [`volume_unpublish`](../../OpenEJovianDSS/Common.pm#L3969)                                                                           | jdssc `targets delete` ([`:3994-4004`](../../OpenEJovianDSS/Common.pm#L3994-L4004)); in the cycle, gated on the foreign-session probe [`_target_foreign_sessions`](../../OpenEJovianDSS/Common.pm#L2251) over [`target_get_sessions`](../../OpenEJovianDSS/Common.pm#L2177)                                                                                                                                                                                                                                                                                                                          | **yes**                                         |

Everything around Table 1 is transport-agnostic: the cycle driver
[`volume_activate`](../../OpenEJovianDSS/Common.pm#L4620) with its three-way
error classification, [`volume_deactivate`](../../OpenEJovianDSS/Common.pm#L4999)
over LUN records, the lock wrappers (`_activate_volume_lock`,
[`OpenEJovianDSSPlugin.pm:1829`](../../OpenEJovianDSSPlugin.pm#L1829)), the
plugin's alloc/free/clone/rename/snapshot methods, `cluster_prefix`
([0004](0004-cluster-prefix-design.md)), credentials
([0005](0005-password-resolution-through-ctx.md), [0008](0008-sensitive-data-transfer-control.md)).

### The NVMe-oF appliance API
[The_NVMe_oF_appliance_API](#the-nvme-of-appliance-api)

Source: `jdss-rest-api-spec/jdss2/nvme-of-rest-api.md` (scraped from the
appliance's `rest/v4/zfs/nvmet.py`, API v4). The blueprint is registered only
when `FEATURES_AVAILABLE.nvmet` is true — on an appliance without the feature
**every path below answers 404**. All paths sit under `/pools/<pool>`, which
[`rest_proxy.pool_request`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L243)
already prefixes, so the jdssc request strings are the bare tails.

**Table 2 — `nvmet` endpoints** · `tbl_nvmet_endpoints`

| Method · tail | Purpose | Notes |
|---|---|---|
| `GET /nvmet` | list every subsystem of the pool | `{"nvmet_subsystems": [ … ]}` |
| `GET /nvmet/<volume_name>` | one subsystem, **keyed by the zvol name** | same record shape |
| `POST /nvmet` | create a subsystem for `volume_name` | required: `volume_name`; `vips: [{vip_name, transmission_type?}]` (omit → reachable on no port); optional `subsystem_name` (NQN; auto-generated and "not descriptive" if absent), `subsystem_serial`. **201** |
| `PUT /nvmet/<volume_name>` | modify: `subsystem_name`, `subsystem_serial`, `active`, `vips` (overwrites the list) | renaming recreates the subsystem and drops connected hosts. **200** + record |
| `DELETE /nvmet/<volume_name>` | delete the subsystem | **204** |

A subsystem record carries `subsystem_name` (NQN), `subsystem_serial`, `active`,
`nvmet_zvols` (always one), `vips[]` (`vip_name`, `transmission_type` ∈
`tcp` \| `rdma`), and `namespaces[]` (always one: `number` — present only
while active — `uuid`, `nguid`, `block_size`, `zvol_name`).

What the model has that iSCSI lacks, and vice versa — this list drives the
whole design:

- **One subsystem per zvol, addressed by zvol name.** No target groups, no LUN
  numbering, no `luns_per_target` packing, no target-name suffix search
  ([`_acquire_taget_volume_lun`](../../jdssc/jdssc/jovian_common/driver.py#L1340)),
  no shared-target bookkeeping. The namespace is always `1`.
- **VIP assignment by name**, exactly as iSCSI's `vip_allowed_portals`
  ([`create_target:570-573`](../../jdssc/jdssc/jovian_common/rest.py#L570-L573)) —
  the existing `data_addresses` → VIP-name mapping applies verbatim.
- **A per-VIP transport type** (`tcp`/`rdma`) — new; iSCSI has none.
- **Namespace identity from the API** (`uuid`, `nguid`) — the analog of the
  LUN `scsi_id`, but returned by the subsystem record rather than a volume
  property.
- **No authentication** (no CHAP analog; NVMe's DH-HMAC-CHAP / TLS are not
  exposed), **no host allow-list**, **no connected-hosts / sessions query**
  (iSCSI has `/san/iscsi/targets/<iqn>/sessions`, [0003](0003-jdssc-target-sessions.md)),
  **no port in the record** (NVMe/TCP's IANA port is 4420 — assumed, Open
  Question 2).

### The host side
[The_host_side](#the-host-side)

- **Initiator:** `nvme-cli` (`nvme connect -t tcp -a <ip> -s <port> -n <nqn>`,
  `nvme disconnect -n <nqn>`, `nvme list-subsys`, `nvme ns-rescan`). Host
  identity is `/etc/nvme/hostnqn` + `/etc/nvme/hostid` (the analog of
  `/etc/iscsi/initiatorname.iscsi`, [`get_local_initiator_name`](../../OpenEJovianDSS/Common.pm#L2213));
  both are created by the `nvme-cli` package. Not in
  [`debian/control`](../../debian/control#L6) today.
- **Native multipath.** With `nvme_core.multipath=Y` (the Debian/PVE kernel
  default — verify, Open Question 4) the kernel coalesces every controller
  connected to the same subsystem NQN into **one** namespace block device
  `/dev/nvmeXnY`; connecting to each VIP is all that "multipath" takes. There
  is no dm-multipath map, no `multipathd`, no udev-cookie semaphore — the
  entire `multipath` lock-class story of [0007](0007-volume-activation-with-reactivation.md)
  does not apply. Path health is per controller (`nvme list-subsys` shows
  `live`/`connecting`/`deleting`).
- **Device identity.** udev creates `/dev/disk/by-id/nvme-<wwid>` from the
  namespace's kernel `wwid` attribute, which the nvme core builds as
  `uuid.<uuid>` when a namespace UUID is present, else `eui.<nguid|eui64>`.
  The appliance reports both `uuid` and `nguid`, so the expected symlink is
  `/dev/disk/by-id/nvme-uuid.<uuid>` — the exact form is pinned by live
  verification before implementation (Open Question 3); `nvme-eui.<nguid>`
  is the alternative if the appliance turns out not to populate a UUID.
- **Reconnect semantics.** A lost controller is retried by the kernel for
  `ctrl_loss_tmo` seconds (default 600) and then removed. JovianDSS HA moves
  the VIP between nodes with the same address, so the reconnect targets the
  right place; for a VM disk the plugin should ask for an unbounded retry
  (`--ctrl-loss-tmo=-1`) so a longer failover never deletes the device from
  under a running guest (the iSCSI plugin relies on the initiator's own
  `replacement_timeout` for this). Tunable — see
  [Configuration properties](#configuration-properties).

---

## Problem
[Problem](#problem)

JovianDSS can export volumes over NVMe-oF, and NVMe/TCP is the transport
Proxmox deployments increasingly want (lower per-IO CPU cost than iSCSI, native
multipath in the kernel, no `multipathd`). The plugin cannot use it: every
backend export and every host staging step in Table 1 is written against the
iSCSI resource model and `iscsiadm`. Concretely:

- The export API in use is `/san/iscsi/targets` throughout
  [`rest.py`](../../jdssc/jdssc/jovian_common/rest.py#L539) and there is no
  `nvmet` client at any jdssc layer.
- The plugin type, its properties (`target_prefix`, `luns_per_target`,
  `chap_*`, `multipath`, `data_port` = 3260 —
  [`properties:145-331`](../../OpenEJovianDSSPlugin.pm#L145-L331)) and its
  device-path derivation (`scsi-…`, `/dev/mapper/…`,
  [`block_device_path_from_serial`](../../OpenEJovianDSS/Common.pm#L3251)) are
  iSCSI-only.
- The host chokepoints (`iscsiadm` in `volume_stage_iscsi`, `multipath_cmd`
  in `volume_stage_multipath`) have no NVMe counterpart.

At the same time the plugin has just acquired a large body of
transport-agnostic machinery — the reactivation cycle, the fatal/contention
error classes, the lock registry, the LUN-record state and its
deactivate-by-record path — that an NVMe plugin must not duplicate.

---

## Key Observation
[Key_Observation](#key-observation)

**The iSCSI plugin is already two things glued together: a transport-agnostic
volume plugin and an iSCSI transport.** The seam runs exactly along Table 1's
last column. Every transport-specific function is *called from* a
transport-agnostic driver — `_volume_activate_attempt` calls
`volume_publish` → `volume_stage_iscsi` → `volume_stage_multipath` →
`lun_record_local_create`; `_path` calls `block_device_path_from_*`;
`volume_deactivate_by_lun_record` calls `volume_unstage_*` — and none of the
drivers inspect what the callee did beyond a few opaque tokens (`targetname`,
`lunid`, `scsiid`, `hosts`, a block-device path).

The NVMe-oF model maps onto those tokens one-to-one, **and simpler**:

| iSCSI token | NVMe-oF value |
|---|---|
| `targetname` (IQN, shared by up to `luns_per_target` volumes) | the subsystem **NQN** (one per volume) |
| `lunid` | the namespace number, always `1` |
| `scsiid` (LUN `scsi_id` → `2<eui64>`) | the namespace **`uuid`** (kernel `wwid` = `uuid.<uuid>`) |
| `hosts` (VIP addresses) | the same VIP addresses |
| `/dev/disk/by-id/scsi-<id>` / `/dev/mapper/<id>` | `/dev/disk/by-id/nvme-uuid.<uuid>` (native multipath — one path form) |

The one place the mapping is *not* one-to-one is creation itself: an iSCSI
target is a container that has to be **searched** for a free slot, while a
subsystem is looked **up** by its volume — the whole LUN-slot, suffix, re-home
and shared-target apparatus has no counterpart
([Export creation](#export-creation--one-subsystem-per-volume)).

So the design's job is to (1) name the seam as a **transport**, (2) write the
NVMe side of each seam function, and (3) leave everything else alone. The
"which plugin type am I" question is already answered the way [0005](0005-password-resolution-through-ctx.md)
answered it for credentials: from `$scfg->{type}` through `get_plugin_type`.

---

## Design
[Design](#design)

### Plugin type and transport
[Plugin_type_and_transport](#plugin-type-and-transport)

A third type constant and `get_plugin_type` branch
([`Common.pm:567-582`](../../OpenEJovianDSS/Common.pm#L567-L582)), plus a
**transport accessor** derived from it — the one place the code asks "iSCSI or
NVMe-oF?":

```perl
# Common.pm — use constant block (:168-169 today)
PLUGIN_TYPE_JOVIANDSS_NVMEOF => 'joviandss-nvmeof',
TRANSPORT_ISCSI              => 'iscsi',
TRANSPORT_NVMEOF             => 'nvmeof',

sub get_transport {
    my ($ctx) = @_;
    my $type = get_plugin_type($ctx);              # dies on unset/unknown type
    return TRANSPORT_ISCSI  if $type eq PLUGIN_TYPE_JOVIANDSS;
    return TRANSPORT_NVMEOF if $type eq PLUGIN_TYPE_JOVIANDSS_NVMEOF;
    die "JovianDSS: storage type '$type' has no block transport\n";   # NFS
}
```

`get_plugin_password_dir` needs no change: the NVMe plugin's `.pw` file lands
at `/etc/pve/priv/storage/joviandss-nvmeof/<storeid>.pw` by construction, and
`joviandss_cmd`'s `--sensitive-file` ([0008](0008-sensitive-data-transfer-control.md))
follows it.

### Variant A — thin plugin over a transport-dispatched Common
[Variant_A](#variant-a--thin-plugin-over-a-transport-dispatched-common)

The transport-agnostic drivers stay where they are and **dispatch on
`get_transport($ctx)` at the seam**. The NVMe side of each seam function lives
in a new module `OpenEJovianDSS/NVMeCommon.pm` (a leaf like `NFSCommon.pm` — helpers
only, no orchestration), and `Common.pm` grows a handful of dispatchers:

```perl
# Common.pm — dispatch at the seam; the iSCSI bodies keep their names
sub volume_publish {                      # :2280 today → becomes the dispatcher
    my ($ctx, @args) = @_;
    return get_transport($ctx) eq TRANSPORT_NVMEOF
        ? OpenEJovianDSS::NVMeCommon::volume_publish($ctx, @args)
        : _volume_publish_iscsi($ctx, @args);        # today's body, renamed
}
# likewise: volume_unpublish, target_active_info, block_device_path_from_rest,
#           block_device_path_from_lun_rec, block_device_path_from_serial,
#           get_data_port (transport default), volume_delete_transport_args
```

and `_volume_activate_attempt` / `_volume_deactivate_attempt` /
`volume_deactivate_by_lun_record` / `lun_record_update_device` branch once
each on the transport for their stage/unstage calls (Table 4 below lists every
branch). The plugin file is a **subclass** of the iSCSI plugin that overrides
only what differs:

```perl
package PVE::Storage::Custom::OpenEJovianDSSNVMeoFPlugin;
use base qw(PVE::Storage::Custom::OpenEJovianDSSPlugin);

sub type       { return OpenEJovianDSS::Common::PLUGIN_TYPE_JOVIANDSS_NVMEOF }
sub properties { return { nqn_prefix => {…}, nvme_transport => {…}, nvme_ctrl_loss_tmo => {…} } }
sub options    { … iSCSI's list minus target_prefix/luns_per_target/chap_*/multipath/multipath_lock_*,
                   plus the three above … }
sub on_add_hook { probe `nvmet list` once (Risk 1), then SUPER::on_add_hook }
```

`path`, `alloc_image`, `free_image`, `clone_image`, `rename_volume`,
`activate_volume`, `deactivate_volume`, `volume_resize`, the snapshot methods,
`list_images`, `status`, `get_identity`, the update/delete hooks — **all
inherited**: they call the seam functions through `Common`, which dispatch on
the type the overridden `type()` returns. The two iSCSI-specific plugin-level
touches are handled by the seam too: `_free_image`'s `volume delete -c
--target-prefix … --target-group-name …`
([`OpenEJovianDSSPlugin.pm:1340-1347`](../../OpenEJovianDSSPlugin.pm#L1340-L1347))
becomes `--transport <t>` (jdssc's delete detaches whatever export the volume
has — [Volume delete and resize](#volume-delete-and-resize)), and
`_volume_resize`'s post-resize device refresh goes through the dispatched
`lun_record_update_device`.

**Property registration** follows the SectionConfig rule 0006 records
([`OpenEJovianDSSNFSPlugin.pm:92-98`](../../OpenEJovianDSSNFSPlugin.pm#L92-L98)):
names are global, so the NVMe plugin's `properties()` declares **only its
three new names** and lists the shared ones in `options()`. Inheriting
`properties()` unchanged would re-declare every iSCSI property and die at
`pvesm` startup — the override is mandatory, not cosmetic.

**Cost:** ~10 dispatch points in `Common.pm` (the list above plus the Table 4 branches), one new leaf module (~600 lines:
publish/unpublish, connect/disconnect, identity, capacity, the `nvme_cmd`
runner), a ~150-line plugin file, and the jdssc `nvmet` resource. **Benefit:**
the cycle, error classes, lock registry, records, deactivate-by-record,
`_path`'s record/REST fallback and every plugin method are shared by
construction — a fix in `volume_activate` fixes both transports.

### Variant B — standalone plugin with its own NVMeCommon
[Variant_B](#variant-b--standalone-plugin-with-its-own-nvmecommon)

The NFS shape: `OpenEJovianDSSNVMeoFPlugin.pm` inherits `PVE::Storage::Plugin`
directly and carries its own copies of the plugin methods (alloc/free/clone/
rename/snapshot/activate/deactivate/resize/path — the lock wrappers included),
and `OpenEJovianDSS/NVMeCommon.pm` carries its own `volume_activate` cycle,
`volume_deactivate`, record helpers and staging. `Common.pm` is used for what
NFS uses it for: `new_ctx`, `joviandss_cmd`, credentials, `debugmsg`, locks,
the name helpers.

**Cost:** the plugin file is ~2 000 lines of near-copy (the iSCSI plugin minus
CHAP/multipath), and `NVMeCommon.pm` re-implements the reactivation cycle
(0007's classification, sweep gate, session-gated detach, budget check),
`volume_deactivate`'s record resolution and the LUN-record API — ~1 500 lines
whose only difference from `Common.pm` is the transport calls. Every later
change to the cycle or to a plugin method must be made twice. **Benefit:** the
iSCSI plugin is untouched — zero regression surface on the shipping transport —
and the two transports can diverge freely.

### Choosing between them
[Choosing_between_them](#choosing-between-them)

|                                | A (dispatch + subclass)                 | B (standalone + NVMeCommon)        |
|--------------------------------|-----------------------------------------|------------------------------------|
| New Perl                       | ~750 lines (leaf module + thin plugin)   | ~3 500 lines (mostly copies)       |
| Reactivation cycle, error classes, locks, records | shared by construction        | duplicated                         |
| Plugin methods (alloc/clone/rename/snapshot/…) | inherited                        | copied                             |
| iSCSI regression surface       | the ~10 dispatch points (unit-pinned)   | none                               |
| Divergence later               | deliberate (add a branch)               | silent (edit one copy)             |
| Precedent                      | 0005's type-derived credential path     | NFS plugin                         |

**Recommendation: A.** The NFS plugin is a standalone because NFS shares
*nothing* with the block path — different content types, no records, no
staging. NVMe-oF shares everything except the seam. B's one real advantage,
zero iSCSI regression surface, is bought back in A by pinning each dispatch
point in `tests/` and by the fact that every dispatch default is the iSCSI
branch (`get_transport` on a `joviandss` storage returns `iscsi`, and NFS
storages never reach a block seam). What tips it is 0007: its cycle is the
most intricate code in the tree and was hard-won over three review rounds — a
second copy of it is the single most expensive maintenance liability this
project could add.

### Shared contract (both variants)
[Shared_contract](#shared-contract-both-variants)

Everything below is the same under A and B; only *where* the Perl lives
differs.

#### Configuration properties
[Configuration_properties](#configuration-properties)

**Table 3 — `joviandss-nvmeof` storage.cfg properties** · `tbl_nvmeof_properties`

| Property | Status vs iSCSI | Notes |
|---|---|---|
| `pool_name`, `user_name`, `user_password`, `control_addresses`, `control_port`, `ssl_cert_verify`, `jdssc_*`, `jdssc_general_lock_*`, `jdssc_info_lock_*`, `block_size`, `thin_provisioning`, `cluster_prefix`, `delete_timeout`, `data_copy_bs`, `debug`, `log_file`, `shared`, `content`, `path`, `create-base-path` | **kept** | listed in `options()` only (declared by the iSCSI plugin) |
| `data_addresses` | **kept, mandatory** | VIP addresses to connect; mapped to VIP names for the subsystem exactly as iSCSI ([`_get_conforming_vips`](../../jdssc/jdssc/jovian_common/driver.py#L1559)). The iSCSI fallbacks — `hosts --iscsi`, then control addresses ([`get_iscsi_addresses:2079-2110`](../../OpenEJovianDSS/Common.pm#L2079-L2110)) — are **not** carried over: a subsystem without VIPs is unreachable by API definition, so the property is required (`options: data_addresses => {}` already makes it so for iSCSI, [`:370`](../../OpenEJovianDSSPlugin.pm#L370)) |
| `data_port` | **kept, transport default** | the schema default (3260, [`:278-283`](../../OpenEJovianDSSPlugin.pm#L278-L283)) is global and cannot differ per plugin, so `get_data_port` becomes transport-aware: unset on a `joviandss-nvmeof` storage → `NVMEOF_DEFAULT_PORT`. (`pvesm` help will still print 3260 as the default — a known wart of the shared schema; a note in the NVMe-oF user docs covers it) |
| `nqn_prefix` | **new** | NQN prefix for subsystem names, default `NVMEOF_DEFAULT_NQN_PREFIX`; the analog of `target_prefix`, but consulted at creation only — not `fixed` ([Subsystem naming](#subsystem-naming)) |
| `nvme_transport` | **new** | `tcp` (default) \| `rdma` — the `transmission_type` sent per VIP and the `-t` of `nvme connect` |
| `nvme_ctrl_loss_tmo` | **new** | seconds the kernel keeps reconnecting a lost controller before removing it; default `NVMEOF_DEFAULT_CTRL_LOSS_TMO` (`-1`, unbounded) |
| `target_prefix`, `luns_per_target`, `chap_enabled`, `chap_user_name`, `chap_user_password`, `multipath`, `multipath_lock_*` | **dropped** | no target groups, no in-band auth in the API, no dm-multipath |

`plugindata` is the iSCSI one minus `chap_user_password` from
`sensitive-properties`. `api()` is inherited (storage API 9–15).

#### Subsystem naming
[Subsystem_naming](#subsystem-naming)

The appliance auto-generates an NQN if none is given and calls it
non-descriptive; the plugin supplies one **at creation time only**. Since the
subsystem is looked up **by volume name** and never parsed back, the NQN only
needs to be unique and diagnosable:

```
<nqn_prefix><pool>:<backend volume name>
nqn.2025-04.proxmox.joviandss.nvmeof:Pool-2:v_vm-100-disk-0          # plain
nqn.2025-04.proxmox.joviandss.nvmeof:Pool-2:v_pveA_vm-100-disk-0     # cluster_prefix
nqn.2025-04.proxmox.joviandss.nvmeof:Pool-2:se_snap1_…               # snapshot clone
```

The backend name is what jdssc already computes (`vname()` /
`sname()` in [`jdss_common.py`](../../jdssc/jdssc/jovian_common/jdss_common.py#L124)),
so uniqueness *within a pool* is inherited from ZFS. The **pool is part of the
name** because NQNs, like IQNs, are appliance-global while zvol names are
pool-scoped: two pools each holding `v_vm-100-disk-0` would otherwise collide
on the same NQN — the exact case the iSCSI driver has to detect at runtime as
`JDSSTargetPoolConflictException` ([`driver.py:1812`](../../jdssc/jdssc/jovian_common/driver.py#L1812))
and tell the operator to fix by hand. Here it cannot arise by construction.

**The record is authoritative afterwards.** Once a subsystem exists, its NQN
is whatever `GET /nvmet/<volume>` returns — the plugin never recomputes it and
never renames it (a `PUT subsystem_name` recreates the subsystem and drops
every connected host, per the API). A subsystem created under an older
`nqn_prefix`, by an operator, or with an appliance-generated name is simply
**adopted**. `nqn_prefix` is therefore not `fixed`: changing it affects only
subsystems created afterwards, and the iSCSI-style "rename the prefix and
lose sight of your volumes" hazard ([0004 — Immutability](0004-cluster-prefix-design.md#immutability))
does not exist, because lookup is by volume name, not by prefix.

Two constraints to pin live (Open Question 5): the NQN charset the appliance
accepts (`_` in `v_`, uppercase and `-` in a pool name or `cluster_prefix`) and
the 223-byte length bound of the NVMe spec — if either bites, jdssc lowercases
and falls back to a base32 encoding of the volume name (the same
`JBase32FromStr` used for `vb_` names). `subsystem_serial` is left to the
appliance.

#### Export creation — one subsystem per volume
[Export_creation](#export-creation--one-subsystem-per-volume)

**This is where the two transports differ most, and where the iSCSI code is
most intricate.** An iSCSI target is a *container* — up to `luns_per_target`
volumes share `<target_prefix><group>-<n>` — so publishing a volume is a
**search**: find a target under the prefix+group with a free LUN slot, or
create the next suffix; if the volume is already attached somewhere, decide
whether to keep it there or re-home it, which may require detaching a target
that other initiators are using. An NVMe-oF subsystem holds **exactly one**
volume and is addressed by that volume's name, so publishing is a **lookup**:
`GET /nvmet/<volume>` — adopt if present, `POST` if absent. Nothing is ever
searched, numbered, re-homed or detached from under another host. Every
mechanism the iSCSI container model needs has a definite fate:

**Table 3a — The multi-LUN target machinery and its NVMe-oF fate** · `tbl_target_model`

| iSCSI mechanism | Where | NVMe-oF fate |
|---|---|---|
| Target search: prefix + group + `-<n>` suffix, free-LUN-slot scan, `luns_per_target`, `--current` | [`_acquire_taget_volume_lun`](../../jdssc/jdssc/jovian_common/driver.py#L1340), [`ensure_target_volume`](../../jdssc/jdssc/jovian_common/driver.py#L1476) | **none** — `ensure_nvmet_volume` is `GET` then `POST`; no suffix, no slot, no group |
| Target name computed by the client (`<prefix><group>-<n>`) and reconstructed on every call (`targets get/delete` take the prefix and group) | [`volume_unpublish:3994-4004`](../../OpenEJovianDSS/Common.pm#L3994-L4004), [`target_active_info:2144-2148`](../../OpenEJovianDSS/Common.pm#L2144-L2148) | **inverted** — the NQN is supplied once at `POST` and read back from the record ever after; `nvmet get/delete` take only the volume name ([Subsystem naming](#subsystem-naming)) |
| Re-home with the array-session guard: detaching a volume from a target with live foreign sessions raises `JDSSTargetInUseException` → `joviandss-target-in-use:` → cycle class (1c) fails fast | [`driver.py:1166-1192`](../../jdssc/jdssc/jovian_common/driver.py#L1166-L1192), [`targets.py:274-292`](../../jdssc/jdssc/targets.py#L274-L292), [`volume_activate:4694-4698`](../../OpenEJovianDSS/Common.pm#L4694-L4698) | **none** — a volume is never moved between subsystems, so nothing is ever detached from under a host; the marker is never emitted and class (1c) is inert (unchanged code) |
| Target name owned by another pool: `JDSSTargetPoolConflictException` → `joviandss-target-pool-conflict:` → cycle class (1d) | [`driver.py:1780-1812`](../../jdssc/jdssc/jovian_common/driver.py#L1780-L1812), [`volume_activate:4704-4708`](../../OpenEJovianDSS/Common.pm#L4704-L4708) | **prevented by construction** — the pool is in the NQN. Residual: a `POST` refused because the chosen NQN exists for a *different* zvol (a hand-made subsystem, or an appliance that rejects the `:` form) → jdssc emits the **same** `joviandss-target-pool-conflict:` marker with an NQN-specific message, and class (1d) fails fast unchanged |
| Shared-target guard: another storage's record under the same target → `joviandss-target-collision:` → class (1b); the alloc/clone warm-up undoes its publish on collision | [`_volume_activate_attempt:4839-4858`](../../OpenEJovianDSS/Common.pm#L4839-L4858), [`OpenEJovianDSSPlugin.pm:1213-1222`](../../OpenEJovianDSSPlugin.pm#L1213-L1222), [`:1015-1024`](../../OpenEJovianDSSPlugin.pm#L1015-L1024) | **inert, unchanged** — `lun_record_local_search_by_target` looks for *other* volumes' records under the returned name; no two volumes share an NQN, so it never matches. No branch needed |
| Pre-activation **warm-up publish** at alloc and clone (best-effort, maintainer ruling F-07) | [`OpenEJovianDSSPlugin.pm:1197-1206`](../../OpenEJovianDSSPlugin.pm#L1197-L1206), [`:1010`](../../OpenEJovianDSSPlugin.pm#L1010) | **kept, through the dispatcher** — the subsystem is created at alloc time and, since nothing but `free_image` / snapshot-clone teardown / the (inert) recovery detach ever unpublishes a plain volume, **it exists for the volume's whole life**. This is what makes `block_device_path_from_rest` work on an inactive volume ([Device identity and path](#device-identity-and-path)) |
| Multi-record disambiguation asks the array which target/LUN currently carries the volume | [`volume_deactivate:5067`](../../OpenEJovianDSS/Common.pm#L5067), [`volume_update_size:5345`](../../OpenEJovianDSS/Common.pm#L5345) → [`target_active_info`](../../OpenEJovianDSS/Common.pm#L2131) | **dispatched** — `target_active_info` becomes a seam function; the NVMe branch runs `nvmet get` and returns `{name => $nqn, lun => $nsid, iplist}`. Duplicate records can only arise from a stale record under a previous NQN, and the array's answer resolves it exactly as for iSCSI |
| Residual target logout when the last LUN record on a target goes; "target shared between storages" warning | [`lun_record_local_delete:4450-4474`](../../OpenEJovianDSS/Common.pm#L4450-L4474), [`:4510-4527`](../../OpenEJovianDSS/Common.pm#L4510-L4527) | **degenerates correctly** — one record per NQN dir, so "last record" is "the record"; the disconnect has already run in the teardown ([Stage and unstage](#stage-and-unstage)); the warning cannot fire |
| `--luns-per-target`, `--target-prefix`, `--target-group-name` on every `targets` call; `target_update_chap` | [`volume_publish:2287-2291`](../../OpenEJovianDSS/Common.pm#L2287-L2291), [`target_update_chap`](../../OpenEJovianDSS/Common.pm#L2343) | **none** |
| VIP restriction by name (`vip_allowed_portals.assigned_vips`) | [`_get_conforming_vips`](../../jdssc/jdssc/jovian_common/driver.py#L1559) | **same** — `vips: [{vip_name, transmission_type}]` at `POST`, reconciled with `PUT` |

Two things the simpler model *adds*: (a) **reconcile on adopt** — an existing
subsystem may have been created by an older configuration, so `ensure` corrects
its VIP set (`PUT vips`) and re-activates it (`PUT active`) but touches nothing
else; (b) **concurrent hosts** — live migration needs the source and
destination nodes connected to the same subsystem at once, which the iSCSI
target model gives for free (two initiators, one target). The API describes no
host allow-list, so subsystems are presumed to accept any host; this is load-
bearing and unverified (Open Question 6f).

#### jdssc: the `nvmet` resource
[jdssc_nvmet_resource](#jdssc-the-nvmet-resource)

A new pool-level resource, wired like `targets` in
[`pool.py:74-84`](../../jdssc/jdssc/pool.py#L74-L84) (bare `add_parser`,
one-line delegating handler, own module with dispatch dict and `__parse`):

```
pool <pool> nvmet create -v <volume> [--snapshot <snap>] [-d]
                         --nqn-prefix <p> [--transport tcp|rdma]
pool <pool> nvmet delete -v <volume> [--snapshot <snap>] [-d]
pool <pool> nvmet get    -v <volume> [--snapshot <snap>] [-d]
pool <pool> nvmet list
```

**Output contract of `create` and `get`** — one line, the analog of
[`targets.py:318`](../../jdssc/jdssc/targets.py#L318), consumed by the Perl
`volume_publish`:

```
<nqn> <nsid> <ip1,ip2,…> <uuid> <nguid>
```

`nsid` is the record's `namespaces[0].number` (`1`; printed rather than
assumed so a future multi-namespace appliance does not silently break the
record path). `uuid`/`nguid` print `-` when absent (the `-` placeholder
convention of the NAS listing), and Perl dies on a `-` uuid the way it dies on
a missing scsi id today ([`volume_publish:2316-2321`](../../OpenEJovianDSS/Common.pm#L2316-L2321)).

Layering follows the house pattern (CLI → driver → REST, never CLI → REST):

- **REST** (`rest.py`): `create_nvmet(volume_name, vips, subsystem_name=None)`
  → `POST /nvmet`, 201; 409 → `JDSSResourceExistsException` (assumed —
  Open Question 6). `get_nvmet(volume_name)` → `GET /nvmet/<v>`, 404 →
  `JDSSResourceNotFoundException`. `get_nvmets()`, `delete_nvmet(volume_name)`
  (204; 404 tolerated by the driver), `edit_nvmet(volume_name, **fields)` →
  `PUT`. **Feature gate:** a 404 on `GET /nvmet` (the *collection*) means the
  blueprint is absent; it maps to a dedicated `JDSSNvmetUnavailableException`
  whose message names the cause, so the operator never sees a bare 404.
- **Driver** (`driver.py`): `ensure_nvmet_volume(nqn_prefix, volume_name,
  transport, direct_mode=False)` — the analog of `ensure_target_volume`
  with the search replaced by a lookup ([Export creation](#export-creation--one-subsystem-per-volume)):
  `is_lun` check; `GET /nvmet/<v>`; **absent** → `POST` with `vips` =
  `[{vip_name, transmission_type}]` over `_get_conforming_vips()` and
  `subsystem_name` per [Subsystem naming](#subsystem-naming); **present** →
  **adopt**: keep its NQN whatever it is (never `PUT subsystem_name`), and
  reconcile only the VIP set (`PUT vips`, the analog of
  `set_target_assigned_vips`) and `active`. A `POST` answered 409 is a lost
  race with a concurrent publish → re-`GET` and adopt; a `POST` refused
  because the NQN is already taken by another zvol → the
  `joviandss-target-pool-conflict:` marker (Table 3a). The subsystem must be
  `active` before the result is read — `namespaces[].number` exists only
  then (Table 2); a missing `nsid` after activation is an error, not a `-`.
  Returns `{nqn, nsid, vips, uuid, nguid}`. `get_nvmet_volume(volume_name,
  snapshot_name=None, direct_mode=False)` is the read-only counterpart behind
  `nvmet get` (and `block_device_path_from_rest`): same return shape, raises
  `JDSSResourceNotFoundException` when no subsystem exists. `create_export_snapshot_nvmet` /
  `remove_export_nvmet` / `remove_export_snapshot_nvmet` mirror
  [`create_export_snapshot`](../../jdssc/jdssc/jovian_common/driver.py#L761)
  / [`remove_export`](../../jdssc/jdssc/jovian_common/driver.py#L821) /
  [`remove_export_snapshot`](../../jdssc/jdssc/jovian_common/driver.py#L849):
  same `_clone_object` of the snapshot into a read-only `sname()` clone, then
  the subsystem is created **for the clone** (its own NQN).
- **Volume delete:** [`_delete_volume`](../../jdssc/jdssc/jovian_common/driver.py#L410)
  gains an nvmet detach beside its iSCSI [`_detach_volume`](../../jdssc/jdssc/jovian_common/driver.py#L1039)
  — `DELETE /nvmet/<v>` for the volume and for each hidden snapshot clone,
  404-tolerant — selected by a new `volume delete --transport iscsi|nvmeof`
  flag (default `iscsi`, so the existing call is unchanged).

No credentials cross this resource beyond the REST password, which already
travels the `--sensitive-file` channel; nothing new for 0008.

#### Publish and unpublish
[Publish_and_unpublish](#publish-and-unpublish)

`OpenEJovianDSS::NVMeCommon::volume_publish($ctx, $tgname, $volname, $snapname,
$content_volume_flag)` keeps the iSCSI signature so the dispatcher is a
pass-through. `$tgname` is accepted and ignored (there are no groups; the
argument stays so `_volume_activate_attempt` needs no transport branch for
it). It runs `pool <pool> nvmet create -v <volname> [--snapshot <snap>] [-d]
--nqn-prefix <p> --transport <t>` and returns the `%tinfo` shape the cycle
reads ([`_volume_activate_attempt:4807-4830`](../../OpenEJovianDSS/Common.pm#L4807-L4830)):

```perl
my %tinfo = (
    target => $nqn,            # $state->{targetname}
    lunid  => $nsid,           # $state->{lunid}
    iplist => \@vips,          # $state->{hosts}
    scsiid => $uuid,           # $state->{scsiid} — the device-identity token
    nguid  => $nguid,          # NVMe-only extra, recorded for diagnostics
);
```

The field names are kept (`target`, `lunid`, `scsiid`) because they are the
cycle's vocabulary — renaming them is a separate, transport-neutral cleanup
and out of scope. `volume_unpublish` runs `nvmet delete`. Idempotency matches
iSCSI: create on an existing subsystem reconciles, delete on a missing one is
a no-op.

#### Stage and unstage
[Stage_and_unstage](#stage-and-unstage)

`OpenEJovianDSS::NVMeCommon::volume_stage($ctx, $nqn, $nsid, $hosts, $uuid,
$expected_size)` — the analog of
[`volume_stage_iscsi`](../../OpenEJovianDSS/Common.pm#L2660), same shape:

1. **Fast path** — the by-id device exists and
   [`capacity_ok`](#capacity-check) passes → return it (mirrors
   [`:2666-2669`](../../OpenEJovianDSS/Common.pm#L2666-L2669)).
2. **Connect per VIP** — for each host not already connected (read once from
   `nvme list-subsys -o json`; a controller in state `live` for `<nqn>` at
   `traddr=<host>` counts as present — the analog of the `iscsiadm --mode
   session` scan at [`:2673-2697`](../../OpenEJovianDSS/Common.pm#L2673-L2697)):

   ```
   nvme connect -t <transport> -a <host> -s <port> -n <nqn>
                --ctrl-loss-tmo <tmo> [--reconnect-delay …]
   ```

   run through `nvme_cmd` (below) with `NVME_CONNECT_CMD_TIMEOUT`; an
   "already connected" exit is success, like iSCSI's "already present"
   ([`:2824,2838-2842`](../../OpenEJovianDSS/Common.pm#L2824-L2842)).
   `NVME_LOGIN_ATTEMPTS` rounds with a per-portal `refresh_locks` cooperation
   point after every connect (the F-05 rule, [`:2859-2866`](../../OpenEJovianDSS/Common.pm#L2859-L2866)).
   At least one live controller is required; fewer than all is a warning,
   exactly the iSCSI contract ([`:2893-2906`](../../OpenEJovianDSS/Common.pm#L2893-L2906)).
3. **Device wait** — up to `NVME_DEVICE_WAIT_TICKS` × 1 s for
   `/dev/disk/by-id/nvme-uuid.<uuid>` present **and** capacity verified, a
   `refresh_locks` tick every 10th wait ([`:2926-2928`](../../OpenEJovianDSS/Common.pm#L2926-L2928)),
   and every 3rd tick a namespace rescan of the subsystem's controllers
   (`nvme ns-rescan /dev/nvmeX` via `nvme_cmd` — the analog of
   [`_rescan_target_hosts`](../../OpenEJovianDSS/Common.pm#L2566); it issues
   the same controller rescan `capacity_ok` triggers through sysfs, so a
   wait tick and a capacity probe never disagree on what "rescan" means).
   Exhaustion dies into the cycle. **The exit contract is the iSCSI one:**
   never return on controller evidence alone
   ([0007 — Staging under the lock](0007-volume-activation-with-reactivation.md#staging-under-the-lock)).

There is **no multipath stage**: the native head node *is* the multipath
device. `_volume_activate_attempt`'s Stage 3 is skipped for the transport
(Table 4).

Unstage — `OpenEJovianDSS::NVMeCommon::volume_unstage($ctx, $nqn)` — is one
command, `nvme disconnect -n <nqn>`, which tears down every controller of the
subsystem on this host. Because a subsystem holds exactly one volume, the
iSCSI two-step (delete the `sd` paths per LUN, then log out of the target once
its last LUN record is gone —
[`volume_unstage_iscsi_device`](../../OpenEJovianDSS/Common.pm#L3582) and the
residual-logout rule in [`lun_record_local_delete:4497-4527`](../../OpenEJovianDSS/Common.pm#L4497-L4527))
collapses: the disconnect runs at the `volume_unstage_iscsi_device` position
of the teardown, and the record helper's residual logout finds nothing left to
do (the target dir empties with the single record). The
"target shared between storages" warning ([`:4451-4462`](../../OpenEJovianDSS/Common.pm#L4451-L4462))
cannot fire — an NQN embeds the pool-unique volume name.

`nvme_cmd($ctx, $cmd, $timeout, $outfunc)` is the host chokepoint for every
`nvme` invocation — the `multipath_cmd` shape
([`Common.pm:1514`](../../OpenEJovianDSS/Common.pm#L1514)) **minus** the
TERM-first `timeout(1)` ladder and the lock: `nvme-cli` holds no IPC
semaphore and a SIGKILL'd `nvme connect` strands nothing (the kernel owns the
controller), so `run_command`'s own kill is the right bound and there is no
component hazard to serialize (see [Locks](#locks)). It exists for uniform
logging, the fixed `{exitcode, out}` return shape, `noerr` semantics and a
single place to add a lock later if the field proves one necessary.

#### Device identity and path
[Device_identity_and_path](#device-identity-and-path)

[`block_device_path_from_serial`](../../OpenEJovianDSS/Common.pm#L3251) gains
the transport: for NVMe-oF it returns `/dev/disk/by-id/nvme-uuid.<uuid>`
(never a mapper path). The two callers dispatch on their inputs:

- **From a record** ([`block_device_path_from_lun_rec`](../../OpenEJovianDSS/Common.pm#L3278)):
  the record's `transport` field selects the form; the iSCSI multipath
  re-stage branch ([`:3286-3294`](../../OpenEJovianDSS/Common.pm#L3286-L3294))
  is iSCSI-only.
- **From REST** ([`block_device_path_from_rest`](../../OpenEJovianDSS/Common.pm#L3267)):
  iSCSI derives the id from a *volume* property (`volume get -i`); NVMe-oF's
  uuid is a *namespace* property, so the NVMe branch runs `nvmet get -v <vol>`.
  In practice the subsystem is there: the alloc/clone warm-up creates it and
  nothing unpublishes a plain volume before `free_image` (Table 3a), so an
  inactive volume resolves exactly as an iSCSI one does. The residual case —
  no subsystem (warm-up failed, or an operator deleted it) — returns **undef**
  and `_path` reports no path ([`:441-444`](../../OpenEJovianDSSPlugin.pm#L441-L444)
  is the same shape for a missing volume today); the next `activate_volume`
  republishes and repairs it. Whether the uuid survives a subsystem
  delete/recreate (Open Question 3b) is therefore informational only.

#### Capacity check
[Capacity_check](#capacity-check)

`OpenEJovianDSS::NVMeCommon::capacity_ok($ctx, $path, $expected)` keeps finding
#23's rule — **rescan, then read** ([`_iscsi_capacity_ok:2968-2977`](../../OpenEJovianDSS/Common.pm#L2968-L2977)):
resolve the by-id symlink to `/dev/nvmeXnY`, write `1` to
`/sys/class/nvme/nvmeX/rescan_controller` for each controller of the head
node (the NVMe IDENTIFY NAMESPACE round-trip that forces the appliance to
answer), then `blockdev --getsize64`; zero or unreadable never verifies, a
non-zero size verifies when no expectation is given (the F-04 contract). The
broken-export tell this guards — a namespace that appears but reports zero
capacity — is transport-independent.

#### LUN records
[LUN_records](#lun-records)

The on-disk layout is reused unchanged —
`/etc/joviandss/state/<storeid>/<nqn>/<nsid>/<volname>` — so
[`lun_record_local_get_info_list`](../../OpenEJovianDSS/Common.pm#L4106)'s
path regex ([`:4136`](../../OpenEJovianDSS/Common.pm#L4136)), the
snapshot-record listing, `volume_deactivate`'s record resolution
([`:5048-5104`](../../OpenEJovianDSS/Common.pm#L5048-L5104)) and the residual
cleanup in `lun_record_local_delete` all work as they are. NQNs contain only
`[a-z0-9.:_-]`, which the record path whitelist
([`:4064`](../../OpenEJovianDSS/Common.pm#L4064)) already accepts.

The record gains two fields — `transport` (`nvmeof`) and `nguid` — and keeps
`scsiid` as the identity token (holding the uuid) so that
`volume_deactivate_by_lun_record` and `lun_record_update_device` need only
the transport branch, not a field rename. `multipath` is recorded `\0` for
the transport. A record without a `transport` field is iSCSI (every record
written before this change).

#### Activation cycle deltas
[Activation_cycle_deltas](#activation-cycle-deltas)

The cycle in [`volume_activate`](../../OpenEJovianDSS/Common.pm#L4620) —
classification, sweep gate, teardown, budget check — runs unchanged. The
per-stage bodies branch as follows.

**Table 4 — Transport branches in the shared drivers** · `tbl_cycle_branches`

| Site | iSCSI (today) | NVMe-oF branch |
|---|---|---|
| [`_volume_activate_attempt:4807`](../../OpenEJovianDSS/Common.pm#L4807) publish | `volume_publish` | dispatched — no branch here |
| [`:4879`](../../OpenEJovianDSS/Common.pm#L4879) stage | `volume_stage_iscsi(targetname, lunid, hosts, scsiid, size)` | `NVMeCommon::volume_stage(nqn, nsid, hosts, uuid, size)` |
| [`:4892`](../../OpenEJovianDSS/Common.pm#L4892) multipath | `volume_stage_multipath` when `get_multipath` | **skipped** on the transport regardless of `get_multipath` (which returns its default `0` anyway — the property is not in the type's `options()`) |
| [`:4903`](../../OpenEJovianDSS/Common.pm#L4903) record | `lun_record_local_create(…, $multipath, …)` | same call; `multipath => 0`, `transport`, `nguid` added |
| [`_volume_deactivate_attempt:4934`](../../OpenEJovianDSS/Common.pm#L4934) unstage | `volume_unstage_iscsi_device` | `NVMeCommon::volume_unstage(nqn)` |
| [`:4940`](../../OpenEJovianDSS/Common.pm#L4940) multipath unstage | `volume_unstage_multipath` | **skipped** |
| [`volume_activate:4683-4708`](../../OpenEJovianDSS/Common.pm#L4683-L4708) fail-fast classes (1b) collision, (1c) in use, (1d) pool conflict | marker match on `$last_err` | **unchanged** — (1b) and (1c) can never trigger (Table 3a); (1d) is reused for an NQN owned by another zvol |
| [`:4954`, `:4983`](../../OpenEJovianDSS/Common.pm#L4954) unpublish | `volume_unpublish` | dispatched — no branch |
| [`:4965`](../../OpenEJovianDSS/Common.pm#L4965) foreign-session gate | `_target_foreign_sessions` over the sessions endpoint | **no endpoint** → the probe dies "no session query for transport nvmeof" → *no evidence, no detach*: the recovery detach **never fires** for NVMe-oF until the appliance exposes connected hosts (Open Question 1). The final cycle therefore runs without the re-attach reset — safe, weaker |
| [`volume_deactivate_by_lun_record:4565-4598`](../../OpenEJovianDSS/Common.pm#L4565-L4598) | unstage device, then multipath | `NVMeCommon::volume_unstage`; no multipath block |
| [`lun_record_update_device`](../../OpenEJovianDSS/Common.pm#L5112) (lenient resize path) | sd rescan, `multipath -r`, `multipathd reconfigure` ladder | `nvme ns-rescan` + `capacity_ok`; no dm-layer steps |
| [`volume_deactivate:5067`](../../OpenEJovianDSS/Common.pm#L5067) / [`volume_update_size:5345`](../../OpenEJovianDSS/Common.pm#L5345) multi-record disambiguation | `target_active_info` → `targets get --current` | dispatched — `target_active_info` becomes a seam function; the NVMe branch answers from `nvmet get` (Table 3a) |
| [`_path:429`](../../OpenEJovianDSSPlugin.pm#L429) / [`:468`](../../OpenEJovianDSSPlugin.pm#L468) | `block_device_path_from_rest` / `…_from_lun_rec` | dispatched — no branch |

The stale-cookie sweep ([0007 — Stale-cookie recovery](0007-volume-activation-with-reactivation.md#stale-cookie-recovery))
can never arm for the transport — nothing sets `_multipath_cmd_ladder_exhausted`
— and is a no-op by construction.

#### Snapshots and clones
[Snapshots_and_clones](#snapshots-and-clones)

Unchanged in mechanism: a snapshot is exported by cloning it into a read-only
`sname()` volume and publishing the clone ([`create_export_snapshot`](../../jdssc/jdssc/jovian_common/driver.py#L761));
the clone gets its own subsystem. The clone's NQN differs from the parent's,
so a snapshot activation never touches the parent's connections — the same
isolation iSCSI gets from separate LUNs, without the shared target. Rollback,
`volume_snapshot_delete`'s deactivate-before-delete, and the
`snapshot-record` listing that `volume_deactivate` walks
([`:5040-5047`](../../OpenEJovianDSS/Common.pm#L5040-L5047)) work on the
records and are transport-blind.

#### Volume delete and resize
[Volume_delete_and_resize](#volume-delete-and-resize)

`_free_image` deactivates the volume and then runs `volume delete -c` with the
iSCSI target arguments ([`OpenEJovianDSSPlugin.pm:1340-1347`](../../OpenEJovianDSSPlugin.pm#L1340-L1347)),
relying on jdssc to detach the target during the delete (the comment at
[`:1331-1338`](../../OpenEJovianDSSPlugin.pm#L1331-L1338) records why
`volume_unpublish` is skipped). The NVMe branch passes `--transport nvmeof`
instead of the target arguments and jdssc's delete removes the subsystem(s)
first — the same single-call economy, same rationale.

Resize: `_volume_resize` ([`:2015`](../../OpenEJovianDSSPlugin.pm#L2015))
resizes the zvol and calls `lun_record_update_device` for the local device;
the NVMe branch of that function (Table 4) rescans the namespace and
re-verifies capacity. The appliance's nvmet layer is expected to raise an
AEN on the size change, so the rescan is a belt-and-braces (Open Question 7).

#### Locks
[Locks](#locks)

No new lock class. The method locks (`vm`/`storage`) and the jdssc locks are
transport-neutral and apply as they are. The `multipath` class stays iSCSI's.
`nvme-cli` is not a known non-concurrency-safe component (0006's criterion for
a class): concurrent `nvme connect` calls are serialized by the kernel's
fabrics interface and share no user-space state. If field behavior contradicts
this, adding an `nvme` class is the one-row-per-map addition 0006 specifies —
`nvme_cmd` is already the single place to take it.

`refresh_locks` cooperation points are placed where iSCSI has them (per
connect, every 10th wait tick), so the held `vm` lock's mtime and hold
deadline are serviced through the whole stage.

---

## Alternatives Considered
[Alternatives_Considered](#alternatives-considered)

- **A `transport` property on the existing `joviandss` type** (one plugin,
  `transport iscsi|nvmeof` in storage.cfg) instead of a new type. Rejected:
  the two transports have different mandatory/forbidden property sets
  (`chap_*`, `multipath`, `luns_per_target` vs `nqn_prefix`, `nvme_transport`),
  which SectionConfig cannot express per value of another property; the
  password directory, `get_identity` and the operator's mental model all key
  on type; and a type is what lets `pvesm add joviandss-nvmeof …` fail early
  on an appliance without the feature. The `get_transport` accessor gives the
  code the single axis this alternative wanted, without the config ambiguity.
- **Discovery-based connect** (`nvme discover` / `connect-all` against a
  discovery controller instead of connecting per VIP to a known NQN).
  Rejected: the NQN and the VIP list are returned by the create call, so
  discovery adds a round-trip and a failure mode (a discovery controller
  that lists more than this volume) for nothing; per-VIP connect also mirrors
  iSCSI's per-portal login, keeping the stage logic parallel.
- **Using dm-multipath over NVMe paths** (`nvme_core.multipath=N` +
  `multipathd`). Rejected: it re-imports the semaphore hazard and the entire
  0007 multipath apparatus to replace a kernel feature that is on by default
  and does the same job with no daemon.
- **Reusing the iSCSI `scsi_id`/`volume get -i` for NVMe identity.** Rejected:
  the namespace uuid is what the kernel names the device by; the zvol's SCSI
  serial is not exposed on the NVMe path.

---

## Consequences
[Consequences](#consequences)

- A third storage type, `joviandss-nvmeof`, with `images`/`rootdir` content,
  `raw` format, snapshots/rollback/clone/resize/migration — feature parity
  with the iSCSI plugin except for CHAP and the recovery detach.
- The activation seam becomes explicit: `get_transport` and the dispatchers
  are the documented extension points for any further block transport.
- The iSCSI plugin's behavior is unchanged: every dispatcher defaults to the
  iSCSI branch and its tests pin that.
- A new host dependency (`nvme-cli`) and a new appliance requirement
  (`FEATURES_AVAILABLE.nvmet`), both surfaced at `pvesm add` rather than at
  first VM start (Risk 1).
- No new secrets, no new lock class, no change to the record directory layout (two fields
  added, absent = iSCSI), no
  jdssc argv change for the iSCSI path (the `volume delete` flag defaults to
  today's behavior).

---

## Risks & Backward Compatibility
[Risks_and_Backward_Compatibility](#risks--backward-compatibility)

### Preserved (low risk)

- **iSCSI and NFS storages see no behavior change.** `get_transport` returns
  `iscsi` for `joviandss`; NFS never reaches a block seam; every dispatch
  point's iSCSI branch is the current body under a new name. Pinned by the
  existing suites plus one dispatch test per seam function.
- **Records, locks, credentials, naming are untouched.** Existing records
  (no `transport` field) read as iSCSI.
- **jdssc's iSCSI CLI surface is untouched** — `nvmet` is a new resource;
  `volume delete --transport` defaults to `iscsi`.

### Risks

1. **The appliance may not have `nvmet` (highest, must fail early).** Every
   `/nvmet` path 404s without `FEATURES_AVAILABLE.nvmet`, and a bare 404
   would surface as "resource does not exist" at first activation — the
   Issue 9 failure shape (`pvesm add` accepts a storage that cannot work).
   Guard: jdssc maps a 404 on the *collection* to
   `JDSSNvmetUnavailableException`; `on_add_hook` probes `nvmet list` once
   and refuses the add with that message. (This is the single pool check
   Issue 9 recommends for `on_add_hook`, applied to the feature.)
2. **The recovery detach is inert for the transport.** With no sessions
   endpoint, `_target_foreign_sessions` has no evidence and the pre-final
   teardown never detaches — the wedged-attachment recovery of 0007's Option
   B is unavailable; NVMe-oF activation has Option C's semantics (logout-level
   teardown only). Safe (never a wrong detach), strictly weaker recovery.
   Guard: tracked as Open Question 1 with the API request; the branch is one
   function to fill in once an endpoint exists.
3. **No in-band authentication and no host allow-list.** Any host that can
   reach a data VIP can `nvme connect` to any subsystem whose NQN it knows —
   the situation iSCSI is in with `chap_enabled 0`, minus the option to turn
   it on. Guard: documented as a network-isolation requirement in the
   NVMe-oF user docs; DH-HMAC-CHAP / host NQN allow-lists become a design
   follow-up when the API exposes them (Open Question 8).
4. **Device identity form is assumed, not measured.** `nvme-uuid.<uuid>` vs
   `nvme-eui.<nguid>` depends on the kernel's `wwid` preference and on what
   the appliance actually populates; a wrong assumption fails every device
   wait. Guard: the form is pinned by live verification **before**
   implementation (Open Question 3) and lives in one place
   (`block_device_path_from_serial`); no runtime dual-form probing — the
   record carries `nguid` so the alternative is derivable, but the design
   does not speculate on a kernel preference change.
5. **Native multipath disabled on the host.** With `nvme_core.multipath=N`
   each controller becomes its own `/dev/nvmeXnY` and the by-id link points
   at one of them — silently single-path. Guard: the stage reads
   `/sys/module/nvme_core/parameters/multipath` and, when `N` with more than
   one `data_addresses` entry, dies with an actionable message rather than
   activating a non-redundant device (fail loud, value #1).
6. **Reconnect tuning is new territory.** `ctrl_loss_tmo=-1` keeps a
   controller in `connecting` forever after a permanent VIP loss, which is
   what a running VM wants but leaves `nvme list-subsys` clutter after a
   deliberate decommission — `nvme disconnect` in the teardown clears it.
   Tunable via `nvme_ctrl_loss_tmo`.
7. **Subclassing a Custom plugin (Variant A).** `use base` on
   `PVE::Storage::Custom::OpenEJovianDSSPlugin` loads the parent first, so
   registration order is satisfied; but PVE's `Custom` scan double-loads
   modules (the `perl -c` "Subroutine redefined" artifact noted in the
   development-environment guide), and the inherited `properties()` **must**
   be overridden to avoid duplicate-property deaths. Guard: unit test that
   both plugins register and `pvesm` starts with both types present.
8. **RDMA is declared but unqualified.** `nvme_transport rdma` is a straight
   pass-through of the API's `transmission_type` and of `nvme connect -t`;
   nothing here is RDMA-specific, and nothing has been tested on RDMA
   hardware. Documented as unsupported until qualified (Open Question 9).
9. **`--transport` on `volume delete` is a jdssc contract change.** Default
   `iscsi` keeps today's callers exact; a mis-passed value on the NVMe plugin
   would leave a subsystem attached and make the zvol delete fail loudly
   (the appliance refuses to delete an exported zvol — verify, Open Question
   6c) rather than orphan anything.

---

## Files That Would Change
[Files_That_Would_Change](#files-that-would-change)

Variant A shown; Variant B replaces the first three Perl rows with a standalone
plugin (~2 000 lines) and `NVMeCommon.pm` (~1 500 lines).

**Table 5 — Files that would change** · `tbl_files_changed`

| File | Change |
|---|---|
| `OpenEJovianDSS/Common.pm` | `PLUGIN_TYPE_JOVIANDSS_NVMEOF`, `TRANSPORT_*` constants; `get_plugin_type` branch; `get_transport`; NVMe defaults (`NVMEOF_DEFAULT_*`) + getters (`get_nqn_prefix`, `get_nvme_transport`, `get_nvme_ctrl_loss_tmo`); rename today's `volume_publish`/`volume_unpublish`/`target_active_info` bodies to `_volume_publish_iscsi`/`_volume_unpublish_iscsi`/`_target_active_info_iscsi` and add the dispatchers; transport branches at every Table 4 site; `block_device_path_from_serial`/`_from_rest`/`_from_lun_rec` transport-aware; record `transport`/`nguid` fields in `lun_record_local_create`; `get_data_port` transport default; `_free_image`'s delete arguments via a `volume_delete_transport_args($ctx, $tgname)` helper |
| `OpenEJovianDSS/NVMeCommon.pm` | **new** leaf module: `volume_publish`, `volume_unpublish`, `target_active_info`, `volume_stage`, `volume_unstage`, `capacity_ok`, `nvme_cmd`, `controllers_for_nqn` (`nvme list-subsys -o json` parse), `host_nqn` (reads `/etc/nvme/hostnqn`), `native_multipath_enabled` |
| `OpenEJovianDSSNVMeoFPlugin.pm` | **new**, subclass of the iSCSI plugin: `type`, `plugindata`, `properties` (the three new names only), `options`, `on_add_hook` override adding the `nvmet list` feature probe before delegating |
| `OpenEJovianDSSPlugin.pm` | none functionally; `_free_image` and `_volume_resize` call the Common helpers instead of inlining iSCSI arguments |
| `jdssc/jdssc/nvmet.py` | **new** CLI resource (`create`/`delete`/`get`/`list`, the `snapshots.py` module shape) |
| `jdssc/jdssc/pool.py` | `nvmet` subparser + delegating handler |
| `jdssc/jdssc/jovian_common/rest.py` | `create_nvmet`, `get_nvmet`, `get_nvmets`, `edit_nvmet`, `delete_nvmet`; feature-gate 404 mapping |
| `jdssc/jdssc/jovian_common/driver.py` | `ensure_nvmet_volume`, `create_export_snapshot_nvmet`, `remove_export_nvmet`, `remove_export_snapshot_nvmet`, `get_nvmet_volume`; `_delete_volume` nvmet detach behind `transport` |
| `jdssc/jdssc/jovian_common/exception.py` | `JDSSNvmetUnavailableException` |
| `jdssc/jdssc/volume.py` | `delete --transport iscsi\|nvmeof` (default `iscsi`) |
| `jdssc/tests/test_nvmet.py` | **new** — REST request shapes, driver reconcile logic, CLI output contract, feature-gate mapping (mocked REST) |
| `tests/nvmeof_dispatch_test.pl` | **new** — every dispatcher returns the iSCSI branch for `joviandss`, the NVMe branch for `joviandss-nvmeof`, dies for `joviandss-nfs`; record `transport` defaulting |
| `tests/nvmeof_plugin_test.pl` | **new** — properties/options shape, duplicate-property registration with both plugins loaded, `on_add_hook` feature refusal |
| `debian/control` | `Depends: … nvme-cli` |
| `install.pl` | install the new plugin file and `NVMeCommon.pm` |
| `docs/Plugin-configuration-NVMeoF.md`, `docs/Quick-Start-NVMeoF.md` | **new** user docs (network-isolation note per Risk 3) |
| `docs/design/README.md` | none (this document follows the conventions; the `0008` status example there is already stale — separate fix) |
| `docs/design/0009-nvmeof-plugin-design.md` | this document |

---

## New Constants
[New_Constants](#new-constants)

Values appear in Table 6b only; prose refers to constants by name.

**Table 6a — Constant descriptions** · `tbl_constants_desc`

| Constant | Description |
|---|---|
| `PLUGIN_TYPE_JOVIANDSS_NVMEOF` | the storage type string; keys `get_plugin_type`, the password dir, `get_transport` |
| `TRANSPORT_ISCSI` / `TRANSPORT_NVMEOF` | the `get_transport` values every seam dispatches on |
| `NVMEOF_DEFAULT_PORT` | `data_port` default for the type (NVMe/TCP's IANA-assigned port) |
| `NVMEOF_DEFAULT_NQN_PREFIX` | `nqn_prefix` default — the NVMe analog of `DEFAULT_TARGET_PREFIX` ([`Common.pm:292`](../../OpenEJovianDSS/Common.pm#L292)) |
| `NVMEOF_DEFAULT_TRANSPORT` | `nvme_transport` default |
| `NVMEOF_DEFAULT_CTRL_LOSS_TMO` | `nvme_ctrl_loss_tmo` default; `-1` = reconnect indefinitely |
| `NVME_CONNECT_CMD_TIMEOUT` | end-to-end bound on one `nvme connect` (reaches a wedged fabrics layer; the analog of `ISCSI_LOGIN_CMD_TIMEOUT`) |
| `NVME_CMD_TIMEOUT_DEFAULT` | bound for every other `nvme` invocation through `nvme_cmd` |
| `NVME_LOGIN_ATTEMPTS` | connect rounds per stage before giving up (iSCSI: the `10` literal at [`:2708`](../../OpenEJovianDSS/Common.pm#L2708)) |
| `NVME_DEVICE_WAIT_TICKS` | 1 s ticks waiting for the verified by-id device (iSCSI: the `240` literal at [`:2908`](../../OpenEJovianDSS/Common.pm#L2908)) |
| `NVME_CAPACITY_PROBE_TIMEOUT` | bound on the `blockdev --getsize64` read in `capacity_ok` (analog of `ISCSI_CAPACITY_PROBE_TIMEOUT`) |

**Table 6b — Constant values** · `tbl_constants_values`

| Constant | Value | Denomination | Location |
|---|---|---|---|
| `PLUGIN_TYPE_JOVIANDSS_NVMEOF` | `joviandss-nvmeof` | string | `OpenEJovianDSS::Common` |
| `TRANSPORT_ISCSI` | `iscsi` | string | `OpenEJovianDSS::Common` |
| `TRANSPORT_NVMEOF` | `nvmeof` | string | `OpenEJovianDSS::Common` |
| `NVMEOF_DEFAULT_PORT` | 4420 | port | `OpenEJovianDSS::Common` |
| `NVMEOF_DEFAULT_NQN_PREFIX` | `nqn.2025-04.proxmox.joviandss.nvmeof:` | string | `OpenEJovianDSS::Common` |
| `NVMEOF_DEFAULT_TRANSPORT` | `tcp` | string | `OpenEJovianDSS::Common` |
| `NVMEOF_DEFAULT_CTRL_LOSS_TMO` | -1 | seconds | `OpenEJovianDSS::Common` |
| `NVME_CONNECT_CMD_TIMEOUT` | 35 | seconds | `OpenEJovianDSS::Common` |
| `NVME_CMD_TIMEOUT_DEFAULT` | 20 | seconds | `OpenEJovianDSS::Common` |
| `NVME_LOGIN_ATTEMPTS` | 10 | rounds | `OpenEJovianDSS::Common` |
| `NVME_DEVICE_WAIT_TICKS` | 240 | ticks | `OpenEJovianDSS::Common` |
| `NVME_CAPACITY_PROBE_TIMEOUT` | 10 | seconds | `OpenEJovianDSS::Common` |

**Value notes.** The connect/wait/probe values copy their iSCSI counterparts
(`ISCSI_LOGIN_CMD_TIMEOUT` 35, the 10-attempt login loop, the 240-tick device
wait, `ISCSI_CAPACITY_PROBE_TIMEOUT` 10) so that the cycle budget worked out
in [0007 — Time budget](0007-volume-activation-with-reactivation.md#time-budget)
holds for the transport without the multipath terms — the NVMe cycle is
strictly cheaper. The NQN prefix mirrors the iSCSI default's date and domain
so the two families sort together in appliance listings.

---

## New Functions
[New_Functions](#new-functions)

In `OpenEJovianDSS/Common.pm`:

- **`get_transport($ctx)`** — `iscsi` / `nvmeof` from the validated plugin
  type; dies for NFS or an unknown type.
- **`get_nqn_prefix`, `get_nvme_transport`, `get_nvme_ctrl_loss_tmo`** —
  property getters with the constants as defaults (the `get_target_prefix`
  pattern, [`:401`](../../OpenEJovianDSS/Common.pm#L401)).
- **`volume_publish` / `volume_unpublish` / `target_active_info`** become
  dispatchers over `_volume_publish_iscsi` / `_volume_unpublish_iscsi` /
  `_target_active_info_iscsi` (today's bodies) and the
  `OpenEJovianDSS::NVMeCommon` functions of the same names.
- **`volume_delete_transport_args($ctx, $tgname)`** — the jdssc `volume
  delete` transport arguments for the storage (`--target-prefix …
  --target-group-name …` for iSCSI, `--transport nvmeof` for NVMe-oF); the
  cascade flag `-c` is transport-neutral and stays at the call site, so
  `_free_image` stays transport-blind.
- **`get_data_port($ctx)`** — becomes transport-aware: an unset `data_port`
  resolves to `DEFAULT_DATA_PORT` for iSCSI and `NVMEOF_DEFAULT_PORT` for
  NVMe-oF (Table 3).

In `OpenEJovianDSS/NVMeCommon.pm` (new):

- **`volume_publish($ctx, $tgname, $volname, $snapname, $content_volume_flag)`**
  — `nvmet create`; returns the `%tinfo` shape of
  [Publish and unpublish](#publish-and-unpublish).
- **`volume_unpublish($ctx, $vmid, $volname, $snapname, $content_volume_flag)`**
  — `nvmet delete` (volume or snapshot clone).
- **`target_active_info($ctx, $tgname, $volname, $snapname, $content_volume_flag)`**
  — `nvmet get`; returns `{name => $nqn, lun => $nsid, iplist}` (the shape
  [`:2169-2173`](../../OpenEJovianDSS/Common.pm#L2169-L2173) returns today) or
  `undef` when no subsystem exists; `$tgname` accepted and ignored.
- **`volume_stage($ctx, $nqn, $nsid, $hosts, $uuid, $expected_size)`** — per-VIP
  connect rounds + verified device wait; returns `[$by_id_path]`; dies on
  exhaustion.
- **`volume_unstage($ctx, $nqn)`** — `nvme disconnect -n <nqn>`, best-effort
  bounded.
- **`capacity_ok($ctx, $path, $expected)`** — controller rescan then
  `blockdev --getsize64`.
- **`nvme_cmd($ctx, $cmd, $timeout, $outfunc)`** — the `nvme` runner;
  `{exitcode, out}`.
- **`controllers_for_nqn($ctx, $nqn)`** — `[{traddr, state, ctrl}]` from
  `nvme list-subsys -o json`.
- **`host_nqn($ctx)`** — `/etc/nvme/hostnqn` (for diagnostics and the future
  foreign-host gate).
- **`native_multipath_enabled()`** — reads
  `/sys/module/nvme_core/parameters/multipath`.

In `jdssc`: the REST/driver/CLI functions listed in
[Files That Would Change](#files-that-would-change).

---

## Testing
[Testing](#testing)

- **Unit (no appliance).** `jdssc/tests/test_nvmet.py`: REST request bodies
  for create (VIP objects with transport, subsystem name), 404-on-collection →
  `JDSSNvmetUnavailableException`, 409 → reconcile path, the `get`/`create`
  output line, `volume delete --transport` default. Perl:
  `nvmeof_dispatch_test.pl` (every seam × three types),
  `nvmeof_plugin_test.pl` (registration with both plugins, property sets,
  `on_add_hook` refusal), and the existing `api_compat_test.pl` run unchanged
  to pin the iSCSI branch.
- **Live, `pve-91` cluster** (per the `JovianDSS-Proxmox:verify` skill:
  alloc → activate → deactivate → free with the plugin log as evidence;
  vmid range 990001–990101, always cleaned up). Before any of it, the
  appliance facts in [Open Questions](#open-questions) 2–6 are captured with
  `curl` against `Pool-2`'s `nvmet` collection (the 0003 method), and the
  kernel facts (by-id form, `nvme_core.multipath`) on `pve-91-1`.
- **E2e, `pve-testing`.** A new `testcases/nvmeof-plugin/` tree mirroring the
  iSCSI layout: `api-compatibility` (v11/v13/v14/v15 — the NFS campaign's
  shape), `delete`, `config-change`, `resilience` (VIP failover under IO with
  `nvme_ctrl_loss_tmo` at default and at a short value), `concurrency` (the
  activation storm that motivated 0007 — the transport must not regress under
  it), plus a `security/` case asserting no secret on `argv` (0008's
  assertions apply verbatim — the only secret is the REST password).
- **Negative:** `pvesm add` against an appliance without `nvmet`;
  `nvme_core.multipath=N` with two VIPs; a zero-capacity namespace (simulated
  by the `jdss-simulator`) driving the cycle through all four attempts.

---

## Relationship to Other Work
[Relationship_to_Other_Work](#relationship-to-other-work)

- [0007 volume-activation-with-reactivation](0007-volume-activation-with-reactivation.md)
  — the cycle this transport runs inside unchanged; Table 4 is the delta.
  Its recovery-detach gate is inert for NVMe-oF (Risk 2).
- [0006 multi-layer-lock](0006-multi-layer-lock-design.md) — no new class;
  `nvme_cmd` is the reserved site if one is ever needed.
- [0005 password-resolution-through-ctx](0005-password-resolution-through-ctx.md)
  — the type-derived pattern `get_transport` copies; the NVMe `.pw` dir falls
  out of it.
- [0004 cluster-prefix](0004-cluster-prefix-design.md) — unchanged; the prefix
  reaches the NQN through the backend volume name.
- [0003 jdssc-target-sessions](0003-jdssc-target-sessions.md) — the shape a
  future `nvmet … hosts list` would take (Open Question 1).
- [0002 chap-auth](0002-chap-auth-design.md) — not applicable; the CHAP
  properties are dropped from the type.
- `docs/issues/ISSUES.md` Issue 9 — the `on_add_hook` feature probe is that
  issue's recommended direction, applied to a feature rather than a pool.
- `jdss-rest-api-spec/jdss2/nvme-of-rest-api.md` — the API contract; its
  gaps are this document's Open Questions 1, 2 and 5–8.

---

## Open Questions
[Open_Questions](#open-questions)

1. **Connected-hosts query.** The API exposes no per-subsystem session/host
   list, so the recovery detach can never gather evidence. Ask Open-E for a
   `GET /nvmet/<volume_name>/hosts` (host NQN + address per controller);
   until then the gate stays closed (Risk 2). Decides whether
   `_target_foreign_sessions` gets an NVMe branch or a permanent "no
   evidence" branch.
2. **Port.** Is NVMe/TCP served on 4420 on every VIP, and is the port
   configurable/exposed anywhere? Assumed 4420 (`NVMEOF_DEFAULT_PORT`).
3. **Device identity.** (a) Which by-id link appears on PVE 9.1 for a JovianDSS
   namespace — `nvme-uuid.<uuid>` or `nvme-eui.<nguid>` — and does the kernel
   populate both? (b) Is the namespace `uuid` stable across
   `DELETE`+`POST` of the subsystem for the same zvol (derived from the zvol),
   or regenerated? (b) is informational: the warm-up publish keeps the
   subsystem alive for the volume's life, so `_path` reads the uuid from it.
4. **Native multipath default.** Confirm `nvme_core.multipath=Y` on the PVE
   9.x kernel and that two connects to one NQN yield one head node.
5. **NQN constraints.** Does the appliance accept `_` and uppercase in
   `subsystem_name`, and what length bound does it enforce? Decides whether
   the plain `<prefix><vname>` form stands or the base32 fallback is needed.
6. **API edge behavior.** (a) `POST /nvmet` for a volume that already has a
   subsystem → 409 (assumed) or 200/reconcile? (b) `GET /nvmet/<v>` for a
   volume without one → 404 (assumed)? (c) `DELETE` of a zvol that still has
   a subsystem → refused or cascaded? (d) Is a freshly `POST`ed subsystem
   `active: true`, or must `PUT {"active": true}` follow? (e) Does a VIP
   failover between HA nodes keep the subsystem served (i.e. is the nvmet
   config replicated) — the assumption behind `ctrl_loss_tmo=-1`? (f) **Does
   a subsystem accept several hosts at once** (nvmet `allow_any_host`)? Live
   migration needs source and destination connected simultaneously; if the
   appliance restricts a subsystem to one host, the transport cannot support
   live migration and the design must say so up front.
7. **Resize propagation.** Does the appliance's nvmet raise a namespace
   attribute-change AEN on zvol resize, so the host sees the new size without
   a rescan? The design rescans regardless; this decides whether the lenient
   verify loop can be shortened for the transport.
8. **Authentication and host allow-list.** Will the API expose DH-HMAC-CHAP
   credentials or `allowed_hosts` on the subsystem? Either would be a
   follow-up design in the 0002/0008 mold (secret off argv, marker-swap
   analog for `/etc/nvme/config.json` if `nvme-cli` takes the key only on
   argv).
9. **RDMA.** Which NICs/offloads does JovianDSS's `rdma` transmission type
   support, and is there a test rig? Until answered, `nvme_transport rdma` is
   documented as unqualified (Risk 8).
10. **Variant.** A is recommended; the decision is recorded here once taken.
