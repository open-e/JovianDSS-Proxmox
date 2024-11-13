This guide provides brief description on how to quickly setup JovianDSS Proxmox plugin on a single proxmox server.

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
keep in mind that path to this file should be provided in file above in property `config`.

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
logfile: /var/log/jdss-Pool-0.log
```

## Troubleshooting

### Connectivity issues
Possible source of failure during start is incorrect network configuration.
User can verify connectivity by pinging IP addresses specified in `/etc/pve/jdss-Pool-0.yaml` config.
```bash
root@pve:~# ping -c 5 192.168.21.100
```
In everything is OK `ping` output will look like:
```
PING 172.16.0.220 (172.16.0.220) 56(84) bytes of data.
64 bytes from 192.168.21.100: icmp_seq=1 ttl=64 time=0.258 ms
64 bytes from 192.168.21.100: icmp_seq=2 ttl=64 time=0.336 ms
64 bytes from 192.168.21.100: icmp_seq=3 ttl=64 time=0.323 ms
64 bytes from 192.168.21.100: icmp_seq=4 ttl=64 time=0.357 ms
64 bytes from 192.168.21.100: icmp_seq=5 ttl=64 time=0.291 ms

--- 192.168.21.100 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4101ms
rtt min/avg/max/mdev = 0.258/0.313/0.357/0.034 ms
```
In case of error
```
root@pve:~# ping -c 5 192.168.21.100
PING 192.168.21.100 (192.168.21.100) 56(84) bytes of data.

--- 192.168.21.100 ping statistics ---
5 packets transmitted, 0 received, 100% packet loss, time 4079ms
```
Possible source of problem might be routing issues, in that case check [network configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Network-configuration)
