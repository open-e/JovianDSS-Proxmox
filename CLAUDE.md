# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Open-E JovianDSS Proxmox Plugin — integrates Proxmox VE with JovianDSS enterprise storage via iSCSI. Supports snapshots, rollback, cloning, live migration, thin provisioning, HA, and multipath. Licensed Apache 2.0.

Current version: stored in `VERSION` file (also duplicated in `setup.py`, `debian/control`, `OpenEJovianDSSPlugin.pm:$PLUGIN_VERSION`, `jdssc/jdssc/jovian_common/driver.py:self.VERSION` — all must be kept in sync manually).

## Build Commands

```bash
# Build .deb package (requires dpkg-deb, uses git describe for version)
make deb

# Install from source to a DESTDIR
make install DESTDIR=/

# Uninstall
make uninstall
```

The `jdssc` Python package is installed via its own `jdssc/Makefile` (called by the root Makefile).

## Architecture

### Two-Layer Design

**Layer 1 — Perl Storage Plugin** (runs inside Proxmox VE):
- `OpenEJovianDSSPlugin.pm` — registers storage type `joviandss`, implements `PVE::Storage::Plugin` interface (`alloc_image`, `free_image`, `list_images`, `activate_volume`, `deactivate_volume`, `volume_snapshot`, `volume_snapshot_rollback`, `clone_image`, `volume_resize`, etc.)
- `OpenEJovianDSS/Common.pm` (~3000 lines) — shared library with iSCSI session management, LUN record handling, multipath logic, and the `joviandss_cmd()` function that shells out to `jdssc`

**Layer 2 — Python CLI `jdssc`** (called as subprocess by Perl layer):
- Entry point: `jdssc/bin/jdssc`
- Hierarchical argparse subcommands: `pool <name> volume|volumes|targets|shares|nas_volumes ...`
- Each resource is a class (`Volume`, `Volumes`, `Targets`, `Snapshot`, etc.) that dispatches to action methods
- `jdssc/jdssc/jovian_common/driver.py` (~76KB) — `JovianDSSDriver` class, all business logic
- `jdssc/jdssc/jovian_common/rest.py` (~50KB) — `JovianRESTAPI` class, wraps all REST calls with regex-based error pattern matching
- `jdssc/jdssc/jovian_common/rest_proxy.py` — `JovianDSSRESTProxy`, HTTP session management using `requests` + `retry`

### Data Flow

1. Perl plugin calls `jdssc` to create volume + iSCSI target on JovianDSS appliance
2. `jdssc` calls JovianDSS REST API (HTTPS, default port 82)
3. Perl plugin runs `iscsiadm` to login to the target
4. Optionally `multipathd` handles multipath device mapper entries
5. LUN records (JSON) stored locally at `/etc/joviandss/state/<storeid>/`

### Volume/Snapshot Naming

- Proxmox `vm-100-disk-0` → JovianDSS `v_vm-100-disk-0`
- Names with disallowed chars → Base32-encoded: `vb_<encoded>` or `vh_<encoded>`
- Snapshots: `s_<md5hash>-<snapname>` or `se_<encoded>`
- Encoding logic in `jdssc/jdssc/jovian_common/jdss_common.py`

### blockdevicemanager Daemon

`blockdevicemanager/blockdevicemanager` — Python daemon using `inotify_simple` to watch `/etc/pve/priv/joviandss` for changes. Listens on UNIX socket `/var/run/joviandssblockdevicemanager.sock`. Auto-performs `iscsiadm` login/logout when iSCSI config files change. Systemd unit: `blockdevicemanager/joviandssblockdevicemanager.service`.

## Configuration

Plugin config lives in `/etc/pve/storage.cfg` under `joviandss:` sections. Key properties: `pool_name`, `control_addresses` (REST API IPs), `data_addresses` (iSCSI VIPs), `control_port` (default 82), `data_port` (default 3260), `luns_per_target` (default 8), `block_size`, `thin_provisioning`, `multipath`, `target_prefix`.

Password stored separately at `/etc/pve/priv/storage/joviandss/<storeid>.pw`.

## Testing

Test cases are YAML specification files in `tests/testcases/` (not executable scripts). They define prerequisites, steps, and expected results for manual or external test framework execution. The actual test runner lives in a separate repo (`open-e/pve-testing`).

Categories: `jdssc/` (createvolume, createtarget, rollback) and `plugin/` (start, snapshots, rollback, multipath, poolconfig, concurrency, resilience, etc.).

## Installation

Two installers exist:
- `install.pl` — production installer, downloads from GitHub releases, supports `--all-nodes` for cluster-wide SSH-based deployment
- `dev/install-local.pl` — developer installer, takes `--package <path>` for local .deb file, supports same cluster operations

Both require running on Proxmox VE (use `PVE::Tools::run_command`).

## Proxmox API Compatibility

Supports Proxmox VE Storage API versions 9–13 (PVE 7.x through 9.x), detected dynamically at runtime in `OpenEJovianDSSPlugin.pm`.

## Code Conventions

### Perl
- `use strict; use warnings;` everywhere
- Logging via `OpenEJovianDSS::Common::debugmsg($scfg, 'debug'|'error'|'warn', ...)`
- External data sanitized with `clean_word()` (strips non-ASCII, whitespace)
- All JovianDSS operations via `joviandss_cmd($scfg, $storeid, [@args])`

### Python
- Python 3, Apache 2.0 license header on all files
- Module-level `LOG = logging.getLogger(__name__)`
- Exceptions in `exception.py` with numeric error codes (1=general, 2=REST, 3=proxy, 4=comms, 5=outdated)
- `_()` i18n stub (no-op) via `stub.py`

## Dependencies

Runtime: `python3-oslo.utils`, `python3-yaml`, `multipath-tools`, `sg3-utils`, `python3-retry`, `libstring-util-perl`. System tools: `iscsiadm`, `multipath`, `multipathd`, `dmsetup`.
