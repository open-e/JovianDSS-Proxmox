# Snapshot Rollback and High Availability

This guide explains how the JovianDSS Proxmox plugin handles snapshot rollback operations, particularly when VMs or containers are managed by Proxmox High Availability (HA), and how to use the `force_rollback` feature for advanced rollback scenarios.

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

**Using the Web UI:**
1. Navigate to `Datacenter` → `HA` → `Resources`
2. Select the VM or container
3. Click `Edit`
4. Set `State` to `ignored`
5. Click `OK`

**Using the CLI:**
```bash
# For a VM
ha-manager set vm:100 --state ignored

# For a container
ha-manager set ct:100 --state ignored
```

#### Step 2: Stop the VM/Container

```bash
# For a VM
qm stop 100

# For a container
pct stop 100
```

#### Step 3: Perform the Rollback

**Using the Web UI:**
1. Select the VM/container
2. Go to `Snapshots`
3. Select the target snapshot
4. Click `Rollback`

**Using the CLI:**
```bash
# For a VM
qm rollback 100 snapshot_name

# For a container
pct rollback 100 snapshot_name
```

#### Step 4: Restore HA Management

After rollback completes, restore HA management:

```bash
# Restore to previous state (e.g., started)
ha-manager set vm:100 --state started
```

## Force Rollback for Unmanaged Snapshots

### Why Confirmation is Required

In Open-E JovianDSS, rollback is a destructive operation — all snapshots newer than the rollback target must be deleted. When these newer snapshots were created outside of Proxmox (by JovianDSS scheduled tasks, replication, or manual REST API calls), Proxmox has no record of them and cannot warn you about their removal.

To prevent accidental data loss, the plugin requires explicit confirmation before proceeding. This confirmation is given by adding the `force_rollback` tag to your VM or container.

### Adding the force_rollback Tag

**Web UI:**
1. Select the VM or container → `Options` → `Tags` → `Edit`
2. Add `force_rollback` and click `OK`

**CLI:**
```bash
qm set 100 --tags "force_rollback"    # VM
pct set 100 --tags "force_rollback"   # Container
```

Once the tag is set, stop the VM/container and perform rollback normally. The plugin will delete blocking unmanaged snapshots and proceed.

**Remove the tag after rollback** to prevent unintended forced rollbacks in the future.

### Limitations

The `force_rollback` tag only bypasses unmanaged snapshots. It will **not** bypass:
- Proxmox-managed snapshots (delete through Proxmox first)
- Dependent clones (remove clone volumes first)
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
│ Are blockers     │──Yes──▶ BLOCKED
│ managed by PVE   │         (delete via Proxmox)
│ or are clones?   │
└──────────────────┘
       │No (only unmanaged snapshots)
       ▼
┌──────────────────┐
│ Is force_rollback│──No──▶ BLOCKED
│    tag set?      │        (add tag to proceed)
└──────────────────┘
       │Yes
       ▼
┌──────────────────┐
│ DELETE unmanaged │
│ snapshots, then  │
│    ROLLBACK      │
└──────────────────┘
```

## Best Practices

### Before Rollback

1. **Check HA status** — Verify if the resource is HA-managed
2. **Review blocking resources** — Understand what's preventing rollback
3. **Back up critical data** — Rollback is destructive to newer states
4. **Plan for downtime** — VM/CT must be stopped during rollback

### For HA-Managed Resources

1. **Schedule maintenance windows** — Coordinate with HA policies
2. **Document the process** — Record original HA state before changes
3. **Test in non-production first** — Verify procedure on test VMs

### For force_rollback

1. **Use sparingly** — Only when automatic JovianDSS snapshots block operations
2. **Remove tag immediately after** — Prevents unintended forced rollbacks
3. **Verify snapshot necessity** — Ensure deleted snapshots are truly unneeded
4. **Consider JovianDSS snapshot policies** — Adjust automatic snapshot schedules if they frequently conflict

## Troubleshooting

### "Rollback blocked" but no blockers listed

This typically indicates an HA issue. Check:
```bash
ha-manager status
```

### force_rollback tag set but still blocked

The blockers include managed resources. Check the full error message for:
- Proxmox-managed snapshot names
- Clone volume names

### Rollback succeeds but VM won't start

After rollback:
1. Check VM configuration matches rollback state
2. Verify disk attachments are correct
3. Review `/var/log/joviandss/` for errors

## Related Documentation

- [Plugin Configuration](Plugin-configuration.md) — Storage pool settings
- [Volume and Snapshot Naming](Volume-and-Snapshot-Naming-Conventions.md) — Understanding snapshot names
- [Quick Start](Quick-Start.md) — Initial setup guide
