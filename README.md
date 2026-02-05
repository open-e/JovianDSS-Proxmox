# Open-E JovianDSS Proxmox

## Overview

The Open-E JovianDSS Proxmox Plugin integrates Proxmox virtualization environment with high-grade enterprise Open-E JovianDSS storage,
allowing administrator to manage everything from one place.

Virtual machines and containers gain access to fast, reliable storage with built-in data protection — snapshots take seconds and use minimal space.

JovianDSS delivers enterprise-class High Availability with redundant storage controllers and automatic failover, ensuring data remains accessible even if hardware fails.

Combined with Proxmox's own HA capabilities for virtual machines, results in comprehensive protection at both the storage and virtualization layers.

Deployment is [simple](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start), a single install script lets you set up the plugin across all nodes in your cluster with minimal effort.

It's actively maintained and continuously improved to work smoothly with the latest Proxmox releases.


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
