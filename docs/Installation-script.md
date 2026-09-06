JovianDSS Proxmox plugin can be installed with the `install.pl` script, which
simplifies installation and removal of the plugin across Proxmox VE clusters.

## Installation

By default `install.pl` will check and install the latest JovianDSS Proxmox plugin release on the
node that is running it:

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl -
```

Cluster-wide installation can be done by:

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes
```

It is recommended to restart the `pvedaemon`, `pvestatd`, `pveproxy`, `pve-ha-lrm` and `pve-ha-crm` services on every Proxmox server where the plugin was installed.
Automatic restart can be done by adding the `--restart` argument:

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes --restart
```

But it is **IMPORTANT** to remember that the `install.pl` script with `--restart` should **NOT** be called from
the Proxmox Web UI as `--restart` will restart the shell interfaces provided by the Proxmox Web UI.

The recommended multipath configuration file `open-e-joviandss.conf` is automatically installed to `/etc/multipath/conf.d/` as part of the plugin package.

## Removal

Removal of the JovianDSS Proxmox plugin can be done in the same manner as installation:

```bash
# this node only
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --remove

# all nodes in the cluster
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --remove --all-nodes
```

## Options


### all-nodes

**Default**: `False`

Install or remove the plugin on all cluster nodes instead of just the local node. The script automatically discovers cluster node IPs from cluster membership information.


### assume-yes

**Default**: `False`


Automatically answer "yes" to all prompts. This enables non-interactive mode, useful for automation scripts and CI/CD pipelines.

Without this flag, the installer prompts for confirmation before installing or removing packages on cluster nodes. With `--assume-yes`, the installer proceeds automatically without user interaction.

Example:
```bash
./install.pl --all-nodes --assume-yes
```


### pre

**Default**: `stable`

Install the latest pre-release instead of the latest stable release. Use this flag to test new features before they are officially released.

### reinstall

**Default**: `False`


Use the `--reinstall` apt flag during package installation. This forces reinstallation even if the package is already installed.


### remove

**Default**: `False`

Remove the plugin instead of installing it. Can be combined with `--all-nodes` to remove from all cluster nodes.


### restart

**Default**: `False`

Automatically restart the affected Proxmox VE services after installation or removal (see [Installation](#installation) for the list).
Must **not** be used from the Proxmox Web UI shell.


### version

**Default**: None

Install a specific release tag instead of the latest version. Specify the exact GitHub release tag (e.g., `v0.10.8-2`).

## Notes

### Other options

- `--allow-downgrades` — allow installing an older package version than the one currently installed (apt refuses downgrades by default). Downgrading can cause configuration incompatibilities; make sure you have backups
- `--dry-run` — show what would be done without executing any commands
- `--help`, `-h` — show usage information
- `--ssh-flags "<flags>"` — extra SSH flags for remote operations (default: `-o BatchMode=yes -o StrictHostKeyChecking=accept-new`)
- `--sudo` — use sudo for commands when not running as root
- `--user <name>` — SSH user for remote operations (default: `root`)
- `--verbose`, `-v` — show detailed output

## Verification

Check installed version:
```bash
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin
```

Verify cluster installation:
```bash
# Run on each node
pvesm status
```

## Next Steps

After successful installation:

1. **Configure Storage**: Follow the [iSCSI Quick Start](Quick-Start-iSCSI) or [NFS Quick Start](Quick-Start-NFS) to configure storage
2. **Network Setup**: Review [Networking](Networking) for optimal network configuration
3. **Multipath Setup**: See [Multipathing](Multipathing) for advanced multipath configuration
