# Open-E JovianDSS Proxmox VE Plugin Best Practices

The following best practices describe supported and safe usage patterns when operating **Proxmox VE** together with **Open-E JovianDSS** via the **Open-E JovianDSS Proxmox VE Plugin**.
They help prevent accidental data loss, service disruption, or inconsistent system state caused by bypassing the **Proxmox VE** resource manager. 


## iSCSI Volumes — Important Notes

Do Not Delete Proxmox VE-Managed Volumes via the Open-E JovianDSS UI.

Volumes created and managed by **Proxmox VE** must not be deleted directly from the **Open-E JovianDSS** Web UI.

**Proxmox VE** maintains its own internal state and metadata for managed volumes,

and removing them outside of **Proxmox VE** can lead to orphaned resources, broken VM/CT configurations,

failed storage operations, and data loss.

All **Proxmox VE**-managed volumes should be removed using **Proxmox VE** tools such as the **Web UI** or **CLI**.

For example, to delete a **Proxmox VE**-managed volume:
```bash
pvesm free jdss-Pool-0:vm-100-disk-4
```
## VMs/Containers Assigned to Proxmox VE HA

Virtual machines or containers assigned to **Proxmox VE High Availability (HA)** should not be managed directly by users through operations such as rollback, migration, or direct state changes while they are under active **Proxmox VE HA** control. These actions may conflict with **Proxmox VE HA** rules, trigger automatic recovery behavior, or be blocked despite underlying storage being healthy.

To safely perform such operations:

  - First adjust the Proxmox VE HA state of the VM/CT (for example by disabling HA for that resource or marking it as ignored in HA).
  - Then perform the desired action once HA will not interfere.