# JovianDSS Proxmox Plugin Project Status

This document tracks the implementation status of the JovianDSS Proxmox plugin as defined in spec.md.

## Repository Structure Status

### ✅ Core Plugin Implementation (iSCSI)
- [x] **OpenEJovianDSSPlugin.pm** - iSCSI-based storage plugin (version 0.10.14)
- [x] **OpenEJovianDSS/Common.pm** - Shared utility functions for REST API communication
- [x] **Installation script** - install.pl for automated installation
- [x] **Documentation** - Comprehensive documentation in docs/ folder
- [x] **Testing infrastructure** - Test files and configurations

### ✅ NFS Plugin Implementation (v0.7.0 — Production-tested)

#### ✅ Initial Prototype Created (2025.01.09)
- [x] **OpenEJovianDSSNFSPlugin.pm** - NFS-based storage plugin (version 0.7.0)
  - [x] Basic plugin structure based on Proxmox NFSPlugin
  - [x] NFS mount/unmount functionality
  - [x] JovianDSS share creation/management via REST API
  - [x] ZFS snapshot support (create/delete/list/info)
  - [x] Password management hooks
  - [x] Configuration properties and options

#### ✅ Rollback Implementation Completed and Tested (2025.01.09)
- [x] **Design Decision:** Rollback uses clone-based approach
  - Clone snapshot → create temp NFS share → mount → copy files → cleanup
  - Mirrors iSCSI plugin's volume_activate/volume_deactivate pattern
  - Function naming: `nas_volume_activate` / `nas_volume_deactivate` (in NFSCommon.pm)
- [x] **REST API Path Corrections** - Fixed to use `nas-volumes` instead of `volume`
  - Snapshot create/delete/list now use correct API endpoints
  - Matches JovianDSS REST API v4 specification
- [x] **End-to-end rollback tested** on pve-91-1 cluster (2026.02.26)
  - Full test: alloc → write data → snapshot → overwrite → rollback → verify ✅

#### ✅ jdssc CLI Tool - NAS Volume Snapshot & Clone Support (2025.01.09)
**Implemented complete snapshot functionality for NAS volumes**

Implemented REST API functions in `jdssc/jovian_common/rest.py`:
- [x] **`create_nas_snapshot`** - Create snapshot for NAS volume
  - REST API: `POST /pools/{pool}/nas-volumes/{dataset}/snapshots`
  - Body: `{"name": "snapshot_name"}`
- [x] **`delete_nas_snapshot`** - Delete NAS volume snapshot
  - REST API: `DELETE /pools/{pool}/nas-volumes/{dataset}/snapshots/{snap}`
- [x] **`get_nas_snapshot`** - Get specific snapshot info
  - REST API: `GET /pools/{pool}/nas-volumes/{dataset}/snapshots/{snap}`
- [x] **`get_nas_snapshots`** - List all snapshots for NAS volume
  - REST API: `GET /pools/{pool}/nas-volumes/{dataset}/snapshots`
- [x] **`create_nas_clone`** - Create clone from snapshot
  - REST API: `POST /pools/{pool}/nas-volumes/{dataset}/snapshots/{snap}/clones`
  - Body: `{"name": "clone_name", ...}` with optional ZFS properties
- [x] **`delete_nas_clone`** - Delete clone
  - REST API: `DELETE /pools/{pool}/nas-volumes/{dataset}/snapshots/{snap}/clones/{clone}`
- [x] **`get_nas_clones`** - List clones for snapshot
  - REST API: `GET /pools/{pool}/nas-volumes/{dataset}/snapshots/{snap}/clones`

Implemented CLI commands:
- [x] **`jdssc/jdssc/nas_snapshots.py`** - Plural operations
  - `create` - Create new snapshot
  - `list` - List all snapshots
- [x] **`jdssc/jdssc/nas_snapshot.py`** - Singular operations
  - `delete` - Delete snapshot
  - `get` - Get snapshot info
  - `clones create` - Create clone from snapshot
  - `clones delete` - Delete clone
  - `clones list` - List all clones
- [x] **Updated `jdssc/jdssc/nasvolume.py`** - Added snapshot/snapshots subcommands

CLI Usage Examples:
```bash
# Create snapshot
jdssc pool Pool-0 nas_volumes Dataset-0 snapshots create snap1

# List snapshots
jdssc pool Pool-0 nas_volumes Dataset-0 snapshots list

# Delete snapshot
jdssc pool Pool-0 nas_volumes Dataset-0 snapshot snap1 delete

# Create clone from snapshot
jdssc pool Pool-0 nas_volumes Dataset-0 snapshot snap1 clones create clone1

# List clones
jdssc pool Pool-0 nas_volumes Dataset-0 snapshot snap1 clones list

# Delete clone
jdssc pool Pool-0 nas_volumes Dataset-0 snapshot snap1 clones delete clone1
```

#### ✅ Core Implementation Complete

- [x] **nas_volume_activate** in NFSCommon.pm - Activate snapshot via clone
- [x] **nas_volume_deactivate** in NFSCommon.pm - Cleanup activated snapshot
- [x] **snapshot_publish / snapshot_unpublish** - Full publish lifecycle
- [x] **snapshot_deactivate_unpublish** - Atomic deactivate + unpublish
- [x] **all_snapshots_deactivate_unpublish** - Bulk cleanup
- [x] **volume_snapshot_rollback** - File-based rollback (tested ✅)
- [x] **volume_rollback_is_possible** - Snapshot existence check (tested ✅)

#### 🔄 Pending Implementation

- [ ] **Clone operations** - Implement clone_image for VM cloning (volume_has_feature returns 0 for 'clone')
- [ ] **Testing** - Unit and integration tests (0%)
- [ ] **Documentation** - NFS plugin configuration guide (0%)
- [ ] **Installation integration** - Update install.pl to support NFS plugin (0%)
- [ ] **Minor cleanup** - Empty directories left after rollback in `private/mounts/{vmid}/` (cosmetic)

#### 📝 Architecture & Design Learnings (2025.01.09)

**System Architecture:**
- **JovianDSS**: ZFS storage with datasets, NFS shares pre-configured by administrator
- **Proxmox**: Mounts NFS shares from JovianDSS, accesses files over NFS protocol
- **Critical insight**: `.zfs/snapshot/` directory exists on JovianDSS filesystem, but is NOT automatically visible through NFS mounts

**Configuration Architecture (Updated 2025.01.12):**
- **Export path format**: `/Pools/<pool_name>/<dataset_name>` (e.g., `/Pools/Pool-2/test1`)
- **Parse at runtime**: `parse_export_path()` extracts pool and dataset for REST API calls
- **No share management**: NFS shares must be pre-configured on JovianDSS
- **Standard NFS mounting**: Uses standard Proxmox NFS mount operations
- **REST API usage**: Only for snapshot operations on dataset, not share management

**Snapshot Rollback Architecture:**
- Cannot use direct `.zfs/snapshot/<snapname>` access via NFS (not exposed)
- Must use **clone-based approach**:
  1. Create temporary clone of snapshot via REST API
  2. Create temporary NFS share pointing to clone
  3. Mount temp share on Proxmox
  4. Copy files from mounted clone to live storage
  5. Unmount and delete temp share and clone
- This mirrors the iSCSI plugin's `volume_activate` / `volume_deactivate` pattern

**JovianDSS REST API Terminology:**
- Datasets are called **"nas-volumes"** in the API
- REST API paths: `/pools/{pool}/nas-volumes/{dataset}/snapshots/{snap}/clones`
- Function naming should match API resources: `nas_volume_activate` not `nfs_volume_activate`
- NFS is the protocol, nas-volumes is the resource type

**jdssc CLI Tool Architecture:**
- Located at: `/usr/local/bin/jdssc` (Python tool)
- Structure: `Common.pm` → calls `joviandss_cmd()` → executes `/usr/local/bin/jdssc` → wraps REST API
- Command format: `jdssc [connection-options] [command] [args]`
- Connection options include: `--control-addresses`, `--user-name`, `--ssl-cert-verify`, etc.
- Example: `jdssc --control-addresses 192.168.1.1 pool Pool-0 nas-volumes Dataset-0 snapshots create snap1`

**Code Architecture Pattern:**
- **Helper functions** (like `volume_publish`, `nas_volume_activate`) build command arrays
- **All REST API calls** go through `joviandss_cmd()` which calls jdssc CLI
- **Local operations** (iSCSI login, NFS mount) use `PVE::Tools::run_command()` directly
- **State tracking**: Volume activation creates local state files for cleanup
- **Error handling**: Use eval blocks, cleanup on error, return structured data

**Function Naming Convention:**
- Follow pattern: `<resource>_<action>` (e.g., `volume_activate`, `volume_publish`)
- iSCSI: `volume_activate($scfg, $storeid, $vmid, $volname, $snapname, $content_volume_flag)`
- NFS: `nas_volume_activate($scfg, $storeid, $dataset_path, $snapname)`
- Key difference: NFS works at dataset level (no VM ID needed), iSCSI works at volume level

**Proxmox Storage Plugin API Requirements:**
- Must implement: `volume_snapshot_rollback($class, $scfg, $storeid, $volname, $snap)` (fixed signature)
- Cannot change Proxmox API function names, only internal implementation
- Internally can call any helper functions needed

**jdssc CLI Implementation Pattern (Updated 2025.01.13):**
- **Layered architecture** (proper separation of concerns):
  - **CLI layer** (`nas_snapshot.py`, `nas_snapshots.py`, `nasvolume.py`, `nasvolumes.py`): User interface, argument parsing
  - **Driver layer** (`driver.py`): Business logic, name transformation via `jcom.vname()`/`jcom.sname()`
  - **REST API layer** (`rest.py`): HTTP requests, response handling
  - **Pattern**: CLI → Driver → REST API (never CLI → REST API directly)
- **Routing architecture** (`pool.py`):
  - Separate commands for singular vs plural operations
  - iSCSI: `volume` (singular) vs `volumes` (plural)
  - NAS: `nas_volume` (singular) vs `nas_volumes` (plural)
  - Collection operations: `jdssc pool X nas_volumes create|list`
  - Individual operations: `jdssc pool X nas_volume <name> snapshots|snapshot|get|delete`
- **File naming convention**: Use resource prefix to distinguish types
  - iSCSI volumes: `volume.py` / `volumes.py`, `snapshot.py` / `snapshots.py`
  - NAS volumes: `nasvolume.py` / `nasvolumes.py`, `nas_snapshot.py` / `nas_snapshots.py`
  - Pattern: `<resource_type>_<entity>.py` for resource-specific operations
- **Singular vs Plural files**:
  - Plural file (e.g., `nas_snapshots.py`): Operations on multiple items
    - `create` - Create new resource
    - `list` - List all resources
  - Singular file (e.g., `nas_snapshot.py`): Operations on single item
    - `delete` - Delete resource
    - `get` - Get resource info
    - `<subresource>` - Manage sub-resources (e.g., clones)
- **Driver methods** (in `driver.py`):
  - CLI calls: `self.jdss.create_nas_snapshot()` (driver method)
  - Driver calls: `self.ra.create_nas_snapshot()` (REST API method)
  - Driver handles name transformation: `jcom.vname(dataset)`, `jcom.sname(snapshot)`
  - Driver provides error handling and business logic
- **REST API wrapper functions** (in `rest.py`):
  - Follow pattern: `<verb>_nas_<resource>` (e.g., `create_nas_snapshot`)
  - Use `.get()` method for safe dictionary access to avoid KeyError
  - Return `resp.get("data")` for successful operations
  - Raise appropriate exceptions from `jdssc.jovian_common.exception`
- **CLI integration**:
  - Add subcommand to parent resource parser (e.g., in `nasvolume.py`)
  - Import and instantiate the command class
  - Pass `args`, `uargs`, and `jdss` context to command handler
- **Error handling pattern**:
  - Check HTTP response codes: `200, 201, 204` for success
  - Handle `500` errors with specific errno codes
  - Match error messages with regex patterns for specific exceptions
  - Log errors appropriately (INFO for operations, DEBUG for details, ERROR for failures)

**Perl Code Style Standards (2025.01.09):**
- **File size**: Keep under 1000 lines (NFS plugin: 634 lines ✓)
- **Indentation**: Use 4 spaces (no tabs)
- **Parameter unpacking**: Use spaces for consistency with iSCSI plugin
  - Standard: `my ( $class, $scfg, $storeid, $volname, $snap ) = @_;`
  - Note: NFS plugin currently uses `my ($class, ...)` - needs update
- **Line length**: Prefer 80 characters max (per statut-automatum)
- **String quoting**:
  - Double quotes for interpolation: `"${var}"`
  - Single quotes for literals: `'string'`
- **Error messages**: Always end with newline: `die "message\n";`
- **Hash formatting**: Use fat comma with spacing: `key => value`
- **Variable scoping**: Always use `my` for lexical variables
- **Error handling**: Use `eval { }` blocks with proper cleanup
- **Module structure**:
  - `use strict;` and `use warnings;` mandatory
  - Proper `package` declaration
  - Inherit via `use base qw(...)`
  - Export symbols via `qw(:all)` where needed
- **Security**:
  - Use array refs for shell commands (avoid interpolation)
  - Handle passwords via secure storage (Common module)
  - Taint mode compatible code
- **Code review findings**:
  - ✅ Syntax valid, structure correct
  - ✅ No security vulnerabilities
  - ✅ Good separation of concerns (SRP)
  - ⚠️ Minor: Parameter unpacking spacing inconsistent with iSCSI plugin
  - ⚠️ Minor: Some lines exceed 80 characters

#### ✅ Resolved Design Decisions (2025.01.12-13)

**Share Management:**
- ✅ **Resolved:** NFS shares are pre-configured by administrator on JovianDSS
- ✅ **Decision:** Plugin does NOT create/manage shares via REST API
- ✅ **Rationale:** Simpler architecture, follows standard Proxmox NFS pattern
- ✅ **Result:** Removed `ensure_joviandss_share()` and share management logic

**Configuration:**
- ✅ **Resolved:** Export path format defined as `/Pools/<pool_name>/<dataset_name>`
- ✅ **Decision:** Parse pool and dataset from export path at runtime
- ✅ **Result:** Single source of truth, no redundant configuration fields

**REST API Endpoints:**
- ✅ **Resolved:** Use `/pools/{pool}/nas-volumes/{dataset}/snapshots` for snapshot operations
- ✅ **Decision:** Dataset name only (not full path) in REST API calls
- ✅ **Example:** `jdssc pool Pool-2 nas_volume test1 snapshots create snap1`

**jdssc Routing:**
- ✅ **Resolved:** Separate singular vs plural commands
- ✅ **Decision:** `nas_volume` (singular) for individual ops, `nas_volumes` (plural) for collection ops
- ✅ **Result:** Architecture matches iSCSI pattern, clear separation of concerns

#### ❓ Remaining Design Questions

**Snapshot Scope:**
- **Question:** Should snapshots be per-VM or per-storage?
  - Current implementation: Per-storage (dataset-level)
  - **Impact:** All VMs on that storage share same snapshot namespace
  - **Alternative:** Use per-VM datasets with separate snapshots

**Multipath Support:**
- **Question:** Is multipath relevant for NFS?
  - Assumption: No (NFS handles failover differently than iSCSI)
  - **Question:** Should we support NFS with multiple IP addresses?

## Configuration Comparison

### iSCSI Plugin Configuration
```
pool_name, config, multipath, user_name, user_password, target_prefix,
luns_per_target, ssl_cert_verify, control_addresses, control_port,
data_addresses, data_port, block_size, thin_provisioning, debug, log_file
```

### NFS Plugin Configuration (Current)
```
server, export, path, user_name, user_password, control_addresses,
control_port, ssl_cert_verify, debug, log_file, (+ standard NFS options)
```

**Key Configuration Fields:**
- `server`: NFS server IP/hostname (e.g., "192.168.1.100")
- `export`: NFS export path (e.g., "/Pools/Pool-2/test1")
  - Format: `/Pools/<pool_name>/<dataset_name>`
  - Automatically parsed to extract pool and dataset for REST API calls
- `path`: Local mount point (e.g., "/mnt/pve/mystorage")

**Configuration Differences from iSCSI:**
- NFS adds: `server`, `export` (standard NFS fields)
- NFS removes: `pool_name`, `multipath`, `target_prefix`, `luns_per_target`, `data_addresses`, `data_port`, `block_size`, `thin_provisioning`
- **Simplified:** No separate `pool_name`, `share_name`, or `dataset_path` - all derived from `export`

## Feature Matrix

| Feature | iSCSI Plugin | NFS Plugin (Prototype) | Notes |
|---------|--------------|------------------------|-------|
| Block storage | ✅ | ❌ | NFS is file-based |
| File storage | ❌ | ✅ | NFS supports all content types |
| Volume snapshots | ✅ | ✅ | ZFS snapshots via REST API |
| Volume rollback | ✅ | ✅ | ZFS rollback via REST API |
| Volume cloning | ✅ | ❓ | Needs implementation |
| Thin provisioning | ✅ | N/A | File-based storage |
| Multipath | ✅ | ❓ | May not be applicable |
| iSCSI targets | ✅ | N/A | NFS uses shares |
| LUN management | ✅ | N/A | NFS doesn't use LUNs |
| Live migration | ✅ | ✅ | Should work with NFS |
| Content types | images, rootdir | images, rootdir, vztmpl, iso, backup, snippets, import | NFS supports more types |

## Dependencies Status

### ✅ Current Dependencies (Both Plugins)
- [x] **Perl** - Core language
- [x] **PVE::Storage** - Proxmox storage framework
- [x] **PVE::Tools** - Proxmox utilities
- [x] **REST client** - For JovianDSS API communication

### ✅ Additional NFS Dependencies
- [x] **NFS client tools** - mount.nfs, showmount, rpcinfo
- [x] **Net::IP** - IP address handling
- [x] **PVE::Network** - Network utilities

## Outstanding Issues & Questions

### Critical Questions for NFS Plugin
1. **API Endpoint Verification** - Are the REST API commands correct for share management?
2. **Dataset Path Structure** - What's the best practice for organizing NFS storage on JovianDSS?
3. **Snapshot Granularity** - Should snapshots be per-VM or per-storage?
4. **Permission Management** - How to handle NFS export permissions for Proxmox nodes?
5. **Share Creation** - Should shares be created automatically or require pre-configuration?

### Clarification Needed
- **Integration Testing** - How to test without physical JovianDSS instance?
- **Error Handling** - Are all JovianDSS REST API error cases handled?
- **Logging** - Should NFS plugin use separate log file or shared with iSCSI plugin?
- **Common.pm Extensions** - Which functions need to be added/modified?

## Next Steps Priority

### High Priority (Blocks usability)
1. **Verify REST API commands** - Test against actual JovianDSS instance
2. **Answer design questions** - Clarify dataset structure, snapshot scope, share lifecycle
3. **Test basic functionality** - Mount/unmount, snapshot create/delete/rollback
4. **Update Common.pm** - Add NFS-specific helper functions if needed

### Medium Priority (Enhances functionality)
1. **Implement clone_image** - ZFS clone support for NFS volumes
2. **Add comprehensive error handling** - Handle all REST API failure scenarios
3. **Write documentation** - Configuration guide for NFS plugin
4. **Update installation script** - Support NFS plugin installation

### Low Priority (Nice to have)
1. **Performance optimization** - Cache REST API results where appropriate
2. **Enhanced logging** - Detailed debug logs for troubleshooting
3. **Configuration validation** - Validate JovianDSS connectivity on storage add
4. **Automated testing** - Unit tests and integration test framework

## Implementation Notes

### NFS Plugin Architecture
The NFS plugin follows a hybrid design:
- **Storage Protocol:** Standard NFS (mount/unmount like Proxmox NFSPlugin)
- **Advanced Features:** ZFS snapshots/rollback via JovianDSS REST API
- **Base Class:** PVE::Storage::Plugin (like NFSPlugin, not DirPlugin)
- **Shared Code:** OpenEJovianDSS::Common for REST API communication

### Key Design Decisions
1. **Inherit from Plugin, not DirPlugin** - Provides more control over NFS-specific behavior
2. **Dataset-level snapshots** - Snapshots operate on the underlying ZFS dataset
3. **Auto-create shares** - Plugin creates NFS share on JovianDSS if it doesn't exist
4. **Reuse Common.pm** - Leverage existing REST API infrastructure from iSCSI plugin

### Code Style Compliance
- ✅ Follows PEP8-equivalent Perl style (per statut-automatum guidelines)
- ✅ Uses proper error handling with eval blocks
- ✅ Includes debugging messages via Common.pm
- ✅ Implements sensitive password handling
- ✅ Version tracking in comments

## Completion Status: 75%

### Overall Progress
- ✅ iSCSI Plugin: 100% (production-ready)
- ✅ NFS Plugin: 75% (core functionality production-tested)
  - ✅ Core structure: 100%
  - ✅ NFS mount/unmount: 100%
  - ✅ Snapshot operations: 100% (tested 2026.02.26)
  - ✅ Snapshot rollback: 100% (tested 2026.02.26)
  - ✅ Snapshot timestamp in info: 100% (tested 2026.02.26)
  - ✅ iSCSI force_rollback per-blocker deletion: 100% (2026.02.26)
  - ✅ iSCSI force_rollback config file cleanup: 100% (tested 2026.02.26)
  - ✅ iSCSI rollback error messages: 100% (tested 2026.02.26)
  - ❌ Clone operations (clone_image): 0%
  - ❌ Testing (unit/integration): 0%
  - ❌ Documentation: 0%
  - ❌ Installation integration: 0%
- ✅ Common infrastructure (NFSCommon.pm): 100%
- ✅ Installation tooling: 100% (for iSCSI, needs NFS updates)
- ✅ Documentation infrastructure: 100%

### Component Breakdown
- ✅ Plugin registration and configuration: 100%
- ✅ Storage activation/deactivation: 100%
- ✅ NFS mounting/unmounting: 100%
- ✅ Export path parsing: 100%
- ✅ Snapshot create/delete/list: 100% (tested ✅)
- ✅ Snapshot rollback: 100% (tested ✅)
- ✅ volume_rollback_is_possible: 100% (tested ✅)
- ✅ jdssc CLI NAS volumes: 100% (tested ✅)
- ✅ jdssc CLI publish/unpublish: 100% (tested ✅)
- ✅ NFSCommon.pm (activate/deactivate/publish): 100% (tested ✅)
- ✅ NFS snapshot timestamp in info: 100% (tested 2026.02.26)
- ✅ NFS snapshot naming (sv_ removed): 100% (tested 2026.02.26)
- ✅ iSCSI force_rollback per-blocker deletion: 100% (2026.02.26)
- ❌ Clone operations (clone_image): 0%
- ❌ Unit tests: 0%
- ❌ Integration tests: 0%
- ❌ User documentation: 0%

## Change Log

### 2026.02.26 - iSCSI Force-Rollback: config file editing + message fixes (tested ✅)

**`remove_vm_snapshot_config` — new function (`Common.pm`):**
- Replaces `qm delsnapshot` / `pct delsnapshot` external command calls.
- Directly edits `/etc/pve/qemu-server/<vmid>.conf` or
  `/etc/pve/lxc/<vmid>.conf` to remove the `[snapname]` section.
- Parser: reads file line by line; on encountering `[target]` header, sets
  `$skip=1` and pops trailing blank separator line(s) from output; other
  sections pass through unchanged.
- Idempotent: silently no-ops if the section is not found.
- Exported from `Common.pm`; `file_set_contents` added to PVE::Tools import.

**`volume_snapshot_rollback` — managed blocker path rewritten
(`OpenEJovianDSSPlugin.pm`):**
- Removed `run_command([qm/pct, 'delsnapshot', ...])` call.
- All blockers (managed and unmanaged) now use the same JovianDSS deletion
  path: `volume_deactivate` + `joviandss_cmd snapshot delete`.
- Managed blockers additionally call `remove_vm_snapshot_config` to clean
  the Proxmox config file.

**`format_rollback_block_reason` — full rewrite (`Common.pm`):**
- Replaced two ad-hoc "special case" early returns with three clean branches:
  1. `force_rollback=1`: shows only clones/unknown that need manual removal;
     managed/unmanaged snapshots not listed (auto-handled).
  2. No clones, no unknown (force_rollback=0): shows blocker list +
     `force_rollback` hint for ALL snapshot-only cases (managed, unmanaged,
     mixed) — previously only unmanaged-only got this hint.
  3. Clones or unknown present: "Rollback blocked. Remove these first." —
     no misleading force_rollback suggestion.
- Fixed old bug: unknown-only case previously showed a `force_rollback` hint
  even though `force_rollback` cannot handle unknown blockers.
- Removed stale "Rollback is possible to the latest Proxmox managed snapshot
  only" generic message (was misleading for clone cases).

**`volume_rollback_check` — dead variable removed (`Common.pm`):**
- `$managed_snapshot_blocker` was initialised to 0 and set to 0 again when
  a managed blocker was found; never set to 1, never read. Removed.

**Integration test — 16/16 passed on pve-91-1:**
- Config file manipulation: snap2 removed, snap1 preserved, no double blank
  lines, idempotent on missing snapshot.
- Error message (no force_rollback): "Rollback blocked by newer snapshots …
  Hint: add 'force_rollback' tag" — correct wording confirmed.
- Force rollback with managed blocker: data restored (md5 match), `[snap2]`
  removed from config, `[snap1]` preserved.

### 2026.02.26 - iSCSI Force-Rollback Enhancements (superseded above)

**Snapshot naming for NFS volumes (NFSCommon.pm):**
- Removed `sv_` prefix from internal snapshot names — was a redundant namespace
  marker; vmid is still present and sufficient for per-VM filtering.
- New format: `{vmid}_{snapname}` (e.g., `999_testsnap1`)
- `nas_sname()`, `nas_vmid_from_sname()`, `nas_snapid_from_sname()` updated;
  no backward-compatibility fallbacks (clean break).
- Tested on pve-91-1: full alloc → snapshot → rollback → verify cycle ✅

**Creation timestamp in NFS snapshot info:**
- `driver.py list_nas_snapshots()`: extracts integer Unix epoch from
  `properties.creation` in REST response (was already an integer, no parsing
  needed).
- `nas_snapshots.py list`: added `--creation` flag; outputs
  `{name} {epoch}` space-separated.
- `NFSCommon.pm snapshot_info()`: passes `--creation` to jdssc, parses two
  columns, stores result as `timestamp` (integer) in the returned hash.
- Live test confirmed: `{'testsnap1' => {'name' => 'testsnap1', 'timestamp' =>
  1772134706}}`

**iSCSI `volume_snapshot_rollback` — per-blocker deletion
(`OpenEJovianDSSPlugin.pm`):**
- Replaced `--force-snapshots` flag (bulk atomic) with explicit loop that
  deletes each blocker individually so different blocker types can be handled
  differently.
- For **Proxmox-managed** blockers: calls `qm delsnapshot` (qemu) or
  `pct delsnapshot` (lxc) — lets Proxmox handle full cleanup including disk
  snapshot deletion and VM config update.
- For **unmanaged/storage-side** blockers: keeps existing `volume_deactivate`
  + `joviandss_cmd snapshot delete` path.
- Virt type determined via `vmid_identify_virt_type()` (returns 'qemu'/'lxc').
- Managed snapshot set built from `snapshots_list_from_vmid()` at rollback time.

**`volume_rollback_check` — tracked snapshots no longer block force rollback
(`Common.pm`):**
- Commented-out `$force_rollback_possible = 0` for Proxmox-managed snapshot
  blockers (user change). Only clone and unknown blockers now prevent forced
  rollback.

**`format_rollback_block_reason` message fix (`Common.pm`):**
- Condition changed: `($has_managed || $has_clones)` → `$has_clones`.
- Updated message: "force_rollback handles managed snapshots automatically,
  but clones must be removed manually first" — accurately reflects new behavior.
- Removed managed-snapshot section from the force_rollback error path (they
  are auto-deleted now).

### 2026.02.26 - NFS Plugin Bug Fixes and Production Testing

**End-to-end rollback test passed on pve-91-1, pve-91-2, pve-91-3 cluster.**

**Bugs identified and fixed:**

1. **`properties()` duplicate registration** (`OpenEJovianDSSNFSPlugin.pm`):
   - Problem: Declaring JovianDSS-specific properties in `properties()` caused
     `duplicate property 'user_name'` at pvesm startup because the iSCSI plugin
     already registers them globally via `PVE::SectionConfig`.
   - Fix: Reverted `properties()` to `return {}` with explanatory comment.

2. **`data_addresses` removed from `options()`** (`OpenEJovianDSSNFSPlugin.pm`):
   - Problem: Removing `data_addresses` broke deployed storage.cfg files that
     already contained `data_addresses 192.168.28.102`.
   - Fix: Restored `data_addresses => { optional => 1 }` for backward compat.

3. **Wrong `joviandss_cmd` called in snapshot operations** (`OpenEJovianDSSNFSPlugin.pm`):
   - Problem: `volume_snapshot` and `volume_snapshot_delete` called
     `OpenEJovianDSS::Common::joviandss_cmd` directly. This bypasses the NFS
     password file (`/etc/pve/priv/storage/joviandss-nfs/<storeid>.pw`), causing
     `JovianDSS REST user password is not provided`.
   - Fix: Changed both calls to `OpenEJovianDSS::NFSCommon::joviandss_cmd`.

4. **Format-aware copy in rollback** (`OpenEJovianDSSNFSPlugin.pm`):
   - Problem: `dd oflag=direct` fails for qcow2 images (O_DIRECT incompatible
     with qcow2 metadata).
   - Fix: `volume_snapshot_rollback` now captures `$format` from `parse_volname`
     and uses `dd conv=sparse` for raw, `qemu-img convert` for other formats.

**Test sequence on pve-91-1 (all passed ✅):**
```
pvesm alloc jdss-nfs-Pool-2 999 vm-999-disk-0.raw 128M
# write known data (md5: 7c9aa...)
pvesm snapshots jdss-nfs-Pool-2 vm-999-disk-0.raw → [testsnap1]
# overwrite data with zeros
pvesm rollback jdss-nfs-Pool-2 vm-999-disk-0.raw testsnap1
# verify md5 restored ✅
pvesm delsnapshot jdss-nfs-Pool-2 vm-999-disk-0.raw testsnap1
pvesm free jdss-nfs-Pool-2 vm-999-disk-0.raw
```

**Minor known issue (cosmetic):**
- Empty directories `private/mounts/{vmid}/{volname}` left after rollback.
  `snapshot_deactivate` unmounts but does not remove the now-empty parent dirs.
  No functional impact; directories are empty.

### 2025.01.13 - NAS Snapshot Publish/Unpublish Architecture (Completed)

**Problem Identified**: Initial `nas_volume_activate()` implementation in Common.pm was generating clone names in Perl layer, which violates the architecture pattern where Python layer (jdssc) handles all naming conventions with base32 encoding.

**Solution Design**: Implement `publish`/`unpublish` commands for NAS snapshots, mirroring the iSCSI plugin's target publish pattern:

**Architectural Pattern**:
- **iSCSI**: `targets create` → Creates target + LUN, returns target info
- **NAS**: `snapshot publish` → Creates clone + share, returns clone dataset name

**Implementation Completed**:

1. **jdssc CLI Layer** (`nas_snapshot.py`):
   - ✅ Add `publish` action to action dictionary (line 34)
   - ✅ Add `unpublish` action to action dictionary (line 35)
   - ✅ Add `publish` parser (line 97)
   - ✅ Add `unpublish` parser (line 99)
   - ✅ Add `--publish-name` flag to `get` parser (lines 66-70)
   - ✅ Implement `publish()` method → calls `jdss.publish_nas_snapshot()` (lines 200-213)
   - ✅ Implement `unpublish()` method → calls `jdss.unpublish_nas_snapshot()` (lines 215-227)
   - ✅ Update `get()` method to handle `--publish-name` flag (lines 123-152)

2. **Driver Layer** (`driver.py`):
   - ✅ Implement `get_nas_snapshot_publish_name(dataset, snapshot)` (lines 1590-1603):
     - Returns clone name using `sname(snapshot, dataset)` without creating anything
     - Used to determine mount paths without state tracking
   - ✅ Implement `publish_nas_snapshot(dataset, snapshot)` (lines 1605-1639):
     - Generates proper clone name using `sname(snapshot, dataset)` from `jdss_common.py`
     - Creates clone via `ra.create_nas_clone()`
     - Creates NFS share for clone via `ra.create_share()`
     - Returns clone dataset name for mounting
   - ✅ Implement `unpublish_nas_snapshot(dataset, snapshot)` (lines 1641-1666):
     - Determines clone name using same `sname()` logic
     - Deletes NFS share via `ra.delete_share()`
     - Deletes clone via `ra.delete_nas_clone()`

3. **Common.pm Updates**:
   - ✅ Update `nas_volume_activate()` (lines 2549-2674):
     - Calls: `jdssc pool $pool nas_volume $dataset snapshot $snap publish`
     - Parses returned clone name from output
     - Mounts at: `$path/private/snapshots/$clone_name` (not /tmp)
     - Uses `get_path($scfg)` for storage path
     - **No local state tracking** - relies on `get --publish-name` for cleanup
   - ✅ Update `nas_volume_deactivate()` (lines 2678-2767):
     - Calls: `jdssc pool $pool nas_volume $dataset snapshot $snap get --publish-name` to get clone name
     - Constructs mount path: `$path/private/snapshots/$clone_name`
     - Unmounts from calculated path
     - Calls: `jdssc pool $pool nas_volume $dataset snapshot $snap unpublish`
     - **No local state tracking** - mount path determined on-demand
   - ✅ NFS plugin `volume_snapshot_rollback()` already uses activate/deactivate pattern (no changes needed)

**Clone Naming Convention** (handled by Python):
- Simple snapshot names (allowed chars): `se_{snapshot}_{base32_dataset}`
- Complex snapshot names: `sb_{base32_snapshot}_{base32_dataset}`
- Implementation: `jcom.sname(snapshot_name, dataset_name)` in driver.py
- Examples:
  - Snapshot "snap1" on dataset "test1": `se_snap1_MFRGG33VOQZEI3LMNR...`
  - Snapshot "before.update" on dataset "test1": `sb_{base32}_{base32}`

**Mount Location**:
- **Old (incorrect)**: `/tmp/joviandss_rollback_{timestamp}_{clone_name}`
- **New (correct)**: `$path/private/snapshots/{clone_name}`
- Where `$path` is storage configuration path (e.g., `/mnt/pve/joviandss-nfs`)

**Mount Path Determination**:
- Activation: Clone name returned by `publish` command
- Deactivation: Clone name queried via `get --publish-name` command
- No local state files needed - clone name computed deterministically using `sname()`
- Mount path constructed as: `$path/private/snapshots/{clone_name}`

**Benefits of This Architecture**:
1. **Single Source of Truth**: All naming logic in Python `jdss_common.py`
2. **Consistency**: NAS snapshots follow same naming as iSCSI snapshots
3. **Maintainability**: Changes to naming rules only affect Python layer
4. **Proper Mount Location**: Uses storage private area, not /tmp
5. **Clean Separation**: Perl handles mounting, Python handles ZFS operations
6. **Stateless**: No local state files needed - clone names computed deterministically on-demand

**Status**: ✅ Complete - All layers implemented and syntax validated

### 2025.01.13 - NFS Plugin Volume Activation/Deactivation (Completed)

**Objective**: Implement `activate_volume()` and `deactivate_volume()` methods in NFS plugin to handle storage mounting and cleanup of published snapshot clones.

**Implementation Completed**:

1. **Stateless Architecture Improvements**:
   - ✅ Removed all local state tracking from `nas_volume_activate()` and `nas_volume_deactivate()`
   - ✅ Changed `remove_tree()` to `rmdir()` for safer directory cleanup (lines 2642, 2739 in Common.pm)
   - ✅ Added `get --publish-name` to query clone names without creating resources

2. **Snapshots List Enhancement** (`nas_snapshots.py`):
   - ✅ Added `--with-clones` flag to `list` parser (lines 62-66)
   - ✅ Updated `list()` method to filter snapshots with clones (lines 91-116)
   - ✅ Usage: `pool $pool nas_volume $dataset snapshots list --with-clones`
   - ✅ Returns only snapshot names that have published clones

3. **NFS Plugin `activate_volume()`** (lines 437-461):
   - ✅ Checks that main NFS storage share is mounted
   - ✅ Uses `nfs_is_mounted()` to verify mount status
   - ✅ Dies with error if storage is not accessible
   - ✅ Simple validation - ensures storage is ready for use

4. **NFS Plugin `deactivate_volume()`** (lines 463-551):
   - ✅ Gets list of snapshots with clones: `snapshots list --with-clones`
   - ✅ For each snapshot with clones:
     - Gets clone name: `snapshot $snap get --publish-name`
     - Constructs mount path: `$path/private/snapshots/$clone_name`
     - Checks if mounted by reading `/proc/mounts`
     - If mounted, calls `nas_volume_deactivate()` to cleanup
   - ✅ Logs count of deactivated snapshot clones
   - ✅ Handles errors gracefully - continues processing remaining snapshots

**Workflow**:
- **Activate**: Verify main NFS share is mounted → ready for VM/container operations
- **Deactivate**: Find all published snapshot clones → check if mounted → unmount + unpublish

**Benefits**:
1. **Automatic Cleanup**: Deactivation cleans up all published snapshot clones automatically
2. **No State Files**: Completely stateless - queries current state on-demand
3. **Safe Directory Removal**: `rmdir()` only removes empty directories (fails safely if unmount failed)
4. **Efficient Query**: `--with-clones` flag avoids checking snapshots without clones
5. **Robust Error Handling**: Continues processing even if individual snapshot cleanup fails

**Status**: ✅ Complete - All methods implemented and tested for syntax

### 2025.01.14 - Direct Mode for NAS Volumes (Completed)

**Problem Identified**: Dataset names extracted from the NFS `export` property are the exact dataset names on JovianDSS, but jdssc CLI was applying naming transformations (via `vname()`) which is incorrect for NAS volumes that already have their real names.

**Key Discovery**:
- **Export property format**: `/Pools/<pool>/<dataset>` where `<dataset>` is the **exact name on JovianDSS**
- **Naming transformation**: jdssc `vname()` function adds prefixes for iSCSI volumes but should **not** be used for NAS volumes when the dataset name comes from the export property
- **Solution**: Use `-d` (direct mode) flag to bypass `vname()` transformation

**Architecture Rule**:
```
Dataset name source          | Use -d flag? | Reason
-----------------------------|--------------|------------------------------------------
From export property         | YES          | Already exact name on JovianDSS
From jdssc CLI output        | NO           | Already processed/formatted by jdssc
```

**Implementation Status**:

1. **Parser Support** (`nasvolume.py`):
   - ✅ `-d` flag already exists at nas_volume level (lines 45-49)
   - ✅ Flag name: `nas_volume_direct_mode`
   - ✅ Usage: `pool $pool nas_volume -d $dataset ...`

2. **New Function Created** (`Common.pm`):
   - ✅ Created `nas_volume_snapshots_info()` (lines 716-744)
   - ✅ Separate from `volume_snapshots_info()` (iSCSI version)
   - ✅ Uses `-d` flag: `pool $pool nas_volume -d $dataset snapshots list`
   - ✅ Returns hash: `{snapshot_name => {name => snapshot_name}}`
   - ✅ Exported from Common.pm (line 95)

3. **NFS Plugin Updates**:
   - ✅ `volume_snapshot()`: Added `-d` flag (line 317)
   - ✅ `volume_snapshot_info()`: Now calls `nas_volume_snapshots_info()` (line 325)
   - ✅ `volume_rollback_is_possible()`: Uses `nas_volume_snapshots_info()` (line 408)

4. **Completed Updates**:
   - ✅ Add `-d` to `deactivate_volume()` snapshots list call
   - ✅ Add `-d` to `deactivate_volume()` get --publish-name call
   - ✅ Add `-d` to `volume_snapshot_delete()` call
   - ✅ Add `-d` to `volume_snapshot_list()` call
   - ✅ Add `-d` to `nas_volume_activate()` and `nas_volume_deactivate()`

**Important Notes**:
- **Never mix direct/non-direct modes**: If dataset came from export property, always use `-d`
- **Clone names from jdssc**: When jdssc returns a clone name (e.g., from `publish` or `get --publish-name`), that name should NOT use `-d` because jdssc already formatted it
- **iSCSI compatibility**: `volume_snapshots_info()` unchanged - iSCSI plugin remains fully functional

**Files Modified**:
- `OpenEJovianDSS/Common.pm`: Added `nas_volume_snapshots_info()`, exported it
- `OpenEJovianDSSNFSPlugin.pm`: Updated snapshot-related methods to use new function and `-d` flag

**Status**: ✅ Complete - Direct mode used consistently for export-derived dataset names

**CLI Default**:
- `-d` (direct mode) defaults to `false` in jdssc NAS commands; callers
  must pass `-d` explicitly when dataset names come from export paths.

### 2025.01.13 - NAS Volume Rollback Implementation (Completed and Refactored)

**Initial Implementation** (completed earlier):
- ✅ Added `nas_volume_activate()` in Common.pm
- ✅ Added `nas_volume_deactivate()` in Common.pm
- ✅ Updated `volume_snapshot_rollback()` in NFS plugin
- ✅ Updated `volume_rollback_is_possible()` to use REST API
- ✅ Exported functions from Common.pm

**Issues Identified and Resolved**:
- ✅ **Fixed**: Clone naming now done in Python layer (not Perl)
- ✅ **Fixed**: Mounting to `$path/private/snapshots/` (not /tmp)
- ✅ **Resolution**: Implemented publish/unpublish architecture (see above)

### 2025.01.13 - jdssc CLI Routing Architecture Fix
- **Fixed** missing `list()` method in `nasvolumes.py`
  - Bug prevented any nas_volumes commands from initializing
  - Added REST API method: `get_nas_volumes()` in `rest.py`
  - Added driver method: `list_nas_volumes()` in `driver.py`
  - Added CLI method: `list()` in `nasvolumes.py`
  - Returns list of all NAS volumes (datasets) in pool
- **Fixed** routing architecture for singular vs plural operations
  - Added `nas_volume` (singular) command to `pool.py`
  - Separated: `nas_volumes` (plural) for collection ops, `nas_volume` (singular) for individual volume ops
  - Mirrors iSCSI pattern: `volumes` vs `volume`
  - Import added: `import jdssc.nasvolume as nasvolume` in `pool.py`
  - Parser added: `parsers.add_parser('nas_volume', add_help=False)`
  - Handler added: `def nasvolume(self): nasvolume.NASVolume(...)`
- **Refactored** `nasvolume.py` to handle only singular operations
  - Removed plural actions ('create', 'list') from routing
  - Class renamed: `NASVolumes` → `NASVolume`
  - Simplified parser: only handles individual volume operations (get, delete, snapshot, snapshots)
  - Removed conditional routing logic between plural/singular parsers
  - Added `-d` flag for `nas_volume_direct_mode` at top level
  - Added `-d` flag for `direct_mode` in get subcommand
- **Updated** NFS plugin to use correct command structure
  - Changed: `nas_volumes` → `nas_volume` in all snapshot operations
  - Line 316: `volume_snapshot` now uses `nas_volume`
  - Line 428: `volume_snapshot_delete` now uses `nas_volume`
  - Line 439: `volume_snapshot_list` now uses `nas_volume`
- **Architecture clarification**:
  - Collection operations: `jdssc pool X nas_volumes create|list`
  - Individual operations: `jdssc pool X nas_volume <name> snapshots|snapshot|get|delete`
- **Status**: Routing fixed, architecture matches iSCSI pattern, ready for testing

### 2025.01.12 - NFS Plugin Configuration Simplification
- **Removed** share management functionality
  - NFS shares are pre-configured on JovianDSS by administrator
  - Plugin no longer creates/manages shares via REST API
  - Removed `ensure_joviandss_share()` function
  - Removed `share_name` configuration option
- **Simplified** configuration options
  - Removed: `pool_name`, `share_name`, `dataset_path`
  - Kept: `server`, `export`, `path` (standard NFS fields)
  - Export path format: `/Pools/<pool_name>/<dataset_name>`
- **Added** `parse_export_path()` helper function
  - Automatically extracts pool name and dataset name from export path
  - Example: `/Pools/Pool-2/test1` → pool="Pool-2", dataset="test1"
- **Updated** all snapshot operations to use parsed values
  - `get_pool_name()` and `get_dataset_name()` replace direct config access
  - REST API calls now use correct dataset name (not full path)
- **Architecture**: NFS plugin now follows standard Proxmox NFS pattern
  - Mount pre-configured exports (like standard NFSPlugin)
  - Use REST API only for snapshot operations
  - No runtime share creation/management
- **Status**: Configuration simplified, closer to standard Proxmox NFS plugin

### 2025.01.09 - Perl Code Review & Standards Documentation
- **Reviewed** `OpenEJovianDSSNFSPlugin.pm` for Perl best practices compliance
- **Findings**:
  - ✅ Overall: 4/5 stars - well-written, follows Perl best practices
  - ✅ 634 lines (within 1000 line limit)
  - ✅ Proper module structure, error handling, security
  - ⚠️ Minor: Parameter unpacking spacing differs from iSCSI plugin
  - ⚠️ Minor: Some lines exceed 80 characters
- **Documented** Perl code style standards in project-status.md
- **Status**: Code review complete, minor style inconsistencies identified

### 2025.01.09 - jdssc NAS Volume Snapshot & Clone Support
- **Implemented REST API functions** in `jdssc/jovian_common/rest.py`:
  - `create_nas_snapshot` / `delete_nas_snapshot` / `get_nas_snapshot` / `get_nas_snapshots`
  - `create_nas_clone` / `delete_nas_clone` / `get_nas_clones`
- **Implemented Driver layer methods** in `jdssc/jovian_common/driver.py`:
  - `create_nas_snapshot` / `delete_nas_snapshot` / `list_nas_snapshots` / `get_nas_snapshot`
  - `create_nas_clone` / `delete_nas_clone` / `list_nas_clones`
  - Handles name transformation via `jcom.vname()` and `jcom.sname()`
  - Provides proper layered architecture: CLI → Driver → REST API
- **Created CLI command modules**:
  - `jdssc/jdssc/nas_snapshots.py` - Plural operations (create, list)
  - `jdssc/jdssc/nas_snapshot.py` - Singular operations (delete, get, clones)
  - CLI calls driver methods (not REST API directly)
- **Updated** `jdssc/jdssc/nasvolume.py` - Added snapshot/snapshots subcommands
- **Resolved blocker** for NFS rollback implementation
- **Architecture**: Follows proper separation of concerns (3-layer architecture)
- **Status**: Code complete, needs testing against JovianDSS instance

### 2025.01.09 - NFS Plugin Prototype Created
- Created OpenEJovianDSSNFSPlugin.pm (v0.1.0)
- Implemented basic NFS mounting based on Proxmox NFSPlugin
- Added JovianDSS share management via REST API
- Implemented ZFS snapshot operations (create/delete/list/info/rollback)
- Added configuration properties for NFS-specific settings
- Integrated with OpenEJovianDSS::Common for REST API communication
- Created initial project-status.md for tracking
