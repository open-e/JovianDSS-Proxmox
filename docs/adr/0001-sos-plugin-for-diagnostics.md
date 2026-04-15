# ADR 0001: sos Plugin for JovianDSS Proxmox Diagnostics

## Status

Accepted

## Context

Troubleshooting the JovianDSS Proxmox plugin usually requires data from several
places:

- Proxmox storage state (`pvesm status`, `pvesm config`, `pvesm list ...`).
- JovianDSS plugin logs under `/var/log/joviandss`.
- Local and cluster plugin state under `/etc/joviandss/state` and
  `/etc/pve/priv/joviandss/state`.
- iSCSI session state.
- multipath state.
- NFS mount/export state for `joviandss-nfs`.
- Package version and installed file state.

The manual collection procedure is error-prone, especially in clusters where the
same data must be gathered from every Proxmox node. It is also easy to
accidentally include sensitive password files from `/etc/pve/priv/storage/`.

The supported diagnostic target is `sos` version `4.9.1` or newer. This allows
the plugin to use the modern `sos.report.plugins` API without carrying
compatibility code for older `sosreport` releases.

## Decision

Add a repository-maintained `sos` plugin at:

```text
tools/sos/joviandss.py
```

The plugin collects JovianDSS Proxmox diagnostics and intentionally excludes
sensitive password files.

The plugin will:

- Copy plugin logs and state:
  - `/var/log/joviandss`
  - `/etc/joviandss/state`
  - `/etc/pve/priv/joviandss/state`
- Copy relevant host configuration:
  - `/etc/multipath/conf.d/open-e-joviandss.conf`
  - `/etc/joviandss/multipath-open-e-joviandss.conf.example`
  - `/etc/udev/rules.d/50-joviandss-scsi-skip-dm.rules`
  - `/etc/lvm/lvm.conf`
- Forbid password files:
  - `/etc/pve/priv/storage/joviandss/*.pw`
  - `/etc/pve/priv/storage/joviandss-nfs/*.pw`
- Provide an explicit opt-in option `collect_pw_file_format` that reads those
  password files but stores only sanitized copies in the report. Password values
  are replaced with `<secret password>` while preserving line structure well
  enough to diagnose malformed files.
- Collect command output for package, Proxmox, iSCSI, multipath and logs.
- Parse `/etc/pve/storage.cfg` to find storage IDs of type `joviandss` and
  `joviandss-nfs`, then run `pvesm list <storage_id>` for each one.
- Parse `/etc/pve/storage.cfg` to find `server` values for `joviandss-nfs`
  entries, then collect `showmount`, `rpcinfo` and port `2049` checks for those
  servers.

The plugin is initially stored as a source file in the repository. Packaging it
into the `.deb` can be decided separately after testing on supported Proxmox VE
systems with `sos >= 4.9.1`.

## Usage

For local testing, copy the plugin into the `sos` plugin directory used by the
target host. On Debian/Proxmox this is commonly:

```text
/usr/share/sos/report/plugins/joviandss.py
```

Run only the JovianDSS plugin:

```bash
sos report --only-plugins joviandss --cmd-timeout 300 --debug
```

Run the plugin with sanitized password-file format collection enabled:

```bash
sos report \
  --only-plugins joviandss \
  --plugin-option joviandss.collect_pw_file_format=true \
  --cmd-timeout 300 \
  --debug
```

Run it as part of the broader recommended report:

```bash
sos report \
  --batch \
  --tmp-dir /var/tmp \
  --skip-plugins pcs,pacemaker,ceph,process,processor,kernel,pci \
  --cmd-timeout 300 \
  --debug
```

## Consequences

Benefits:

- Support collection becomes repeatable and less dependent on manual command
  copying.
- `pvesm list <storage_id>` validates that the plugin is loadable and can query
  the configured backend.
- NFS diagnostics are included when `joviandss-nfs` entries are present.
- Password files are explicitly excluded.
- Malformed password files can be diagnosed without exposing actual passwords,
  but only when the user explicitly enables the sanitized collection option.

Tradeoffs:

- The plugin depends on the `sos` 4.9.1+ plugin API.
- Automatic NFS server checks depend on parsing `/etc/pve/storage.cfg`; malformed
  storage entries may prevent those optional checks from being added.
- `sos` reports may still contain environment-sensitive data such as hostnames,
  IP addresses, storage IDs, VM IDs and paths. Reports must be reviewed before
  sharing externally.
- Enabling `collect_pw_file_format` causes the plugin to read sensitive password
  files. The stored report content is sanitized, but the option should still be
  used only when password-file formatting is relevant to the incident.
- The plugin is not installed by the package yet; until packaging is added, it
  must be copied manually for testing.

## Follow-Up Work

- Test on supported Proxmox VE versions with `sos >= 4.9.1`.
- Decide whether to install the plugin from the Debian package.
- If packaged, document the installed path and add a package changelog entry.
- Consider adding a `sos` preset or wrapper command for cluster-wide collection.
