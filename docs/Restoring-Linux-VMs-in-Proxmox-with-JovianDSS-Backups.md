JovianDSS provides a volume-backup feature.

This guide describes how to use it with the JovianDSS Proxmox plugin. In our example, we'll assume a cluster of two JovianDSS nodes plus a single backup node.

> **Important**: Proxmox VE's built-in backup functionality does not back up snapshots created with the JovianDSS plugin. Only the base volume data is included in Proxmox backups. For complete data protection including snapshots, use JovianDSS's native backup features as described in this guide.

This configuration builds on the setup introduced in the Networking article.

## Environment

1. *Net1* 172.28.0.0/16 Management/Internet connection
2. *Net2* 172.29.0.0/16 Data network
2. *Net2* 172.30.0.0/16 Data network

![backup-3-nodes-1](https://github.com/user-attachments/assets/6df00977-2cc2-422f-849b-c53f1ba9ae59)

### JovianDSS

Two JovianDSS storage nodes with *Failover* enabled, and `Pool-2` has three virtual IP addresses assigned:

- VIP0 192.168.28.102 associated with physical interfaces connected to *Net1* 172.28.0.0/16
- VIP1 192.168.29.102 associated with physical interfaces connected to *Net2* 172.29.0.0/16
- VIP2 192.168.30.102 associated with physical interfaces connected to *Net3* 172.30.0.0/16

![vips-3-pool2-2](https://github.com/user-attachments/assets/5adf1cf0-fe59-456f-ab74-0170e194069b)

Single JovianDSS backup node with `Pool-1-backup` has three virtual IP addresses assigned:

- VIP0 192.168.28.101 associated with physical interfaces connected to *Net1* 172.28.0.0/16
- VIP1 192.168.29.101 associated with physical interfaces connected to *Net2* 172.29.0.0/16
- VIP2 192.168.30.101 associated with physical interfaces connected to *Net3* 172.30.0.0/16

![vips-3-pool-1-backup](https://github.com/user-attachments/assets/b067e81c-a15a-49a0-bbcf-d6250db015b0)

### Proxmox

A three-node Proxmox VE cluster in which each node has three network interfaces connected to physical networks:

- *vmbr0* connected to *Net1* associated with virtual bridge vmbr0 with ip 172.28.143.11/16 
- *ens224* connected to *Net2* associated with interface ens224 with ip 172.29.143.11/16 
- *ens256* connected to *Net3* associated with interface ens256 with ip 172.30.143.11/16


Proxmox storage config file `storage.cfg`:
```
joviandss: jdss-Pool-2
        pool_name Pool-2
        target_prefix iqn.2025-06.proxmox.pool-2
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
        user_password admin
        log_file /var/log/joviandss/jdss-Pool-2.log
        disable 0

joviandss: jdss-Pool-1-backup
        pool_name Pool-1-backup
        target_prefix iqn.2025-06.proxmox.pool-1-backup
        user_name admin
        user_password admin
        path /mnt/pve/jdss-Pool-1-backup
        content images,rootdir
        ssl_cert_verify 0
        control_addresses 192.168.28.101
        data_addresses 192.168.29.101,192.168.30.101
        path /mnt/pve/jdss-Pool-1-backup
        log_file /var/log/joviandss/jdss-Pool-1-backup
        shared 1
```
On one of the `node1` hosts, run VM 100, which uses the disk `vm-100-disk-0` residing on the JovianDSS `pool` `Pool-2`.

![debian-100](https://github.com/user-attachments/assets/91571772-8014-4ca4-baf0-02c8c204200a)

## Backup setup

To start a backup task to `Pool-1-backup`, create a dedicated volume to store the backups.
In this example, that volume is named `backup-vm-100-disk-0`.

### Create `backup destination`

Designate the volume `backup-vm-100-disk-0` as the `backup destination`.

![set-backup-destination](https://github.com/user-attachments/assets/9707813f-e98b-4c70-ba93-e17254bf134e)

A volume configured as the `backup destination` appears as follows:

![set-backup-destination-done](https://github.com/user-attachments/assets/191a03d0-7a53-4f28-9352-d163b6a645d9)

### Enable backup task

Add a backup task for the volume `v_vm-100-disk-0` on `Pool-2`.

![add-back-up-task](https://github.com/user-attachments/assets/df1fa376-19ea-4800-81c1-67058a925b9a)

![add-back-up-task-1](https://github.com/user-attachments/assets/0848341c-9a64-46d3-99db-28fd6dc71302)
![add-back-up-task-2](https://github.com/user-attachments/assets/6ed75b1c-c3da-4a5e-91f3-3bf29ed0adab)
![add-back-up-task-3](https://github.com/user-attachments/assets/4d6f0dfa-1ff9-4ee9-aad2-479438f23141)

The volume with the configured backup task should look like:
![add-back-up-task-done-front](https://github.com/user-attachments/assets/c751ac7a-5004-4eef-a1cf-925f79b9dee8)


The destination volume appears as follows:
![add-back-up-task-done-back](https://github.com/user-attachments/assets/4d9cade4-2275-481a-821a-106b89dc0137)


For a more detailed guide on JovianDSS backup setup and configuration, please refer to the: [Round the clock backup of everything with On- & Off-site Data Protection](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Round-the-clock-backup.pdf)


## Recovery


In case of major hardware failure that resulted in loss or temporal inability for JovianDSS nodes hosting `Pool-2` to operate user can recover latest state of `vm-100-disk-0` from backup stored in `backup-vm-100-disk-0` located on the `Pool-1-backup`.

In the event of a major hardware failure that causes the JovianDSS nodes hosting `Pool-2` to become unavailable or lose data, you can recover the latest state of vm-100-disk-0 from the backup volume backup-vm-100-disk-0 on `Pool-1-backup`.


### Disable affected `storage pool`

![backup-snapshots](https://github.com/user-attachments/assets/f8108b9a-c043-454b-8747-44e550d795bf)


In the event that both nodes hosting `Pool-2` become inoperable due to a major malfunction, disable the `jdss-Pool-2` storage pool to prevent further error messages.
To do this set the disable flag for Pool-2 to 1.
Shut down the VMs with volumes related to it.

![pool-2-failure](https://github.com/user-attachments/assets/98039e4d-f7f5-4053-893f-e9fb23bf5e12)

Detach the disk associated with `Pool-2` from the VM `debian-linux`.

![datach-disk-from-vm](https://github.com/user-attachments/assets/b9f9872a-5211-4ee2-a3db-a2eadc6390c1)


### Cloning

Create a clone from the desired snapshot, assigning it a name that includes the next available index:


![backup-clone-redone](https://github.com/user-attachments/assets/752ffcb6-642c-45d3-ba70-c0ffb202a509)

Config any additional parameters you deem necessary.

![backup-clone-2](https://github.com/user-attachments/assets/291a5f8e-56eb-47cc-abb1-0408ec0c49e2)

Name the clone using naming conventions compliant with both the plugin and Proxmox standards:

```
v_vm-100-disk-1
``` 

Here, the `v_` prefix indicates that the volume is managed by the JovianDSS Proxmox plugin, and `vm-100-disk-1` is the name displayed in the Proxmox VE cluster.

![backup-clone-3](https://github.com/user-attachments/assets/03d7f43b-6013-4f6c-95e7-066454240309)


### Restoring VM on new storage


Attach the clone created in the previous step to the VM:

```bash
root@node1:# qm set 100 --sata0 jdss-Pool-1-backup:vm-100-disk-1
update VM 100: -sata0 jdss-Pool-1-backup:vm-100-disk-1
```

![backup-attached-re](https://github.com/user-attachments/assets/64d4e653-f779-4242-95ff-740c5ea0cf96)

Once the clone is attached, you can replicate the VM to a more suitable storage target.
For instance, you could clone it to local Proxmox VE storage or to a newly created JovianDSS pool - such as `Pool-0`.

![vm-restore-101](https://github.com/user-attachments/assets/51dfc7e9-0001-4226-9081-7aba03c7d310)


Alternatively, if you successfully restore the Pool-2 storage pool, ...

![vm-restore-102-pool-2](https://github.com/user-attachments/assets/75275b32-a9f5-4527-9b65-3a056c26f65e)


If necessary, mark the attached disk as `bootable` under `VM Options → Boot Order`.

![boot-order](https://github.com/user-attachments/assets/85af5570-b52e-4a44-b3e9-b3450f85e9ab)


## Clean up

Once you’ve finished cloning the original VM from its backup-volume clone, delete the clone.

![clean-broken-vm](https://github.com/user-attachments/assets/3d755a36-ffd1-4298-b437-04653d18a509)

This operation deletes the clone volume created from a snapshot of `backup-vm-100-disk-0` without affecting the original snapshot. The backup destination volume remains intact for future use.
