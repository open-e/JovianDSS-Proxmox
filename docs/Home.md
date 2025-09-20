JovianDSS Proxmox Plugin

Integrate high-availability, software-defined storage with Proxmox VE via JovianDSS.

## Overview

The JovianDSS Proxmox Plugin enables Proxmox VE clusters to use JovianDSS storage pools as backend storage via iSCSI.

It provides:

- Automated Volume Management: Dynamically attach/detach iSCSI targets and manage multipath devices.
- High Availability: Support for JovianDSS failover and multipathing across multiple network interfaces.
- Thin Provisioning: On-demand volume allocation to optimize storage usage.
- Cluster-wide Integration: Treat storage as shared, enabling live migration and HA features in Proxmox VE.

## Getting Started

Start using the plugin by going through the [Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start).

## Documentation

Comprehensive documentation is maintained on GitHub:

* Plugin Configuration: [Plugin-configuration](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration)

* Networking: [Plugin Networking](https://github.com/open-e/JovianDSS-Proxmox/wiki/Networking)

* Multipathing: [Multipathing Guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Multipathing)

For a full list of topics, visit the [JovianDSS Proxmox Wiki](https://github.com/open-e/JovianDSS-Proxmox/wiki).

## Support & Contribution

Report issues and feature requests via the repository Issues.

Contributions are welcome! Please fork the repository, submit a pull request.
