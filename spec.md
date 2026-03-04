# Open-E JovianDSS Proxmox plugin

## Documentation

Documentation is stored in `docs` folder.

Related wiki repo is open-e/JovianDSS-Proxmox.wiki.git

## Testing

Testing related scripts and files are stored separately at open-e/pve-testing

## REST api

REST API files are stored separately at open-e/jdss-rest-api-spec


## OpenEJovianDSSNFSPlugin

Minimal extension of Proxmox NFS plugin with capability to make snapshot and rollback.

In this plugin single JovianDSS `dataset`( v4/d/pools/+poolname+/nas-volumes/+datasetname+) is used for storing all data as files on it.

### Snapshot

Snapshot is done through means of JovianDSS rest api v4/d/pools/+poolname+/nas-volumes/+datasetname+/snapshots

### Rollback


Rollback to snapshot consists of 3 stages:

1. `activate` specific snapshot, in similar way as it is done in OpenEJovianDSSPlugin.pm (iSCSI plugin)
2. Physicaly copy of vm/container file from activated snapshot to share managed by JovianDSS.
