# Open-E JovianDSS iSCSI & NFS Proxmox VE Plugin

## Overview

The Open-E JovianDSS Proxmox Plugin integrates Proxmox virtualization environment with high-grade enterprise Open-E JovianDSS storage,
allowing administrator to manage everything from one place.

Virtual machines and containers gain access to fast, reliable storage with built-in data protection — snapshots take seconds and use minimal space.

JovianDSS delivers enterprise-class High Availability with redundant storage controllers and automatic failover, ensuring data remains accessible even if hardware fails.

Combined with Proxmox's own HA capabilities for virtual machines, results in comprehensive protection at both the storage and virtualization layers.

Deployment is [simple](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start), a single install script lets you set up the plugin across all nodes in your cluster with minimal effort.

It's actively maintained and continuously improved to work smoothly with the latest Proxmox releases.


## Documentation

Start using the plugin by going through the
  
  [iSCSI plugin Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start-iSCSI)
  
  [NFS plugin Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start-NFS)

For more detailed information:
* [Plugin-configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

* [Plugin Networking](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)

* [Multipathing](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing)

For a full list of topics, visit the 
    [JovianDSS Proxmox Wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki)


## Plugin features

| Feature                                                                              | iSCSI Plugin                                                             | NFS Plugin |
|--------------------------------------------------------------------------------------|--------------------------------------------------------------------------| -----------|
| Proxmox VE Content                 | `images`, `rootdir`  | `images`, `rootdir`,  `vztmpl`, `iso`, `backup`, `snippets`  |
| `images`(QEMU/KVM VM images)/`rootdir`(container data) to JovianDSS volume relation  | :white_check_mark: Each VM/CT virtual disk is stored on its own dedicated volume | :white_check_mark: A single ZFS dataset is used to store all Proxmox VE resources, including VM images, container volumes, and ISO files. |
| Snapshots                                                                            | :white_check_mark: Each volume maintains its own set of snapshots. Snapshots are created individually for each volume. **Note**: Proxmox VE's built-in backup functionality does not back up JovianDSS plugin snapshots | :white_check_mark: JovianDSS `dataset` contains snapshots for all resources associated with it |
| Rollback                                                                             | :white_check_mark:                                                       | :white_check_mark: |
| Cloning                                                                              | :white_check_mark:                                                       | :white_check_mark: | 
| Volume movement from one VM to another                                               | :white_check_mark:                                                       | :white_check_mark: |
| Volume resizing                                                                      | :white_check_mark:                                                       | :white_check_mark: |
| Supported format of storing VM/CT data                                               | `raw` (with **Snapshots supported**)                                     | `raw` (with **Snapshots supported**) To store `qcow2` and `vmdk` files, use the native Proxmox VE NFS plugin, as described in the [Open-E JovianDSS with NFS for Proxmox VE: Best Practices Guide](https://www.open-e.com/site_media/download/documents/howtoresource/Open-E_Jovian_DSS_with_NFS_for_Proxmox_VE_Best_Practices_Guide_1.00.pdf)   |
| Thin provisioning                                                                    | :white_check_mark:                                                       | :white_check_mark: Sparse RAW thin allocation supported; physical storage is allocated as data is written. Automatic reclamation of guest-discarded blocks is not supported. Over time, as new blocks are written and deleted, the RAW image may consume storage approaching its full provisioned size |

## Roadmap

- Optional backup-plugin extension


## Support & Contribution

Report issues and feature requests via the repository Issues.
