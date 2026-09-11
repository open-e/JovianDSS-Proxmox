# Open-E JovianDSS iSCSI & NFS Proxmox VE Plugin


The Open-E JovianDSS Proxmox Plugin connects Proxmox with reliable, enterprise-grade Open-E JovianDSS storage and lets you manage it directly from the Proxmox interface.

It provides virtual machines and containers with fast storage, snapshots, high availability, and automatic failover.



## Documentation

Start using the plugin by going through the
  
  [iSCSI plugin Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start-iSCSI)
  
  [NFS plugin Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start-NFS)

For more detailed information:
* [Plugin-configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

* [Plugin-configuration NFS](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS)

* [Plugin Networking](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)

* [Multipathing](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing)

For a full list of topics, visit the 
    [JovianDSS Proxmox Wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki)


## Plugin features

| Feature                                                                              | iSCSI Plugin                                                             | NFS Plugin |
|--------------------------------------------------------------------------------------|--------------------------------------------------------------------------| -----------|
| Proxmox VE Content                 | `images`, `rootdir`  | `images`, `rootdir`,  `vztmpl`, `iso`, `backup`, `snippets`, `import`  |
| `images`(QEMU/KVM VM images)/`rootdir`(container data) to JovianDSS volume relation  | :white_check_mark: Each VM/CT virtual disk is stored on its own dedicated volume | :white_check_mark: A single ZFS dataset is used to store all Proxmox VE resources, including VM images, container volumes, and ISO files. |
| Snapshots                                                                            | :white_check_mark: Each volume maintains its own set of snapshots. Snapshots are created individually for each volume. **Note**: Proxmox VE's built-in backup functionality does not back up JovianDSS plugin snapshots | :white_check_mark: JovianDSS `dataset` contains snapshots for all resources associated with it |
| Rollback                                                                             | :white_check_mark:                                                       | :white_check_mark: |
| Cloning                                                                              | :white_check_mark:                                                       | :white_check_mark: | 
| Volume movement from one VM to another                                               | :white_check_mark:                                                       | :white_check_mark: |
| Volume resizing                                                                      | :white_check_mark:                                                       | :white_check_mark: |
| Supported format of storing VM/CT data                                               | `raw` (with **Snapshots supported**)                                     | `raw` (with **Snapshots supported**)                                                                                                                                    |
| Thin provisioning                                                                    | :white_check_mark:                                                       | :white_check_mark: Sparse RAW thin allocation supported; physical storage is allocated as data is written. Automatic reclamation of guest-discarded blocks is not supported. Over time, as new blocks are written and deleted, the RAW image may consume storage approaching its full provisioned size. |

## Roadmap

- Optional backup-plugin extension


## Support & Contribution

Report issues and feature requests via the repository Issues.
