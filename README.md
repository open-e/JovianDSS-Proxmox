# Open-E JovianDSS Proxmox

## Overview

The Open-E JovianDSS Proxmox plugin enables Proxmox VE clusters to use Open-E JovianDSS storage pools as backend storage via iSCSI.

It provides:

- Automated Volume Management: Dynamically attach/detach iSCSI targets and manage multipath devices.
- High Availability: Support for Open-E JovianDSS failover and multipathing across multiple network interfaces.
- Thin Provisioning: On-demand volume allocation to optimize storage usage.
- Cluster-wide Integration: Treat storage as shared, enabling live migration and HA features in Proxmox VE.



## Versioning

This package uses a centralized `VERSION` file that contains the authoritative version number (e.g., `0.10.5`).

The Debian package uses format `0.10.5-0` where:
- `0.10.5` = upstream software version (matches VERSION file)
- `-0` = Debian revision for packaging-specific changes (dependencies, scripts, metadata)

To see the currently installed version, run:
```bash
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin
```

## Documentation

* Start using the plugin by going through the [Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start).

* Plugin Configuration: [Plugin-configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

* Networking: [Plugin Networking](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)

* Multipathing: [Multipathing Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing)

For a full list of topics, visit the [JovianDSS Proxmox Wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki).


## Plugin features

| Feature                                                                              | JovianDSS Plugin                                                         |
|--------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| Storage of `images`(QEMU/KVM VM images), `rootdir`(container data)                   | :white_check_mark: To store iso, backup, and vztmpl content use the native Proxmox VE NFS plugin as described in [Open-E JovianDSS with NFS for Proxmox VE: Best Practices Guide](https://www.open-e.com/site_media/download/documents/howtoresource/Open-E_Jovian_DSS_with_NFS_for_Proxmox_VE_Best_Practices_Guide_1.00.pdf) |
| `images`(QEMU/KVM VM images)/`rootdir`(container data) to JovianDSS volume relation  | :white_check_mark: Each VM/CT virtual disk is stored on its own dedicated volume |
| Snapshots                                                                            | :white_check_mark: Each volume maintains its own set of snapshots. Snapshots are created individually for each volume. **Note**: Proxmox VE's built-in backup functionality does not back up JovianDSS plugin snapshots |
| Rollback                                                                             | Rollback can be done to the latest snapshot only, user is recommended to use cloning from snapshot to restore to older state  |
| Clonning                                                                             | :white_check_mark:                                                       |
| Volume movement from one VM to another                                               | :white_check_mark:                                                       |
| Volume resizing                                                                      | :white_check_mark:                                                       |
| Supported format of storing VM/CT data                                               | `raw` (with **Snapshots supported**)                                     |
| Thin provisioning                                                                    | :white_check_mark:                                                       |

## Roadmap

- Additional volume configuration options

- CHAP authentication for iSCSI targets

- Optional backup-plugin extension


## Support & Contribution

Report issues and feature requests via the repository Issues.
