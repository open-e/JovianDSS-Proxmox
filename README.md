# JovianDSS-Proxmox

## Configuring

In order to install and run Open-E JovianDSS it is required to declare storage in 
proxmox storage configuration file:
`/etc/pve/storage.cfg` 

```
open-e: joviandss
        joviandss_address 172.16.0.220
        pool_name Pool-0
        config /etc/pve/joviandss.cfg
```

And according to path provided in `storage.cfg` joviandss.yaml configuration. 

```yaml
volume_backend_name: 'jdss-0'
chap_password_len: '14'
driver_use_ssl: True
target_prefix: 'iqn.2016-04.com.open-e:'
jovian_pool: 'Pool-0'
jovian_block_size: '64K'
jovian_rest_send_repeats: 1
san_api_port: 82
target_port: 3260
san_hosts: 
  - '10.0.0.245'
san_login: 'admin'
san_password: 'admin'
san_thin_provision: True
```
## Installing/Uninstalling

Installatiuon can be done by `make` utilit.

```bash
make install
```

Removing proxmox plugin with `jdssc`
```bash
make uninstall
```


## Supported features

- [x] Create volume
- [x] Delete volume
- [x] Create snapshot
- [x] Delete snapshot
- [x] Restore snapshot
- [x] Create template
- [x] Delete template
- [ ] ISO support
- [ ] Container support
