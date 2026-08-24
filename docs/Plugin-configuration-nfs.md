# Configuring the NFS plugin

## Brief Proxmox VE Storage configuration intro

Proxmox VE's storage subsystem is built around a plugin architecture, and all
cluster-wide storage plugin definitions live in a single file:
`/etc/pve/storage.cfg`. Each storage `type` represents a plugin that implements
a common interface so that the rest of the system can call it uniformly.

```
<type>: <STORAGE_ID>
        <property> <value>
        <property> <value>
        <property>
        ...
```

`type` specifies the storage plugin. For the JovianDSS **NFS** plugin, set the
type to `joviandss-nfs`. (The block-storage variant is `joviandss` — see
[Plugin-configuration](Plugin-configuration.md).)

`STORAGE_ID` names the storage as it appears in the Proxmox VE UI and CLI.

`property` and `value` are key-value pairs. A property change becomes effective
immediately after `storage.cfg` is written; the very next request to the
Proxmox VE API takes the new configuration into account.

[More about Proxmox VE storage configuration can be found here](https://pve.proxmox.com/wiki/Storage)

## How the NFS plugin differs from the iSCSI plugin

Both plugins front the same JovianDSS appliance and share the same REST control
channel, credentials and TLS settings. Where they differ:

- **The data path is an NFS mount, not iSCSI.** The plugin mounts a JovianDSS
  NAS share at [path](#path) and stores VM/CT disks as files on it. There is no
  `multipath`, `target_prefix`, `luns_per_target` or `block_size`.
- **A single ZFS dataset holds everything.** One `joviandss-nfs` storage maps to
  one dataset (see [export](#export)); all its VM images, container volumes, ISOs
  and backups live there, and snapshots are taken at the dataset level.
- **The pool and dataset come from [export](#export)**, not from a `pool_name`
  property — there is no `pool_name` for this plugin.
- **More content types.** In addition to `images` and `rootdir`, the NFS plugin
  supports `vztmpl`, `iso`, `backup` and `snippets`.
- **`raw` is the only supported disk format** (as with the iSCSI plugin).

## Plugin properties

Here is an example `joviandss-nfs` record:

```
joviandss-nfs: jdss-nfs-Pool-0
        export /Pools/Pool-0/data
        path /mnt/pve/jdss-nfs-Pool-0
        server 192.168.28.100
        content images,rootdir,vztmpl,iso,backup
        user_name admin
        control_addresses 192.168.28.100
        ssl_cert_verify 0
        shared 1
        disable 0
```

**Note**: `user_password` does not appear in `storage.cfg` — it is stored
securely in `/etc/pve/priv/storage/joviandss-nfs/jdss-nfs-Pool-0.pw`.

### The address model

Three properties describe where the appliance is, and one derives the pool:

| Property | Purpose | Resolution when unset |
|---|---|---|
| [server](#server) | address the NFS share is mounted from (the data path) | — (effectively required) |
| [data_addresses](#data_addresses) | dedicated NFS data address(es) | the mount uses `server` first, so this is used only when `server` is absent |
| [control_addresses](#control_addresses) | address(es) for REST control calls (snapshots, identity) | falls back to `data_addresses`, then to `server` |
| [export](#export) | the JovianDSS NAS share path; **also** determines the pool and dataset | — (required) |

The practical consequences:

- **Minimum configuration:** setting `server` alone drives both the NFS mount and
  the REST control channel — the reference deployment does exactly this.
- **Recommended for production:** set `server` to a data-network VIP (the mount
  uses it) and `control_addresses` to the management address (REST uses it and
  does not fall through to `server`), giving a clean data/control split. For a
  [JovianDSS High Availability cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/),
  `server` and `control_addresses` **must** be VIPs.

---

### content

**Default**: None

**Type**: *string*

**Required**: `True`

**Supported values**: `images` `rootdir` `vztmpl` `iso` `backup` `snippets`

The content types stored on this share:

- `images` — VM disk images
- `rootdir` — container root-directory disks
- `vztmpl` — container templates
- `iso` — ISO images
- `backup` — vzdump backup archives
- `snippets` — hook scripts / cloud-init snippets

Each type is stored under its own sub-directory of the mounted share (for
example `images/`, `template/iso/`, `dump/`), following standard Proxmox VE
directory-storage layout. See the `content-dirs` property under
[Inherited directory-storage properties](#inherited-directory-storage-properties)
to override the sub-directory names.

### control_addresses

**Default**: None (falls back to [data_addresses](#data_addresses), then [server](#server))

**Type**: *string*

**Required**: `False`

A comma-separated list of IP addresses used to send REST requests to JovianDSS —
snapshot create/delete/rollback and storage-identity checks. The plugin cycles
through these addresses and retries before giving up on a command.

When omitted, REST calls reuse [data_addresses](#data_addresses), and if that is
also unset, [server](#server). Set this explicitly to keep REST control traffic
on a separate network from the NFS data mount.

**IMPORTANT!** For a
[JovianDSS High Availability cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/)
you **must** use VIPs for `control_addresses`, as this allows dynamic access to
the pool after a failover.

### control_port

**Default**: `82`

**Type**: *int*

**Required**: `False`

The TCP port used for REST commands to JovianDSS over every entry in
[control_addresses](#control_addresses). JovianDSS accepts REST connections only
over SSL/TLS; changing this port does not alter the protocol.

### create-base-path

**Default**: `1`

**Type**: *bool*

**Required**: `False`

Creates the [path](#path) mount-point directory if it does not exist when the
storage is added or activated.

### data_addresses

**Default**: None

**Type**: *string*

**Required**: `False`

A comma-separated list of addresses for the NFS data path. Because
[server](#server) is consulted first when choosing the mount source, this
property only affects the NFS mount when `server` is not set. It also serves as
the fallback source for [control_addresses](#control_addresses).

In most NFS deployments, set [server](#server) to the data address directly and
leave this unset.

### debug

**Default**: `0`

**Type**: *boolean*

**Required**: `False`

Enables verbose logging of plugin operations to the configured
[log_file](#log_file).

### disable

**Default**: `0`

**Type**: *int*

**Required**: `False`

When set to `1`, the storage entry stays in the cluster configuration but is
taken offline: Proxmox VE skips mounting or activating it on any node, and
backups, migrations, clones and snapshot jobs ignore it. Use this for planned
maintenance instead of deleting or commenting out the record, which risks the
GUI or API rewriting your configuration.

### export

**Default**: None

**Type**: *string*

**Required**: `True` (`fixed` — cannot be changed after creation)

The JovianDSS NAS share path, in the form `/Pools/<pool>/<export-path>` — for
example `/Pools/Pool-0/data` or `/Pools/Pool-0/data/production`. This single property determines three things:

- the NFS share that is mounted at [path](#path);
- the JovianDSS **pool** (`<pool>`), used for every REST call; and
- the **JovianDSS share export path** (`<export-path>`), consisting of `dataset` name and `share path` for the given dataset.

The dataset must already exist on the appliance and be exported over NFS. A
malformed value (not matching `/Pools/<pool>/<export-path>`) is rejected.

Because the dataset is shared by every guest on this storage, snapshots and
rollbacks operate per-file on top of a dataset snapshot; the plugin isolates
individual volumes so that rolling one guest back does not affect its
neighbours on the same dataset.

### log_file

**Default**: `/var/log/joviandss/joviandss.log`

**Type**: *string*

**Required**: `False`

Filesystem path where the plugin writes its log output. By default it records
basic operational events; enable [debug](#debug) for detailed tracing. Logs are
rotated, retaining up to six files of 16 MiB each.

### options

**Default**: None

**Type**: *string*

**Required**: `False`

NFS mount options passed verbatim to `mount -t nfs -o <options>`. Use this to
select the NFS protocol version or tune the mount — for example
`vers=4,soft,timeo=100`. When `vers=4` is present the plugin also adjusts its
reachability probe accordingly.

If unset, the system's default NFS mount behaviour applies (typically NFSv3 on
current Proxmox VE hosts).

### path

**Default**: `/mnt/pve/<STORAGE_ID>`

**Type**: *string*

**Required**: `False` (`fixed` — cannot be changed after creation)

The local directory where the JovianDSS NFS share is mounted. Unlike the iSCSI
plugin — where `path` is unused — this is a real, active mount point: VM and
container disk files live under it once the share is mounted. It defaults to
`/mnt/pve/<STORAGE_ID>` and is created automatically when
[create-base-path](#create-base-path) is set.

### server

**Default**: None

**Type**: *string*

**Required**: `True` (`fixed` — cannot be changed after creation)

The address the NFS share is mounted from — the data path. This is the primary
address the plugin uses: the share `<server>:<export>` is mounted at
[path](#path), and when neither [control_addresses](#control_addresses) nor
[data_addresses](#data_addresses) is set, REST control calls use it as well.

Set this to the address that should carry NFS data traffic. In a High
Availability deployment it **must** be a VIP so the mount survives a pool
failover.

### shared

**Default**: `0`

**Type**: *int*

**Required**: `False`

A Proxmox VE storage-system flag (not specific to this plugin) indicating that
volumes created on one node are reachable from other nodes — which they always
are here, since the data lives on JovianDSS and the same share is mounted
cluster-wide. Set `shared 1` so Proxmox VE permits live migration of guests on
this storage.

### ssl_cert_verify

**Default**: `1`

**Type**: *int*

**Required**: `False`

Controls SSL/TLS certificate verification for the REST connection from Proxmox
VE to JovianDSS. Strict verification is enabled by default. To permit
self-signed or otherwise untrusted certificates (common during evaluation), set
`ssl_cert_verify 0`.

- [Setting a custom HTTPS certificate](https://www.open-e.com/support-and-services/academy/video-tutorials/video/setting-a-custom-https-certificate/)
- [HTTPS certificate regeneration](https://kb.open-e.com/jdss-https-certificate-regeneration_3121.html)

### user_name

**Default**: `admin`

**Type**: *string*

**Required**: `True`

The JovianDSS REST API user name the plugin uses for authentication and command
execution (snapshots, identity checks). Configure it in the JovianDSS web UI
under the REST API settings. It must be identical across all nodes of a
[High Availability cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/)
that share the same pool for failover to work.

### user_password

**Default**: None

**Type**: *string*

**Required**: `True`

**Security Note**: `user_password` is handled as a sensitive parameter and
stored in `/etc/pve/priv/storage/joviandss-nfs/<STORAGE_ID>.pw` instead of
appearing in `storage.cfg`.

The JovianDSS REST API password. The NFS plugin **requires** a stored password:
adding a storage without one fails immediately, and the password may be changed
later but never cleared. It must be identical across all nodes of a High
Availability cluster that share the same pool.

**Usage**:
- With `pvesm add`/`pvesm set`: include `--user_password <password>` and it is stored securely.
- When manually editing `storage.cfg`: the password line is removed from the file after processing.
- To view the stored value: read `/etc/pve/priv/storage/joviandss-nfs/<STORAGE_ID>.pw`.

## Inherited directory-storage properties

Because the NFS plugin presents a mounted filesystem, it also accepts the
standard Proxmox VE directory/NFS-storage properties, which behave exactly as
they do for the built-in `dir`/`nfs` types:

- `content-dirs` — override the per-content-type sub-directory names.
- `nodes` — restrict the storage to specific cluster nodes.
- `prune-backups`, `max-protected-backups` — backup retention policy for the `backup` content type.
- `mkdir`, `create-subdirs` — control automatic creation of the mount point and content sub-directories.
- `bwlimit` — bandwidth limits for storage operations.
- `preallocation` — file preallocation mode for new images.
- `format` — image format; **`raw` only** for this plugin.

See the [Proxmox VE storage documentation](https://pve.proxmox.com/wiki/Storage)
for these.

## Advanced / engineering properties

The REST-resilience tuning properties (`jdssc_rest_connect_timeout`,
`jdssc_rest_read_timeout`, `jdssc_rest_request_send_cycle_attempts`,
`jdssc_rest_request_send_cycle_delay`,
`jdssc_rest_send_retry_on_decode_error_attempts`) apply to the `joviandss-nfs`
type as well and are documented on the
[Plugin Configuration: Engineering Properties](Plugin-configuration-engineering.md)
page. The `jdssc_general_lock_*` and `jdssc_info_lock_*` properties are internal
locking-tuning knobs; leave them unset unless directed by Open-E support.

## Examples

### Minimal record

The smallest working configuration — `server` alone drives both the NFS mount
and the REST control channel:

```
joviandss-nfs: jdss-nfs-Pool-0
        export /Pools/Pool-0/data
        path /mnt/pve/jdss-nfs-Pool-0
        server 192.168.28.100
        content images,rootdir
        user_name admin
        ssl_cert_verify 0
        shared 1
        disable 0
```

- **Pool / dataset**: `Pool-0` / `data`, both derived from `export`.
- **Mount**: `192.168.28.100:/Pools/Pool-0/data` at `/mnt/pve/jdss-nfs-Pool-0`.
- **REST control**: reuses `192.168.28.100` (no separate `control_addresses`).
- **Content**: VM images and container disks.
- **Credentials**: REST user `admin`; the password is stored in the `.pw` file.

### Separated data and control networks, broad content

Recommended for production: NFS data on a dedicated VIP, REST control on the
management address, and the share used as a general-purpose datastore.

```
joviandss-nfs: jdss-nfs-Pool-2
        export /Pools/Pool-2/data2
        path /mnt/pve/jdss-nfs-Pool-2
        server 192.168.29.102
        control_addresses 192.168.28.102
        content images,rootdir,vztmpl,iso,backup,snippets
        user_name admin
        ssl_cert_verify 0
        shared 1
        options vers=4
        debug 0
        log_file /var/log/joviandss/jdss-nfs-Pool-2.log
        disable 0
```

- **Mount**: `192.168.29.102:/Pools/Pool-2/data2` (the data VIP) over NFSv4.
- **REST control**: `192.168.28.102:82` — separate from the data path, so it does
  not fall through to `server`.
- **Content**: full datastore — images, container disks and templates, ISOs,
  backups and snippets, all on the one `data2` dataset.
