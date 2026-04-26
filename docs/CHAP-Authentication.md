# iSCSI CHAP Authentication

CHAP (Challenge-Handshake Authentication Protocol) protects iSCSI traffic between
the Proxmox node (initiator) and JovianDSS (target). Without it, any host on the
SAN that knows a target IQN can attach to the LUN. With CHAP enabled, JovianDSS
challenges the initiator at login time and refuses connections that cannot produce
the correct response.

The plugin uses a single shared credential per storage instance — one username and
password applied to all iSCSI targets managed by that storage.

---

## Requirements

- JovianDSS firmware with iSCSI CHAP support
- CHAP password: minimum 12 characters, maximum 16 characters (iSCSI RFC 3720 limit)
- Proxmox VE plugin version 0.10.5 or later

---

## Enabling CHAP

CHAP is configured with three properties: `chap_enabled`, `chap_user_name`, and
`chap_user_password`. All three must be set together.

**When adding a new storage:**

```bash
pvesm add joviandss jdss-Pool-0 \
    --pool_name Pool-0 \
    --user_name admin \
    --user_password <rest-api-password> \
    --control_addresses 192.168.28.100 \
    --data_addresses 192.168.29.100 \
    --chap_enabled 1 \
    --chap_user_name chapuser \
    --chap_user_password <chap-password>
```

**On an existing storage:**

```bash
pvesm set jdss-Pool-0 \
    --chap_enabled 1 \
    --chap_user_name chapuser \
    --chap_user_password <chap-password>
```

The plugin validates that `chap_user_name` and `chap_user_password` are both present
when `chap_enabled` is set to `1`. If either is missing the command fails immediately
with an error.

### What gets written where

`chap_enabled` and `chap_user_name` are stored in `/etc/pve/storage.cfg` and
replicated to all cluster nodes automatically by Proxmox VE.

`chap_user_password` is a sensitive property — it is never written to `storage.cfg`.
Instead it is stored in the private password file on each node:

```
/etc/pve/priv/storage/joviandss/<storeid>.pw
```

The file holds both the REST API password and the CHAP password, one per line:

```
chap_user_password <chap-password>
user_password      <rest-api-password>
```

---

## Disabling CHAP

```bash
pvesm set jdss-Pool-0 --chap_enabled 0
```

Active iSCSI sessions are unaffected — CHAP is only checked at login time. The
change takes effect the next time a VM is started or migrated.

---

## Password Rotation

To change the CHAP password without downtime:

```bash
pvesm set jdss-Pool-0 --chap_user_password <new-password>
```

Active sessions continue uninterrupted. On the next VM start, if the new password
does not yet match what JovianDSS has stored for the target, the plugin detects
the authentication failure (iscsiadm exit code 24), automatically pushes the new
password to JovianDSS, and retries the login. No manual intervention is required.

---

## How It Works During VM Activation

Each `volume_activate` call runs two phases:

**1. Publish** — creates or verifies the iSCSI target on JovianDSS and attaches
the LUN. When CHAP is enabled, `--chap-user` and `--chap-password` are passed to
`jdssc targets create`. JovianDSS sets `incoming_users_active: true` on the target,
meaning it will challenge every initiator at login.

**2. Stage** — logs the Proxmox node into the target via `iscsiadm`. The plugin
writes CHAP credentials to the iscsiadm node database before calling `--login`,
so the initiator can respond to the challenge. If login fails with an authorization
error (exit code 24), the plugin performs one automatic recovery:

- Pushes current credentials from the `.pw` file to JovianDSS via `jdssc target update`.
- Retries `--login` with fresh credentials.

If the second attempt also fails, the plugin stops and logs:

```
CHAP authentication failed for target <targetname> on hosts <hosts>
after credential refresh — check CHAP configuration
```

---

## Troubleshooting

**`chap_user_name is required when chap_enabled is set`**

`pvesm set` was called with `chap_enabled 1` but `chap_user_name` was not provided.
Set both properties in the same command.

**`chap_user_password is required when chap_enabled is set`**

`chap_user_password` is missing from the `.pw` file. Re-run `pvesm set` with
`--chap_user_password`.

**`CHAP authentication failed ... after credential refresh`**

The credentials in the `.pw` file do not match what JovianDSS has stored for the
target, and the automatic recovery also failed. Check:

1. `pvesm set jdss-Pool-0 --chap_user_password <current-password>` — ensure the
   `.pw` file holds the correct password.
2. On JovianDSS, inspect the target's incoming users via the web UI or REST API
   and verify the username matches `chap_user_name`.

**iscsiadm sessions do not use CHAP after enabling it**

Existing sessions are not affected by a configuration change. Stop the VM,
which logs out the iSCSI session, then start it again. The new session will be
established with CHAP.
