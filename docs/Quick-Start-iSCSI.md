This guide shows you how to set up the Open-E JovianDSS Proxmox plugin on a ProxmoxVE cluster in just a few steps.

## Open-E JovianDSS preparation

### Enable REST API
Ensure `REST` services are enabled on your Open-E JovianDSS storage.
You’ll find the REST settings under `System Settings > Administration`.
Configure a username and password for REST API access.
This guide uses admin/admin, but choose a stronger password at setup.

By default, the storage `REST API` listens on port 82, and this guide assumes you retain that setting.
The `REST API` communicates over `SSL/TLS` only, so changing the port won’t switch to an unencrypted connection.
If you choose to proceed with an insecure connection because the certificate is self-signed, disable certificate verification by setting the `ssl_cert_verify` property to `0` (see [ssl_cert_verify](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#ssl_cert_verify)).


### Create pool
The Open-E JovianDSS Proxmox plugin manages existing JovianDSS `Pools`.
You must ensure at least one pool exists.
For instructions on creating a pool, see:

[Quick Start video](https://youtu.be/QvSFNAg2lhc?feature=shared&t=1358)

[JumpStart Paper Chapter 3](https://www.open-e.com/site_media/download/documents/productguide/JDSS_JumpStart_A4_21112024.pdf)

In this guide, we assume that `Pool-0` already exists and that the Proxmox JovianDSS plugin will manage it.

### Assign VIP to Pool

Open-E JovianDSS’s Proxmox plugin creates volumes on the JovianDSS side and exports them over iSCSI.
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

Possible source of issues: routing problems. If you encounter connectivity issues, check the [Network Configuration Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking).

### Installation

The iSCSI plugin is distributed in the same package as the NFS plugin. If the NFS plugin is already installed, no additional installation steps are required, and you can proceed directly to the [Configuration](#configuration) section.

Install latest plugin on all nodes in a cluster by running following command on any Proxmox VE server:

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes
```

Restart Proxmox VE services to make them aware of the newly installed plugin:

```bash
systemctl restart pvedaemon
systemctl restart pvestatd.service
systemctl restart pveproxy.service
systemctl restart pve-ha-lrm.service
systemctl restart pve-ha-crm.service
```

Alternatively, user can call installation script *over SSH* with [`--restart`](https://github.com/open-e/JovianDSS-Proxmox/wiki/Installation-script#restart) flag to tell `install` script to restart some Proxmox VE services.

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes --restart
```

It is IMPORTANT to remember that the install.pl script with `--restart` should NOT be called from the Proxmox Web UI as `--restart` will restart the shell interfaces provided by the Proxmox Web UI.

For pre-release installs, version checks, downgrade and plugin removal instructions, please refer to the [Installation script](https://github.com/open-e/JovianDSS-Proxmox/wiki/Installation-script) guide.

## Configuration

Next, make Proxmox aware of the plugin by creating a storage pool configuration.

The recommended approach is to use the `pvesm` command, which automatically handles secure password storage and configuration validation.

### Using pvesm command (Recommended)

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
  --create-base-path 1 \
  --shared 1
```

**Security Note:** The password is stored securely in `/etc/pve/priv/storage/joviandss/jdss-Pool-0.pw` and does not appear in the main `storage.cfg` file.

#### Understanding the parameters

Below are explanations for each parameter used in the command above:
- **storage_pool_name** (`jdss-Pool-0`) - Name as it appears in Proxmox VE UI and CLI (choose something concise)
- [pool_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#pool_name) - Pool name that exists on your Open-E JovianDSS storage system (e.g., `Pool-0`)
- [user_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_name)/[user_password](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_password) - Credentials configured in JovianDSS REST API settings. Both of them must be identical across all nodes in the [High Availability Cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/) that share same [pool_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#pool_name) for failover to function correctly
- [content](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#content) - Types of data to store (`images` for VM disks, `rootdir` for containers)
- [ssl_cert_verify](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#ssl_cert_verify) - Set to `0` to accept self-signed certificates
- [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses) - A comma-separated list of VIP addresses used for communication with the JovianDSS REST API.
It is recommended to have `control_addresses` as VIPs, as this is required for the [High Availability Cluster feature](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/) to function properly.
- [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) - Comma-separated list of VIP addresses used for communication with the JovianDSS iSCSI.
- [path](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#path) - Directory path for plugin reference (not actually used by the plugin, but required by Proxmox VE)
- [create-base-path](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#create-base-path) - Set to 1 to automatically create `path` directory
- [shared](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#shared) - Set to `1` to allow VM migration within the Proxmox cluster

For the complete list of available options, see the [configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration).

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
        create-base-path 1
        shared 1
```

The record can also be created by editing `/etc/pve/storage.cfg` manually; the password must then be placed in `/etc/pve/priv/storage/joviandss/jdss-Pool-0.pw` yourself.

[More about ProxmoxVE storage configuration can be found here](https://pve.proxmox.com/wiki/Storage)

[More about Open-E JovianDSS Proxmox plugin configuration can be found here](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

## Gathering Logs

Out of the box, the JovianDSS Proxmox plugin writes logs in the `/var/log/joviandss/` folder.

To collect detailed logs, enable debugging by setting the `debug` flag to `1` and configure the `log_file` path in the `storage pool` section of your `storage.cfg` file:

```
...
debug 1
log_file /var/log/joviandss/joviandss-pool-0.log
...
```
