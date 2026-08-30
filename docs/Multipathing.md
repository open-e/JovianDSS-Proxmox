# Multipathing

Multipathing provides redundancy and load balancing for block storage by exposing multiple physical I/O paths to a single logical device.

The JovianDSS Proxmox plugin leverages this by aggregating multiple iSCSI sessions into a single device-mapper entry via the host’s `multipathd` (multipath daemon): it enrolls each volume’s SCSI ID (WWID) in the kernel’s multipath subsystem and returns the resulting `/dev/mapper/…` path to Proxmox VE.

The packages providing the daemon (`multipath-tools`, `sg3-utils`) are installed automatically as plugin dependencies, but because `multipathd` is critical to cluster stability — and to any services already relying on its configuration — enabling and configuring it remains the administrator’s responsibility.

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

## multipathd

### Installing and enabling

Both `multipath-tools` and `sg3-utils` are installed automatically with the plugin package. If the plugin was installed from source, install them manually:

```bash
apt install multipath-tools sg3-utils
```

The `multipathd` service must be enabled for autostart and running on all cluster nodes:

```bash
systemctl enable multipathd
systemctl start multipathd
systemctl status multipathd
```

### Configuring

The plugin package installs the recommended configuration below to `/etc/multipath/conf.d/open-e-joviandss.conf` (a reference copy is kept at `/etc/joviandss/multipath-open-e-joviandss.conf.example`). Multipath configuration must be consistent across every node in the cluster.

The plugin enrolls volumes by their SCSI ID (WWID). A catch-all WWID blacklist such as:

```
blacklist {
    wwid .*
}
```

matches every WWID and prevents plugin volumes from appearing under `/dev/mapper` — make sure no such rule exists in your multipath configuration.

To keep unrelated devices out of the multipath daemon, the recommended configuration blacklists by vendor instead, admitting only JovianDSS devices:
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
        no_path_retry           24
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
- The blacklist_exceptions block re-allows devices whose vendor string begins with `SCST_` — the vendor identifier reported by JovianDSS iSCSI targets.

## Enabling multipath for a storage pool

Multipathing is enabled by setting `multipath 1` in the `storage pool` record; volumes activated from then on are presented to Proxmox VE as multipath devices.

Each redundancy path corresponds to one IP in [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses), so make sure that list matches your intended [network topology](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking).

Changes to `multipath` or to the `data_addresses` list never affect running guests: a guest keeps the paths it was started with — single-path or multipath — until it is fully deactivated (stopped, iSCSI devices unmapped) and started again. This applies equally to enabling multipath, disabling it, and adding or removing addresses.
