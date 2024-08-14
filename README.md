# JovianDSS-Proxmox

## Docs

Please visit [wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki) for more information.
1. [Quick Start](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start)
2. [JovianDSS recovery from a major storage failure](https://github.com/open-e/JovianDSS-Proxmox/wiki/JovianDSS-recovery-from-a-major-storage-failure)
3. [Updating](https://github.com/open-e/JovianDSS-Proxmox/wiki/Updating)

## Configuring

Enabling JovianDSS for `proxmox` require 2 configuration files.
First is a proxmox storage configuration file that gives basic information about storage.
And the second is a config used by a minimal joviandss cli `jdssc`.

### JovianDSS configuration

Prior to installation please ensure that services mentioned below are enabled on JovianDSS storage:
1. REST in `System Settings->Administration`


### Proxmox config

This config provides brief introduce Open-E JovianDSS plugin to proxmox storage sub-system.
And contains minimal set of information required by perl part to run.

`/etc/pve/storage.cfg` 

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.yaml
        content iso,backup,images,rootdir,vztmpl
        content_volume_name proxmox-content-jdss-pool-0
        content_volume_size 100
        path /mnt/jdss-Pool-0
        debug 0
        multipath 0
```

| Option                     | Default value                     | Description                                                         |
|----------------------------|-----------------------------------|---------------------------------------------------------------------|
| `pool_name`                | Pool-0                            | Pool name that is going to be used. Must be created in \[1\]        |
| `config`                   | /etc/pve/jdss-\<pool\_name\>.yaml | Path to `jdssc` configuration file                                  |
| `content`                  | None                              | List content type that you expect JovianDSS to store. Supported values: iso,backup,images,rootdir,vztmpl |
| `content_volume_name`	     | proxmox-content-volume-\<pool\_name\>| Dedicated volume that would be used to store content resources. Only lowercase, numbers and symbols - . are allowed |
| `content_volume_size`      | 100                               | Size of content volume, measured in Gigabytes                       |
| `path`                     | /mnt/proxmox-content-jdss-\<pool\_name\> | Location that would be used to mount proxmox dedicated volume |
| `debug`                    | 0                                 | Debuging flag, place 1 to enable                                    |
| `multipath`                | 0                                 | Multipath flag, place 1 to enable                                   |

[1] [Can be created by going to JovianDSS Web interface/Storage](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)

`content_volume` is a dedicated volume that is responsible for storing `iso`, `vztmpl` and `backup` files created and managed by proxmox.
This volume gets automaticaly created on the pool `pool_name` and introduced to system as iscsi target.
User is responsible for maintaining file system of `content_volume`.
And if user wants to change size or modify this storage in other way, he should address it in `Storage/<pool_name>/iSCSI Targets` section of JovianDSS web UI.

### Jdssc config

This config file should be placed according to the path provided in `storage.cfg` file mentioned in the section above.
`joviandss.yaml` provides detailed information on interaction with storage.

```yaml
driver_use_ssl: True
driver_ssl_cert_verify: False
target_prefix: 'iqn.2021-10.iscsi:'
jovian_block_size: '16K'
jovian_rest_send_repeats: 3
rest_api_addresses:
  - '192.168.21.100'
rest_api_port: 82
target_port: 3260
rest_api_login: 'admin'
rest_api_password: 'admin'
thin_provision: True
loglevel: info
logfile: /var/log/jdss-Pool-0.log
```

| Option                     | Default value           | Description                                                         |
|----------------------------|-------------------------|---------------------------------------------------------------------|
| `driver_use_ssl`           | True                    | Use SSL to send requests to JovianDSS\[1\]                          |
| `driver_ssl_cert_verify`   | True                    | Verify authenticity of JovianDSS[1] certificate\[1\]                |
| `driver_ssl_cert_path`     | None                    | Path to the JovianDSS[1] certificate for verification               |
| `iscsi_target_prefix`      | iqn.2021-10.iscsi:      | Prefix that will be used to form target name for volume             |
| `jovian_block_size`        | 16K                     | Block size of a new volume, can be: 16K, 32K, 64K, 128K, 256K, 512K, 1M  |
| `jovian_rest_send_repeats` | 3                       | Number of times that driver will try to send REST request. This option is deprecated. Changing it will not affect behaviour  |
| `rest_api_addresses`           |                         | Yaml list of IP address of the JovianDSS, only addresses specified here would be used for multipathing |
| `rest_api_port`             | 82                      | Rest port according to the settings in \[1\]                        |
| `target_port`              | 3260                    | Port for iSCSI connections                                          |
| `rest_api_login`                | admin                   | Must be set according to the settings in \[1\]                      |
| `rest_api_password`             | admin                   | Jovian password \[1\], **should be changed** for security purposes  |
| `thin_provision`       | False                   | Using thin provisioning for new volumes                             |
| `loglevel`                 |                         | Logging level. Both `loglvl` and `logfile` have to be specified in order to make logging operational. Possible log levels are: critical, error, warning, info, debug |
| `logfile`                  |                         | Path to file to store logs.                                         |


[1] Can be enabled by going to JovianDSS Web interface/System Settings/REST Access

[2] [Can be created by going to JovianDSS Web interface/Storage](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)

[More info about Open-E JovianDSS](http://blog.open-e.com/?s=how+to)

### Multiple Pools

Plugin allows proxmox use more then one joviandss `Pool` at a same time.
To introduce new `Pool` to proxmox user have to duplicate storage section in `storage.cfg`.

Make sure that variables `pool_name`, `path` and `content_volume_name` are different.
Here is an example of presenting 2 pools `Pool-0` and `Pool-1` to `Proxmox` as 2 independent storages `jdss-Pool-0` and `jdss-Pool-1` using `joviandss` plugin.

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.yaml
        content iso,backup,images,rootdir,vztmpl
        content_volume_name proxmox-content-jdss-pool-0
        content_volume_size 100
        path /mnt/jdss-Pool-0
        debug 0
        multipath 0

joviandss: jdss-Pool-1
        pool_name Pool-1
        config /etc/pve/jdss-Pool-1.yaml
        content iso,backup,images,rootdir,vztmpl
        content_volume_name proxmox-content-jdss-pool-1
        content_volume_size 100
        path /mnt/jdss-Pool-1
        debug 0
        multipath 0
```

And here is 2 `config` files referenced in `storage.cfg` file above:

`/etc/pve/jdss-Pool-0.yaml`
```yaml
driver_use_ssl: True
driver_ssl_cert_verify: False
target_prefix: 'iqn.2021-10.iscsi:'
jovian_block_size: '16K'
jovian_rest_send_repeats: 3
rest_api_addresses:
  - '192.168.21.100'
rest_api_port: 82
target_port: 3260
rest_api_login: 'admin'
rest_api_password: 'admin'
thin_provision: True
loglevel: info
logfile: /var/log/jdss-Pool-0.log
```

`/etc/pve/jdss-Pool-1.yaml`
```yaml
driver_use_ssl: True
driver_ssl_cert_verify: False
target_prefix: 'iqn.2021-10.iscsi:'
jovian_block_size: '16K'
jovian_rest_send_repeats: 3
rest_api_addresses:
  - '192.168.31.100'
rest_api_port: 82
target_port: 3260
rest_api_login: 'admin'
rest_api_password: 'admin'
thin_provision: True
loglevel: info
logfile: /var/log/jdss-Pool-1.log
```


## Multipathing

In order to enable multipathing user should provide a set of modifications to `storage.cfg` and `jdss-Pool-0.yaml`

For instance if user wants to enable multipathing on for storage `jdss-Pool-0` described in config files as:


`/etc/pve/storage.cfg`
```
joviandss: jdss-Pool-0
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.yaml
        content iso,backup,images,rootdir,vztmpl
        content_volume_name proxmox-content-jdss-pool-0
        content_volume_size 100
        path /mnt/jdss-Pool-0
        debug 0
        multipath 0
```

`/etc/pve/jdss-Pool-0.yaml`
```yaml
driver_use_ssl: True
driver_ssl_cert_verify: False
target_prefix: 'iqn.2021-10.iscsi:'
jovian_block_size: '16K'
jovian_rest_send_repeats: 3
rest_api_addresses:
  - '192.168.21.100'
rest_api_port: 82
target_port: 3260
rest_api_login: 'admin'
rest_api_password: 'admin'
thin_provision: True
loglevel: info
logfile: /tmp/jdss.log
```

You should apply folowing changes:

### storage.cfg

Set `multipath` option to `1`

`/etc/pve/storage.cfg`
```
joviandss: jdss-Pool-0
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.yaml
        content iso,backup,images,rootdir,vztmpl
        content_volume_name proxmox-content-jdss-pool-0
        content_volume_size 100
        path /mnt/jdss-Pool-0
        debug 0
        multipath 1
```

### jdss-Pool-0.yaml

Provide list of ip's that would be used for multipathing in `rest_api_addresses` property.

`/etc/pve/jdss-Pool-0.yaml`
```yaml
driver_use_ssl: True
driver_ssl_cert_verify: False
target_prefix: 'iqn.2021-10.iscsi:'
jovian_block_size: '16K'
jovian_rest_send_repeats: 3
rest_api_addresses:
  - '192.168.21.100'
  - '192.168.31.100'
rest_api_port: 82
target_port: 3260
rest_api_login: 'admin'
rest_api_password: 'admin'
thin_provision: True
loglevel: info
logfile: /tmp/jdss.log
```
### Proxmox multipathing configuration

Proxmox JovianDSS plugin does not require any specific changes in multipath configuration file in order to operate.

Make sure that multipath service is present:
```bash
apt install multipath-tools sg3-utils
```

And running:
```bash
systemctl enable multipathd
systemctl start multipathd
```

### Storage.cfg
Activate feature by setting `1` for `multipath` property in `storage.cfg` 

### Content volume

If `content` being set in `storage.cfg` JovianDSS Proxmox plugin will try to use volume specified as `content_volume_name` in `storage.conf` as a storage for
data described in `content` variable.
User can create volume `content_volume_name` manually or let JovianDSS plugin create it automatically.
After activation plugin will try to mount content volume to directory specified as `path` in `storage.conf` file.
If volume was not formatted administrator is expected to format it manually.

Plugin will show path of device representation is OS through error message in web interface ![fs-error](pic/fs-error.png)

Or in command line:
```bash
pvesm list jdss-Pool-0
```

Will output address `/dev/mapper/iqn.2021-10.com.open-e:proxmox-content-jdss-pool-0` for volume `proxmox-content-jdss-Pool-0`.
```bash
Unable identify file system type for content storage, if that is a first run, format /dev/mapper/iqn.2021-10.com.open-e:proxmox-content-jdss-Pool-0 to a file system of your choise. at /usr/share/perl5/PVE/Storage/Custom/OpenEJovianDSSPlugin.pm line 1010.
```

Formatting can be done by calling

```bash
mkfs.ext3 /dev/mapper/iqn.2021-10.com.open-e:proxmox-content-jdss-Pool-0
```

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
apt install ./open-e-joviandss-proxmox-plugin_0.9.8.deb
```

Once installation is done, provide configuration.

After installation and configuration restart proxmox service.

```bash
systemctl restart pvedaemon
```
### Clustering

Plugin have to be installed and configured on all nodes in cluster.


## Supported features

- [x] Create volume
- [x] Delete volume
- [x] Create snapshot
- [x] Delete snapshot
- [X] Restore snapshot, only for latest one
- [x] Create template
- [x] Delete template
- [x] ISO support
- [x] Backup volume
- [x] Container support
