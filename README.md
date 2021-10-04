# JovianDSS-Proxmox


pen-e: joviandss
        joviandss_address 172.16.0.220
        pool_name Pool-0
        config /etc/pve/joviandss.cfg

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
