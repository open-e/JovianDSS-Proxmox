# JovianDSS-Proxmox

The JovianDSS Proxmox package provides a set of plugins that extends Proxmox with the capability to use JovianDSS as a storage system.
The plugins: `joviandss` and `joviandss-lvm` have been installed together since version 0.9.9-3 along side with the internal cli `jdssc`.
Plugins installation requires manual editing of the Proxmox storage configuration file and providing addition communication information in form of `jdssc` yaml config file.
Once it is done plugins get natively integrated in Proxmox and its user interface.

These plugins, are `joviandss` and `joviandss-lvm` approach allocation and usage of JovianDSS resources in a distinct ways.

## Plugin difference
The difference in approches used by plugins can be summorised by following table:

| Feature                                                                              |Original JovianDSS Plugin                                                 |  JovianDSS-LVM Plugin                                                               |
|--------------------------------------------------------------------------------------|--------------------------------------------------------------------------|-------------------------------------------------------------------------------------|
| Storage of `iso`, `vztmpl`, `backup` files                                           | :white_check_mark:                                                       | :x: for storing iso, vztmpl, backup files on side of JovianDSS please refere to the Proxmox NFS plugin  |
| Storage of `images`(QEMU/KVM VM images), `rootdir`(container data)                   | :white_check_mark:                                                       | :white_check_mark:                                                                  |
| `images`(QEMU/KVM VM images)/`rootdir`(container data) to JovianDSS volume relation  | :white_check_mark: Each VM/CT virtual disk is stored on dedicated volume | :white_check_mark: There is a single volume for VM/CT that stores all `images`/`rootdir` files related to it |
| Snapshots                                                                            | :white_check_mark: Each volume maintains its own independent set of snapshots. Snapshotting is done individualy for each volume | :white_check_mark: All virtual volumes of a single VM/Container receive an atomic snapshot simultaneously |
| Rollback                                                                             | Rollback can be done to the latest snapshot only, user is recommended to use cloning from snapshot to restore to older state  | Rollback can be done to the latest snapshot only, user is recommended to use cloning from snapshot to restore to older state |
| Clonning                                                                             | :white_check_mark:                                                       | :white_check_mark:                                                                  |
| Volume movement from one VM to another                                               | :white_check_mark:                                                       | :x: User have to create new volume for VM and copy data using tools like `scp`      |
| Volume resizing                                                                      | :white_check_mark:                                                       | :white_check_mark:                                                                  |
| VM atomic snapshots                                                                  | :x: Proxmox is responsible for maintaining data integrity during snapshot creation | :white_check_mark:                                                        |
| Supported format of storing VM/CT data                                               | `raw` (with **Snapshots supported**)                                     | `raw` (with **Snapshots supported**)                                                |
| Thin provisioning                                                                    | :white_check_mark:                                                       | :white_check_mark:                                                                  |

[`joviandss`](https://github.com/open-e/JovianDSS-Proxmox/docs/plugin-installation-and-configuration.md) is deprecaded and will be removed, please move your data to `jovnadss-lvm` plugin. 

`joviandss-lvm` utilises LVM over iSCSI as additinal layer of volume abstraction over JovianDSS ZVols.

This approach have several benefits in comparison to original `joviandss` plugin:
- All virtual disks associated with VM are stored on single ZVol, that simplifies backup and disaster recovery functionality provided by JovianDSS
- Snapshots, that are native JovianDSS(not LVM snapshots) are created for all virtual disks that are related to virtula machine at the same time.

A downside of this approach is that the user cannot attache volumes from one particular virtual machine to another.
To attach a volume with specific data, the user is advised to use Proxmox `storage migration` function.

Configuring-JovianDSS‐LVM-plugin
## Docs

Please visit [wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki) for more information.
1. [Quick Start](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start)
2. [Configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Configuring-JovianDSS‐LVM-plugin)
3. [JovianDSS recovery from a major storage failure](https://github.com/open-e/JovianDSS-Proxmox/wiki/JovianDSS-recovery-from-a-major-storage-failure)
4. [Updating](https://github.com/open-e/JovianDSS-Proxmox/wiki/Updating)


