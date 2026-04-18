# CHAP Authentication — Design Document

## Overview

This document describes the implementation of iSCSI CHAP (Challenge-Handshake
Authentication Protocol) for the JovianDSS Proxmox plugin. The decision to
implement CHAP was recorded in `docs/adr/0001-add-chap-auth.md` (Accepted
2026-04-15): a single shared credential per storage instance is used for all
iSCSI targets managed by that instance.

CHAP protects data-plane iSCSI traffic between the Proxmox node (initiator)
and JovianDSS (target). Without it, any host on the SAN that knows a target
IQN can attach to the LUN. With it, the target challenges the initiator at
login time and refuses connections that cannot produce the correct response.

The implementation spans three layers:

1. **Proxmox plugin** (`OpenEJovianDSSPlugin.pm`, `OpenEJovianDSS/Common.pm`) —
   configuration properties, credential storage, target creation, and iSCSI
   login.
2. **jdssc CLI** (`jdssc/jdssc/targets.py`) — new `--chap-user` /
   `--chap-password` arguments on the `targets create` subcommand.
3. **jdssc REST/driver layer** (`jdssc/jdssc/jovian_common/rest.py`,
   `driver.py`) — already supports CHAP; no changes required.

---

## Background

### Existing iSCSI target lifecycle

A volume becomes accessible to Proxmox in two steps:

**1. Publish** (`volume_publish`, `Common.pm`) — creates the iSCSI target and
attaches the LUN on the JovianDSS side. Calls `jdssc ... pool $pool targets
create ...`. Returns the target name, LUN id, and data-plane VIPs.

**2. Stage** (`volume_stage_iscsi`, `Common.pm`) — logs the Proxmox node into
the iSCSI target. Creates a node DB entry with `iscsiadm -o new`, sets
connection parameters, then calls `iscsiadm --login`.

CHAP must be enforced at both steps: the JovianDSS target must require
authentication (publish), and the initiator must supply credentials (stage).

### Existing REST and driver support

The jdssc REST and driver layers already have full CHAP support:

- `rest.py:509` — `create_target(... use_chap=True)` sets
  `incoming_users_active: true` on the target.
- `rest.py:587` — `create_target_user(target_name, chap_cred)` attaches a
  `{name, password}` credential to the target.
- `driver.py:1496` — `_create_target_volume_lun()` calls `create_target()`
  with `use_chap=(provider_auth is not None)` and, when credentials are
  provided, calls `_set_target_credentials()`.

The only gap in the jdssc layer is the CLI: `targets.py` has no parameters
for CHAP credentials, so `provider_auth` is always `None` today.

---

## Configuration Properties

Three new fields are added to the iSCSI plugin storage configuration.

### `chap_enabled` — storage.cfg

```perl
chap_enabled => {
    description => "Enable CHAP authentication for iSCSI targets",
    type        => 'boolean',
    default     => 0,
},
```

Added to `options` as `optional => 1`. Stored in `/etc/pve/storage.cfg`.

### `chap_user_name` — storage.cfg

```perl
chap_user_name => {
    description => "CHAP initiator username presented to iSCSI targets",
    type        => 'string',
},
```

Added to `options` as `optional => 1`. Stored in `/etc/pve/storage.cfg`.
Readable by all cluster nodes (needed at login time on each node).

### `chap_user_password` — sensitive property, .pw file

```perl
'sensitive-properties' => {
    'user_password'      => 1,
    'chap_user_password' => 1,
},
```

Not stored in `storage.cfg`. Handled by `on_add_hook` and `on_update_hook`
via the existing sensitive-properties mechanism; written to the `.pw` file.

---

## Password File Format

The existing file `/etc/pve/priv/storage/joviandss/${storeid}.pw` is extended
to carry both the REST API password and the CHAP password:

```
user_password      <rest-api-password>
chap_user_password <chap-password>
```

Both keys are optional. The file is parsed by key, so the order does not
matter and existing files without `chap_user_password` continue to work.

### Constraints

The JovianDSS REST API requires a minimum CHAP password length of 12
characters (`jovian_chap_pass_len = 12` in `driver.py:53`). iSCSI RFC 3720
sets a maximum of 16 bytes for CHAP secrets. The plugin does not enforce
these limits itself — validation at the Proxmox `pvesm` input layer is
sufficient for the initial implementation.

---

## New Common.pm Functions

### Getters

```perl
sub get_chap_enabled {
    my ($ctx) = @_;
    return $ctx->{scfg}{chap_enabled} // 0;
}

sub get_chap_user_name {
    my ($ctx) = @_;
    return $ctx->{scfg}{chap_user_name};
}

sub get_chap_user_password {
    my ($ctx) = @_;
    return _password_file_get_key($ctx, 'chap_user_password');
}
```

`_password_file_get_key` is a shared helper that reads the `.pw` file and
returns the value for a named key. The existing `get_user_password` is
refactored to use it:

```perl
sub _password_file_get_key {
    my ($ctx, $key) = @_;

    my $pwfile = get_password_file_name($ctx);
    return undef if ! -f $pwfile;

    my $content = PVE::Tools::file_get_contents($pwfile);
    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || $line eq '';
        if ($line =~ /^(\S+)\s+(.+)$/ && $1 eq $key) {
            return $2;
        }
    }
    return undef;
}

sub get_user_password {
    my ($ctx) = @_;
    return _password_file_get_key($ctx, 'user_password');
}

sub get_chap_user_password {
    my ($ctx) = @_;
    return _password_file_get_key($ctx, 'chap_user_password');
}
```

### Writers

`password_file_set_password` and `password_file_delete` are extended to
preserve unrelated keys when writing. A general `_password_file_set_key`
helper reads the existing file, updates or inserts the named key, and rewrites
atomically:

```perl
sub _password_file_set_key {
    my ($ctx, $key, $value) = @_;

    my $pwfile = get_password_file_name($ctx);
    my $dir    = "/etc/pve/priv/storage/joviandss";
    File::Path::make_path($dir, { mode => 0700 }) if ! -d $dir;

    my %config;
    if (-f $pwfile) {
        my $content = PVE::Tools::file_get_contents($pwfile);
        foreach my $line (split /\n/, $content) {
            $line =~ s/^\s+|\s+$//g;
            next if $line =~ /^#/ || $line eq '';
            $config{$1} = $2 if $line =~ /^(\S+)\s+(.+)$/;
        }
    }

    $config{$key} = $value;

    my $out = join('', map { "$_ $config{$_}\n" } sort keys %config);
    PVE::Tools::file_set_contents($pwfile, $out, 0600, 1);
}

sub _password_file_delete_key {
    my ($ctx, $key) = @_;

    my $pwfile = get_password_file_name($ctx);
    return unless -f $pwfile;

    my %config;
    my $content = PVE::Tools::file_get_contents($pwfile);
    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || $line eq '';
        $config{$1} = $2 if $line =~ /^(\S+)\s+(.+)$/;
    }

    return unless exists $config{$key};
    delete $config{$key};

    if (%config) {
        my $out = join('', map { "$_ $config{$_}\n" } sort keys %config);
        PVE::Tools::file_set_contents($pwfile, $out, 0600, 1);
    } else {
        unlink $pwfile;
    }
}
```

`password_file_set_password` and the new `password_file_set_chap_password`
become thin wrappers:

```perl
sub password_file_set_password {
    my ($ctx, $password) = @_;
    _password_file_set_key($ctx, 'user_password', $password);
}

sub password_file_set_chap_password {
    my ($ctx, $password) = @_;
    _password_file_set_key($ctx, 'chap_user_password', $password);
}

sub password_file_delete {
    my ($ctx) = @_;
    _password_file_delete_key($ctx, 'user_password');
}

sub password_file_delete_chap_password {
    my ($ctx) = @_;
    _password_file_delete_key($ctx, 'chap_user_password');
}
```

---

## Hook Changes

### `on_add_hook` and `on_update_hook`

Both hooks receive `chap_user_password` via the sensitive-properties
mechanism (same pattern as `user_password`).

```perl
# on_add_hook addition
if (exists($sensitive{chap_user_password})) {
    if (defined($sensitive{chap_user_password})) {
        OpenEJovianDSS::Common::password_file_set_chap_password(
            $ctx, $sensitive{chap_user_password});
    }
}

# on_update_hook addition
if (exists($param{chap_user_password})) {
    if (defined($param{chap_user_password})) {
        OpenEJovianDSS::Common::password_file_set_chap_password(
            $ctx, $param{chap_user_password});
    } else {
        OpenEJovianDSS::Common::password_file_delete_chap_password($ctx);
    }
}
```

`on_delete_hook` does not need a separate deletion call: `password_file_delete`
already removes the entire file (via `_password_file_delete_key`, which calls
`unlink` when the file would be left empty). If `chap_user_password` is the
only remaining key, the file is removed atomically.

---

## Target Creation — `volume_publish`

When `chap_enabled` is true, CHAP credentials are appended to the `jdssc
targets create` command:

```perl
my $create_target_cmd = [
    'pool',            $pool,    'targets',             'create',
    '--target-prefix', $prefix,  '--target-group-name', $tgname,
    '-v',              $volname, '--luns-per-target',   $luns_per_target,
];

if (get_chap_enabled($ctx)) {
    my $chap_user = get_chap_user_name($ctx);
    my $chap_pass = get_chap_user_password($ctx);
    die "chap_user_name not set\n"      unless defined $chap_user;
    die "chap_user_password not set\n"  unless defined $chap_pass;
    push @$create_target_cmd, '--chap-user', $chap_user, '--chap-password', $chap_pass;
}
```

The credentials are passed positionally, not via environment or stdin, because
`joviandss_cmd` shells out to `jdssc` which reads `sys.argv`. The `jdssc`
process is short-lived and the Proxmox node is assumed to be trusted
infrastructure; the `/proc/<pid>/cmdline` exposure window is therefore
accepted for the initial implementation. A follow-up can move credentials to
a temp-file argument (`--chap-credentials-file`) to close this window
completely.

**Idempotency:** `jdssc targets create` calls `ensure_target_volume()` in the
driver, which is already idempotent — it returns the existing target if it
already exists. When CHAP is enabled, `_create_target_volume_lun()` calls
`_set_target_credentials()` which overwrites credentials on each invocation.
This means if the CHAP password is rotated, the next `volume_publish` (i.e.
next activation from cold) will update the target credentials automatically.

---

## jdssc CLI Changes — `targets.py`

The `create` subcommand gains two optional arguments:

```python
parser_create.add_argument(
    '--chap-user',
    dest='chap_user',
    default=None,
    help='CHAP initiator username',
)
parser_create.add_argument(
    '--chap-password',
    dest='chap_password',
    default=None,
    help='CHAP initiator password',
)
```

In the `create()` handler, `provider_auth` is constructed from these args when
both are present:

```python
provider_auth = None
if args.chap_user and args.chap_password:
    provider_auth = f"CHAP {args.chap_user} {args.chap_password}"

self.jdss.ensure_target_volume(
    ...,
    provider_auth=provider_auth,
)
```

The `driver.py` `ensure_target_volume()` already accepts and propagates
`provider_auth` to `_create_target_volume_lun()` — no driver changes required.

---

## iSCSI Login — `volume_stage_iscsi`

The login sequence for each host inside the retry loop is:

```
1. iscsiadm -o new          — create node DB entry (must exist before any -o update)
2. iscsiadm -o update       — set login_timeout
3. iscsiadm -o update ×3    — set CHAP authmethod / username / password   ← NEW
4. iscsiadm --login         — establish session (CHAP handshake happens here)
```

CHAP parameters **must** be written to the node DB after step 1 and before
step 4. `iscsiadm -o update` requires the node record to be present; `--login`
reads the auth parameters from the node DB at connection time. Configuring
credentials after login has no effect on the already-established session.

The complete per-host block with CHAP added:

```perl
for my $host (@pending) {
    # Step 1 — create node DB entry (errors suppressed; already-existing is normal)
    eval {
        my $cmd = [
            $ISCSIADM, '--mode', 'node',
            '-p', $host, '--targetname', $targetname, '-o', 'new'
        ];
        run_command($cmd, outfunc => sub { }, errfunc => sub { }, noerr => 1);
    };

    # Step 2 — set login timeout
    eval {
        my $cmd = [
            $ISCSIADM, '--mode', 'node',
            '-p', $host, '--targetname', $targetname,
            '-o', 'update', '-n', 'node.conn[0].timeo.login_timeout', '-v', '30'
        ];
        run_command($cmd, outfunc => sub { }, errfunc => sub { }, noerr => 1);
    };

    # Step 3 — configure CHAP credentials (must precede --login)
    if (get_chap_enabled($ctx)) {
        my $chap_user = get_chap_user_name($ctx);
        my $chap_pass = get_chap_user_password($ctx);
        die "chap_user_name not set\n"     unless defined $chap_user;
        die "chap_user_password not set\n" unless defined $chap_pass;

        for my $update (
            [ 'node.session.auth.authmethod', 'CHAP'     ],
            [ 'node.session.auth.username',   $chap_user ],
            [ 'node.session.auth.password',   $chap_pass ],
        ) {
            my ($param, $value) = @$update;
            my $cmd = [
                $ISCSIADM, '--mode', 'node',
                '-p', $host, '--targetname', $targetname,
                '-o', 'update', '-n', $param, '-v', $value,
            ];
            run_command($cmd,
                outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift) },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift) },
                timeout => 10,
            );
        }
    }

    # Step 4 — login (CHAP handshake occurs here if target requires it)
    eval {
        my $cmd = [
            $ISCSIADM, '--mode', 'node',
            '-p', $host, '--targetname', $targetname, '--login'
        ];
        run_command($cmd, ...);
        $host_has_session{$host} = 1;
    };
}
```

**Re-login safety:** on each activation the node DB entry is created fresh
(`-o new`). The CHAP block runs on every iteration, so credentials are always
present in the node DB before `--login` regardless of whether this is a first
login or a retry.

### Authorization Failure — Error and Recovery

When the initiator supplies credentials that do not match the target, iscsiadm
produces the following output on stderr and exits with code 24:

```
iscsiadm: Could not login to [iface: default, target: <targetname>, portal: <host>,3260].
iscsiadm: initiator reported error (24 - iSCSI login failed due to authorization failure)
iscsiadm: Could not log into all portals
```

Exit code 24 is the only code that indicates a credential mismatch. All other
non-zero codes indicate connectivity or target availability problems handled by
the existing retry loop.

**Recovery on exit code 24:**

A credential mismatch can happen mid-flight if the operator rotated the CHAP
password via `pvesm set` while a VM start was already in progress. In that
case the `.pw` file on disk already has the new password but the JovianDSS
target still holds the old one, or vice versa.

When exit code 24 is detected, the plugin performs one recovery attempt before
failing:

```
1. Re-read chap_user_name and chap_user_password from .pw file (fresh read,
   picks up any password change committed since this activation began).
2. Re-push credentials to JovianDSS target via volume_publish (idempotent —
   calls _set_target_credentials() which overwrites the target's CHAP user).
3. Re-configure the iscsiadm node DB with the fresh credentials.
4. Retry --login once.
5. If exit code 24 again, die with a clear message; do not loop.
```

Reference implementation of the login step with recovery:

```perl
    my $chap_auth_err = 0;

    # Step 4 — login (CHAP handshake occurs here if target requires it)
    eval {
        my $cmd = [
            $ISCSIADM, '--mode', 'node',
            '-p', $host, '--targetname', $targetname, '--login'
        ];
        run_command($cmd,
            outfunc => sub { },
            errfunc => sub {
                my $line = shift;
                $chap_auth_err = 1 if $line =~ /authorization failure/i;
                $already_present = 1 if $line =~ /already present/i;
                cmd_log_output($ctx,
                    $already_present ? 'debug' : 'warn', $cmd, $line);
            },
        );
        $host_has_session{$host} = 1;
    };

    if ($@ && $chap_auth_err && get_chap_enabled($ctx)) {
        debugmsg($ctx, 'warn',
            "CHAP authorization failure for target ${targetname} on ${host}, "
            . "refreshing credentials and retrying\n");

        # Re-read credentials from disk — picks up any rotation in progress.
        my $chap_user = get_chap_user_name($ctx);
        my $chap_pass = get_chap_user_password($ctx);
        die "chap_user_name not set\n"     unless defined $chap_user;
        die "chap_user_password not set\n" unless defined $chap_pass;

        # Re-push credentials to the JovianDSS target.
        volume_publish($ctx, $volname, $snapname);

        # Re-configure node DB with fresh credentials.
        for my $update (
            [ 'node.session.auth.authmethod', 'CHAP'     ],
            [ 'node.session.auth.username',   $chap_user ],
            [ 'node.session.auth.password',   $chap_pass ],
        ) {
            my ($param, $value) = @$update;
            my $cmd = [
                $ISCSIADM, '--mode', 'node',
                '-p', $host, '--targetname', $targetname,
                '-o', 'update', '-n', $param, '-v', $value,
            ];
            run_command($cmd,
                outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift) },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift) },
                timeout => 10,
            );
        }

        # Single retry — no further recovery on second failure.
        eval {
            my $cmd = [
                $ISCSIADM, '--mode', 'node',
                '-p', $host, '--targetname', $targetname, '--login'
            ];
            run_command($cmd,
                outfunc => sub { },
                errfunc => sub {
                    my $line = shift;
                    $already_present = 1 if $line =~ /already present/i;
                    cmd_log_output($ctx,
                        $already_present ? 'debug' : 'warn', $cmd, $line);
                },
            );
            $host_has_session{$host} = 1;
        };
        die "CHAP authentication failed for target ${targetname} on ${host} "
          . "after credential refresh — check chap_user_name and chap_user_password\n"
          if $@ && !$already_present;
    }
```

The recovery path calls `volume_publish` which already constructs and runs the
`jdssc targets create --chap-user ... --chap-password ...` command.
`ensure_target_volume()` in the driver is idempotent and will call
`_set_target_credentials()` regardless of whether the target already exists.

---

## Data Flow

```
pvesm set <storeid> --chap-enabled 1 \
                    --chap-user-name chapuser \
                    --chap-user-password <secret>
        │
        ├─► on_add_hook / on_update_hook
        │       password_file_set_chap_password($ctx, $secret)
        │       → /etc/pve/priv/storage/joviandss/<storeid>.pw
        │           user_password      <rest-secret>
        │           chap_user_password <chap-secret>
        │
        └─► storage.cfg
                chap_enabled  1
                chap_user_name chapuser


volume_activate (each login)
    │
    ├─► volume_publish  ─────────────────────────────────────────►  JovianDSS target
    │       get_chap_enabled → true                                  incoming_users_active: true
    │       get_chap_user_name → "chapuser"                          CHAP user: chapuser / <secret>
    │       get_chap_user_password → "<secret>"
    │       jdssc ... targets create --chap-user chapuser \
    │                                --chap-password <secret>
    │
    └─► volume_stage_iscsi  ──────────────────────────────────────►  iscsiadm node DB
            iscsiadm -o new  (create node entry)                     node.session.auth.authmethod CHAP
            get_chap_enabled → true                                  node.session.auth.username   chapuser
            iscsiadm -o update ... authmethod CHAP                   node.session.auth.password   <secret>
            iscsiadm -o update ... username   chapuser
            iscsiadm -o update ... password   <secret>
            iscsiadm --login  ────────────────────────────────────►  CHAP handshake → session established
```

---

## Interaction with Existing Flows

### Multipath

CHAP credentials are written to the node DB before login. When multipath is
enabled, `volume_stage_multipath` is called after the iSCSI session is already
established — CHAP is transparent to it.

### Re-login (unstage / restage)

`volume_unstage_iscsi_device` calls `iscsiadm --logout`, which terminates the
session but leaves the node DB entry intact. On the next `volume_stage_iscsi`,
the node entry is re-created (`-o new`) and CHAP parameters are set again.
There is no stale-credential risk.

### Password rotation

When `chap_user_password` is updated via `pvesm set`, `on_update_hook` writes
the new password to the `.pw` file immediately. Active iSCSI sessions are
unaffected (CHAP is only checked at login time).

**Rotation between VM stop and VM start (normal case):**

1. `volume_unstage_iscsi_device` logs out all sessions.
2. Next activation: `volume_publish` calls `_set_target_credentials()` and
   updates the JovianDSS target credential.
3. `volume_stage_iscsi` reads the new password from the `.pw` file, configures
   the node DB, and logs in.

**Rotation mid-flight (password changed while VM start is in progress):**

If the operator updates `chap_user_password` after `volume_stage_iscsi` has
already read the old password but before `--login` is issued, the login will
fail with exit code 24. The authorization failure recovery path handles this:
it re-reads credentials from the `.pw` file (which now holds the new
password), re-pushes them to the JovianDSS target, and retries login.

Rotation therefore takes effect automatically in both cases without manual
intervention.

### Snapshot targets

Snapshot volumes are published via `volume_publish` with `--snapshot` set.
The same CHAP block applies regardless of snapshot flag — the target is
created with `use_chap=True` when credentials are provided. No special
handling is required.

---

## Error Handling

| Situation | Behaviour |
|---|---|
| `chap_enabled=1` but `chap_user_name` not set | `die "chap_user_name not set\n"` in `volume_publish` and `volume_stage_iscsi` |
| `chap_enabled=1` but `chap_user_password` not set (missing .pw entry) | `die "chap_user_password not set\n"` in same locations |
| `iscsiadm -o update` fails for auth param | `run_command` raises; `volume_stage_iscsi` propagates the error; login is not attempted |
| `iscsiadm --login` fails with exit code 24 (`authorization failure`) | Credentials refreshed from `.pw` file, re-pushed to JovianDSS target via `volume_publish`, node DB reconfigured, login retried once. If second attempt also fails with auth error, dies with `"CHAP authentication failed ... after credential refresh"` |
| Second login attempt fails with exit code 24 | Fatal — `die` with clear message. Operator must verify `chap_user_name` and `chap_user_password` match the JovianDSS target configuration |
| Target exists without CHAP, `chap_enabled` is now true | Next `volume_publish` calls `_set_target_credentials()` and sets `incoming_users_active: true` on the target. The initiator then supplies credentials at next login. |
| Target exists with CHAP, `chap_enabled` is now false | Mismatch: target still requires CHAP but initiator won't provide credentials. Login fails with exit code 24. Recovery re-reads credentials — but since CHAP is disabled there are none — and dies with `"chap_user_name not set"`. Operator must re-enable CHAP or manually remove the CHAP user from the JovianDSS target. |

---

## Files Changed

| File | Change |
|---|---|
| `OpenEJovianDSSPlugin.pm` | Add `chap_enabled`, `chap_user_name` to `properties()` and `options`; add `chap_user_password` to `sensitive-properties`; extend `on_add_hook` and `on_update_hook` |
| `OpenEJovianDSS/Common.pm` | Add `_password_file_set_key`, `_password_file_delete_key`, `_password_file_get_key` helpers; refactor existing password functions to use them; add `get_chap_enabled`, `get_chap_user_name`, `get_chap_user_password`, `password_file_set_chap_password`, `password_file_delete_chap_password`; extend `volume_publish` and `volume_stage_iscsi` |
| `jdssc/jdssc/targets.py` | Add `--chap-user` and `--chap-password` arguments to `create` subcommand; construct and pass `provider_auth` to `ensure_target_volume` |

No changes required to:
- `jdssc/jdssc/jovian_common/driver.py` — `provider_auth` support already present
- `jdssc/jdssc/jovian_common/rest.py` — `create_target(use_chap=...)` and `create_target_user()` already present
- `OpenEJovianDSSNFSPlugin.pm` — NFS plugin does not use iSCSI targets

---

## Open Questions

1. **Credential validation at property-set time** — should the plugin validate
   password length (≥12, ≤16 bytes) in the `properties()` definition, or
   accept that JovianDSS will reject invalid lengths via REST error?

2. **CHAP disable with active targets** — the error-handling table notes that
   disabling CHAP on a live storage with CHAP-enabled targets creates an
   unrecoverable login failure. A `pvesm` migration path (batch
   deactivate/update/reactivate) would make this safer but is out of scope
   for the initial implementation.

3. **`--chap-credentials-file` for jdssc** — passing credentials via argv
   exposes them in `/proc/<pid>/cmdline`. A file-based argument would close
   this window without requiring stdin changes to `joviandss_cmd`. Tracked as
   a follow-up to C-3 from the security review.
