# JovianDSS-Proxmox

## Configuring

Enabling JovianDSS for `proxmox` require 2 configuration files.
First is a proxmox storage configuration file that gives basic information about storage.
And the second is a config used by a minimal joviandss cli `jdssc`.

### Proxmox config

This config provides brief introduce Open-E JovianDSS plugin to proxmox storage sub-system.
And contains minimal set of information required by perl part to run.

`/etc/pve/storage.cfg` 

```
open-e: joviandss
        joviandss_address 172.16.0.220
        pool_name Pool-0
        config /etc/pve/joviandss.yaml
        path /mnt/joviandss
        content iso,backup,images,rootdir
        share_user proxmox
        share_pass proxmox_1

```

| Option                     | Default value                     | Description                                                         |
|----------------------------|-----------------------------------|---------------------------------------------------------------------|
| `joviandss_address`        | 172.16.0.220                      | IP address of Open-E JovianDSS storage                              |
| `pool_name`                | Pool-0                            | Pool name that is going to be used. Must be created in \[1\]        |
| `config`                   | /etc/pve/joviandss.yaml           | path to `jdssc` configuration file                                  |
| `path`                     | None                              | Location that would be used to mount proxmox dedicated volume       |
| `content`                  | None                              | List content type that you expect JovianDSS to store                | 
| `share_user`               | None                              | Share user                                                          | 
| `share_pass`               | None                              | Share password                                                      |

[1] [Can be created by going to JovianDSS Web interface/Storage](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)

Options `path`, `content`, `share_user` and `share_pass` are optional.
They are responsible for creation of a dedicated storage that gets attached to proxmox to store iso images and backups.
Specify this option in configuration file if you want to enable this dedicated storage.
Plugin will create it for you automatically.
If you want to change size of or modify this storage in other way, please find it in `Storage/Shares/proxmox-internal-data`.

### Jdssc config

This config file should be placed according to the path provided in `storage.cfg` file mentioned in the section above.
`joviandss.yaml` provides detailed information on interaction with storage.

```yaml
driver_use_ssl: True
target_prefix: 'iqn.2021-10.com.open-e:'
jovian_pool: 'Pool-0'
jovian_block_size: '64K'
jovian_rest_send_repeats: 3
san_api_port: 82
target_port: 3260
san_hosts: 
  - '172.16.0.220'
san_login: 'admin'
san_password: 'admin'
san_thin_provision: True
loglevel: debug
logfile: /tmp/jdss.log
```

| Option                     | Default value           | Description                                                         |
|----------------------------|-------------------------|---------------------------------------------------------------------|
| `driver_use_ssl`           | True                    | Use SSL to send requests to JovianDSS\[1\]                          |
| `iscsi_target_prefix`      | iqn.2021-10.com.open-e: | Prefix that will be used to form target name for volume             |
| `jovian_pool`              | Pool-0                  | Pool name that is going to be used. Must be created in \[2\]        |
| `jovian_block_size`        | 64K                     | Block size of a new volume, can be: 32K, 64K, 128K, 256K, 512K, 1M  |
| `jovian_rest_send_repeats` | 3                       | Number of times that driver will try to send REST request           |
| `san_api_port`             | 82                      | Rest port according to the settings in \[1\]                        |
| `target_port`              | 3260                    | Port for iSCSI connections                                          |
| `volume_driver`            |                         | Location of the driver source code                                  |
| `san_hosts`                |                         | Comma separated list of IP address of the JovianDSS                 |
| `san_login`                | admin                   | Must be set according to the settings in \[1\]                      |
| `san_password`             | admin                   | Jovian password \[1\], **should be changed** for security purposes  |
| `san_thin_provision`       | False                   | Using thin provisioning for new volumes                             |
| `loglevel`                 |                         | Logging level. Both `loglvl` and `logfile` have to be specified in order to make logging operational |
| `logfile`                  |                         | Path to file to store logs.                                         |


[1] Can be enabled by going to JovianDSS Web interface/System Settings/REST Access

[2] [Can be created by going to JovianDSS Web interface/Storage](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)

[More info about Open-E JovianDSS](http://blog.open-e.com/?s=how+to)



## Installing/Uninstalling

Installation can be done by `make` inside source code folder

```bash
make install
```

Removing proxmox plugin with `jdssc`
```bash
make uninstall
```

Or by installing it from debian package

```bash
apt install ./open-e-joviandss-proxmox-plugin_0.9.1-1.deb
```

Once installation is done, provide configuration.

After installation and configuration restart proxmox server.

```bash
reboot
```

## Supported features

- [x] Create volume
- [x] Delete volume
- [x] Create snapshot
- [x] Delete snapshot
- [x] Restore snapshot
- [x] Create template
- [x] Delete template
- [x] ISO support
- [x] Backup volume
- [x] Container support
