# Snapshot Rollback and High Availability

This guide explains how the JovianDSS Proxmox plugin handles snapshot rollback operations, particularly when VMs or containers are managed by Proxmox High Availability (HA), and how to use the `force-rollback` feature for advanced rollback scenarios.

## Overview

Snapshot rollback in Proxmox restores a VM or container disk to a previous point in time. However, rollback can be blocked by:

1. **Proxmox HA management** — HA-managed resources require special handling
2. **Newer snapshots** — ZFS requires deleting snapshots newer than the rollback target
3. **Dependent clones** — Volumes cloned from the target snapshot must be handled first

The JovianDSS plugin provides safeguards and workarounds for these scenarios.

## HA Rollback Protection

### Why Rollback is Blocked for HA Resources

When a VM or container is managed by Proxmox High Availability, the HA manager actively monitors and controls the resource's state. Performing a rollback on an HA-managed resource can cause conflicts:

- HA may attempt to restart the VM/CT during rollback
- HA may migrate the resource to another node mid-operation
- State inconsistencies can occur between HA expectations and actual resource state

To prevent these issues, the plugin blocks rollback for any resource with an active HA configuration unless the HA state is set to `ignored`.

### HA States and Rollback Behavior

| HA State | Rollback Allowed | Description |
|----------|------------------|-------------|
| `started` | No | HA actively keeps VM/CT running |
| `stopped` | No | HA actively keeps VM/CT stopped |
| `disabled` | No | HA resource defined but disabled |
| `ignored` | **Yes** | HA ignores this resource — manual control |
| (not defined) | **Yes** | Resource is not HA-managed |

### Error Message

When rollback is blocked due to HA, you will see:

```
Rollback blocked: vm:100 is controlled by High Availability (state: started).
Rollback requires temporary manual control to prevent HA from restarting or moving the resource.
Disable HA management before retrying:
Web UI: Datacenter -> HA -> Resources -> set state to ignored
CLI: ha-manager set vm:100 --state ignored
```

### How to Perform Rollback on HA-Managed Resources

#### Step 1: Set HA State to Ignored

Web UI: `Datacenter` → `HA` → `Resources` → select the VM/CT → `Edit` → set `State` to `ignored`.

CLI:
```bash
ha-manager set vm:100 --state ignored   # VM
ha-manager set ct:100 --state ignored   # Container
```

#### Step 2: Stop the VM/Container

```bash
qm stop 100    # VM
pct stop 100   # Container
```

#### Step 3: Perform the Rollback

Web UI: select the VM/CT → `Snapshots` → choose the target snapshot → `Rollback`.

CLI:
```bash
qm rollback 100 snapshot_name    # VM
pct rollback 100 snapshot_name   # Container
```

#### Step 4: Restore HA Management

After rollback completes, restore the previous HA state (e.g., `started`):

```bash
ha-manager set vm:100 --state started
```

## Force Rollback of Blocking Snapshots

### Why Confirmation is Required

In Open-E JovianDSS, rollback is a destructive operation — all snapshots newer than the rollback target must be deleted. Some of these snapshots may have been created outside of Proxmox (by JovianDSS scheduled tasks, replication, or manual REST API calls), so Proxmox cannot warn you about everything that will be destroyed.

To prevent accidental data loss, the plugin blocks such a rollback and lists every snapshot that would be deleted. You consent to the deletion by adding the `force-rollback` tag to the VM or container.

### Adding the force-rollback Tag

**Web UI:**
1. Select the VM or container → `Options` → `Tags` → `Edit`
2. Add `force-rollback` and click `OK`

**CLI:**
```bash
qm set 100 --tags "force-rollback"    # VM
pct set 100 --tags "force-rollback"   # Container
```

Once the tag is set, stop the VM/container and perform rollback normally. The plugin deletes all newer snapshots — Proxmox-managed and storage-side alike — removes deleted Proxmox snapshots from the guest configuration, and proceeds with the rollback.

**Remove the tag after rollback** to prevent unintended forced rollbacks in the future.

### Limitations

The `force-rollback` tag only consents to deleting snapshots. It will **not** bypass:
- Dependent clones (remove the clone volumes first)
- Blockers of unknown origin (inspect and remove them manually)
- HA management (set HA state to `ignored` first)

## Rollback Decision Flowchart

```
Rollback Request
       │
       ▼
┌──────────────────┐
│ Is VM/CT managed │──Yes──▶ Is HA state 'ignored'? ──No──▶ BLOCKED
│    by HA?        │                    │                  (set state to ignored)
└──────────────────┘                   Yes
       │No                              │
       ▼                                ▼
┌──────────────────┐         ┌──────────────────┐
│ Are there newer  │──No──▶  │    ROLLBACK      │
│   blockers?      │         │    PROCEEDS      │
└──────────────────┘         └──────────────────┘
       │Yes
       ▼
┌──────────────────┐
│ Dependent clones │──Yes──▶ BLOCKED
│ or blockers of   │         (remove manually)
│ unknown origin?  │
└──────────────────┘
       │No (only snapshots)
       ▼
┌──────────────────┐
│ Is force-rollback│──No──▶ BLOCKED
│    tag set?      │        (add tag to proceed)
└──────────────────┘
       │Yes
       ▼
┌──────────────────┐
│ DELETE newer     │
│ snapshots, then  │
│    ROLLBACK      │
└──────────────────┘
```

## Best Practices

- **Back up critical data first** — rollback destroys all newer snapshots and states.
- **Plan for downtime** — the VM/CT must be stopped during rollback.
- **For HA resources, record the original HA state** before setting it to `ignored`, and restore it afterwards.
- **Remove the `force-rollback` tag immediately after use** — a forgotten tag silently authorizes future destructive rollbacks.
- **Review JovianDSS snapshot schedules** if automatic snapshots frequently block rollbacks.

## Troubleshooting

### "Rollback blocked" but no blockers listed

This typically indicates an HA issue. Check:
```bash
ha-manager status
```

### force-rollback tag set but still blocked

The blockers include resources the tag cannot remove. Check the full error message for:
- Dependent clone volume names
- Blockers of unknown origin

### Rollback succeeds but VM won't start

After rollback:
1. Check VM configuration matches rollback state
2. Verify disk attachments are correct
3. Review `/var/log/joviandss/` for errors

## Related Documentation

- [Plugin Configuration](Plugin-configuration) — Storage pool settings
- [Quick Start (iSCSI)](Quick-Start-iSCSI) — Initial setup guide
