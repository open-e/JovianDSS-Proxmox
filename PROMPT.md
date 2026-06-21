# Review code of JovianDSS Proxmox Plugin

Check documentation in docs folder

Check if changes in current branch are coherent and do not break things.

Review code to be coherent.

There are 2 parts of software:

perl plugin
    ./OpenEJovianDSS/Common.pm
    ./OpenEJovianDSS/Lock.pm
    ./OpenEJovianDSS/NFSCommon.pm
    ./OpenEJovianDSSPlugin.pm
    ./OpenEJovianDSSNFSPlugin.pm

python tool located in jdssc folder

Code can be tested on remote nodes available over ssh: pve-91-1, pve-91-2, pve-91-3
