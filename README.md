# JovianDSS-Proxmox

The JovianDSS Proxmox package provides a set of plugins that extends Proxmox with the capability to use JovianDSS as a storage system.
The plugins: `joviandss` and `joviandss-lvm` have been installed together since version 0.9.9-3 along side with the internal cli `jdssc`.
Plugins installation requires manual editing of the Proxmox storage configuration file and providing addition communication information in form of `jdssc` yaml config file.
Once it is done plugins get natively integrated in Proxmox and its user interface.

These plugins, are `joviandss` and `joviandss-lvm` approach allocation and usage of JovianDSS resources in a distinct ways.

## Plugin difference
The difference in approches used by plugins can be summorised by following table:

| Feature                                    | Original JovianDSS Plugin         | JovianDSS-LVM Plugin                                                |
|--------------------------------------------|-----------------------------------|---------------------------------------------------------------------|
| Storage of iso, vztmpl, backup files       | :white_check_mark:                | :x:                                                                 |
| Storage of images, rootdit                 | :white_check_mark:                | :white_check_mark:                                                  |
| Image/rootdir to JovianDSS volume relation | :white_check_mark: Each image and rootdir file are stored on dedicated volume | :white_check_mark: There is a single volume for virtual machine that stores all images/rootdir files related to it |
| Snapshots                                  | :white_check_mark: Each virtual volume have its own snapshot | :white_check_mark:All virtual volumes of a single VM receive an atomic snapshot simultaneously |
| Rollback                                   | Rollback can be done to the latest snapshot only | Rollback can be done to the latest snapshot only     |
| Clonning                                   | :white_check_mark:                | :white_check_mark:                                                  |
| Volume movement from one vm to another     | :white_check_mark:                | :x:                                                                 |
| Volume resizing                            | :white_check_mark:                | :white_check_mark:                                                  |
| VM atomic snapshots                        | :x:                               | :white_check_mark:                                                  |
| Supported format                           | `raw` **Snapshots supported**     | `raw` **Snapshots supported**                                       |
| Thin provisioning                          | :white_check_mark: This feature is enabled through a YAML configuration file | :white_check_mark: This feature is enabled through a YAML configuration file   |

`joviandss` plugin is an old plugin that remains the same and get [configured the same way](https://github.com/open-e/JovianDSS-Proxmox/docs/plugin-installation-and-configuration.md)

`joviandss-lvm` utilises LVM as additinal layer of volume abstraction over JovianDSS ZVols.

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


