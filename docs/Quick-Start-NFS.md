This guide shows you how to set up the JovianDSS NFS Proxmox plugin on a Proxmox VE cluster in just a few steps.

## JovianDSS preparation

### Enable REST API
Ensure `REST` services are enabled on your JovianDSS storage.
You’ll find the REST settings under `System Settings > Administration`.
Configure a username and password for REST API access.
This guide uses admin/admin, but choose a stronger password at setup.

By default, the JovianDSS `REST API` listens on port 82, and this guide assumes you retain that setting.
The `REST API` communicates over `SSL/TLS` only, so changing the port won’t switch to an unencrypted connection.
If you choose to proceed with an insecure connection because the certificate is self-signed, disable certificate verification by setting the `ssl_cert_verify` property to `0` (see [ssl_cert_verify](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#ssl_cert_verify)).

### Create pool
The JovianDSS NFS plugin uses an existing JovianDSS `Pool` and NAS volume (dataset).
You must ensure at least one pool exists.
For instructions on creating a pool, see:

[Quick Start video](https://youtu.be/QvSFNAg2lhc?feature=shared&t=1358)

[JumpStart Paper Chapter 3](https://www.open-e.com/site_media/download/documents/productguide/JDSS_JumpStart_A4_21112024.pdf)

In this guide, we assume that `Pool-1` already exists.

### Create NFS dataset/export
Create (or reuse) an NAS volume in JovianDSS that will be mounted by Proxmox over NFS.

In this guide, we assume the NAS volume is named `datastore-pve-01`, and its export path is:

`/Pools/Pool-1/datastore-pve-01`

## Proxmox VE server preparation

### Network check

Ensure that both the `REST API` address and the NFS data address are accessible from every Proxmox node in your cluster. To test connectivity, run the ping command from each node against the specified addresses.

Test connectivity:

```
root@pve-node1:~# ping -c 5 192.168.31.152
```

Possible source of issues: routing problems. If you encounter connectivity issues, check the [Network Configuration Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking).

**Ensure that both the REST API and NFS data addresses are accessible from every node in the cluster.**

### Installation

Clone the repository, build the package, and install it on all nodes:

```bash
git clone https://github.com/open-e/JovianDSS-Proxmox.git
cd JovianDSS-Proxmox
make deb
./dev/install-local.pl ./open-e-joviandss-proxmox-plugin-latest.deb --all-nodes
```

Restart the pvedaemon service on **every Proxmox node** to load the newly installed plugin:

```bash
systemctl restart pvedaemon
```

> The `--all-nodes` flag installs the package cluster-wide via SSH, but the service restart must be performed on each node individually.

To check the current version of the installed plugin, run the following script:
```bash
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin
```

To update to a newer NFS plugin version, pull the latest changes from `main`, run `make deb` again, and reinstall with `dev/install-local.pl`.

To remove the plugin, use:

```bash
./dev/install-local.pl --remove --all-nodes
```

## Configuration

Next, make Proxmox aware of the plugin by creating a storage pool configuration.

The recommended approach is to use the `pvesm` command, which automatically handles secure password storage and configuration validation.

### Using pvesm command (Recommended)

Create the storage configuration using the `pvesm add` command with this general format:

```bash
pvesm add joviandss-nfs <storage_pool_name> \
  --server <nfs_data_vip_or_host> \
  --export /Pools/<pool>/<nas_volume> \
  --path <directory_path> \
  --user_name <rest_api_username> \
  --user_password <rest_api_password> \
  --control_addresses <rest_api_vips> \
  --data_addresses <rest_api_vips> \
  --ssl_cert_verify 0 \
  --content images,rootdir \
  --shared 1
```

#### Understanding the parameters

Below are explanations for each parameter used in the command above:
- **storage_pool_name** - Name as it appears in Proxmox VE UI and CLI (choose something concise like `jdss-nfs-01`)
- `server` with **<nfs_data_vip_or_host>** - NFS data address used by the plugin for storage mount/activation
- `export` with **/Pools/<pool>/<nas_volume>** - JovianDSS NFS export path in the form `/Pools/<pool>/<dataset>`
- [path](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#path) with **<directory_path>** - Local mountpoint directory on Proxmox VE (for example `/mnt/pve/jdss-nfs-01`)
- [user_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_name)/[user_password](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_password) with **<rest_api_username/rest_api_password>** - Credentials configured in JovianDSS REST API settings. Required for snapshot operations.
- [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses) with **<rest_api_vips>** - A comma-separated list of VIP addresses used for communication with the JovianDSS REST API
- [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) with **<nfs_data_vips>** - A comma-separated list of NFS data transfer addresses. Proxmox uses these IPs to mount and access the NFS share. Can differ from `control_addresses` in multi-network setups.
- [ssl_cert_verify](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#ssl_cert_verify) with **0** - Set to `0` to accept self-signed certificates
- [content](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#content) with **images,rootdir** - Types of data to store (`images` for VM disks, `rootdir` for containers)
- [shared](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#shared) with **1** - Set to `1` to allow VM migration within the Proxmox cluster
- [options](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#options) - Optional comma-separated NFS mount options passed directly to the mount command (e.g. `vers=4,nofail,soft`). Useful for tuning NFS behaviour in production environments.

For this plugin type (`joviandss-nfs`), `server`, `export`, and `path` are core properties.
Pool and dataset are derived from the `export` path.

#### Example configuration

Let's configure a concrete example where:
- JovianDSS has pool `Pool-1` and NAS volume `datastore-pve-01`
- REST API available at VIP `192.168.31.152` with credentials `admin/admin`
- NFS data transfer should be conducted over address `192.168.31.152`

```bash
pvesm add joviandss-nfs jdss-nfs-01 \
  --server 192.168.31.152 \
  --export /Pools/Pool-1/datastore-pve-01 \
  --path /mnt/pve/jdss-nfs-01 \
  --user_name admin \
  --user_password admin \
  --control_addresses 192.168.31.152 \
  --data_addresses 192.168.31.152 \
  --ssl_cert_verify 0 \
  --content images,rootdir \
  --shared 1
```

**Security Note:** The password will be automatically stored securely in `/etc/pve/priv/storage/joviandss-nfs/` and will not appear in the main `storage.cfg` file.

### Viewing the configuration

After running the `pvesm add` command, you can verify the configuration by viewing the storage.cfg file. The resulting config record will look like this:

```ini
joviandss-nfs: jdss-nfs-01
        server 192.168.31.152
        export /Pools/Pool-1/datastore-pve-01
        path /mnt/pve/jdss-nfs-01
        user_name admin
        control_addresses 192.168.31.152
        data_addresses 192.168.31.152
        ssl_cert_verify 0
        content images,rootdir
        shared 1
```

**Note:** The `user_password` line will not appear in `storage.cfg` as passwords are now stored securely in separate files for enhanced security.

### Manual configuration (Alternative)

Alternatively, you can manually edit `/etc/pve/storage.cfg` and add the above configuration block, but using `pvesm add` is recommended as it handles password security automatically.

**Note:** The password for storage pool `jdss-nfs-01` can be found in `/etc/pve/priv/storage/joviandss-nfs/jdss-nfs-01.pw`.

[More about Proxmox VE storage configuration can be found here](https://pve.proxmox.com/wiki/Storage)

[More about JovianDSS Proxmox plugin configuration can be found here](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

## Troubleshooting

### Connectivity issues
Possible source of issues: routing problems. If you encounter connectivity issues, check the [Network Configuration Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking).

### NFS mount checks
Verify that storage mount is active:

```bash
findmnt -M /mnt/pve/jdss-nfs-01
```

Verify NFS export visibility:

```bash
showmount --exports 192.168.31.152
```

### Gathering Logs

Out of the box, the JovianDSS Proxmox plugin writes logs in the `/var/log/joviandss/` folder.

To collect detailed logs, enable debugging by setting the `debug` flag to `1` and configure the `log_file` path in the `storage pool` section of your `storage.cfg` file:

```ini
...
debug 1
log_file /var/log/joviandss/joviandss-nfs01.log
...
```

With debugging enabled, the plugin configuration dump will include the debug line, for example:

```ini
joviandss-nfs: jdss-nfs-01
        server 192.168.31.152
        export /Pools/Pool-1/datastore-pve-01
        path /mnt/pve/jdss-nfs-01
        user_name admin
        control_addresses 192.168.31.152
        data_addresses 192.168.31.152
        ssl_cert_verify 0
        content images,rootdir
        shared 1
        debug 1
        log_file /var/log/joviandss/joviandss-nfs01.log
```

## Snapshots and rollback

The JovianDSS NFS plugin supports ZFS-backed VM snapshots and rollback through the Proxmox VE snapshot interface — no additional configuration is required beyond what is described above.

When you take a Proxmox VM snapshot, the plugin creates a ZFS snapshot of the NAS volume on JovianDSS and temporarily clones it as a read-only NFS share so Proxmox can access disk images at the snapshot point.

When you roll back to a snapshot, the plugin uses the JovianDSS REST API to atomically restore the volume to the chosen snapshot state, removing any newer snapshots in the process.

> **Note:** Snapshot operations require valid REST API credentials (`user_name` / `user_password`) and working `control_addresses` connectivity from all Proxmox nodes.

## Further reading

- [Plugin configuration reference](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)
- [Network configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)
- [Proxmox VE storage documentation](https://pve.proxmox.com/wiki/Storage)
- [JovianDSS JumpStart Paper](https://www.open-e.com/site_media/download/documents/productguide/JDSS_JumpStart_A4_21112024.pdf)
- [Issue tracker](https://github.com/open-e/JovianDSS-Proxmox/issues)
