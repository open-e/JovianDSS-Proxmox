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

See this video [iSCSI Targets Available Through Specific VIPs](https://www.youtube.com/watch?v=iFF9VPKUdTk)

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
Possible source of issues: routing problems. If you encounter connectivity issues, check the [Network Configuration Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking).

**Ensure that both the REST API and VIP addresses are accessible from every node in the cluster.**

### Installation

Install latest plugin on all nodes in a cluster by running following command on any Proxmox VE server:

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes
```

Restart the pvedaemon service to load the newly installed plugin:

```bash
systemctl restart pvedaemon
```

To check the current version of the installed plugin, run the following script:
```bash
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin
```

## Configuration

Next, make Proxmox aware of the plugin by creating a storage pool configuration.

The recommended approach is to use the `pvesm` command, which automatically handles secure password storage and configuration validation.

### Using pvesm command (Recommended)

Create the storage configuration using the `pvesm add` command with this general format:

```bash
pvesm add joviandss <storage_pool_name> \
  --pool_name <joviandss_pool_name> \
  --user_name <rest_api_username> \
  --user_password <rest_api_password> \
  --content images,rootdir \
  --ssl_cert_verify 0 \
  --control_addresses <rest_api_vips> \
  --data_addresses <iscsi_data_vips> \
  --path <directory_path> \
  --shared 1
```

#### Understanding the parameters

Below are explanations for each parameter used in the command above:

- **storage_pool_name** - Name as it appears in Proxmox VE UI and CLI (choose something concise like `jdss-Pool-0`)
- **joviandss_pool_name** - Pool name that exists on your JovianDSS storage system (e.g., `Pool-0`)
- **rest_api_username/password** - Credentials configured in JovianDSS REST API settings
- **content** - Types of data to store (`images` for VM disks, `rootdir` for containers)
- **ssl_cert_verify** - Set to `0` to accept self-signed certificates
- **rest_api_vips** - Comma-separated list of VIP addresses for JovianDSS REST API communication
- **iscsi_data_vips** - Comma-separated list of VIP addresses assigned to the JovianDSS pool for iSCSI data
- **directory_path** - Directory path for plugin reference (not actually used by the plugin)
- **shared** - Set to `1` to allow VM migration within the Proxmox cluster

For the complete list of available options, see the [configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-installation-and-configuration).

#### Example configuration

Let's configure a concrete example where:
- JovianDSS has pool `Pool-0`
- REST API available at VIP `192.168.21.100` with credentials `admin/admin`
- Data transfer should be conducted over VIP `192.168.41.100` assigned to Pool-0

```bash
pvesm add joviandss jdss-Pool-0 \
  --pool_name Pool-0 \
  --user_name admin \
  --user_password admin \
  --content images,rootdir \
  --ssl_cert_verify 0 \
  --control_addresses 192.168.21.100 \
  --data_addresses 192.168.41.100 \
  --path /mnt/pve/jdss-Pool-0 \
  --shared 1
```

**Security Note:** The password will be automatically stored securely in `/etc/pve/priv/storage/joviandss/` and will not appear in the main `storage.cfg` file.

### Viewing the configuration

After running the `pvesm add` command, you can verify the configuration by viewing the storage.cfg file. The resulting config record will look like this:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        user_name admin
        content images,rootdir
        ssl_cert_verify 0
        control_addresses 192.168.21.100
        data_addresses 192.168.41.100
        path /mnt/pve/jdss-Pool-0
        shared 1
```

**Note:** The `user_password` line will not appear in `storage.cfg` as passwords are now stored securely in separate files for enhanced security.

### Manual configuration (Alternative)

Alternatively, you can manually edit `/etc/pve/storage.cfg` and add the above configuration block, but using `pvesm add` is recommended as it handles password security automatically.

**Note:** The password for storage pool `jdss-Pool-0` can be found in `/etc/pve/priv/storage/joviandss/jdss-Pool-0.pw`.

[More about ProxmoxVE storage configuration can be found here](https://pve.proxmox.com/wiki/Storage)

[More about JovianDSS Proxmox plugin configuration can be found here](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)


## Troubleshooting

### Connectivity issues
Possible source of issues: routing problems. If you encounter connectivity issues, check the [Network Configuration Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking).

### Gathering Logs

Out of the box, the JovianDSS Proxmox plugin writes logs in the `/var/log/joviandss/` folder.

To collect detailed logs, enable debugging by setting the `debug` flag to `1` and configure the `log_file` path in the `storage pool` section of your `storage.cfg` file:

```
...
debug 1
log_file /var/log/joviandss/joviandss-pool-0.log
...
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
        log_file /var/log/joviandss/joviandss-pool-0.log
```
