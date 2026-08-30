# Plugin networking

## Plugin and volume data

The plugin manages volumes on the JovianDSS side — allocating, deleting, snapshotting, and reverting them — and exposes those volumes to Proxmox VE over iSCSI.
All iSCSI data travels exclusively over the VIP addresses specified in `data_addresses` in `storage.cfg`.

### How it works

#### Configuration

1. VIP addresses (e.g. `192.168.28.102`, `192.168.29.102`, `192.168.30.102`) are allocated to the JovianDSS `Pool` — [see the JovianDSS VIPs section](#joviandss-vips).
2. [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses) — a comma-separated list of addresses used to send management requests to the JovianDSS REST API.
3. [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) — a comma-separated list of the pool’s VIPs used for data transfer (e.g. `192.168.29.102,192.168.30.102`). These VIPs must be reachable from every Proxmox VE node; see the [Example](#example) section.
4. [user_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_name) and [user_password](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_password) — REST API credentials; they must be identical across all nodes of a [High Availability cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/) that share the pool.

```
...
user_name admin
user_password <some secret password>
control_addresses 192.168.28.102
data_addresses 192.168.29.102,192.168.30.102
...
```

#### Operation

When a virtual machine is created and started (for example, VM 100 with a single disk `vm-100-disk-0`):

1. The plugin creates an iSCSI target on JovianDSS — `iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0` — and assigns the VIP addresses `192.168.29.102`, `192.168.30.102` to it.

2. The plugin creates the corresponding iSCSI record on the Proxmox VE server that is hosting the virtual machine.

   ```
   iscsiadm --mode node -p 192.168.29.102 --targetname iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0 -o new
   iscsiadm --mode node -p 192.168.30.102 --targetname iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0 -o new
   ```

3. The plugin logs in to the target.

   ```bash
   iscsiadm --mode node -p 192.168.29.102 --targetname iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0 --login
   iscsiadm --mode node -p 192.168.30.102 --targetname iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0 --login
   ```

> **Note:** The plugin does not allocate VIP addresses to the JovianDSS `Pool`; it only assigns VIPs already added to the pool to newly created iSCSI targets.
>
> Entries in `data_addresses` that are not VIPs of the pool are ignored — they create no additional targets or data paths. If none of the addresses match a pool VIP, volume provisioning fails:
>
> ```
> TASK ERROR: Unable to identify VIP name for ip's: 192.168.29.102,192.168.30.102. Please make sure that VIP are assigned to the Pool
> ```


If the active JovianDSS node suffers a critical hardware failure, the `Pool` migrates automatically to the backup node of a [High Availability cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/) — together with its VIPs, iSCSI targets, and active connections.

The plugin and the virtual machines it serves continue operating over the same VIP addresses.

## JovianDSS VIPs

### Adding a VIP to JovianDSS `Pool`

Navigate to `Storage->Pool->Virtual IPs->Add Virtual IP`

![vip_select_pool2](https://github.com/user-attachments/assets/94a17f3a-41d5-44b0-8c95-f7931c5846b5)

Specify the VIP properties - such as its address and netmask - and select the network interface to which it is assigned.

![vip_add_pool2](https://github.com/user-attachments/assets/fffb8606-5afa-45d8-9a17-090afae8e786)

For detailed information on JovianDSS network configurations, consult the following resources:
- [JovianDSS Advanced Metro High Availability Cluster Step-by-Step](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step.pdf)
- [JovianDSS Advanced Metro High Availability Cluster Step-by-Step (2 rings)](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)
- [Open-E Knowledgebase](https://kb.open-e.com/joviandss-121/) 
- [iSCSI Targets Available Through Specific VIPs](https://www.youtube.com/watch?v=iFF9VPKUdTk)
- [JovianDSS failover mechanism technologies explained](https://kb.open-e.com/jdss-joviandss-failover-mechanism-technologies-explained_3161.html)

## Example

Consider a scenario in which the Proxmox VE cluster and the JovianDSS storage are both attached to three physical networks:

1. *Net1* 172.28.0.0/16 Management/Internet connection
2. *Net2* 172.29.0.0/16 Data network
3. *Net3* 172.30.0.0/16 Data network


![two-nodes-three-serv](https://github.com/user-attachments/assets/48c32685-bf9f-46a5-82d9-8eb17fca80ca)

There are two JovianDSS storage nodes with *Failover* enabled, and `Pool-2` has three virtual IP addresses assigned:

- VIP0 192.168.28.102 associated with physical interfaces connected to *Net1* 172.28.0.0/16
- VIP1 192.168.29.102 associated with physical interfaces connected to *Net2* 172.29.0.0/16
- VIP2 192.168.30.102 associated with physical interfaces connected to *Net3* 172.30.0.0/16

![vips-3-pool2-2](https://github.com/user-attachments/assets/5adf1cf0-fe59-456f-ab74-0170e194069b)

A three-node Proxmox VE cluster in which each node has three network interfaces connected to physical networks:

- *vmbr0* — bridge on *Net1*, IP 172.28.143.11/16
- *ens224* — interface on *Net2*, IP 172.29.143.11/16
- *ens256* — interface on *Net3*, IP 172.30.143.11/16

Data transfers are restricted to the VIPs 192.168.29.102 and 192.168.30.102, while REST commands use only 192.168.28.102.

Example excerpt from the storage pool section for jdss-Pool-2 in the storage.cfg file:
```
joviandss: jdss-Pool-2
        pool_name Pool-2
        shared 1
        ...
        control_addresses 192.168.28.102
        data_addresses 192.168.29.102,192.168.30.102
        ...
```

Verify connectivity from every Proxmox VE node in the cluster to each JovianDSS VIP:
```
root@node1:~# ping -c 5 192.168.28.102
```

If connectivity is good, you’ll see output similar to:
```
PING 192.168.28.102 (192.168.28.102) 56(84) bytes of data.
64 bytes from 192.168.28.102: icmp_seq=1 ttl=64 time=0.228 ms
...
5 packets transmitted, 5 received, 0% packet loss, time 4075ms
```

Missing route configuration is a potential cause of connectivity issues.

Static routes in Proxmox VE are defined by creating the file `/etc/network/interfaces.d/joviandss_pool_2_vip_routes`
```
iface vmbr0 inet static
        up /sbin/ip route add 192.168.28.102 dev vmbr0
        down /sbin/ip route del 192.168.28.102 dev vmbr0

iface ens224 inet static
        up /sbin/ip route add 192.168.29.102 dev ens224
        down /sbin/ip route del 192.168.29.102 dev ens224

iface ens256 inet static
        up /sbin/ip route add 192.168.30.102 dev ens256
        down /sbin/ip route del 192.168.30.102 dev ens256
```
