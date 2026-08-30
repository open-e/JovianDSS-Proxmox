# Open-E JovianDSS iSCSI & NFS Proxmox VE Plugin

## Overview

The Open-E JovianDSS Proxmox Plugin integrates the Proxmox virtualization environment with enterprise Open-E JovianDSS storage, allowing administrators to manage everything from one place.

Virtual machines and containers gain access to fast, reliable storage with built-in data protection — snapshots take seconds and use minimal space.

JovianDSS delivers enterprise-class High Availability with redundant storage controllers and automatic failover; combined with Proxmox's own HA for virtual machines, this protects both the storage and virtualization layers.

Deployment is simple — a [single install script](https://github.com/open-e/JovianDSS-Proxmox/wiki/Installation-script) sets up the plugin across all nodes in your cluster, or it can be [installed manually](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-installation-and-updating).


## Documentation

Start using the plugin by going through the
  
  [iSCSI plugin Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start-iSCSI)
  
  [NFS plugin Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start-NFS)

For more detailed information:
* [Plugin-configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

* [Plugin-configuration NFS](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS)

* [Plugin configuration: engineering properties](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-engineering)

* [Plugin Networking](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)

* [Multipathing](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing)

* [Snapshot Rollback and High Availability](https://github.com/open-e/JovianDSS-Proxmox/wiki/Snapshot-Rollback-and-High-Availability)

For a full list of topics, visit the 
    [JovianDSS Proxmox Wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki)


## Plugin features

| Feature                                                              | iSCSI Plugin                                                                     | NFS Plugin |
|----------------------------------------------------------------------|----------------------------------------------------------------------------------| -----------|
| Proxmox VE Content                                                   | `images`, `rootdir`                                                              | `images`, `rootdir`, `vztmpl`, `iso`, `backup`, `snippets`, `import` |
| Storage layout                                                       | :white_check_mark: Each VM/CT virtual disk is stored on its own dedicated volume | :white_check_mark: A single ZFS dataset stores all Proxmox VE resources, including VM images, container volumes, and ISO files |
| Snapshots                                                            | :white_check_mark: Each volume maintains its own set of snapshots                | :white_check_mark: The JovianDSS `dataset` holds snapshots for all resources associated with it |
| Volume operations (rollback, cloning, move between guests, resizing) | :white_check_mark:                                                               | :white_check_mark: |
| Supported format of storing VM/CT data                               | `raw`                                                                            | `raw` |
| Thin provisioning                                                    | :white_check_mark:                                                               | :white_check_mark: Sparse `raw` files — space is allocated as data is written; guest-discarded blocks are not reclaimed automatically |

**Note**: Proxmox VE's built-in backup functionality backs up only the base volume data — it does not back up JovianDSS plugin snapshots.

## Roadmap

- Optional backup-plugin extension


## Support & Contribution

Report issues and feature requests via the repository Issues.
