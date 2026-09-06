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
- CHAP user name: letters, digits, `-` and `_`; must start and end with a letter,
  digit or `_`
- CHAP password: 12 to 255 characters, made up of letters, digits and
  `-_!@%()+?.:;` — no spaces and no other punctuation
- Proxmox VE plugin version v0.11.4 or later

---

## Enabling CHAP

CHAP is configured with three properties: `chap_enabled`, `chap_user_name`, and
`chap_user_password`. All three must be set together — if any of them is
missing, the command fails immediately with an error.

**On an existing storage:**

```bash
pvesm set jdss-Pool-0 \
    --chap_enabled 1 \
    --chap_user_name <chap-user-name> \
    --chap_user_password <chap-password>
```

When creating a new storage, include the same three flags in the initial
`pvesm add` command.

> **Note:** Enabling, disabling, or
> rotating credentials never affects established sessions — changes take
> effect at the next VM start or migration.

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

---

## Password Rotation

To change the CHAP password without downtime:

```bash
pvesm set jdss-Pool-0 --chap_user_password <new-password>
```

On the next VM start, if the new password does not yet match what JovianDSS has
stored for the target, the plugin reconciles it automatically — see
[How It Works](#how-it-works-during-vm-activation) below.

---

## How It Works During VM Activation

Each `volume_activate` call runs two phases:

**1. Publish** — creates or verifies the iSCSI target on JovianDSS and attaches
the LUN. When CHAP is enabled, the plugin passes the user name to
`jdssc … targets create`; the password comes from the `.pw` file, never from the
command line. JovianDSS sets `incoming_users_active: true` on the target, meaning
it will challenge every initiator at login.

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
