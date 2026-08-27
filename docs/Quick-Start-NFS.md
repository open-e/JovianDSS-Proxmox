This guide shows you how to set up the JovianDSS NFS Proxmox plugin on a Proxmox VE cluster in just a few steps.

## JovianDSS preparation

### Enable REST API
Ensure `REST` services are enabled on your JovianDSS storage.
You’ll find the REST settings under `System Settings > Administration`.
Configure a username and password for REST API access.
This guide uses admin/admin, but choose a stronger password at setup.

By default, the JovianDSS `REST API` listens on port 82, and this guide assumes you retain that setting.
The `REST API` communicates over `SSL/TLS` only, so changing the port won’t switch to an unencrypted connection.
If you choose to proceed with an insecure connection because the certificate is self-signed, disable certificate verification by setting the `ssl_cert_verify` property to `0` (see [ssl_cert_verify](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#ssl_cert_verify)).

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

### Installation

The NFS plugin is distributed in the same package as the iSCSI plugin. If the iSCSI plugin is already installed, no additional installation steps are required, and you can proceed directly to the [Configuration](#configuration) section.

Install latest plugin on all nodes in a cluster by running following command on any Proxmox VE server:

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes
```

Restart the Proxmox VE services to load the newly installed plugin:

```bash
systemctl restart pvedaemon
systemctl restart pvestatd.service
systemctl restart pveproxy.service
systemctl restart pve-ha-lrm.service
systemctl restart pve-ha-crm.service
```

Alternatively, user can call installation script over SSH with [--restart](https://github.com/open-e/JovianDSS-Proxmox/wiki/Installation-script#restart) flag to tell install script to restart some Proxmox VE services.

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
  --ssl_cert_verify 0 \
  --content images,rootdir \
  --shared 1
```

**Security Note:** The password is stored securely in `/etc/pve/priv/storage/joviandss-nfs/jdss-nfs-01.pw` and does not appear in the main `storage.cfg` file.

#### Understanding the parameters

Below are explanations for the parameters used in the command above, plus optional parameters:
- **storage_pool_name** (`jdss-nfs-01`) - Name as it appears in Proxmox VE UI and CLI (choose something concise)
- [server](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#server) - NFS data address used by the plugin for storage mount/activation
- [export](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#export) - JovianDSS NFS export path in the form `/Pools/<pool>/<dataset>`; everything after `/Pools/<pool>/` must be exactly the dataset name
- [path](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#path) - Local mountpoint directory on Proxmox VE (for example `/mnt/pve/jdss-nfs-01`)
- [user_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#user_name)/[user_password](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#user_password) - Credentials configured in JovianDSS REST API settings. Required for snapshot operations.
- [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#control_addresses) - A comma-separated list of VIP addresses used for communication with the JovianDSS REST API
- [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#data_addresses) - Optional. Does not affect the NFS mount — the share is always mounted from `server`; serves only as a fallback source of REST control addresses when `control_addresses` is not set.
- [ssl_cert_verify](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#ssl_cert_verify) - Set to `0` to accept self-signed certificates
- [content](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#content) - Types of data to store (`images` for VM disks, `rootdir` for containers)
- [shared](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#shared) - Set to `1` to allow VM migration within the Proxmox cluster
- [options](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS#options) - Optional comma-separated NFS mount options passed directly to the mount command (e.g. `vers=4,nofail,soft`)

### Viewing the configuration

After running the `pvesm add` command, you can verify the configuration by viewing the storage.cfg file. The resulting config record will look like this:

```ini
joviandss-nfs: jdss-nfs-01
        server 192.168.31.152
        export /Pools/Pool-1/datastore-pve-01
        path /mnt/pve/jdss-nfs-01
        user_name admin
        ssl_cert_verify 0
        content images,rootdir
        shared 1
```

### Manual configuration (Alternative)

The record can also be created by editing `/etc/pve/storage.cfg` manually. The password must then be placed in a password file yourself — its name must match the storage name (`jdss-nfs-01` → `jdss-nfs-01.pw`):

```bash
mkdir -p /etc/pve/priv/storage/joviandss-nfs
```

`/etc/pve/priv/storage/joviandss-nfs/jdss-nfs-01.pw`:

```
user_password <rest_api_password>
```

## Troubleshooting

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

To send logs to the development team, create an archive of the `/var/log/joviandss` folder:

```bash
tar -cvzf ./jdss-logs.tar.gz /var/log/joviandss
```

## Snapshots and rollback

The JovianDSS NFS plugin supports ZFS-backed VM snapshots and rollback through the Proxmox VE snapshot interface — no additional configuration is required beyond what is described above.

When you take a Proxmox VM snapshot, the plugin creates a ZFS snapshot of the NAS volume on JovianDSS and temporarily clones it as a read-only NFS share so Proxmox can access disk images at the snapshot point.

When you roll back Proxmox VM to a snapshot, the plugin uses the JovianDSS REST API to attach snapshot and restore specific Proxmox VM disk by using `dd` from snapshot.

> **Note:** Snapshot operations require valid REST API credentials (user_name / user_password) and connectivity from all Proxmox nodes.

## Further reading

- [NFS plugin configuration reference](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-NFS)
- [Network configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)
- [Proxmox VE storage documentation](https://pve.proxmox.com/wiki/Storage)
- [JovianDSS JumpStart Paper](https://www.open-e.com/site_media/download/documents/productguide/JDSS_JumpStart_A4_21112024.pdf)
- [Issue tracker](https://github.com/open-e/JovianDSS-Proxmox/issues)
