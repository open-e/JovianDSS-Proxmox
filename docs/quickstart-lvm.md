This guide provides brief description on how to quickly setup JovianDSS-LVM Proxmox VE plugin on a single Proxmox VE machine.

Please note that since version `v0.9.9-1` plugin is enforcing usage of VIP addresses to transfer iscsi data.
User have to assign VIP addresses to JovianDSS Pool in order to make plugin work.



## Overview

Since version 0.9.9-3 multiple plugins are shipped under single debian package.
Currently there are `joviandss` and `joviandss-lvm` plugins.
Here is a table that provides comparison of plugin functionality:

| Feature                                    | Original JovianDSS Plugin         | JovianDSS-LVM Plugin                                                |
|--------------------------------------------|-----------------------------------|---------------------------------------------------------------------|
| Stotage of iso, vztmpl, backup files       | :white_check_mark:                | :x:                                                                 |
| Stotage of images, rootdit                 | :white_check_mark:                | :white_check_mark:                                                  |
| Image/rootdir to JovianDSS volume relation | each image and rootdir file are stored on dedicated volume | there is a single volume for virtual machine that stores all images/rootdir files related to it |
| Snapshots                                  | Each zfs volume have its own snapshot | All disk of a virtual machine have have a single snapshot                                |
| Rollback                                   | Rollback can be done to the latest snapshot only | Rollback can be done to the latest snapshot only     |
| Clonning                                   | :white_check_mark:                | :white_check_mark:                                                  |
| Volume movement from one vm to another     | :white_check_mark:                | :x:                                                                 |
| Volume resizing                            | :white_check_mark:                | :white_check_mark:                                                  |
| VM atomic snapshots                        | :x:                               | :white_check_mark:                                                  |


Core difference between them is usage of LVM on top of JovianDSS volumes for `joviandss-lvm` plugin.
`joviandss` plugin is an old plugin that remains the same and get [configured the same way](https://github.com/open-e/JovianDSS-Proxmox/docs/plugin-installation-and-configuration.md)
`joviandss-lvm` plugin utilises different aproach to store volumes related to virtual machine.
Instead if creation of single volume for each proxmox viartual disk, it creates single JovianDSS Zvol for virtula machine or container and allocates virtual disks on this new zvol using LVM.
This allows user to create 'atomic' snapshots of all disks at once, yet it comes with the price of impossibility to move proxmox virtual disks between machines as linkage between virtual disk and its snapshot will be lost.

## Installing plugin

Download latest `deb` package from [github](https://github.com/open-e/JovianDSS-Proxmox/releases).

Use `apt` package manager to install package.
```bash
apt install ./open-e-joviandss-proxmox-plugin_0.9.9-1.deb
```

This is short a guide on 'joviandss-lvm` plugin installation.

Please note that extended guide for `joviandss-lvm` can be found [here](https://github.com/open-e/JovianDSS-Proxmox/docs/joviandss-lvm-plugin-installation-and-configuration.md)

Configuration guide for original `joviandss` plugin can be found [here](https://github.com/open-e/JovianDSS-Proxmox/docs/plugin-installation-and-configuration.md)

## Configuring plugin

Add storage pool record to `storage.cfg`. 
Make sure to pay attention to following options:
- `pool_name` JovianDSS pool name that will be used to store proxmox volumes
- `user_name` and `user_password` are credentials that is used to authenticate to JovianDSS REST API 
- `control_addresses` coma separated list of network address used to send REST commands to JovianDSS
- `data_addresses` coma separated list of VIP network address assigned to `Pool-0`

`/etc/pve/storage.cfg` 

```
joviandss-lvm: jdss-Pool-0-nfs
        pool_name Pool-0
        user_name admin
        user_password admin
        content images,rootdir
        path /mnt/pve/jdss-Pool-0-lvm
        ssl_cert_verify 0
        control_addresses 192.168.20.100
        data_addresses 192.168.40.100
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

