## Install and configure JovianDSS proxmox plugin

In this guide we will show how to configure backup of Proxmox container and VM data located on JovianDSS storage.

> **Important**: Proxmox VE's built-in backup functionality does not back up snapshots created with the JovianDSS plugin. Only the base volume data is included in Proxmox backups. For complete data protection including snapshots, use JovianDSS's native backup features as described in this guide.

For this purpose we will use 2 JovianDSS storage's:

Pool `Pool-0` has 2 virtual IP's: 192.168.21.100, 192.168.31.100
1. `Production` node with pool `Pool-0` with virtual IP's 192.168.21.100, 192.168.31.100
2. `Backup` node with pool `Pool-0` with virtual IP's 192.168.22.100, 192.168.32.100


Make sure to introduce them to your proxmox as [storage pools](https://pve.proxmox.com/pve-docs/chapter-pvesm.html) in `/etc/pve/storage.cfg` according to [configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-installation-and-configuration#configuring)

### Configuration of `Production node`

In demo setup it looks like this:

#### JovianDSS side

Pool present
![jdss-setup-iscsi-base](https://user-images.githubusercontent.com/21205679/205968596-d5f0b061-6e10-4d72-a7ff-5f0c329dbe81.png)

Virtual IP's present
![vip-prod](https://github.com/open-e/JovianDSS-Proxmox/assets/21205679/33ec3ea4-cbb4-4d91-932a-405f3791665f)


REST API is ON
![jdss-doc-enable-rest](https://user-images.githubusercontent.com/21205679/205957343-7d968e14-61e8-4980-ad50-8050313a0f54.png)

#### Proxmox side

/etc/pve/storage.cfg
```cfg
joviandss: jdss-Production-node-Pool-0
        pool_name Pool-0
        user_name admin
        user_password admin
        content images,rootdir
        ssl_cert_verify 0
        control_addresses 192.168.21.100
        data_addresses 192.168.31.100
        path /mnt/pve/jdss-Pool-0
        shared 1
```

### Configuration of `Backup node`

#### JovianDSS side
Pool present
![jdss-setup-backup-iscsi-base](https://user-images.githubusercontent.com/21205679/205971464-6fc6aced-f1d3-4163-942e-cfa7330220d6.png)

Virtual IP's present

![vip-back](https://github.com/open-e/JovianDSS-Proxmox/assets/21205679/78177aaa-ab7f-490c-b283-2b3abd42574f)

REST API is ON
![jdss-doc-enable-rest](https://user-images.githubusercontent.com/21205679/205957343-7d968e14-61e8-4980-ad50-8050313a0f54.png)

#### Proxmox side

/etc/pve/storage.cfg
```cfg
joviandss: jdss-Backup-node-Pool-0
        pool_name Pool-0
        user_name admin
        user_password admin
        content images,rootdir
        ssl_cert_verify 0
        control_addresses 192.168.22.100
        data_addresses 192.168.32.100
        path /mnt/pve/jdss-Pool-0
        shared 1
```

### Final check
To check that both storages configured properly, you can check proxmox server web page.

![jdss-setup-proxmox](https://user-images.githubusercontent.com/21205679/205975586-32cca3cd-118b-4450-b621-8729eb738a0e.png)

Here`jdss-Production-node-Pool-0` and `jdss-Backup-node-Pool-0` are online.

or use command line:
```bash
root@proxmox-demo:~# pvesm status
Name                               Type     Status           Total            Used       Available        %
jdss-Backup-node-Pool-0       joviandss     active       499122176        26214400       472907776    5.25%
jdss-Production-node-Pool-0   joviandss     active       266338304        46137344       220200960   17.32%
local                               dir     active        14145416         2831516        10573548   20.02%
```

## Create VM/Container

![demo-create-1](https://user-images.githubusercontent.com/21205679/206229987-b0db3d1f-c059-4c21-af59-d8136815b0f7.png)
![demo-create-2](https://user-images.githubusercontent.com/21205679/206230010-d8927d9e-26a0-45aa-8538-7c2a98e772cb.png)
![demo-create-3](https://user-images.githubusercontent.com/21205679/206230021-73acb0e3-702e-4516-8d10-3279662f9c99.png)
![demo-create-4](https://user-images.githubusercontent.com/21205679/206230041-bb4c8760-b596-4073-b03f-4df76f04822f.png)
![demo-create-5](https://user-images.githubusercontent.com/21205679/206230055-257748e7-26d3-4d76-9115-0b6fb14168ed.png)
![demo-create-6](https://user-images.githubusercontent.com/21205679/206230134-17b7e5ca-c82d-4ea0-920c-0add87768c7f.png)
![demo-create-7](https://user-images.githubusercontent.com/21205679/206230135-541e220c-e4d0-4bd4-baac-a7f1f60105f5.png)
![demo-create-8](https://user-images.githubusercontent.com/21205679/206230136-f1065fa6-cf10-46fe-9dae-63b79c4e8a99.png)


## Enable backup feature for volume

Now when everything is working we would setup backup task for VM `100(windows-demo)`.

To do this we will create dedicated `zvol` on `Backup node` and set `Production node` to store back up information on it.

### Create a `zvol` responsible for storing backups on `Backup node`

Go to `Storage` tab of `Backup node` and create `backup-vm-100-disk-0` `zvol`. Name is arbitraty, but it would be better if this name will be easily associated with original volume.
![demo-create-backup-volume](https://user-images.githubusercontent.com/21205679/206247447-366dfde0-cd22-41df-8eef-75eed716ef6f.png)
![demo-create-backup-volume-2](https://user-images.githubusercontent.com/21205679/206247455-402f9050-d920-4abc-9b6e-898f0f57dbeb.png)

### Set the backup task on `Production node`
1. Go to `Storage/iSCSI Targets` tab of `Production node`
2. Find `zvol` `v_vm-100-disk-0` attached to respective target
3. Click setting for `v_vm-100-disk-0`
4. Select `Add to backup task`
![demo-add-backup-task-1](https://user-images.githubusercontent.com/21205679/206247246-3fa7ebb2-1a5c-47f0-8a48-6546c3d6e433.png)
5. Specify appropriate `retension-interval` plans
![demo-add-backup-task-2](https://user-images.githubusercontent.com/21205679/206247258-a9a92c6e-2cbb-483a-8596-0a642d6579ac.png)
6. Set `Destination server` field to `Backup node` by providing its IP address in. In this case it is 
7. Set `Resource path` as `Pool-0/backup-vm-100-disk-0` or other `zvol` name if you named `zvol` `backup-vm-100-disk-0` differently.
![demo-add-backup-task-remote-vol-2](https://user-images.githubusercontent.com/21205679/206247279-fee587b2-c055-44d8-9c22-93058dabd9f1.png)
![demo-add-backup-task-remote-vol](https://user-images.githubusercontent.com/21205679/206247270-7aec2b00-535c-4f07-9034-224e15acf404.png)

8. Go through other configurations

![demo-add-backup-task-remote-vol-3](https://user-images.githubusercontent.com/21205679/206247307-009d48eb-0474-4544-9a89-ffdd9159068f.png)
![demo-add-backup-task-remote-vol-4](https://user-images.githubusercontent.com/21205679/206247341-a40cb8fb-4805-4113-8979-c4299be3c626.png)
![demo-add-backup-task-remote-vol-5](https://user-images.githubusercontent.com/21205679/206247352-e409669b-894e-4797-ad03-3cc29970621a.png)
9. Check `Production node` `Storage` menu `Snapshot` tab. `v_vm-100-disk-0` includes `A` and `B` icons.
* `A` for Auto-snapshots
* `B` for Backup functionality.
![demo-add-backup-task-remote-vol-6-done](https://user-images.githubusercontent.com/21205679/206247386-e0f465b6-e949-4fbc-ab6e-e0f93f8a5b37.png)

## Disaster
Imagine that something bad happens and virtual machine or its data gets corrupted, encrypted or entire server was damaged by fire or other disaster.
In that case you can restore your virtual machine from back up that was made on `Backup node`.
All you need to do is to clone backuped volume and assign it to copy of a virtual machine.
In the next section we will show how user can do it.

## Clone backuped volume on backup machine

To get access to you previously backed up data user have to make a clone of appropriate snapshot stored on `Backup node`:
1. Go to `Backup node`, and in `Storage` menu find `Snapshots` tab.

![demo-clone-backup-1](https://user-images.githubusercontent.com/21205679/206448735-42aae0ff-f723-4da8-bf3c-b18a8c42d513.png)

2. Select `zvol` that you want to restore by pressing `Select resource` and finding appropriate volume. This action will list you all
available snapshots.

![demo-clone-backup-2](https://user-images.githubusercontent.com/21205679/206448746-0d9b0722-c397-44ca-8865-535b73fd66b7.png)

3. Select snapshot that contains most actual version of storage that you are interested in and press `Clone`.

![demo-clone-backup-3](https://user-images.githubusercontent.com/21205679/206448754-2207a71e-bfd7-404d-80c7-56289189ab74.png)

4. Name new clone in a way that will resemble format `v_vm-<vm id>-disk-<disk id>`.
* `vm id` is a virtual machine identifier that is unique id inside proxmox
* `disk id` is unique disk identifier if disk associated with virtual machine `100`.
Where `disk id` is number that is expected to be unique respective to virtual machine with id `100`.
So that couple 
 In out case it is `v_vm-100-disk-1`.

![demo-clone-backup-4](https://user-images.githubusercontent.com/21205679/206459111-589ff02d-9a1d-4388-a30b-e12fb7a9a28b.png)

5. If everything is `OK` you will see new `zvol` in `iSCSI targets` tab of `Storage` menu.
![demo-clone-backup-5](https://user-images.githubusercontent.com/21205679/206459118-7f99ce1f-44eb-4811-8254-4bc55d11f82d.png)

6. Also volume `v_vm-100-disk-1` will appear in `VM Disks` tab of `storage pool` `jdss-Backup-node-Pool-0` in Proxmox.
![demo-clone-backup-6](https://user-images.githubusercontent.com/21205679/206459121-774fa953-db82-4d5c-9e35-cf73b6ad3185.png)

## Modify proxmox config
Once volume is restored user can create temporary virtual machine.

To do it go to `/etc/pve/qemu-server/`
```bash
root@proxmox-demo:~# cd /etc/pve/qemu-server/
```
And duplicate config file for virtual machine that you want to restore.
In our case it is virtual machine with id `100`.
Make sure that `copy` of original virtual machine config has unique id number.
In this case we use `101` as it is next free `vm id`

```bash
root@proxmox-demo:/etc/pve/qemu-server# ls
100.conf
root@proxmox-demo:/etc/pve/qemu-server# cp ./100.conf ./101.conf
```

Open virtual machine config in your favorite editor 
```
boot: order=ide0;ide2;net0
cores: 4
cpu: qemu64
ide0: jdss-Production-node-Pool-0:vm-100-disk-0,size=32G
us.iso,media=cdrom,size=5420408K
kvm: 0
machine: pc-i440fx-7.1
memory: 8192
meta: creation-qemu=7.1.0,ctime=1670424775
name: windows-demo
net0: e1000=3E:7B:70:D7:D7:E9,bridge=vmbr1,firewall=1
numa: 0
ostype: win10
scsihw: virtio-scsi-single
smbios1: uuid=7e718afc-0e17-4440-8432-0205b113d6ca
sockets: 1
vmgenid: e6ce6195-974a-4349-832f-6e7d4b115665
```
And modify line responsible for storage information.
In this case it is `ide0` record.
```
ide0: jdss-Production-node-Pool-0:vm-100-disk-0,size=32G
```
Make it point out to clone created in previous step by specifying `Backup node` storage pool and proper volume name.
In this case it is: `jdss-Vackup-node-Pool-0:vm-100-disk-1`

So the line will look like:
```
ide0: jdss-Backup-node-Pool-0:vm-100-disk-1,size=32G
```
Also operator might want to change `name` field, so it would be more convenient to navigate.
```
name: windows-demo
```
change to 
```
name: windows-demo-backup
```
So that final config will look like:
```
boot: order=ide0;ide2;net0
cores: 4
cpu: qemu64
ide0: jdss-Backup-node-Pool-0:vm-100-disk-1,size=32G
us.iso,media=cdrom,size=5420408K
kvm: 0
machine: pc-i440fx-7.1
memory: 8192
meta: creation-qemu=7.1.0,ctime=1670424775
name: windows-demo-backup
net0: e1000=3E:7B:70:D7:D7:E9,bridge=vmbr1,firewall=1
numa: 0
ostype: win10
scsihw: virtio-scsi-single
smbios1: uuid=7e718afc-0e17-4440-8432-0205b113d6ca
sockets: 1
vmgenid: e6ce6195-974a-4349-832f-6e7d4b115665
```

Once file is written virtual machine will appear in proxmox:

![demo-clone-restore](https://user-images.githubusercontent.com/21205679/206463442-68747ada-bb2d-4e17-8900-e6513d38b232.png)

## Restore storage
Now user have fully functioning virtual machine and can run it to make sure that all expected data is present.
But we do not recommend using this virtual machine as production as its storage is located on a `Backup node`.
There fore next best move would be to migrate this virtual machine to `Production node`

To do it operator have to go to proxmox and find virtual machine that was created from backup, in this case it is `101(window-demo-backup)`.
Select disk `jdss-Backup-node-Pool-0:vm-100-disk-1` in `Hardware` menu, and press `Disk Action`, there you will find `Move Storage`
![demo-clone-restore-2](https://user-images.githubusercontent.com/21205679/206466667-4ddd6920-e049-4cce-bb1a-adc4cdfc0868.png)

Select resource pool associated with `Production node`, in this case it is`jdss-Production-node-Pool-0` and start transaction.

![demo-clone-restore-3](https://user-images.githubusercontent.com/21205679/206509344-413618a7-ec9b-4648-b1fd-73c939b132d2.png)

Once it is done virtual machine is back to `Production node` and you can continue regular operation. Please notice that proxmox will rename volume. In particular case it would be named `vm-101-disk-0`.
![demo-clone-restore-4](https://user-images.githubusercontent.com/21205679/206512276-752c8790-8172-445c-8f9d-166fa1598e9d.png)

Also we would recommend to set up `backup` task again. As this volume is treated as new one and no backup tasks is applied to it.
