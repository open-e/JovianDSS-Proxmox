# Configuring

## Brief Proxmox VE Storage configuration intro

Proxmox VE’s storage subsystem is built around a plugin architecture.
And all cluster-wide storage plugin definitions live in a single file: `/etc/pve/storage.cfg`.
Where each storage `type` represents a plugin that implements a common interface so that the rest of the system can call uniformly.

```
<type>: <STORAGE_ID>
        <property> <value>
        <property> <value>
        <property>
        ...
```
`type` specifies the storage plugin. For the JovianDSS Proxmox plugin, set type to `joviandss`.

`STORAGE_ID` names the storage pool as it appears in the Proxmox VE UI and CLI.

`property` and `value` are key-value pairs of property and its value.

The property change becomes effective immediately after the storage.cfg file is written.
The very next request to the Proxmox VE API will take the new configuration into account.

[More about ProxmoxVE storage configuration can be found here](https://pve.proxmox.com/wiki/Storage)

## Plugin properties

`/etc/pve/storage.cfg` 
Here is example of `storage pool` record:

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        content images,rootdir
        debug 0
        multipath 0
        path /mnt/pve/jdss-Pool-0
        shared 1
        disable 0
        target_prefix iqn.2025-06.proxmox.pool-0
        user_name admin
        ssl_cert_verify 0
        control_addresses 192.168.21.100
        control_port 82
        data_addresses 192.168.41.100
        data_port 3260
        thin_provisioning 1
        luns_per_target 8
        block_size 16K
        log_file /var/log/joviandss/joviandss.log
```

**Note**: The `user_password` line does not appear in storage.cfg as passwords are stored securely in `/etc/pve/priv/storage/joviandss/jdss-Pool-0.pw`

### pool_name

**Default**: Pool-0

**Type**: *string*

**Required**: `True`

The `pool_name` property specifies the target storage `pool` on the JovianDSS side.
It is case-sensitive and must exactly match an existing `pool` created via the JovianDSS GUI or CLI before plugin configuration.
If the specified `pool` does not exist, the plugin fails.

This property is foundational: all resources managed by the plugin (volumes, snapshots, iSCSI targets) are provisioned within the named `pool`.

Never create multiple storage `pool` records with the same `pool_name`, as doing so may cause race conditions and unpredictable behavior.

### content

**Default**: None

**Type**: *string*

**Required**: `True`

**Supported values**: `images` `rootdir`

Specifies the types of content stored on this backed. Since version 0.10.0, the joviandss plugin supports only two formats:

    images — VM disk images

    rootdir — container root-directory disks


### target_prefix

**Default**: iqn.2025-04.proxmox.joviandss.iscsi:

**Type**: *string*

**Required**: `False`

The `target_prefix` is prepended to every iSCSI target created for a volume in a given storage pool.
Each target name follows this pattern:

 `<target_prefix>:vm-<vmID>-<index>`

- <vmID> is the Proxmox VM or container ID.
- <index> is a sequential number starting at 0, is needed to handle cases when single VM/Container require volume to be active at a same time that is restricted by [luns_per_target](#luns_per_target) property.

Example:

If your prefix is `iqn.2025-06.proxmox.pool-2`, the first target for VM 102 would be:

For instance:  `iqn.2025-06.proxmox.pool-2:vm-102-0`.

    Tip: Include the storage pool name in your `target_prefix` to avoid naming collisions when multiple Proxmox clusters share the same JovianDSS server with different `pools`.



### path

**Default**: None

**Type**: *string*

**Required**: `False`

The folder associated with the JovianDSS Proxmox plugin—intended to host disks and resources presented to the Proxmox VE system—remains unused.

Instead, the plugin attaches iSCSI block devices and creates multipath devices as needed; once a block device appears under `/dev/...` on the Proxmox node, the plugin registers it with the Proxmox VE storage subsystem.


### shared

**Default**: 0

**Type**: *int*

**Required**: `False`

The `shared` property is part of the [Proxmox VE storage system](https://pve.proxmox.com/wiki/Storage)—not the joviandss plugin—and indicates that volumes created on one node are accessible from other nodes.

It has no impact on the plugin’s operation, since all data (volumes and snapshots) resides on the JovianDSS storage from the start.

Its sole purpose is to inform the Proxmox cluster that VMs and containers can be migrated across nodes.

To enable the `shared` property, set it to `1`.

### multipath

**Default**: 0

**Type**: *int*

**Required**: `False`

After enabling multipathing with `multipath 1`, any volume attached thereafter is presented as a multipath device only on the node where Proxmox attaches it. During live migration, the device may briefly appear on both the source and target nodes, but Proxmox guarantees it won’t be attached to more than one node at a time outside of migration.

Changes to multipath or additions to [data_addresses](#data_addresses) take effect only after a full deactivate–activate cycle of the VM/container:
- VMs or containers started with `multipath 0` continue using direct iSCSI devices. To enable multipathing for a running VM/container, fully deactivate it (Full stop) and then start it again.
- VMs or containers started with `multipath 1` continue using multipath block devices. To disable multipathing, perform the same full deactivate–activate cycle, setting `multipath 0` before reactivation.
- Adding a new [data_address](#data_address) does not add paths to running multipath devices, and removing an existing [data_address](#data_address) does not remove paths from them. The VM/container must undergo the full deactivate–activate cycle for the multipath configuration to pick up any additions or removals in data_addresses.

The plugin interacts with multipath devices but does not configure the host’s multipath services.
Ensure the `multipathd` service is enabled on every node in a cluster and its configuration [complies with the JovianDSS Proxmox plugin requirements](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing).

### disabled

**Default**: 0

**Type**: *int*

**Required**: `False`

When set to 1, the storage entry remains in the cluster configuration but is effectively taken “offline”:
- Proxmox will skip mounting or activating that storage on any node.
- The storage no longer appears in individual node listings, though it stays visible under `Datacenter` → `Storage`.
- Backups, live-migrations, clones, snapshot jobs, replication tasks, etc., will all ignore this storage.
- Ideal for planned maintenance or testing: you can disable it temporarily without deleting the definition.
- Editing out (commenting) the 'storage pool' section risks having your configuration removed by the GUI or the API. Using disable preserves the entry and its metadata safely.


### user_name

**Default**: admin

**Type**: *string*

**Required**: `True`

The `user_name` property specifies the JovianDSS REST API user name the plugin uses for authentication and command execution.
Configure it in the JovianDSS web UI under the REST API settings. For details, see:
- [Quick Start: Enabling the REST API](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start#enable-rest-api)
- [Advanced Metro HA Cluster Step-by-Step (2-rings)](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)


### user_password

**Default**: None

**Type**: *string*

**Required**: `True`

**Security Note**: Starting with plugin version 0.10.4-0, the `user_password` property is handled as a sensitive parameter and stored securely in `/etc/pve/priv/storage/joviandss/<storage-id>.pw` instead of appearing in the main `storage.cfg` file.

The `user_password` property specifies the JovianDSS REST API password the plugin uses for authentication and command execution. Configure it in the JovianDSS web UI under the REST API settings.

**Usage**:
- When using `pvesm add` command: Include `--user_password <password>` and it will be automatically stored securely
- When manually editing storage.cfg: The password line will not appear in the file after being processed
- To view the stored password: Check `/etc/pve/priv/storage/joviandss/<storage-id>.pw`

For details on REST API configuration, see:
- [Quick Start: Enabling the REST API](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start#enable-rest-api)
- [Advanced Metro HA Cluster Step-by-Step (2-rings)](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)


### ssl_cert_verify

**Default**: `1`

**Type**: *int*

**Required**: `False`

Controls the strictness of SSL/TLS certificate verification for connections from Proxmox to JovianDSS.

By default, strict verification is enabled (`ssl_cert_verify 1`), ensuring only certificates the server considers secure are accepted.

To permit self-signed or otherwise `untrusted` certificates (commonly useful during initial evaluation), set `ssl_cert_verify 0`.


Check following JovianDSS guides:
- [Setting a custom HTTPS certificate](https://www.open-e.com/support-and-services/academy/video-tutorials/video/setting-a-custom-https-certificate/)
- [HTTPS certificate regeneration](https://kb.open-e.com/jdss-https-certificate-regeneration_3121.html)

### control_addresses

**Default**: None

**Type**: *string*

**Required**: `True`

A comma-separated list of IP addresses used to send REST requests to JovianDSS.
The plugin cycles through these addresses in round-robin fashion—retrying up to three times before giving up on a command.
If [data_addresses](#data_addresses) is not specified, the plugin falls back to using `control_addresses` for iSCSI data transfer.


### control_port

**Default**: 82

**Type**: *int*

**Required**: `False`

Specifies the TCP port used for REST commands to JovianDSS over all entries in [control_addresses](#controll_addresses).
JovianDSS accepts connections only over SSL/TLS; changing this port does not alter the protocol.


### data_addresses

**Default**: None

**Type**: *string*

**Required**: `False`

A comma-separated list of Virtual IP addresses used for iSCSI data transfer.
Assigning non-VIP addresses to the `data_addresses` property causes VM/container startup to fail.

If `data_addresses` is not specified, the plugin falls back to using [control_addresses](#control_addresses).

VIPs must be preassigned to the specified JovianDSS `pool`; dedicated data addresses are strongly recommended.
For more information, see the [Networking](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking#plugin-networking) guide.


### data_port

**Default**: 3260

**Type**: *int*

**Required**: `False`

Specifies the TCP port for iSCSI data connections to all entries in [data_addresses](#data_addresses).
If not set, the default port 3260 is used.

### thin_provisioning

**Default**: `1`

**Type**: *boolean*

**Required**: `False`

Controls whether new volumes created on JovianDSS are thin-provisioned.

When enabled, new volumes are created with minimal initial allocation on JovianDSS. Additional space is allocated from the target pool as data is written.

To create thick-provisioned volumes, set `thin_provisioning 0`. This affects only volumes created after the change; thick volumes consume their full capacity at creation time.

Changing this setting does not affect existing volumes.

### luns_per_target

**Default**: `8`

**Type**: *int*

**Required**: `False`

Specifies the maximum number of volumes (LUNs) that can be attached to a single iSCSI target for a given VM or container.
Targets are named using the format `<target_prefix>:vm-<vmID>-<index>`:

- <target_prefix> is defined by the `target_prefix` property in storage.cfg.
- <vmID> is the Proxmox VM or container ID.
- <index> is a sequential number starting at 0.

When a VM or container requires more volumes than `luns_per_target` allows, additional targets are created with the same <vmID> and an incremented <index>.

### block_size

**Default**: `16K`

**Type**: *string*

**Required**: `False`

Specifies the block size for newly created volumes.

Supported values are: 4K, 8K, 16K, 32K, 64K, 128K, 256K, 512K, and 1M.

This setting does not affect volumes created before it is applied.


### debug

**Default**: `0`

**Type**: *boolean*

**Required**: `False`

Enables verbose logging of plugin operations to the configured [log_file](#log_file).


### log_file

**Default**: `/var/log/joviandss/joviandss.log`

**Type**: *string*

**Required**: `False`

Specifies the filesystem path where the plugin writes its log output. By default, the plugin records basic operational events (e.g., volume creation and deletion). To capture detailed debug information, enable the debug flag. The plugin rotates logs, retaining up to six files of 16 MiB each.


## Examples

### Single record

Here is example of `storage.cfg` file with 4 `storage pool` records related to `dir` plugin, `lvmthin` plugin and `joviandss` plugin.
Instance of `joviandss` driver holds id `jdss-Pool-0`
```
dir: local
        path /var/lib/vz
        content iso,backup,vztmpl

lvmthin: local-lvm
        thinpool data
        vgname pve
        content rootdir,images

joviandss: jdss-Pool-0
        pool_name Pool-0
        content rootdir,images
        control_addresses 192.168.28.100
        control_port 82
        data_addresses 192.168.29.100
        luns_per_target 8
        multipath 0
        shared 1
        ssl_cert_verify 0
        thin_provisioning 1
        user_name admin
        debug 1
        log_file /var/log/joviandss/jdss-Pool-0.log
        disable 0
```

![one-pool-0](https://github.com/user-attachments/assets/f03d98fa-6e09-4720-820a-a1e88801bd55)



The storage plugin instance jdss-Pool-0 is configured as follows:

- **Pool**: Pool-0 on the JovianDSS side

- **Content types**: rootdir, images (container root-dir disks and VM disk images)

- **Control channel**:

        Addresses: 192.168.28.100

        Port: 82

- **Data channel**:

        Addresses: 192.168.29.100

- **LUNs per target**: 8 volumes per iSCSI target before a new target is allocated

- **Multipathing**: Disabled (multipath 0), so each volume attaches as a single iSCSI device on the node that requests it (no multipath device is presented)

- **Shared storage flag**: Enabled (shared 1), allowing Proxmox to treat these volumes as cluster-wide (required for live migration, though data remains on JovianDSS)

- **SSL certificate verification**: Disabled (ssl_cert_verify 0), permitting self-signed or untrusted certificates

- **Thin provisioning**: Enabled (thin_provisioning 1), so new volumes allocate space on demand rather than reserving full size up-front

- **Debug logging**: Enabled (debug 1), producing verbose logs to the configured log_file

- **Log file path**: /var/log/joviandss/jdss-Pool-0.log (rotated per default policy)

- **Activation state**: Active (disable 0)

- **Credentials**: REST API user admin / password admin

Key behaviors:

    iSCSI volumes are presented over a single network path (no multipath) unless live migration briefly spans two nodes.

    Proxmox will send REST calls across 192.168.28.100.

    Thin provisioning defers space allocation until I/O, pulling from the JovianDSS pool up to the volume’s declared size.

    Detailed debug output goes log file at `/var/log/joviandss/jdss-Pool-0.log`, with up to five 16 MiB rotations.

    Self-signed certificates are accepted to simplify initial testing/setup.


### Multiple Pools

The JovianDSS Proxmox plugin exposes one or more JovianDSS pools as back-end storage for a Proxmox VE cluster. You can attach multiple pools—either from the same JovianDSS server or from independent servers—within a single cluster.

    Note
    Control (REST) and data (iSCSI) traffic should use separate IPs. In this example both pools share the same subnets for data traffic, which may suffice for small deployments, but dedicate a physical network per pool in production.

```
joviandss: jdss-Pool-0
        pool_name Pool-0
        content rootdir,images
        control_addresses 192.168.28.100
        control_port 82
        data_addresses 192.168.29.100,192.168.30.100
        luns_per_target 8
        shared 1
        ssl_cert_verify 0
        thin_provisioning 1
        user_name admin
        debug 1
        log_file /var/log/joviandss/jdss-Pool-0.log
        disable 0

joviandss: jdss-Pool-2
        pool_name Pool-2
        content rootdir,images
        control_addresses 192.168.28.102
        control_port 82
        data_addresses 192.168.29.102,192.168.30.102
        luns_per_target 8
        multipath 1
        path /mnt/pve/jdss-Pool-2
        shared 1
        ssl_cert_verify 0
        thin_provisioning 1
        user_name admin
        log_file /var/log/joviandss/jdss-Pool-2.log
        disable 0
```




## Multipathing

Enable multipathing by setting the multipath flag to 1 in the storage pool record:

```
multipath 1
```
Once enabled, any volume attached thereafter is presented as a multipath block device. Volumes attached before the flag was turned on remain single-path until they undergo a full deactivate–activate cycle.

```
joviandss: jdss-Pool-2
        pool_name Pool-2
        content rootdir,images
        control_addresses 192.168.28.102
        control_port 82
        data_addresses 192.168.29.102,192.168.30.102
        luns_per_target 8
        multipath 1
        path /mnt/pve/jdss-Pool-2
        shared 1
        ssl_cert_verify 0
        thin_provisioning 1
        user_name admin
        log_file /var/log/joviandss/jdss-Pool-2.log
        disable 0
```

For further details on multipathing behavior and best practices, see the [multipathing article](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing).
