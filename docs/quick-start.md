This guide shows you how to set up the JovianDSS Proxmox plugin on a ProxmoxVE cluster in just a few steps.

## JovianDSS preparation

### Enable REST API
Ensure `REST` services are enabled on your JovianDSS storage.
You’ll find the REST settings under `System Settings > Administration`.
Configure a username and password for REST API access.
This guide uses admin/admin, but choose a stronger password at setup.

By default, the JovianDSS `REST API` listens on port 82, and this guide assumes you retain that setting.
The `REST API` communicates over `SSL/TLS` only, so changing the port won’t switch to an unencrypted connection.
If you choose to proceed with an insecure connection because the certificate is self-signed, disable certificate verification by setting the `ssl_cert_verify` property to `0`, see [Options](#options)


### Create pool
The JovianDSS Proxmox plugin manages existing JovianDSS `Pools`.
You must ensure at least one pool exists.
For instructions on creating a pool, see:

[Quick Start video](https://youtu.be/QvSFNAg2lhc?feature=shared&t=1358)

[JumpStart Paper Chapter 3](https://www.open-e.com/site_media/download/documents/productguide/JDSS_JumpStart_A4_21112024.pdf)

In this guide, we assume that `Pool-0` already exists and that the Proxmox JovianDSS plugin will manage it.

### Assign VIP to Pool

JovianDSS’s Proxmox plugin creates volumes on the JovianDSS side and exports them over iSCSI.
It transfers iSCSI data only over `VIP` addresses assigned to a JovianDSS 'Pool'.
To use the plugin, assign at least one `VIP` address to the `Pool` you created or referenced earlier.

See this [video example](https://www.youtube.com/watch?v=iFF9VPKUdTk)

In this guide, we assume you’ve assigned `VIP` 192.168.41.100 to `Pool-0` for iSCSI data transfers.

## Proxmox VE server preparation

### Network check

Ensure that both the `REST API` address and the `VIP` address assigned earlier are accessible from every Proxmox node in your cluster. To test connectivity, run the ping command from each node against the specified addresses.

Test the REST API address:
```
root@pve-node1:~# ping -c 5 192.168.21.100
```

If connectivity is good, you’ll see output similar to:

```
PING 192.168.21.100 (192.168.21.100) 56(84) bytes of data.
64 bytes from 192.168.21.100: icmp_seq=1 ttl=64 time=0.258 ms
64 bytes from 192.168.21.100: icmp_seq=2 ttl=64 time=0.336 ms
64 bytes from 192.168.21.100: icmp_seq=3 ttl=64 time=0.323 ms
64 bytes from 192.168.21.100: icmp_seq=4 ttl=64 time=0.357 ms
64 bytes from 192.168.21.100: icmp_seq=5 ttl=64 time=0.291 ms

--- 192.168.21.100 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4101ms
rtt min/avg/max/mdev = 0.258/0.313/0.357/0.034 ms
```
Possible source of issues: routing problems. If you encounter connectivity issues, check the [Network Configuration Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Network-configuration).

**Ensure that both the REST API and VIP addresses are accessible from every node in the cluster.**

### Installation

Download the latest `deb` package from [JovianDSS Proxmox plugin GitHub release page](https://github.com/open-e/JovianDSS-Proxmox/releases).

Install it with the `apt` package manager on every Proxmox VE node in a cluster:
```bash
apt install ./open-e-joviandss-proxmox-plugin_0.10.0.deb
```

Restart the pvedaemon service to load the newly installed plugin:

```bash
systemctl restart pvedaemon
```

## Configuration

Next, make Proxmox aware of the plugin.

This step defines an instance of a `storage pool` managed by the JovianDSS Proxmox plugin in the Proxmox VE `storage.cfg` configuration file.

You can do this by editing `/etc/pve/storage.cfg` or by running `pvesm`.

### Editing storage.cfg

Each `storage pool` record in the Proxmox VE `storage.cfg` file starts with a `pool definition` in the form:
```
<type>: <STORAGE_ID>
```
`type` specifies the storage plugin (set this to `joviandss`).
`STORAGE_ID` names the `storage pool` as it appears in the Proxmox VE UI and CLI. Choose a concise, easy-to-type name. In this guide, we use `jdss-Pool-0`

List of the plugin properties follows `pool definition`.
This guide covers a subset of properties to help you quickly set up a connection and begin evaluation. For the complete list of JovianDSS Proxmox plugin properties, see the [configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-installation-and-configuration).

Below are the minimal list of options to evaluate JovianDSS as a Proxmox VE storage backend.


#### Options

Pool name that is created on the side of the JovianDSS data storage:
```
pool_name Pool-0
```

REST API user name [mentioned before](#enable-rest-api):
```
user_name admin
```

REST API user password [mentioned before](#enable-rest-api), please do not forget to set secure password:
```
user_password admin
```

Types of data that the JovianDSS plugin will store on the JovianDSS side (virtual machine and container disks):
```
content images,rootdir
```

Flag that instructs the JovianDSS plugin to accept self-signed certificates. The plugin always uses SSL/TLS over the REST API:
```
ssl_cert_verify 0
```

Comma-separated list of IP addresses used for REST API communication:
```
control_addresses 192.168.21.100
```

Comma-separated list of VIP addresses for dynamic iSCSI data transfer between Proxmox VE and JovianDSS. These must be assigned to the referenced pool (Pool-0):
```
data_addresses 192.168.41.100
```

Folder on the Proxmox VE server assigned to the plugin:
```
path /mnt/pve/jdss-Pool-0
```

Flag indicating that volumes are bound to a single physical server and can be accessed/migrated within the Proxmox VE cluster:
```
shared 1
```

Resulting config record should look like:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        user_name admin
        user_password admin
        content images,rootdir
        ssl_cert_verify 0
        control_addresses 192.168.21.100
        data_addresses 192.168.41.100
        path /mnt/pve/jdss-Pool-0
        shared 1
```

### Running pvesm

You can achieve the same configuration by passing plugin options directly to `pvesm` as CLI arguments:

```bash
pvesm add joviandss jdss-Pool-0-cmd --pool_name Pool-0 --user_name admin --user_password <your_password> --content images,rootdir --ssl_cert_verify 0 --control_addresses 192.168.21.100 --data_addresses 192.168.41.100 --path /mnt/pve/jdss-Pool-0 --shared 1
```
Replace <your_password> with your secure password.

[More about ProxmoxVE storage configuration can be found here](https://pve.proxmox.com/wiki/Storage)

[More about JovianDSS Proxmox plugin configuration can be found here](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-installation-and-configuration)


## Troubleshooting

### Connectivity issues
Possible source of issues: routing problems. If you encounter connectivity issues, check the [Network Configuration Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Network-configuration).

### Gathering Logs

Out of the box, the JovianDSS Proxmox plugin writes logs in the `/var/log/joviandss/` folder.

To gather more detailed information on plugin operation, enable debugging by setting the `debug` flag to `1` in the storage pool section of your storage.cfg file:

```
debug 1
```

With debugging enabled, the plugin configuration dump will include the debug line, for example:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        user_name admin
        user_password admin
        content images,rootdir
        ssl_cert_verify 0
        control_addresses 192.168.21.100
        data_addresses 192.168.41.100
        path /mnt/pve/jdss-Pool-0
        shared 1
        debug 1
```
