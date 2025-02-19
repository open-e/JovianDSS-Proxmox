# JovianDSS-LVM-Proxmox Plugin

## Docs

Please visit [wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki) for more information.
1. [Quick Start](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start)
2. [JovianDSS recovery from a major storage failure](https://github.com/open-e/JovianDSS-Proxmox/wiki/JovianDSS-recovery-from-a-major-storage-failure)
3. [Connecting to JovianDSS Virtual IP's on Proxmox](https://github.com/open-e/JovianDSS-Proxmox/wiki/Network-configuration)


## Configuring

Enabling JovianDSS-LVM plugin for `proxmox` is configured as JovianDSS plugin and require 2 configuration files.
First is a proxmox storage configuration file that gives basic information about storage.
And the second is a config used by a minimal joviandss cli `jdssc`.

### JovianDSS configuration

Prior to installation please ensure that services mentioned below are enabled on JovianDSS storage:
1. REST in `System Settings->Administration`


### Proxmox config

This config provides brief introduce Open-E JovianDSS-LVM Plugin to proxmox storage sub-system.
And contains minimal set of information required by proxmox part to run.

`/etc/pve/storage.cfg` 

```
joviandss-lvm: jdss-Pool-0-lvm
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.lvm.yaml
        content images,rootdir
        debug 0
        multipath 1
        path /mnt/pve/jdss-Pool-0-lvm
        shared 1
```

| Option                     | Default value                     | Description                                                         |
|----------------------------|-----------------------------------|---------------------------------------------------------------------|
| `pool_name`                | Pool-0                            | Pool name that is going to be used. Must be created in \[1\]        |
| `config`                   | /etc/pve/jdss-\<pool\_name\>.yaml | Path to `jdssc` configuration file                                  |
| `content`                  | None                              | List content type that you expect JovianDSS to store. Supported values: images,rootdir |
| `path`                     | /mnt/proxmox-content-jdss-\<pool\_name\> | Location that would be used to mount proxmox dedicated volume |
| `shared`                   | 0                                 | Migrate flag, setting this flag indicate that plugin support VM and Container migration. It is recommended to enable this flag.|
| `debug`                    | 0                                 | Debuging flag, place 1 to enable                                    |
| `multipath`                | 0                                 | Multipath flag, place 1 to enable                                   |
| `disabled`                 | 0                                 | Flag that instructs Proxmox not to use this storage. Setting this flag will not result in volume deactivation or unmounting |


[1] [Can be created by going to JovianDSS Web interface/Storage](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)

`content_volume` is not available for JovianDSS-LVM Proxmox Plugin, to store container images, iso files and other data on JovianDSS please use NFS plugin.


### Jdssc config

This config file should be placed according to the path provided in `storage.cfg` file mentioned in the section above.
`joviandss.yaml` provides detailed information on interaction with storage.

```yaml
driver_use_ssl: True
# driver_ssl_cert_verify option is available since v0.9.8
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
| `driver_use_ssl`           | True                    | Use TLS/SSL to send requests to JovianDSS\[1\]                      |
| `driver_ssl_cert_verify`   | True                    | Verify TLS/SSL certificates of JovianDSS                            |
| `iscsi_target_prefix`      | iqn.2021-10.iscsi:      | Prefix that will be used to form target name for volume             |
| `jovian_block_size`        | 16K                     | Block size of a new volume, can be: 16K, 32K, 64K, 128K, 256K, 512K, 1M  |
| `jovian_rest_send_repeats` | 3                       | Number of times that driver will try to send REST request. This option is deprecated. Changing it will not affect behaviour |
| `rest_api_addresses`           |                         | Yaml list of IP address of the JovianDSS, only addresses specified here would be used for multipathing, [check for more network related information](https://github.com/open-e/JovianDSS-Proxmox/wiki/Network-configuration) |
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

Plugin allows proxmox use multiple joviandss `Pool` at a same time.
To introduce new `Pool` to proxmox user have to duplicate storage section in `storage.cfg`.

Make sure that variables `pool_name`, `path` and `content_volume_name` are different.
Here is an example of presenting 2 pools `Pool-0` and `Pool-1` to `Proxmox` as 2 independent storage's `jdss-Pool-0` and `jdss-Pool-1` using `joviandss` plugin.

```
joviandss-lvm: jdss-Pool-0
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.lvm.yaml
        content images,rootdir
        path /mnt/pve/jdss-Pool-0
        shared 1
        debug 0
        multipath 0

joviandss-lvm: jdss-Pool-1
        pool_name Pool-1
        config /etc/pve/jdss-Pool-1.lvm.yaml
        content images,rootdir
        path /mnt/pve/jdss-Pool-1
        shared 1
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
  - '192.168.22.100'
rest_api_port: 82
target_port: 3260
rest_api_login: 'admin'
rest_api_password: 'admin'
thin_provision: True
loglevel: info
logfile: /var/log/jdss-Pool-1.log
```


## Multipathing

In order to enable multipathing user should provide a set of modifications to `storage.cfg`, `jdss-Pool-0.yaml` and `multipath.conf`

For instance if user wants to enable multipathing on for storage `jdss-Pool-0` described in config files as:


`/etc/pve/storage.cfg`
```
joviandss-lvm: jdss-Pool-0
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.yaml
        content images,rootdir
        path /mnt/jdss-Pool-0
        shared 1
        debug 0
        multipath 0
```

`/etc/pve/jdss-Pool-0.yaml`
```yaml
driver_use_ssl: True
driver_ssl_cert_verify: False # Option is available since v0.9.8
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

User should apply following changes:

### storage.cfg

Set `multipath` option to `1`

`/etc/pve/storage.cfg`
```
joviandss: jdss-Pool-0
        pool_name Pool-0
        config /etc/pve/jdss-Pool-0.yaml
        content images,rootdir
        path /mnt/jdss-Pool-0
        shared 1
        debug 0
        multipath 1
```

### jdss-Pool-0.yaml

Provide list of ip's that would be used for multipathing in `rest_api_addresses` property.

`/etc/pve/jdss-Pool-0.yaml`
```yaml
driver_use_ssl: True
driver_ssl_cert_verify: False # Option is available since v0.9.8
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
### multipath.conf

Make sure that multipath service is present 

```bash
apt install multipath-tools sg3-utils
```
Make sure that multipath service is running:
```bash
systemctl enable multipathd
systemctl start multipathd
systemctl status multipathd
```
Starting with version 0.9.7, the plugin uses the SCSI ID wwid to serve multipath volumes. Because of this, users should avoid blacklisting by wwid:

```
blacklist {
        wwid .*
}
```
The user must check their configuration and ensure that such a line is NOT present. If it is, it must be removed to allow the plugin to work properly with multipath volumes.

Also to avoid unnecessary volumes to be managed by multipath, it is recommended to `blacklist` by vendor. If user choose to do so, he also have to set exception for JovianDSS volumes.
Example of multipath blacklist and blacklist exception is provided below.

```
blacklist {
    device {
        vendor ".*"
    }
}

blacklist_exceptions {
    device {
        vendor "SCST_BIO"
    }
}
```

## Installing/Uninstalling

### Install from source 

Installation can be done by `make` inside source code folder

```bash
apt install python3-oslo.utils git
git clone https://github.com/open-e/JovianDSS-Proxmox.git
cd ./JovianDSS-Proxmox
make install
```

Removing proxmox plugin with `jdssc`
```bash
make uninstall
```
### Installation for `deb` package
Or by installing it from debian package

```bash
apt install ./open-e-joviandss-proxmox-plugin_0.9.9-0.deb
```

Once installation is done, provide configuration.

After installation and configuration restart proxmox service.

```bash
systemctl restart pvedaemon
```
### Clustering

Plugin have to be installed and configured on all nodes in cluster.
