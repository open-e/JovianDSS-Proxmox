
JovianDSS Proxmox plugin can be installed with `install.pl` script.

`install.pl` simplifies installation and removal of the plugin across Proxmox VE clusters.


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

It is recommended to restart the `pvedaemon` service on every Proxmox server where the plugin was installed.
Automatic restart can be done by adding the `--restart` argument.

But it is **IMPORTANT** to remember that the `install.pl` script with `--restart` should **NOT** be called from
the Proxmox Web UI as `--restart` will restart the shell interfaces provided by the Proxmox Web UI.

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes --restart
```

The installation script `install.pl` can also provide recommended multipath configurations by placing the `open-e-joviandss.conf` file
in the `/etc/multipath/conf.d/` folder.
To do so, add `--add-default-multipath-config` as an argument to the `install.pl` script.

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes --add-default-multipath-config
```

If you already have `open-e-joviandss.conf` installed but want to reinstall it,
add the `--force-multipath-config` flag to the arguments.

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes --add-default-multipath-config --force-multipath-config
```

## Removal

Removal of the JovianDSS Proxmox plugin can be done in the same manner as installation: manually using `apt` or using the `install.pl` script.

Single node removal can be done by running the script with the `--remove` flag added.

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --remove
```

To remove the plugin from all nodes in the cluster, add the `--all-nodes` flag.

```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --remove --all-nodes
```


## Options

### pre

**Default**: `stable`


Install the latest pre-release instead of the latest stable release. Use this flag to test new features before they are officially released.

### version

**Default**: None


Install a specific release tag instead of the latest version. Specify the exact GitHub release tag (e.g., `v0.10.8-2`).

Example:
```bash
./install.pl --version v0.10.8-2 --all-nodes
```

### sudo

**Default**: `False`


Use sudo for commands when not running as root. This flag is useful when the script is executed by a non-root user who has sudo privileges.

### restart

**Default**: `False`


Automatically restart the `pvedaemon` service after installation or removal.

**Important**: Do not use this flag when running the script from the Proxmox Web UI, as it will restart the shell interfaces provided by the Web UI.

### dry-run

**Default**: `False`


Show what would be done without actually executing the commands. Useful for testing the installation process and verifying which nodes would be affected.

### reinstall

**Default**: `False`


Use the `--reinstall` apt flag during package installation. This forces reinstallation even if the package is already installed.

### allow-downgrades

**Default**: `False`


Allow installing older package versions. By default, apt prevents downgrading packages as it can cause compatibility issues. Use this flag when you need to roll back to a previous version.

**Use cases**:
- Rolling back from a buggy version to a stable previous release
- Testing specific versions for compatibility
- Reverting from pre-release to stable

Example:
```bash
./install.pl --version v0.9.9 --allow-downgrades --all-nodes
```

**Warning**: Downgrading packages can cause configuration incompatibilities or data issues. Ensure you have backups before downgrading.

### assume-yes

**Default**: `False`


Automatically answer "yes" to all prompts. This enables non-interactive mode, useful for automation scripts and CI/CD pipelines.

Without this flag, the installer prompts for confirmation before installing or removing packages on cluster nodes. With `--assume-yes`, the installer proceeds automatically without user interaction.

Example:
```bash
./install.pl --all-nodes --assume-yes
```

**Use cases**:
- Automated deployments
- CI/CD integration
- Scripted cluster management
- Remote execution where interactive prompts are not possible

### assume-max-workers-one-yes

**Default**: `False`


Automatically set the Proxmox cluster option `Maximal Workers/bulk-action` to `1` without prompting.
This is recommended to prevent concurrent worker locking issues observed with the plugin.

Example:
```bash
./install.pl --all-nodes --assume-max-workers-one-yes
```

### verbose

**Default**: `False`


Show detailed output during installation and removal operations. Use `-v` or `--verbose` to enable verbose mode.

### help

**Default**: None

Display the help message with usage information and available options. Use `-h` or `--help` to show help.

### all-nodes

**Default**: `False`

Install or remove the plugin on all cluster nodes instead of just the local node. The script automatically discovers cluster node IPs from cluster membership information.

Node discovery methods (in order of preference):
1. `/etc/pve/.members` file
2. `PVE::Cluster::get_members()` API
3. `pvecm nodes` command output


### remove

**Default**: `False`

Remove the plugin instead of installing it. Can be combined with `--all-nodes` to remove from all cluster nodes.

### add-default-multipath-config

**Default**: `False`

Install the default multipath configuration file during installation. This copies the template from `/etc/joviandss/multipath-open-e-joviandss.conf.example` to `/etc/multipath/conf.d/open-e-joviandss.conf`.

The installer checks for existing SCST vendor device configurations and warns if conflicts are detected.

### force-multipath-config

**Default**: `False`

Overwrite existing multipath configuration files when used with `--add-default-multipath-config`. By default, the installer skips multipath configuration if the target file already exists.

## Notes

### Multipath Configuration

When using `--add-default-multipath-config`, the installer:

- Copies template from `/etc/joviandss/multipath-open-e-joviandss.conf.example`
- Installs to `/etc/multipath/conf.d/open-e-joviandss.conf`
- Checks for conflicting SCST vendor configurations
- Reconfigures multipathd service

**Warning**: The installer warns if existing SCST vendor devices are detected in multipath configuration, as the default config may affect their operation.

### Cluster Max Workers

After a successful installation, the installer may prompt to set the Proxmox cluster option
`Maximal Workers/bulk-action` to `1`. Higher values can cause locking issues with concurrent
plugin operations. Use `--assume-max-workers-one-yes` to apply this change automatically.

### Verification

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

1. **Configure Storage**: Follow the [Quick Start guide](Quick-Start.md) to configure storage pools
2. **Network Setup**: Review [Networking](Networking.md) for optimal network configuration
3. **Multipath Setup**: See [Multipathing](Multipathing.md) for advanced multipath configuration
