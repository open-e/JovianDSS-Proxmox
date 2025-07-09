# JovianDSS-Proxmox

The JovianDSS Proxmox package provides a set of plugins that extend Proxmox VE with the capability to use JovianDSS as a storage system.
Plugin installation requires manual editing of the Proxmox VE storage configuration file.
Once completed, the plugins are natively integrated into Proxmox VE and its user interface.

## The plugin is currently under active development. You may experience occasional malfunctions, and some features might change in future updates.

## Plugin features

| Feature                                                                              | JovianDSS Plugin                                                         |
|--------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| Storage of `iso`, `vztmpl`, `backup` files                                           | :x: Storing iso, backup, and vztmpl content is no longer supported by this plugin. Please use the native Proxmox VE NFS plugin as described in [Open-E JovianDSS with NFS for Proxmox VE: Best Practices Guide](https://www.open-e.com/site_media/download/documents/howtoresource/Open-E_Jovian_DSS_with_NFS_for_Proxmox_VE_Best_Practices_Guide_1.00.pdf) | 
| Storage of `images`(QEMU/KVM VM images), `rootdir`(container data)                   | :white_check_mark:                                                       |
| `images`(QEMU/KVM VM images)/`rootdir`(container data) to JovianDSS volume relation  | :white_check_mark: Each VM/CT virtual disk is stored on dedicated volume |
| Snapshots                                                                            | :white_check_mark: Each volume maintains its own independent set of snapshots. Snapshotting is done individualy for each volume |
| Rollback                                                                             | Rollback can be done to the latest snapshot only, user is recommended to use cloning from snapshot to restore to older state  |
| Clonning                                                                             | :white_check_mark:                                                       |
| Volume movement from one VM to another                                               | :white_check_mark:                                                       |
| Volume resizing                                                                      | :white_check_mark:                                                       |
| VM atomic snapshots                                                                  | :x: Proxmox is responsible for maintaining data integrity during snapshot creation |
| Supported format of storing VM/CT data                                               | `raw` (with **Snapshots supported**)                                     |
| Thin provisioning                                                                    | :white_check_mark:                                                       |


## Docs

Please visit [wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki) for more information.
1. [Quick Start](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start)
2. [Configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)
3. [Updating](https://github.com/open-e/JovianDSS-Proxmox/wiki/Updating)


