## Title

iSCSI target CHAP

## Metadata

Date: 2026-04-15
Driver: Andrei Perepiolkin
Approver: Janusz Bak

## Status

Accepted

## Context

Security is a MUST for corporate solutions and data transfer for vms should be protected.

There are 2 possible aproaches of providing CHAP:

1. One user-password for all iscsi targets
2. Individual password for each iscsi target on every connect

### One password

Will require addition of:

`chap_enabled` flag to `/etc/pve/storage.cfg`
`chap_user_name` property to `/etc/pve/storage.cfg`
`chap_user_password` property to the `.pw` file

#### Advantages

Easy to implement

#### Disadvantages

One password controls all
Password change logic is complicated

#### Running

Password get read from config during volume activation and assigned to target.
For each new activation password have to be read again and assigned to target to hadle cases of changing chap password.

What if we update every target with new password?
That will prevent having single jdss pool to be managed by several proxmox nodes.
Also failure during this operation might be fatal.
What if user decides to update password manualy?

### Unique password

Will require

`chap_enabled` flag to `/etc/pve/storage.cfg`

#### Advantages

Simplicity in logic.
No need to warry about changing or preserving password.

#### Disadvantages

Lots of password and user assignments.
A specialy for vm with multiple volumes.


### Questions

Can we have logout and login for iscsi target as recovery mechanism?
Should ensure password during this operations?

## Decision

Use single `chap` password as it will most likely provide less rest requests.
Currently simplicity and reduced amount of requests is prefered.

## Consequences

Volume start will get a bit slower.
