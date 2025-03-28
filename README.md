# JovianDSS-Proxmox

The JovianDSS Proxmox package provides a set of plugins that extends Proxmox with the capability to use JovianDSS as a storage system.
The plugins: `joviandss` and `joviandss-lvm` have been installed together since version 0.9.9-3 along side with the internal cli `jdssc`.
Plugins installation requires manual editing of the Proxmox storage configuration file and providing addition communication information in form of `jdssc` yaml config file.
Once it is done plugins get natively integrated in Proxmox and its user interface.


## Plugin difference
The difference in approches used by plugins can be summorised by following table:

| Feature                                                                              | JovianDSS Plugin                                                         |
|--------------------------------------------------------------------------------------|--------------------------------------------------------------------------|
| Storage of `iso`, `vztmpl`, `backup` files                                           | :white_check_mark:                                                       | 
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

[`joviandss` config](https://github.com/open-e/JovianDSS-Proxmox/docs/plugin-installation-and-configuration.md) is deprecaded and will be removed, please move your data to `jovnadss-lvm` plugin. 


## Docs

Please visit [wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki) for more information.
1. [Quick Start](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start)
2. [Configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-installation-and-configuration)
3. [JovianDSS recovery from a major storage failure](https://github.com/open-e/JovianDSS-Proxmox/wiki/JovianDSS-recovery-from-a-major-storage-failure)
4. [Updating](https://github.com/open-e/JovianDSS-Proxmox/wiki/Updating)


