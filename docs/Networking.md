# Plugin networking

## Plugin and Volume DATA

The JovianDSS Proxmox plugin integrates JovianDSS with Proxmox VE, giving you unrestricted Proxmox functionality while natively leveraging JovianDSS storage as part of the Proxmox VE ecosystem.

The plugin manages volumes on the JovianDSS side—allocating, deleting, snapshotting, and reverting them—and exposes those volumes to Proxmox VE over iSCSI.
Volume data travels only over the VIP addresses specified in `data_addresses` within your `storage.cfg` file.

The plugin routes all iSCSI data transfers exclusively through these VIP addresses.

### How it works

#### Configuration

1. VIP addresses allocated (e.g.`192.168.28.102`,`192.168.29.102`, `192.168.30.102`) to the JovianDSS `Pool`, [see the JovianDSS VIPs section for details](#joviandss-vips)
2. The [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses) property in `storage.cfg` used to send management requests over the JovianDSS REST API. These addresses are provided as a comma-separated list.
3. The [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) property in storage.cfg specifies the VIPs allocated to the JovianDSS `Pool` for data transfer, also as a comma-separated list (e.g., 192.168.29.102,192.168.30.102). These VIPs must be accessible from the Proxmox VE server. See the Routing example section for details](#routing-example).
4. The [user_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_name) and [user_password](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_password) properties in `storage.cfg` define the user credentials used to authenticate with the JovianDSS REST API via the [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses). [user_name](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_name) and [user_password](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#user_password) must be consistent across all nodes in the [High Availability Cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/) cluster that share the pool.

```
...
user_name admin
user_password <some secret password>
control_addresses 192.168.28.102
data_addresses 192.168.29.102,192.168.30.102
...
```

#### Operation

When a virtual machine is created and started (for example, VM 100 with a single disk `vm-100-disk-0`

    1. The plugin creates an iSCSI target on JovianDSS — `iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0` — and assigns the VIP addresses `192.168.29.102` `192.168.30.102` to the target `iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0`.
    
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

    Note:
    The JovianDSS Proxmox plugin does not allocate or assign VIP addresses to the JovianDSS `Pool`.
    It only assigns VIP addresses already added to the pool to newly created iSCSI targets.

    Specifying VIP addresses in the data_addresses property that have not previously been assigned to the JovianDSS pool does not create additional iSCSI targets or data transfer paths; such addresses are ignored.

    If no VIP addresses are assigned to the JovianDSS pool, volume provisioning to the Proxmox VE server over iSCSI fails:
    ```
    TASK ERROR: Unable to identify VIP name for ip's: 192.168.29.102,192.168.30.102. Please make sure that VIP are assigned to the Pool 
    ```


If currently active JovianDSS server experiences a critical hardware failure, the `Pool` will automatically migrate to backup node.

Both [control_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#control_addresses) and [data_addresses](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration#data_addresses) assigned to the same JovianDSS `Pool` will migrate to the backup node within [High Availability cluster](https://www.open-e.com/products/open-e-joviandss/open-e-joviandss-advanced-metro-high-availability-cluster-feature-pack/), along with the iSCSI targets and active connections.

The Proxmox plugin, along with the virtual machines it supports, will continue to operate using the same VIP addresses.

## JovianDSS VIPs

### Adding a VIP to JovianDSS `Pool`

Adding a virtual IP address to the JovianDSS pool is straightforward.

Navigate to `Storage->Pool->Virtual IPs->Add Virtual IP`

![vip_select_pool2](https://github.com/user-attachments/assets/94a17f3a-41d5-44b0-8c95-f7931c5846b5)

Specify the VIP properties - such as its address and netmask - and select the network interface to which it is assigned.

![vip_add_pool2](https://github.com/user-attachments/assets/fffb8606-5afa-45d8-9a17-090afae8e786)

For detailed information on JovianDSS network configurations, consult the following resources:
- [JovianDSS Advanced Metro High Avability Cluster Step by Step](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step.pdf) 
- [JovianDSS Advanced Metro High Avability Cluster Step by Step 2](https://www.open-e.com/site_media/download/documents/Open-E-JovianDSS-Advanced-Metro-High-Avability-Cluster-Step-by-Step-2rings.pdf)
- [Open-E Knowledgebase](https://kb.open-e.com/joviandss-121/) 
- [iSCSI Targets Available Through Specific VIPs](https://www.youtube.com/watch?v=iFF9VPKUdTk)
- [JovianDSS failover mechanism technologies explained](https://kb.open-e.com/jdss-joviandss-failover-mechanism-technologies-explained_3161.html)

## Example

Consider a scenario in which the Proxmox VE cluster and the JovianDSS storage are both attached to three physical networks:

1. *Net1* 172.28.0.0/16 Management/Internet connection
2. *Net2* 172.29.0.0/16 Data network
2. *Net2* 172.30.0.0/16 Data network


![two-nodes-three-serv](https://github.com/user-attachments/assets/48c32685-bf9f-46a5-82d9-8eb17fca80ca)

There are two JovianDSS storage nodes with *Failover* enabled, and `Pool-2` has three virtual IP addresses assigned:

- VIP0 192.168.28.102 associated with physical interfaces connected to *Net1* 172.28.0.0/16
- VIP1 192.168.29.102 associated with physical interfaces connected to *Net2* 172.29.0.0/16
- VIP2 192.168.30.102 associated with physical interfaces connected to *Net3* 172.30.0.0/16

![vips-3-pool2-2](https://github.com/user-attachments/assets/5adf1cf0-fe59-456f-ab74-0170e194069b)

A three-node Proxmox VE cluster in which each node has three network interfaces connected to physical networks:

- *vmbr0* connected to *Net1* associated with virtual bridge vmbr0 with ip 172.28.143.11/16 
- *ens224* connected to *Net2* associated with interface ens224 with ip 172.29.143.11/16 
- *ens256* connected to *Net3* associated with interface ens256 with ip 172.30.143.11/16

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

Such configurations is very complex and it is recommended to check connectivity of each Proxmox VE server in a cluster and JovianDSS VIP's. 
```
root@node1:~# ping -c 5 192.168.28.102
```

If connectivity is good, you’ll see output similar to:
```
PING 192.168.28.102 (192.168.28.102) 56(84) bytes of data.
64 bytes from 192.168.28.102: icmp_seq=1 ttl=64 time=0.228 ms
64 bytes from 192.168.28.102: icmp_seq=2 ttl=64 time=0.214 ms
64 bytes from 192.168.28.102: icmp_seq=3 ttl=64 time=0.186 ms
64 bytes from 192.168.28.102: icmp_seq=4 ttl=64 time=0.167 ms
64 bytes from 192.168.28.102: icmp_seq=5 ttl=64 time=0.178 ms

--- 192.168.28.102 ping statistics ---
5 packets transmitted, 5 received, 0% packet loss, time 4075ms
rtt min/avg/max/mdev = 0.167/0.194/0.228/0.022 ms
```

Missing route configuration is a potential cause of connectivity issues.

Static routes in Proxmox VE are defined by creating the file `/etc/network/interfaces.d/joviandss_pool_2_vip_routes`
```
iface vmbr0 inet static
        up /sbin/ip route add 192.168.28.102 dev vmbr0
        down /sbin/ip route add 192.168.28.102 dev vmbr0

iface ens224 inet static
        up /sbin/ip route add 192.168.29.102 dev ens224
        down /sbin/ip route add 192.168.29.102 dev ens224

iface ens256 inet static
        up /sbin/ip route add 192.168.30.102 dev ens256
        down /sbin/ip route add 192.168.30.102 dev ens256
```
