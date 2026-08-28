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
        control_addresses 192.168.28.100
        control_port 82
        data_addresses 192.168.29.100
        data_port 3260
        thin_provisioning 1
        luns_per_target 8
        block_size 16K
        log_file /var/log/joviandss/joviandss.log
```

**Note**: The `user_password` and `chap_user_password` lines do not appear in storage.cfg as passwords are stored securely in `/etc/pve/priv/storage/joviandss/jdss-Pool-0.pw`


### block_size

**Default**: `16K`

**Type**: *string*

**Required**: `False`

Specifies the block size for newly created volumes.

Supported values are: 4K, 8K, 16K, 32K, 64K, 128K, 256K, 512K, and 1M.

This setting does not affect volumes created before it is applied.

### chap_enabled

**Default**: `0`

**Type**: *boolean*

**Required**: `False`

Enables CHAP (Challenge-Handshake Authentication Protocol) for all iSCSI targets
managed by this storage instance. When set to `1`, JovianDSS will challenge the
Proxmox initiator at login time and refuse connections that cannot supply the correct
credentials.

Requires `chap_user_name` and `chap_user_password` to be set. The plugin enforces
this at configuration time — enabling `chap_enabled` without both credentials present
causes `pvesm add` or `pvesm set` to fail immediately.

See [CHAP Authentication](CHAP-Authentication) for full configuration instructions.

### chap_user_name

**Default**: None

**Type**: *string*

**Required**: `False` (required when `chap_enabled 1`)

The CHAP initiator username presented to JovianDSS iSCSI targets. Stored in
`storage.cfg` and replicated to all cluster nodes automatically by Proxmox VE.

Must be set together with `chap_user_password` whenever `chap_enabled` is `1`.

### chap_user_password

**Default**: None

**Type**: *string*

**Required**: `False` (required when `chap_enabled 1`)

**Security Note**: `chap_user_password` is handled as a sensitive parameter and
stored securely in `/etc/pve/priv/storage/joviandss/<storage-id>.pw` instead of
appearing in `storage.cfg`.

The CHAP initiator password used for iSCSI authentication against JovianDSS targets.
Minimum length is 12 characters; maximum is 16 characters (iSCSI RFC 3720 limit).

**Usage**:
- When using `pvesm add` or `pvesm set`: include `--chap_user_password <password>` and it will be stored securely.
- To rotate the password: run `pvesm set <storeid> --chap_user_password <new-password>`. Active iSCSI sessions are unaffected; the new password takes effect on the next VM start.


### cluster_prefix

> **Experimental** — behaviour may change in future releases. See [Cluster-Prefix](https://github.com/open-e/JovianDSS-Proxmox/wiki/Cluster-Prefix) for full setup instructions.

**Default**: None

**Type**: *string*

**Required**: `False`

A short alphanumeric prefix embedded in every volume name that this storage instance creates on JovianDSS (e.g. `pveA_vm-100-disk-0`). When set, only volumes whose names begin with this prefix are visible to the storage instance — volumes belonging to other clusters are ignored.

This allows multiple independent Proxmox clusters to share the same JovianDSS pool without seeing each other's volumes. A distinct `target_prefix` per cluster is also required for full iSCSI isolation; see [Cluster-Prefix](Cluster-Prefix).

**Constraints**: must start with a letter, followed by letters and digits only — no underscores or hyphens (e.g. `pveA`, `cluster01`). Cannot be changed after the storage instance is created (`fixed` property).

### content

**Default**: None

**Type**: *string*

**Required**: `True`

**Supported values**: `images` `rootdir`

Specifies the types of content stored on this backed. `joviandss` plugin supports only two formats:

    images — VM disk images

    rootdir — container root-directory disks

To store other content types on JovianDSS (container templates, ISO images, backups, snippets), use the [JovianDSS NFS plugin](Plugin-configuration-NFS) — see the [NFS Quick Start](Quick-Start-NFS).

### control_addresses

**Default**: None

**Type**: *string*

**Required**: `True`

A comma-separated list of IP addresses used to send REST requests to JovianDSS, for example `control_addresses 192.168.27.102,192.168.28.102`.
The plugin cycles through these addresses, retrying until the configured retry budget is exhausted (see [Plugin configuration: engineering properties](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration-engineering)).

If no dedicated VIP is available for `control_addresses`, it is recommended to use one or more `data_addresses`.

**IMPORTANT!**

For [JovianDSS High Availability cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/) setup user **MUST** use VIPs(Virtual IP addresses) for `control_addresses` as it allows dynamic access to the `Pool`.


### control_port

**Default**: 82

**Type**: *int*

**Required**: `False`

Specifies the TCP port used for REST commands to JovianDSS over all entries in [control_addresses](#control_addresses).
JovianDSS accepts connections only over SSL/TLS; changing this port does not alter the protocol.


### create-base-path

**Default**: None

**Type**: *bool*

**Required**: `False`

Creates [path](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#path) directory if it does not exists.

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

### delete_timeout

**Default**: `600`

**Type**: *int*

**Required**: `False`

Timeout in seconds for volume delete operations. Increase this if the JovianDSS pool has many dependent snapshots and deletion consistently exceeds the default.

### debug

**Default**: `0`

**Type**: *boolean*

**Required**: `False`

Enables verbose logging of plugin operations to the configured [log_file](#log_file).


### disable

**Default**: 0

**Type**: *int*

**Required**: `False`

When set to `1`, the storage entry stays in the cluster configuration but is
taken offline: nothing is mounted or activated, and all storage jobs ignore it.
Use this for planned maintenance instead of deleting the record.


### log_file

**Default**: `/var/log/joviandss/joviandss.log`

**Type**: *string*

**Required**: `False`

Specifies the filesystem path where the plugin writes its log output. By default, the plugin records basic operational events (e.g., volume creation and deletion). To capture detailed debug information, enable the debug flag. The plugin rotates logs, retaining up to six files of 16 MiB each.


### luns_per_target

**Default**: `8`

**Type**: *int*

**Required**: `False`

Specifies the maximum number of volumes (LUNs) that can be attached to a single iSCSI target for a given VM or container.
When a VM or container requires more volumes than `luns_per_target` allows, additional targets are created with an incremented `<index>` — see [target_prefix](#target_prefix) for the target naming format.


### multipath

**Default**: 0

**Type**: *int*

**Required**: `False`

After enabling multipathing with `multipath 1`, any volume attached thereafter is presented as a multipath device only on the node where Proxmox attaches it. During live migration, the device may briefly appear on both the source and target nodes, but Proxmox guarantees it won’t be attached to more than one node at a time outside of migration.

Enabling or disabling `multipath`, and adding or removing [data_addresses](#data_addresses) entries, take effect for a running VM/container only after a full deactivate–activate cycle (full stop, then start) — see [Multipathing](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing) for details.

The plugin interacts with multipath devices but does not configure the host’s multipath services.
Ensure the `multipathd` service is enabled on every node in a cluster and its configuration [complies with the JovianDSS Proxmox plugin requirements](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing).

### path

**Default**: None

**Type**: *string*

**Required**: `False`

The folder associated with the JovianDSS Proxmox plugin—intended to host disks and resources presented to the Proxmox VE system—remains unused.

Instead, the plugin attaches iSCSI block devices and creates multipath devices as needed; once a block device appears under `/dev/...` on the Proxmox node, the plugin registers it with the Proxmox VE storage subsystem.

### pool_name

**Default**: Pool-0

**Type**: *string*

**Required**: `True`

The `pool_name` property specifies the target storage `pool` on the JovianDSS side.
It is case-sensitive and must exactly match an existing `pool` created via the JovianDSS GUI or CLI before plugin configuration.
If the specified `pool` does not exist, the plugin fails.

This property is foundational: all resources managed by the plugin (volumes, snapshots, iSCSI targets) are provisioned within the named `pool`.

Never create multiple storage `pool` records with the same `pool_name`, as doing so may cause race conditions and unpredictable behavior.


### shared

**Default**: 0

**Type**: *int*

**Required**: `False`

The `shared` property is part of the [Proxmox VE storage system](https://pve.proxmox.com/wiki/Storage)—not the joviandss plugin—and indicates that volumes created on one node are accessible from other nodes.

It has no impact on the plugin’s operation, since all data (volumes and snapshots) resides on the JovianDSS storage from the start.

Its sole purpose is to inform the Proxmox cluster that VMs and containers can be migrated across nodes.

To enable the `shared` property, set it to `1`.


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

### target_prefix

**Default**: iqn.2025-04.proxmox.joviandss.iscsi:

**Type**: *string*

**Required**: `False`

The `target_prefix` is prepended to every iSCSI target created for a volume in a given storage pool.
Each target name follows this pattern:

 `<target_prefix>:vm-<vmID>-<index>`

- <vmID> is the Proxmox VM or container ID.
- <index> is a sequential number starting at 0, is needed to handle cases when single VM/Container require volume to be active at a same time that is restricted by [luns_per_target](#luns_per_target) property.

Use a **lowercase** prefix: the appliance stores target names in lowercase, and a mixed-case prefix prevents volume activation.

**IMPORTANT!**
During the initial VM startup, all assigned volumes are attached to a target defined by the specified prefix.
Changing the target prefix afterward may result in errors during live migration and when starting the VM on other nodes in the cluster.

To apply changes to the target, the user must:

1. Turn off the VM or container
2. Migrate the VM or container to another Proxmox node in offline mode
3. Manually remove the iSCSI target through the JovianDSS web UI

Example: with prefix `iqn.2025-06.proxmox.pool-2`, the first target for VM 102 is `iqn.2025-06.proxmox.pool-2:vm-102-0`.

    Tip: Include the storage pool name in your `target_prefix` to avoid naming collisions when multiple Proxmox clusters share the same JovianDSS server with different `pools`.


### thin_provisioning

**Default**: `1`

**Type**: *boolean*

**Required**: `False`

Controls whether new volumes created on JovianDSS are thin-provisioned.

When enabled, new volumes are created with minimal initial allocation on JovianDSS. Additional space is allocated from the target pool as data is written.

To create thick-provisioned volumes, set `thin_provisioning 0`. This affects only volumes created after the change; thick volumes consume their full capacity at creation time.

Changing this setting does not affect existing volumes.



### user_name

**Default**: admin

**Type**: *string*

**Required**: `True`

The `user_name` property specifies the JovianDSS REST API user name the plugin uses for authentication and command execution.
Configure it in the JovianDSS web UI under the REST API settings. For details, see:
- [Quick Start: Enabling the REST API](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start-iSCSI#enable-rest-api)
- [Advanced Metro HA Cluster Step-by-Step (2-rings)](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)

`user_name` must be identical across all nodes in the [High Availability Cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/) that share same [pool_name](#pool_name) for `failover` to function correctly.

### user_password

**Default**: None

**Type**: *string*

**Required**: `True`

**Security Note**: `user_password` property is handled as a sensitive parameter and stored securely in `/etc/pve/priv/storage/joviandss/<storage-id>.pw` instead of appearing in the main `storage.cfg` file.

The `user_password` property specifies the JovianDSS REST API password the plugin uses for authentication and command execution. Like [user_name](#user_name), it is configured in the JovianDSS REST API settings and must be identical across all HA-cluster nodes sharing the pool.

Set it with `pvesm add`/`pvesm set --user_password <password>`; the stored value can be read from the `.pw` file above.


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



The storage plugin instance `jdss-Pool-0` is configured as follows:

- **Pool**: `Pool-0` on the JovianDSS side, storing VM disk images and container root disks (`content rootdir,images`).
- **Networking**: REST commands go to `192.168.28.100` (port 82); iSCSI data flows over the VIP `192.168.29.100`, single-path (`multipath 0`), up to 8 LUNs per target.
- **Behaviour**: shared across the cluster for live migration, thin-provisioned volumes, self-signed certificates accepted.
- **Diagnostics**: verbose logging (`debug 1`) to `/var/log/joviandss/jdss-Pool-0.log`.


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
