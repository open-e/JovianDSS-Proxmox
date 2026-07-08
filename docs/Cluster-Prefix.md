# Cluster Prefix — Sharing One JovianDSS Pool Across Multiple Clusters

> **Experimental feature.** `cluster_prefix` is new and considered experimental.
> Try it on non-production storage first, and read the
> [Important notes and caveats](#important-notes-and-caveats) before relying on it.

`cluster_prefix` lets several independent Proxmox VE clusters use the **same
JovianDSS pool** at the same time without seeing or interfering with each
other's virtual disks.

By default, every Proxmox cluster connected to a pool sees *all* the volumes in
that pool. Two clusters that both have a VM 100 would each create a volume
called `vm-100-disk-0`, and each cluster would then see the other's disk as a
stray, unrecognised volume — with a real risk that deleting a VM on one cluster
removes a disk belonging to the other. `cluster_prefix` solves this by giving
each cluster its own private namespace inside the shared pool.

---

## What it does

When you set `cluster_prefix pveA` on a storage, the plugin quietly prepends
`pveA_` to every volume name it creates on JovianDSS, and hides any volume that
does **not** carry that prefix.

| | Without `cluster_prefix` | With `cluster_prefix pveA` |
|---|---|---|
| Name shown in Proxmox | `vm-100-disk-0` | `vm-100-disk-0` (unchanged) |
| Name stored on JovianDSS | `v_vm-100-disk-0` | `v_pveA_vm-100-disk-0` |
| Volumes visible to this storage | all volumes in the pool | only volumes starting with `pveA_` |

The prefix is completely invisible inside Proxmox — it never appears in the web
UI, in `qm`/`pct` config, or in volume IDs like `jdss-Pool-0:vm-100-disk-0`. It
only exists in the volume names on the JovianDSS side, where it keeps each
cluster's data in its own lane.

---

## ⚠️ Important: each cluster also needs its own `target_prefix`

`cluster_prefix` isolates **volume names**. It does **not**, on its own, isolate
the **iSCSI targets** used to attach those volumes.

iSCSI target names are built from the VM ID only:

```
<target_prefix>:vm-<vmid>-<index>
```

The cluster prefix is *not* part of the target name. So if two clusters share a
pool, both have a VM 100, and both use the **same** `target_prefix`, they will
both try to create and manage the **same** target IQN
(`iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0`). They will fight over that
target — attaching each other's LUNs, tearing down each other's targets, and
producing intermittent attach failures.

**Therefore, when multiple clusters share one pool, you must give each cluster
both a unique `cluster_prefix` *and* a unique `target_prefix`.**

The rule is really per **storage**, not just per cluster: the iSCSI initiator
on a node tracks targets by IQN alone, so *any* two joviandss storages that
build the same target name — two storages of the same pool inside one cluster
(for example a plain and a `cluster_prefix` storage during a transition, with
a VM keeping disks on both), or even storages of two different arrays
configured with the same `target_prefix` — would end up sharing one target on
the node. The plugin enforces this rule: a storage **refuses to attach a
volume to a target that another storage already uses on the node**, with an
error naming both storages ("Different storages MUST use different
target_prefix values"). For records that already exist (created before the
enforcement), teardown stays safe — a storage never logs out a target while
another storage still has volumes on it, and the last storage to release the
target cleans up all sessions. **Give every joviandss storage its own
`target_prefix`.**

| Setting | Isolates | Required for shared pool? |
|---|---|---|
| `cluster_prefix` | Volume names (what each cluster can see) | **Yes** |
| `target_prefix` | iSCSI target IQNs | **Yes** |

A simple, readable convention is to embed the cluster identifier in both:

```
cluster_prefix  pveA
target_prefix   iqn.2025-04.proxmox.joviandss.pvea:
```

---

## Requirements and constraints

- **Plugin version:** Open-E JovianDSS Proxmox plugin with `cluster_prefix`
  support (v0.11.5 or later).
- **Allowed characters:** the prefix must start with a letter and contain only
  letters and digits — no `_`, no `-`, no dots.
  - Valid: `pveA`, `cluster01`, `prod`, `siteB`
  - Invalid: `pve-a` (hyphen), `cluster_01` (underscore), `01cluster` (starts
    with a digit)
- **Keep it short.** The prefix is added to every volume name; a short tag such
  as `pveA` or `s1` is plenty.
- **It is fixed (immutable).** `cluster_prefix` can only be set when the storage
  is **created**. It cannot be changed afterwards — see
  [Changing or removing the prefix](#changing-or-removing-the-prefix).

---

## Configuring a single storage

Set `cluster_prefix` when you add the storage:

```bash
pvesm add joviandss jdss-Pool-0 \
    --pool_name Pool-0 \
    --user_name admin \
    --user_password <rest-api-password> \
    --control_addresses 192.168.28.100 \
    --data_addresses 192.168.29.100 \
    --cluster_prefix pveA \
    --shared 1
```

The resulting `/etc/pve/storage.cfg` entry:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        cluster_prefix pveA
        control_addresses 192.168.28.100
        data_addresses 192.168.29.100
        shared 1
        ...
```

From this point on, this storage only ever sees volumes whose JovianDSS names
start with `pveA_`, and every disk it creates gets that prefix automatically.

> **Note:** because `cluster_prefix` is a fixed property, it must be present in
> the very first `pvesm add` command. You cannot add it later with `pvesm set`.

---

## Sharing one pool between two clusters — worked example

Two clusters, **Cluster A** and **Cluster B**, both use the JovianDSS pool
`Pool-0`. Each is given a unique cluster prefix and a unique target prefix.

**On Cluster A:**

```bash
pvesm add joviandss jdss-Pool-0 \
    --pool_name Pool-0 \
    --user_name admin \
    --user_password <rest-api-password> \
    --control_addresses 192.168.28.100 \
    --data_addresses 192.168.29.100 \
    --cluster_prefix pveA \
    --target_prefix iqn.2025-04.proxmox.joviandss.pvea: \
    --shared 1
```

**On Cluster B:**

```bash
pvesm add joviandss jdss-Pool-0 \
    --pool_name Pool-0 \
    --user_name admin \
    --user_password <rest-api-password> \
    --control_addresses 192.168.28.100 \
    --data_addresses 192.168.29.100 \
    --cluster_prefix pveB \
    --target_prefix iqn.2025-04.proxmox.joviandss.pveb: \
    --shared 1
```

Now suppose each cluster creates a VM 100 with one disk, and Cluster B also has
a VM 200. On JovianDSS the pool contains:

```
v_pveA_vm-100-disk-0     ← Cluster A, VM 100   (target iqn...pvea:vm-100-0)
v_pveB_vm-100-disk-0     ← Cluster B, VM 100   (target iqn...pveb:vm-100-0)
v_pveB_vm-200-disk-0     ← Cluster B, VM 200   (target iqn...pveb:vm-200-0)
```

- Cluster A's storage lists **only** `vm-100-disk-0`.
- Cluster B's storage lists **only** `vm-100-disk-0` and `vm-200-disk-0`.
- The two `vm-100` disks never collide: different volume names *and* different
  target IQNs.

Neither cluster can see, attach, or delete the other's volumes.

---

## Verifying it works

List what the storage sees from each cluster:

```bash
pvesm list jdss-Pool-0
```

You should see only this cluster's own disks, with normal unprefixed names
(`jdss-Pool-0:vm-100-disk-0`).

To confirm the prefix is being applied on the storage side, inspect the volume
names on JovianDSS (web UI → the pool's volumes, or the JovianDSS CLI). Every
volume created by Cluster A should be named `v_pveA_...`, and by Cluster B
`v_pveB_...`.

To confirm targets are isolated, check the target IQNs on JovianDSS — they
should carry each cluster's `target_prefix`.

---

## Important notes and caveats

### Changing or removing the prefix

`cluster_prefix` is **fixed**: it cannot be changed or removed on a storage that
already exists. Changing it would instantly hide every volume created under the
old prefix (the storage would no longer recognise them), leaving them orphaned
on JovianDSS.

If you must change it:

1. Migrate or back up all VMs/CTs off the storage.
2. Remove the storage definition (`pvesm remove jdss-Pool-0`) — this does *not*
   delete the data on JovianDSS, only the Proxmox configuration.
3. Re-create it with the new prefix.

(Renaming the underlying volumes on JovianDSS to match a new prefix is also
possible but is a manual, advanced operation.)

### Existing (unprefixed) volumes become invisible

If you add `cluster_prefix` to a pool that already contains volumes created
**without** a prefix, those legacy volumes (`v_vm-...`) will no longer be
visible to the prefixed storage, because their names don't start with the
prefix. Plan the prefix before putting data in a shared pool, or migrate legacy
volumes first.

### This is not an access-control / security boundary

`cluster_prefix` prevents *accidental* cross-cluster interference; it is not a
security feature. Any cluster with the JovianDSS REST credentials and a matching
configuration could still reach the data. For network-level protection of the
iSCSI traffic, use [CHAP authentication](CHAP-Authentication.md).

### One prefix per cluster

Use the **same** `cluster_prefix` on every node of a single cluster (it lives in
`storage.cfg`, which Proxmox replicates across the cluster automatically, so this
happens naturally). Use a **different** prefix on each separate cluster.

---

## Troubleshooting

**A cluster sees no volumes after enabling `cluster_prefix`**

The pool's existing volumes were created without the prefix, so they don't match.
This is expected — see *Existing (unprefixed) volumes become invisible* above.
Newly created disks will appear normally.

**Intermittent iSCSI attach failures / a VM disk attaches on the wrong cluster**

The two clusters are sharing the same `target_prefix`. Give each cluster a unique
`target_prefix` (see [the warning above](#️-important-each-cluster-also-needs-its-own-target_prefix)).
Because `target_prefix` is editable, you can correct it with `pvesm set`, but
existing targets created under the old prefix should be torn down first by
stopping the affected VMs.

**`pvesm set jdss-Pool-0 --cluster_prefix ...` is rejected**

`cluster_prefix` is fixed and cannot be changed on an existing storage. Re-create
the storage definition with the desired prefix (see *Changing or removing the
prefix*).

---

## See also

- [CHAP Authentication](CHAP-Authentication.md) — securing the iSCSI transport
- [Plugin configuration](Plugin-configuration.md) — full property reference
- `docs/design/cluster-prefix-design.md` — internal design and implementation
  details (for developers)
