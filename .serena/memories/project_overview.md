# JovianDSS-Proxmox Project Overview

## Purpose
Proxmox VE storage plugin integrating Open-E JovianDSS ZFS storage with Proxmox virtualization.
Two plugins: iSCSI (production) and NFS (prototype ~40% complete).

## Version
0.10.15

## Tech Stack
- **Perl**: Proxmox storage plugins (`OpenEJovianDSSPlugin.pm`, `OpenEJovianDSSNFSPlugin.pm`, `OpenEJovianDSS/Common.pm`, `OpenEJovianDSS/NFSCommon.pm`)
- **Python 3**: `jdssc` CLI tool (REST API wrapper) in `jdssc/` directory
- **JovianDSS REST API v4**: Backend storage management
- **Proxmox VE Storage API**: Plugin framework

## Architecture
```
Proxmox VE → Perl Plugin → Common.pm → jdssc CLI (Python) → REST API → JovianDSS
```

### Perl Layer (Proxmox Plugins)
- `OpenEJovianDSSPlugin.pm` - iSCSI storage plugin (production, v0.10.14)
- `OpenEJovianDSSNFSPlugin.pm` - NFS storage plugin (prototype, v0.1.0)
- `OpenEJovianDSS/Common.pm` - Shared helpers for REST API communication via jdssc
- `OpenEJovianDSS/NFSCommon.pm` - NFS-specific helpers (activate/deactivate snapshots)

### Python Layer (jdssc CLI)
- Located at `jdssc/jdssc/` (installed to `/usr/local/bin/jdssc`)
- 3-layer architecture: CLI → Driver (`jovian_common/driver.py`) → REST API (`jovian_common/rest.py`)
- Naming conventions handled in `jovian_common/jdss_common.py`
- Singular vs plural pattern: `volume`/`volumes`, `nas_volume`/`nas_volumes`, `snapshot`/`snapshots`

### Key Patterns
- iSCSI: creates volumes, exports via iSCSI targets, optional multipath
- NFS: mounts pre-configured shares, snapshots via REST API, clone-based rollback
- Volume naming: `v_` (simple), `vh_` (human-friendly/base32), `s_` (snapshots), `se_` (snapshot export clones)
- Direct mode (`-d` flag): bypass name transformation for NAS volumes from export paths

## Project Structure
```
├── OpenEJovianDSSPlugin.pm      # iSCSI plugin (Perl)
├── OpenEJovianDSSNFSPlugin.pm   # NFS plugin (Perl)
├── OpenEJovianDSS/
│   ├── Common.pm                # Shared Perl utilities
│   └── NFSCommon.pm             # NFS-specific Perl helpers
├── jdssc/                       # Python CLI tool
│   ├── setup.py                 # Package config (deps: retry, pyinotify, toml)
│   ├── Makefile                 # Install to /usr/local/bin/jdssc
│   ├── bin/jdssc                # Entry point
│   └── jdssc/
│       ├── pool.py              # Pool-level routing
│       ├── volume.py/volumes.py # iSCSI volume ops
│       ├── nasvolume.py/nasvolumes.py  # NAS volume ops
│       ├── snapshot.py/snapshots.py    # iSCSI snapshot ops
│       ├── nas_snapshot.py/nas_snapshots.py  # NAS snapshot ops
│       ├── target.py/targets.py        # iSCSI target ops
│       ├── share.py/shares.py          # NFS share ops
│       └── jovian_common/
│           ├── driver.py        # Business logic layer
│           ├── rest.py          # REST API HTTP layer
│           ├── jdss_common.py   # Naming conventions (vname, sname)
│           └── exception.py     # Custom exceptions
├── blockdevicemanager/          # Block device management service
├── install.pl                   # Installation script
├── Makefile                     # Build .deb package
├── configs/                     # Multipath config examples
├── scripts/                     # Test/utility scripts
├── tests/testcases/             # YAML test case definitions
├── docs/                        # Documentation (wiki mirror)
├── spec.md                      # Project specification
└── project-status.md            # SDD project status tracking
```

## Configuration
Plugin configured in `/etc/pve/storage.cfg` with type `joviandss`.
Key properties: pool_name, control_addresses, data_addresses, user_name, user_password, ssl_cert_verify, multipath, thin_provisioning, luns_per_target, debug, log_file.
Passwords stored securely in `/etc/pve/priv/storage/joviandss/<storage-id>.pw`.

## Current Status
- iSCSI plugin: production-ready (100%)
- NFS plugin: prototype (~40%)
  - Core structure, NFS mount, snapshot ops: done
  - Clone ops, testing, docs, install integration: pending
- Known issues: see project-status.md "Open Issues Checklist" section
