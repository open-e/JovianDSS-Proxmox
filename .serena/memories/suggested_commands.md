# Suggested Commands

## Building
```bash
# Build .deb package (from project root)
make deb

# Install locally (from project root)
make install DESTDIR=/

# Uninstall
make uninstall DESTDIR=/
```

## jdssc CLI (Python)
```bash
# Install jdssc (from jdssc/ directory)
cd jdssc && make install DESTDIR=/

# Run jdssc commands
jdssc --control-addresses <ip> pool <pool> volumes list
jdssc --control-addresses <ip> pool <pool> nas_volumes list
jdssc --control-addresses <ip> pool <pool> nas_volume -d <dataset> snapshots list
jdssc --control-addresses <ip> pool <pool> nas_volume -d <dataset> snapshot <snap> publish
```

## Perl Syntax Checking
```bash
# Check Perl plugin syntax
perl -c OpenEJovianDSSPlugin.pm
perl -c OpenEJovianDSSNFSPlugin.pm
perl -I. -c OpenEJovianDSS/Common.pm
perl -I. -c OpenEJovianDSS/NFSCommon.pm
```

## Python Syntax Checking
```bash
# Check Python syntax (from project root)
python3 -m py_compile jdssc/jdssc/nas_snapshot.py
python3 -m py_compile jdssc/jdssc/jovian_common/driver.py
python3 -m py_compile jdssc/jdssc/jovian_common/rest.py
```

## Git
```bash
git status
git log --oneline -20
git diff
```

## Proxmox Plugin Management (on Proxmox host)
```bash
# Add storage
pvesm add joviandss <name> --pool_name <pool> --user_name admin --user_password admin --content images,rootdir --ssl_cert_verify 0 --control_addresses <ip> --data_addresses <ip> --path /mnt/pve/<name> --create-base-path 1 --shared 1

# Check installed version
dpkg-query -W -f='${Version}\n' open-e-joviandss-proxmox-plugin

# Restart plugin
systemctl restart pvedaemon

# Plugin logs
cat /var/log/joviandss/joviandss.log
```

## Testing
Test cases are YAML files in `tests/testcases/` (plugin and jdssc categories).
Testing framework is in separate repo: open-e/pve-testing.
