# Cluster Prefix — Sharing One JovianDSS Pool Across Multiple Clusters

`cluster_prefix` lets several independent Proxmox VE clusters use the **same
JovianDSS pool** at the same time without seeing or interfering with each
other's virtual disks. Without it, every cluster sees *all* volumes in the
pool, and two clusters that both have a VM 100 collide on the same volume name
— with a real risk of one cluster deleting the other's disk. `cluster_prefix`
gives each cluster its own namespace inside the shared pool.

---

## What it does

When you set `cluster_prefix pveA` on a storage, the plugin prepends `pveA_` to
every volume name it creates on JovianDSS, and hides any volume that does
**not** carry that prefix.

| | Without `cluster_prefix` | With `cluster_prefix pveA` |
|---|---|---|
| Name shown in Proxmox | `vm-100-disk-0` | `vm-100-disk-0` (unchanged) |
| Name stored on JovianDSS | `v_vm-100-disk-0` | `v_pveA_vm-100-disk-0` |
| Volumes visible to this storage | all volumes in the pool | only volumes starting with `pveA_` |

The prefix exists only in the JovianDSS-side volume names — it never appears in
the Proxmox web UI, guest configs, or volume IDs.

---

## Important: each cluster also needs its own `target_prefix`

`cluster_prefix` isolates **volume names**. It does **not**, on its own,
isolate the **iSCSI targets** used to attach those volumes. Target names are
built from the VM ID only:

```
<target_prefix>:vm-<vmid>-<index>
```

So if two clusters share a pool, both have a VM 100, and both use the same
`target_prefix`, they will fight over the same target IQN — attaching each
other's LUNs, tearing down each other's targets, and producing intermittent
attach failures.

**Therefore, when multiple clusters share one pool, you must give each cluster
both a unique `cluster_prefix` *and* a unique `target_prefix`.**

Unlike `cluster_prefix`, `target_prefix` is editable: if two clusters are
already colliding, correct it with `pvesm set` after stopping the affected VMs,
so targets created under the old prefix are torn down.

---

## Requirements and constraints

- **Plugin version:** v0.11.5 or later.
- **Allowed characters:** must start with a letter and contain only letters and
  digits — no `_`, `-`, or dots. Valid: `pveA`, `cluster01`; invalid: `pve-a`,
  `cluster_01`, `01cluster`.
- **Keep it short.** The prefix is added to every volume name; a short tag such
  as `pveA` is plenty.
- **It is fixed (immutable).** `cluster_prefix` can only be set when the
  storage is **created** — it must be present in the very first `pvesm add` and
  cannot be changed afterwards; see
  [Changing or removing the prefix](#changing-or-removing-the-prefix).
- **One prefix per cluster.** All nodes of a cluster share it automatically (it
  lives in `storage.cfg`, which Proxmox replicates); each separate cluster
  needs its own.

---

## Sharing one pool between two clusters — worked example

Two clusters, **Cluster A** and **Cluster B**, both use the JovianDSS pool
`Pool-0`, each with a unique cluster prefix and target prefix.

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

**On Cluster B**, run the same command with `--cluster_prefix pveB` and
`--target_prefix iqn.2025-04.proxmox.joviandss.pveb:`.

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

**To verify:** `pvesm list jdss-Pool-0` on each cluster shows only that
cluster's own disks, under normal unprefixed names. On JovianDSS, volumes
appear as `v_pveA_...` / `v_pveB_...`, and target IQNs carry each cluster's
`target_prefix`.

---

## Important notes and caveats

### Changing or removing the prefix

`cluster_prefix` is **fixed**: it cannot be changed or removed on an existing
storage. Changing it would instantly hide every volume created under the old
prefix, leaving them orphaned on JovianDSS. If you must change it:

1. Migrate or back up all VMs/CTs off the storage.
2. Remove the storage definition (`pvesm remove jdss-Pool-0`) — this does *not*
   delete the data on JovianDSS, only the Proxmox configuration.
3. Re-create it with the new prefix.

(Renaming the underlying volumes on JovianDSS to match a new prefix is also
possible but is a manual, advanced operation.)

### Existing (unprefixed) volumes become invisible

If you add `cluster_prefix` to a pool that already contains volumes created
without a prefix, those legacy volumes (`v_vm-...`) no longer match and
disappear from the storage. Plan the prefix before putting data in a shared
pool, or migrate legacy volumes first.

### This is not an access-control / security boundary

`cluster_prefix` prevents *accidental* cross-cluster interference; it is not a
security feature. Any cluster with the JovianDSS REST credentials and a
matching configuration can still reach the data. For network-level protection
of the iSCSI traffic, use [CHAP authentication](CHAP-Authentication).

---

## See also

- [CHAP Authentication](CHAP-Authentication) — securing the iSCSI transport
- [Plugin configuration](Plugin-configuration) — full property reference
