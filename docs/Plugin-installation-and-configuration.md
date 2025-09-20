# Installing/Uninstalling

The JovianDSS Proxmox plugin can be deployed using the automated installation script (recommended), installing the Debian package manually, or by running the Makefile-based installation from source.

**Important**  
The JovianDSS plugin **must** be installed on **every** Proxmox VE node in your cluster.

## Automated Installation (Recommended)

The easiest way to install the JovianDSS Proxmox plugin is using our automated installation script. This script handles downloading, verification, and installation across all cluster nodes.

### Quick Installation

**Install on all cluster nodes:**
```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --all-nodes --no-restart
```

**Remove from all cluster nodes:**
```bash
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --remove --all-nodes --no-restart
```

**Note:** The `--no-restart` flag prevents automatic pvedaemon restart, allowing you to configure the plugin before restarting services manually.

### Additional Options

```bash
# Install latest stable version on local node only
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl -

# Install pre-release version on all nodes
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --pre --all-nodes

# Install specific version on all nodes
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --version v0.10.5 --all-nodes

# Test installation without making changes
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl | perl - --dry-run --all-nodes
```

### Download and Run Locally

If you prefer to download and inspect the script first:

```bash
# Download the script
curl -fsSL https://raw.githubusercontent.com/open-e/JovianDSS-Proxmox/main/install.pl -o install.pl

# Make it executable and run
chmod +x install.pl
./install.pl --all-nodes --no-restart

# View available options
./install.pl --help
```

### Security Features

The installation script includes several security features:

- **Package verification**: Downloads and verifies SHA256 checksums when available
- **HTTPS-only downloads**: All downloads use secure HTTPS connections
- **Source verification**: Downloads packages directly from GitHub releases
- **Cluster discovery**: Automatically discovers all cluster nodes
- **Confirmation prompts**: Shows all affected nodes before proceeding

### Troubleshooting

If you encounter issues:

1. **Permission errors**: Try adding `--sudo` flag if not running as root
2. **Network issues**: Ensure nodes can access GitHub and have internet connectivity
3. **SSH issues**: For cluster operations, ensure SSH key authentication is set up between nodes

After installation, proceed to the [Configuration](#configuration) section to set up storage configurations.

## Manual Installation for `deb` package

```bash
apt install ./open-e-joviandss-proxmox-plugin_0.10.0.deb

systemctl restart pvedaemon
```

After installation  restart the Proxmox `pvedaemon` service.

```bash
systemctl restart pvedaemon
```

To remove the plugin call:

```bash
apt remove -y open-e-joviandss-proxmox-plugin
```

## Install from source 

Installation can be done by `make` inside source code folder:

```bash
apt install python3-oslo.utils git
git clone https://github.com/open-e/JovianDSS-Proxmox.git
cd ./JovianDSS-Proxmox
make install
```

Removing JovianDSS Proxmox plugin:

```bash
make uninstall
```


## Configuration

For a concise walkthrough, see the [Quick Start guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start).

For a full listing of all configuration options and their meanings, refer to the [Plugin Configuration guide](https://github.com/open-e/JovianDSS-Proxmox/wiki/Plugin-configuration).
