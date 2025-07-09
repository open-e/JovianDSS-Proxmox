## Updating from existing version

First user is expected to remove previous version

```bash
apt remove open-e-joviandss-proxmox-plugin
```
Once old package being remove user can install in the same way as recommended in installation guide.

```bash
apt install ./open-e-joviandss-proxmox-plugin-<version>.deb
```
*If user is updating from version v0.9.6 and earlier to v0.9.7 and newer, user is required to update multipath file and reboot proxmox cluster after updating*


## Issues

### Multipathing

Starting from version 0.9.6, multipath management has been simplified. However, some parts of the multipath configuration will need to be updated manually by the user. This changes should be done *AFTER* plugin package update.

#### Auto-generated section removal

The Auto-generated section refers to a set of multipath configurations added by the JovianDSS Plugin (up to version 0.9.6) 
and is separated from the rest of the multipath configuration with the commented lines:.

```
# Start of JovianDSS managed block
...
# End of JovianDSS managed block
```
In newer versions, the plugin no longer manages multipath volumes through config file. Users should remove this section, as leaving it in place may affect functionality in the future.

#### Disable `wwid` blacklisting
Starting with version `0.9.7` plugin use SCSI ID `wwid` to serve multipath volumes.
Because of that user should avoid blacklisting by `wwid`:
```
blacklist {
        wwid .*
}
```
If this configuration is present in your multipath config file, it must be removed.

#### Example
For example original config file that was manipulated by older version of a plugin:
```
defaults {
        polling_interval        2
        path_selector           "round-robin 0"
        path_grouping_policy    multibus
        uid_attribute           ID_SERIAL
        rr_min_io               100
        failback                immediate
        no_path_retry           queue
        user_friendly_names     yes
        config_dir              /etc/multipath/conf.d
}

blacklist {
        wwid .*
        devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
}

multipaths {
# Start of JovianDSS managed block
      multipath {
            wwid 26431623436353033
            alias iqn.2021-10.iscsi:proxmox-content-jdss-pool-0
      }
# End of JovianDSS managed block
}

blacklist_exceptions {
# Start of JovianDSS managed block
      wwid 26431623436353033
# End of JovianDSS managed block
}
```

Will be turned into
```
defaults {
        polling_interval        2
        path_selector           "round-robin 0"
        path_grouping_policy    multibus
        uid_attribute           ID_SERIAL
        rr_min_io               100
        failback                immediate
        no_path_retry           queue
        user_friendly_names     yes
        config_dir              /etc/multipath/conf.d
}

blacklist {
        devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
}

multipaths {
}

blacklist_exceptions {
}
```
### `driver_ssl_cert_verify` property

The `driver_ssl_cert_verify` property has been added to the jdssc configuration.
By default, this property enforces SSL certificate verification when the plugin is configured to connect to JovianDSS over HTTPS.
To avoid connection failures with untrusted certificates, you can disable this verification by setting the `driver_ssl_cert_verify` flag to `False` in `jdssc` config file.
