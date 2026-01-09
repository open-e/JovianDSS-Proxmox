# Understanding Volume and Snapshot Names in JovianDSS Proxmox Plugin

This guide explains how your VM disks and snapshots get their names when using the JovianDSS Proxmox plugin. Understanding this helps you manage your storage more effectively and avoid common naming issues.

## The Big Picture

When you create a VM disk in Proxmox, two things happen behind the scenes:
1. **Proxmox** sees a disk with a name like `vm-100-disk-0`
2. **JovianDSS** stores it with a name like `v_vm-100-disk-0`

The plugin acts as a translator between these two systems, making sure they can work together seamlessly.

## How Proxmox Names Your Disks

Proxmox follows a simple, predictable pattern for naming VM disks:

**For regular VMs:**
- First disk: `vm-100-disk-0`
- Second disk: `vm-100-disk-1`
- Third disk: `vm-100-disk-2`

**For VM templates:**
- Template disks get a "base-" prefix: `base-100-disk-0`

The number "100" in these examples is the VM ID - a unique number Proxmox assigns to each virtual machine. Your VMs might have different numbers like 101, 102, 200, etc.

**Complete disk names in Proxmox:**
When you see disks in the Proxmox interface, they appear with the storage name first:
- `local:vm-100-disk-0` (disk on "local" storage)
- `jdss-storage:vm-101-disk-1` (disk on JovianDSS storage)

## JovianDSS Volume Naming Rules

JovianDSS has strict rules about what characters can be used in volume names. Understanding these rules helps explain why the plugin sometimes creates different types of names.

### JovianDSS Character Limitations
JovianDSS volumes can only contain these characters:
- **Letters:** a-z, A-Z (both uppercase and lowercase)
- **Numbers:** 0-9
- **Special characters:** Only underscore (_) and dash (-)
- **Maximum length:** 256 characters total

**Important:** JovianDSS cannot use periods, spaces, slashes, or any other special symbols in volume names.

## How the Plugin Handles Different Volume Names

The plugin automatically chooses the right naming strategy based on what characters are in the volume name Proxmox requests.

### Simple Names with Standard Prefix (v_)
When Proxmox requests a volume name that only contains allowed characters, the plugin adds a simple `v_` prefix.

**What qualifies as a simple name:**
- Only letters (a-z, A-Z)
- Only numbers (0-9)
- Only underscores (_) and dashes (-)
- No spaces, periods, or other special characters

**Examples:**
- Proxmox requests: `vm-100-disk-0`
- JovianDSS creates: `v_vm-100-disk-0`

- Proxmox requests: `backup-server-001`
- JovianDSS creates: `v_backup-server-001`

- Proxmox requests: `web_server_disk_1`
- JovianDSS creates: `v_web_server_disk_1`

The `v_` prefix tells JovianDSS "this is a volume managed by the Proxmox plugin."

### Complex Names with Human-Friendly Prefix (vh_)
When Proxmox requests a volume name that contains characters JovianDSS doesn't support, the plugin creates a human-friendly name to make it compatible.

**What triggers human-friendly naming:**
- Periods (.) - common in file extensions like `.raw`, `.qcow2`
- Spaces - like `my disk name`
- Slashes (/ or \) - from path-like names
- Special symbols - @, #, $, %, etc.
- Any character not in the allowed set

**How human-friendly naming works:**
1. The plugin takes the original name from Proxmox
2. Creates a sanitized version by replacing problematic characters with underscores
3. Converts the entire original name using Base32 encoding
4. Combines them in the format: `vh_{sanitized}_{base32-encoded}`

**Base32 encoding explained:**
Base32 encoding converts any text into a format that only uses letters A-Z and numbers 2-7. This ensures the name will be compatible with JovianDSS, no matter what special characters were in the original name.

**Examples:**
- Proxmox requests: `vm-100-disk-0.raw`
- JovianDSS creates: `vh_vm-100-disk-0_raw_MFRGG33VOQZEI3LMNRXW45BAN5XG63BBON2GKIDUN4QG2ZLHMU`

- Proxmox requests: `my server disk`
- JovianDSS creates: `vh_my_server_disk_NVQW4Y3PNUQGI33NMVRXK43UOJUW4ZZ7`

- Proxmox requests: `backup/vm-100/disk-0`
- JovianDSS creates: `vh_backup_vm-100_disk-0_MFRGG23VOQZQ2ZLHMU2G65DJORSXG5DTORUW2ZLTORQW45BBON2GKIDUN4`

**Important notes about human-friendly names:**
- They become much longer than the original name
- The sanitized portion keeps them human-readable
- The Base32 portion ensures the complete original name is preserved
- The volume works exactly the same as a simple-named volume
- You can still manage them normally through Proxmox

### Backup and Clone Names
Whether a backup or clone gets a simple `v_` or hash-based `vh_` prefix depends on the name Proxmox uses:

**Simple backup names:**
- Original: `v_vm-100-disk-0`
- Backup: `v_backup-vm-100-disk-1`

**Complex backup names:**
- Original: `vh_vm-100-disk-0_raw_<base32-encoded>`
- Backup: `vh_backup_vm-100-disk-1_raw_<base32-encoded>`

## Understanding Special Naming Cases

The plugin handles some complex scenarios where the usual naming rules have important exceptions. These cases help distinguish between different types of operations.

## Physical Snapshots with `s_` Names and Export Clones with `se_` Names

The plugin creates two different types of snapshots with different naming patterns.

### True ZFS Snapshots (`s_` prefix)
When you create a snapshot in Proxmox, the plugin creates a real ZFS snapshot with an `s_` prefix:

**How `s_` snapshot names are formed:**
```
s_{snapshot_name}
```

**Examples:**
- Proxmox snapshot: "before-update"
- JovianDSS physical snapshot: `s_before-update`

- Proxmox snapshot: "daily-backup-2024"  
- JovianDSS physical snapshot: `s_daily-backup-2024`

These are **true ZFS snapshots** - read-only point-in-time references that don't take additional space.

### Snapshot Extended Clones (`se_` prefix)
When you need to **attach** a snapshot in Proxmox (to browse its contents or mount it), the plugin creates a temporary clone volume with an `se_` prefix:

**How `se_` clone names are formed:**
```
se_{snapshot_name}_{base32-encoded-volume-reference}
```

**Examples:**
- Attaching snapshot "before-update" from volume `vm-100-disk-0`
- Creates export clone: `se_before-update_{base32-encoded-vm-100-disk-0}`

- Attaching snapshot "daily-backup" from complex volume name
- Creates export clone: `se_daily-backup_{base32-encoded-volume-info}`


## When Snapshots Get Names Starting with `v_`

Snapshots get a `v_` prefix when they are actually **volume clones** that Proxmox treats as snapshots, but JovianDSS stores as independent volumes.

### Volume Clone Scenarios
This happens in specific situations:

1. **Cloning from snapshots** - When you create a new VM from a snapshot
2. **Template operations** - When working with VM templates

### How `v_` Snapshot Names Work
Even though Proxmox calls them "snapshots," JovianDSS treats them as full volumes because they:
- **Are writable** (unlike true snapshots)
- **Can be independently managed**
- **Don't depend on the original volume**
- **Use separate storage space**

**Examples:**
- Create VM from template snapshot → gets `v_vm-101-disk-0` (new volume)
- Clone volume from snapshot → gets `v_clone-vm-100-disk-1` (independent volume)

### The Distinction
- **True snapshots** (`s_` prefix): Temporary, read-only access to snapshot data
- **Volume clones** (`v_` prefix): Permanent, writable volumes created from snapshots

**Key differences:**
| Feature | `s_` Snapshot Clones | `v_` Volume Clones |
|---------|---------------------|-------------------|
| Purpose | Temporary snapshot access | Permanent new volume |
| Writable | Read-only | Fully writable |
| Lifetime | Until detached | Until manually deleted |
| Storage | Shared with original | Independent space |
| Management | Automatic | Manual |

## Quick Reference: Name Types

Now that you understand the detailed naming rules, here's a quick reference for the different types of names you might see:

### Volume Name Types
- **Simple volumes:** `v_vm-100-disk-0` (clean names with allowed characters)
- **Human-friendly volumes:** `vh_vm-100-disk-0_raw_MFRGG33VOQZEI3LMNR...` (names with unsupported characters)
- **True ZFS snapshots:** `s_before-update` (permanent, read-only snapshots)
- **Snapshot export clones:** `se_before-update_{base32-encoded}` (temporary volumes for snapshot access)
- **Volume clones from snapshots:** `v_vm-200-disk-0` (permanent volumes created from snapshots)

### How to Identify Each Type
- **Starts with v_:** Standard volume OR permanent volume clone from snapshot
- **Starts with vh_:** Human-friendly volume name (original had special characters)
- **Starts with s_:** True ZFS snapshot (permanent, read-only)
- **Starts with se_:** Temporary clone created for snapshot export/attachment

### Quick Decision Guide
**If you see `v_` or `vh_`:** This is a regular volume that you can manage normally
**If you see `s_`:** This is a permanent ZFS snapshot - manage through Proxmox snapshot interface
**If you see `se_`:** This is a temporary snapshot access clone - don't delete it manually!

## Key Points to Remember

### To Get Simple, Clean Names (v_ prefix)
Stick to these characters in your VM and disk names:
- **Letters:** A-Z, a-z
- **Numbers:** 0-9
- **Dashes:** -
- **Underscores:** _

### What Causes Human-Friendly Names (vh_ prefix)
These characters will trigger human-friendly naming:
- Periods (.) - common in file extensions
- Spaces - in names like "my disk"
- Slashes (/ or \) - from path-like names
- Special symbols like @#$%^&*()

### Length Limits
- **JovianDSS maximum:** 256 characters total
- **Recommendation:** Keep original names under 200 characters
- **Human-friendly names:** Can become 2-3 times longer than the original

### Reserved Prefixes
Never manually create volumes starting with:
- `v_` or `vh_` (managed by plugin for regular volumes)
- `s_` (managed by plugin for snapshot clones)
- `t_` (used for temporary operations)
