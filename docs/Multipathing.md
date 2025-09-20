# Multipathing

Multipathing provides redundancy and load balancing for block storage by exposing multiple physical I/O paths to a single logical device.

The JovianDSS Proxmox plugin leverages this by aggregating multiple iSCSI sessions into a single device mapper entry via the host’s `multipathd` (multipath daemon).

The plugin itself adds and removes SCSI IDs from the kernel’s multipath subsystem and returns the resulting `/dev/mapper/…` path to Proxmox VE. 

It does not install or configure `multipathd`; that daemon must be provisioned and tuned externally.

Because multipathd is critical to cluster stability and to any services already relying on its configuration, its installation and configuration fall under the administrator’s purview.

## Operation

The plugin presents multipath block devices to the Proxmox VE virtualization and container services. Its workflow comprises two phases: Activation and Deactivation.

### Activation
1. iSCSI Attachment

    The plugin issues REST calls and [iSCSI login](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking#plugin-and-volume-data) to present the target volume on the host.

2. SCSI ID Retrieval

    The plugin invokes the `/lib/udev/scsi_id` utility on the new device node to obtain its unique SCSI identifier.

3. Multipath Enrollment

    The retrieved SCSI ID is added to the multipath configuration, causing the kernel’s multipath subsystem to recognize the device.

4. Device Mapping

    A corresponding `/dev/mapper/<mpath_name>` path is created for the multipath device.

5. State Persistence

    Attachment details (storage-ID, volume-ID, SCSI ID, and mapper path) are serialized into a JSON file under `/etc/joviandss/state/<STORAGE_ID>/...`

6. PATH Response

    The plugin returns the block device path (e.g., `/dev/mapper/<mpath_name>`) to be used by the Proxmox storage subsystem.

### Deactivation

1. State Lookup

    The plugin reads the stored JSON record to retrieve the SCSI ID and mapper path for the volume.

2. Multipath Removal

    The SCSI ID is deregistered from the multipath configuration, and the kernel’s multipath maps are reloaded.

3. Device Flush

    The multipath map associated with the SCSI ID is flushed, removing the /dev/mapper entry.

4. State Cleanup

    The corresponding JSON state file under `/etc/joviandss/state/<STORAGE_ID>/...` is deleted.

## MultipathD

### Installing

The `multipath-tools` and `sg3-utils` packages install the multipath daemon on Proxmox VE nodes:

```bash
apt install multipath-tools sg3-utils
```

The `multipathd` service must be enabled for autostart and running on all cluster nodes:

```bash
systemctl enable multipathd
systemctl start multipathd
systemctl status multipathd
```

Proper `multipathd` configuration — consistent across every node and compliant with the JovianDSS Proxmox plugin requirements — is essential for cluster stability.

### Configuring

Note: Proxmox VE 8.4.0 ships with `multipath-tools` v0.9.4, which expects configuration snippets in `/etc/multipath/conf.d/`.

From multipath-tools v0.9.7 onward, the plugin enrolls volumes by their SCSI WWID. Any WWID-based blacklist rule such as:

```
blacklist {
    wwid .*
}
```
Will match every WWID and thus prevent those volumes from being mapped as multipath devices.

Ensure that multipath configuration does not include such catch-all WWID blacklists so that plugin-enrolled devices can appear under `/dev/mapper`.


To prevent unrelated devices from being managed by the multipath daemon, it is common to blacklist by vendor.

In environments using the JovianDSS plugin, this approach excludes all devices except those provided by JovianDSS:
```
defaults {
    uid_attrs                   "sd:ID_SERIAL"
    find_multipaths             strict
    uxsock_timeout              4000
}

devices {
    device {
        vendor                  "^SCST_"
        product                 ".*"
        path_selector           "round-robin 0"
        path_grouping_policy    multibus
        rr_min_io               100
        no_path_retry           queue
        user_friendly_names     no
        skip_kpartx             yes
        prio                    const
        detect_prio             "no"
        path_checker            tur
        hardware_handler        "0"
        prio_args "5"
    }
}

blacklist {
    device {
        vendor                  ".*"
    }
}

blacklist_exceptions {
    device {
        vendor                  "^SCST_"
    }
}
```
- The blacklist block with vendor ".*" excludes every device by default.
- The blacklist_exceptions block re‐allows devices whose vendor string matches "SCST_BIO", the identifier used by JovianDSS iSCSI targets.

This configuration ensures that only JovianDSS volumes are admitted into the multipath subsystem, avoiding spurious multipath mappings for other storage devices.



## Enable multipath for `storage pool`

Multipathing is enabled by setting `multipath 1` in the `storage pool` record.
When enabled for a given pool, any volume in that `stoarge pool` is exposed to Proxmox VE as a multipath device.

`multipath` is closely related to [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) property. As each redundancy path that would be created is based on IP address defined [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses), check [Networking guide for additional information](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)

Because each redundancy path corresponds to an IP in [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses), ensure your [data_address](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) configuration supports the desired [network topology](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking). Changes to `multipath` or to the `data_addresses` list take effect only after a full deactivate–activate cycle of the VM or container:

- Enabling multipath on a running guest
    Guests started with `multipath 0` retain single-path devices until they are fully deactivated (stopped and iSCSI devices unmapped) and then restarted with `multipath 1`.

- Disabling multipath on a running guest
    Guests started with `multipath 1` continue using multipath devices until they undergo the same full deactivate-activate cycle with `multipath 0`.

- Updating data paths
    Adding or removing entries in [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) does not alter `multipath` devices for running guests. A full deactivate-activate cycle is required for any new or removed paths to be recognized.