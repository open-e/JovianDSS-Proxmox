This guide provides brief description on how to quickly setup JovianDSS Proxmox plugin on a single proxmox server.

Please note that since version `v0.9.9-1` plugin is enforcing usage of VIP addresses to transfer iscsi data.
User have to assign VIP addresses to JovianDSS Pool in order to make plugin work.

## Installing plugin

Download latest `deb` package from [github](https://github.com/open-e/JovianDSS-Proxmox/releases).

Use `apt` package manager to install package.
```bash
apt install ./open-e-joviandss-proxmox-plugin_0.9.9-1.deb
```

## Configuring plugin

Add storage pool record to `storage.cfg`. Make sure that option `pool_name` stores proper pool name that you are using on your JovianDSS instance.

`/etc/pve/storage.cfg` 

```
joviandss: jdss-Pool-0-nfs
          pool_name Pool-0
          config /etc/pve/jdss-170.yaml
          content iso,backup,images,rootdir,vztmpl
          content_volume_name proxmox-content-jdss-pool-0-nfs
          content_volume_size 100
          # option is available since v0.9.9
          content_volume_type nfs
          path /mnt/jdss-Pool-0-nfs
          shared 1
```


Create a `yaml` file `/etc/pve/jdss-Pool-0.yaml` that contains detailed information on how to connect to your `JovianDSS` server.
Keep in mind that path to this file should be provided in file above in property `config`.

`/etc/pve/jdss-Pool-0.yaml`
```yaml
driver_use_ssl: True # Use TLS/SSL to communication with JovianDSS storage
driver_ssl_cert_verify: False # Enforce certificate verification for TLS/SSL communication.  Option is available since v0.9.8
# Target prefix name format
# Plagin uses python strftime to resolve name patter
# Please make sure that resulting target prefix contain only allowed symbols
target_prefix: 'iqn.%Y-%m.iscsi:'
jovian_block_size: '16K'
# List of ip addresses that will be used to send management commands to JovianDSS
# In order to send management commands like create or delete new volume plugin uses JovianDSS REST API
# rest_api_addresses is a set of addresses that is utilised to send REST requests to JovainDSS
# In case of network communication error on one of the addresses provided below plugin will switch to the next one
# Plugin will iterate 3 time through rest_api_list in order to deliver management commands
rest_api_addresses: 
  - '192.168.21.100'
rest_api_port: 82 # REST API port
iscsi_vip_addresses: # List of ip addresses that will be used to send storage data over iscsi protocol.  Option is available sinse v0.9.9-1
  # If none is given rest_api_addresses will be used.
  # Only VIP addresses are alowed for iSCSI data transfer
  # Make sure that given addresses are being specified on specific JovianDSS Pool
  - '192.168.21.100'
  - '192.168.31.100'
nfs_vip_addresses: # Option is available sinse v0.9.2
  - '192.168.21.100'
  - '192.168.31.100'

target_port: 3260 # iSCSI target port, 3260 is dafault for new JovianDSS
rest_api_login: 'admin' # Login that is specified for REST API access
rest_api_password: 'admin' # Password that is specified for REST API access
thin_provision: True # Plugin will create new volumes as sparce/thin
loglevel: info # Log level, please set it to debug if you experice issues with plugin
logfile: /var/log/jdss-Pool-0.log # File name that will store debug output
```

## Troubleshooting

### Connectivity issues
Possible source of failure during start is incorrect network configuration.
User can verify connectivity by pinging IP addresses specified in `/etc/pve/jdss-Pool-0.yaml` config.
```bash
root@pve:~# ping -c 3 192.168.21.100
```
In everything is OK `ping` output will look like:
```
root@test2:/etc/network/interfaces.d# ping 192.168.21.100 -c 3
PING 192.168.21.100 (192.168.21.100) 56(84) bytes of data.
64 bytes from 192.168.21.100: icmp_seq=1 ttl=64 time=0.152 ms
64 bytes from 192.168.21.100: icmp_seq=2 ttl=64 time=0.162 ms
64 bytes from 192.168.21.100: icmp_seq=3 ttl=64 time=0.107 ms

--- 192.168.21.100 ping statistics ---
3 packets transmitted, 3 received, 0% packet loss, time 2044ms
rtt min/avg/max/mdev = 0.107/0.140/0.162/0.023 ms

```
In case of error
```
root@pve:~# ping -c 3 192.168.21.100
PING 192.168.21.100 (192.168.21.100) 56(84) bytes of data.

--- 192.168.21.100 ping statistics ---
3 packets transmitted, 0 received, 100% packet loss, time 4079ms
```
Possible source of problem might be routing issues, in that case check [network configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Network-configuration)
