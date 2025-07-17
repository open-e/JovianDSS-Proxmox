# JovianDSS-Proxmox

## Overview

The JovianDSS Proxmox plugin enables Proxmox VE clusters to use JovianDSS storage pools as backend storage via iSCSI.

It provides:

- Automated Volume Management: Dynamically attach/detach iSCSI targets and manage multipath devices.
- High Availability: Support for JovianDSS failover and multipathing across multiple network interfaces.
- Thin Provisioning: On-demand volume allocation to optimize storage usage.
- Cluster-wide Integration: Treat storage as shared, enabling live migration and HA features in Proxmox VE.

## Work in Progress

The JovianDSS Proxmox plugin is under active development.
Version 0.10 represents a rewrite of the `joviandss` plugin and is shipped without the `joviandss-lvm` component.

**Upcoming Features:**

- LVM plugin integration

- Additional volume configuration options

- CHAP authentication for iSCSI targets

- Optional backup-plugin extension

## Getting Started

Start using the plugin by going through the [Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start).

## Documentation

Comprehensive documentation is maintained on GitHub:

* Plugin Configuration: [Plugin-configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

* Networking: [Plugin Networking](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)

* Multipathing: [Multipathing Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing)

For a full list of topics, visit the [JovianDSS Proxmox Wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki).


## Plugin features

| Feature                                                                              | JovianDSS Plugin                                                         |
|--------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| Storage of `iso`, `vztmpl`, `backup` files                                           | :x: Storing iso, backup, and vztmpl content is no longer supported by this plugin. Please use the native Proxmox VE NFS plugin as described in [Open-E JovianDSS with NFS for Proxmox VE: Best Practices Guide](https://www.open-e.com/site_media/download/documents/howtoresource/Open-E_Jovian_DSS_with_NFS_for_Proxmox_VE_Best_Practices_Guide_1.00.pdf) | 
| Storage of `images`(QEMU/KVM VM images), `rootdir`(container data)                   | :white_check_mark:                                                       |
| `images`(QEMU/KVM VM images)/`rootdir`(container data) to JovianDSS volume relation  | :white_check_mark: Each VM/CT virtual disk is stored on its own dedicated volume |
| Snapshots                                                                            | :white_check_mark: Each volume maintains its own set of snapshots. Snapshots are created individually for each volume |
| Rollback                                                                             | Rollback can be done to the latest snapshot only, user is recommended to use cloning from snapshot to restore to older state  |
| Clonning                                                                             | :white_check_mark:                                                       |
| Volume movement from one VM to another                                               | :white_check_mark:                                                       |
| Volume resizing                                                                      | :white_check_mark:                                                       |
| VM atomic snapshots                                                                  | :x: Rollback supports only the latest snapshot; to restore an older state, clone from the desired snapshot instead |
| Supported format of storing VM/CT data                                               | `raw` (with **Snapshots supported**)                                     |
| Thin provisioning                                                                    | :white_check_mark:                                                       |


## Support & Contribution

Report issues and feature requests via the repository Issues.
