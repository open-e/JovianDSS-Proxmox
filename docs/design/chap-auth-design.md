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
   `driver.py`) — extended with `set_target_incoming_users_active`, `update_target`,
   and a rewritten `_ensure_target_volume_lun` CHAP block.

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

### REST and driver support

The jdssc REST and driver layers support CHAP through the following:

- `rest.py` — `create_target(... use_chap=True)` sets `incoming_users_active: true`
  on new targets; `create_target_user` / `delete_target_user` manage credentials;
  `set_target_incoming_users_active` (added for this feature) syncs the enforcement
  flag on existing targets.
- `driver.py` — `_create_target_volume_lun` creates targets with CHAP;
  `_ensure_target_volume_lun` (rewritten) syncs credentials and flag on existing
  targets; `update_target` (added) performs unconditional credential replacement
  for the recovery path.

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

    my $pwfile_path = get_password_file_path($ctx);
    return undef if ! -f $pwfile_path;

    my $content = PVE::Tools::file_get_contents($pwfile_path);
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
```

### Writers

`password_file_set_password` and `password_file_delete` are extended to
preserve unrelated keys when writing. A general `_password_file_set_key`
helper reads the existing file, updates or inserts the named key, and rewrites
atomically:

```perl
sub _password_file_set_key {
    my ($ctx, $key, $value) = @_;

    my $pwfile_path = get_password_file_path($ctx);
    my $dir = PLUGIN_GLOBAL_PASSWORD_FILE_DIR;
    File::Path::make_path($dir, { mode => 0700 }) if ! -d $dir;

    my %config;
    if (-f $pwfile_path) {
        my $content = PVE::Tools::file_get_contents($pwfile_path);
        foreach my $line (split /\n/, $content) {
            $line =~ s/^\s+|\s+$//g;
            next if $line =~ /^#/ || $line eq '';
            $config{$1} = $2 if $line =~ /^(\S+)\s+(.+)$/;
        }
    }

    $config{$key} = $value;

    my $out = join('', map { "$_ $config{$_}\n" } sort keys %config);
    PVE::Tools::file_set_contents($pwfile_path, $out, 0600, 1);
}

sub _password_file_delete_key {
    my ($ctx, $key) = @_;

    my $pwfile_path = get_password_file_path($ctx);
    die "password file '$pwfile_path' does not exist\n" unless -f $pwfile_path;

    my %config;
    my $content = PVE::Tools::file_get_contents($pwfile_path);
    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || $line eq '';
        $config{$1} = $2 if $line =~ /^(\S+)\s+(.+)$/;
    }

    return unless exists $config{$key};
    delete $config{$key};

    if (%config) {
        my $password_file_data = '';
        for my $k (sort keys %config) {
            $password_file_data .= "$k $config{$k}\n";
        }
        PVE::Tools::file_set_contents($pwfile_path, $password_file_data, 0600, 1);
    } else {
        unlink $pwfile_path;
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

### Validation on `chap_enabled=1`

When `chap_enabled` is true, both `chap_user_name` and `chap_user_password`
are required. If either is absent, the hook must fail immediately with a clear
error rather than deferring the failure to the first VM activation.

```perl
# on_add_hook and on_update_hook — validate after writing credentials
if (OpenEJovianDSS::Common::get_chap_enabled($ctx)) {
    die "chap_user_name is required when chap_enabled is set\n"
        unless defined $scfg->{chap_user_name} && length($scfg->{chap_user_name});
    die "chap_user_password is required when chap_enabled is set\n"
        unless defined OpenEJovianDSS::Common::get_chap_user_password($ctx);
}
```

This validation runs after the password file has been written so that
`get_chap_user_password` can read from it. The check in `volume_publish` and
`volume_stage_iscsi` (see Target Creation and iSCSI Login sections) remains as
a defence-in-depth guard, but the hook check is the primary enforcement point.

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
    die "chap_user_name is required when chap_enabled is set\n"
        unless defined $chap_user && length($chap_user);
    die "chap_user_password is required when chap_enabled is set\n"
        unless defined $chap_pass;
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
already exists. For existing targets `_ensure_target_volume_lun` applies a
name-match skip: credentials are only replaced when the username changes.
A password-only rotation on an existing target is therefore not picked up by
`volume_publish`; it is applied lazily via the authorization-failure recovery
path the next time login fails with exit code 24.

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

The `driver.py` `ensure_target_volume()` accepts and propagates `provider_auth`
to `_create_target_volume_lun()`. Additional driver changes (`_ensure_target_volume_lun`
rewrite, `update_target`) are covered in the Target Update Command section.

---

## iSCSI Login — `volume_stage_iscsi`

Each outer retry attempt runs four steps in sequence:

```
Step 1 — read CHAP state (once per attempt, before per-host work)
    get_chap_enabled / get_chap_user_name / get_chap_user_password

Step 2 — configure iscsiadm node DB for each pending host
    iscsiadm -o new      — create node DB entry (once per host, skipped on retry)
    iscsiadm -o update   — set login_timeout    (once per host, skipped on retry)
    _iscsiadm_set_chap   — write CHAP credentials  (every attempt, if enabled)
    _iscsiadm_clear_chap — clear CHAP parameters   (every attempt, if disabled)

Step 3 — attempt login for each pending host
    iscsiadm --login     — CHAP handshake occurs here if target requires it
    collect @chap_failed for step 4

Step 4 — CHAP recovery (at most once per invocation)
    target_update_chap   — one REST call, syncs JovianDSS target to current config
    $chap_recovery_done = 1 — outer loop retries; step 1 re-reads credentials
```

CHAP parameters must be written to the node DB (step 2) before login (step 3).
`iscsiadm -o update` requires the node record to exist; `--login` reads auth
parameters from the node DB at connection time.

The node DB entry (`-o new`, `login_timeout`) is created once per host and
tracked with `%host_db_ready`. CHAP set/clear runs every attempt so that
credentials are always current when the session is established, including after
a step 4 recovery on the previous attempt.

The per-host login block (step 3):

```perl
my @chap_failed;
for my $host (@pending) {
    my $already_present = 0;
    my $chap_auth_err   = 0;
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
                $chap_auth_err   = 1 if $line =~ /authorization failure/i;
                cmd_log_output($ctx, $already_present ? 'debug' : 'warn', $cmd, $line);
            }
        );
        $host_has_session{$host} = 1;
    };
    if ($@) {
        if    ($already_present) { $host_has_session{$host} = 1; }
        elsif ($chap_auth_err)   { push @chap_failed, $host; }
        else                     { debugmsg($ctx, 'warn', "...login failed: $@"); }
    }
}
```

**Node DB reuse:** the `-o new` and `login_timeout` update run once per host
(`%host_db_ready`). CHAP state is written on every attempt so the node DB
always reflects current config before login, including after step 4 changes
credentials on the previous attempt.

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

Exit code 24 can occur in three mid-flight scenarios:

- **Password rotated** — `.pw` file updated after `volume_stage_iscsi` read the
  old password. Target still holds old credentials.
- **CHAP disabled mid-flight** — `volume_publish` ran with old config
  (`chap_enabled=1`, target has CHAP), then operator ran `pvesm set
  --chap-enabled 0`. `volume_stage_iscsi` now has no credentials to supply but
  the target still enforces CHAP.
- **CHAP enabled mid-flight** — `volume_publish` ran without CHAP, then CHAP
  was enabled. Login succeeds (target does not enforce CHAP yet), so exit code
  24 is not triggered; CHAP will be enforced correctly on the next full
  activation.

When exit code 24 is detected, the plugin performs one recovery before
continuing with the outer retry loop:

```
Step 3 (login pass): collect all hosts that failed with exit code 24 into
  @chap_failed; do not retry inline.

Step 4 (CHAP recovery, once per volume_stage_iscsi invocation):
1. Call target_update_chap($ctx, $targetname):
     - chap_enabled=1 → jdssc target <name> update --chap-user ... --chap-password ...
     - chap_enabled=0 → jdssc target <name> update --no-chap
   This syncs the JovianDSS target to current config regardless of direction.
   Called at most once ($chap_recovery_done flag). If @chap_failed is non-empty
   on a subsequent outer attempt, die immediately — credentials are genuinely
   wrong.
2. Set $chap_recovery_done = 1; continue to next outer loop iteration.

On the next outer attempt:
- Step 1 re-reads credentials from the .pw file (which now holds the current
  password after any rotation).
- Step 2 calls _iscsiadm_set_chap or _iscsiadm_clear_chap with fresh values.
- Step 3 retries --login. If CHAP auth fails again → step 4 dies immediately.
```

Implementation (step 3 login pass and step 4):

```perl
    # Step 3: collect CHAP failures
    my @chap_failed;
    for my $host (@pending) {
        my $already_present = 0;
        my $chap_auth_err   = 0;
        eval { ... iscsiadm --login ... $host_has_session{$host} = 1; };
        if ($@) {
            if    ($already_present) { $host_has_session{$host} = 1; }
            elsif ($chap_auth_err)   { push @chap_failed, $host; }
            else                     { debugmsg($ctx, 'warn', "...login failed: $@"); }
        }
    }

    # Step 4: CHAP recovery — one REST call, then let the outer loop retry
    if (@chap_failed) {
        if ($chap_recovery_done) {
            die "CHAP authentication failed for target ${targetname} "
                . "on hosts @chap_failed after credential refresh — "
                . "check CHAP configuration\n";
        }
        target_update_chap($ctx, $targetname);
        $chap_recovery_done = 1;
    }
```

The recovery path uses `target_update_chap` (Common.pm) which calls the narrow
`jdssc target <name> update` command (see "Target Update Command" below) rather
than the full `volume_publish` flow. It handles both CHAP-enable and
CHAP-disable transitions transparently.

The node DB (`_iscsiadm_set_chap` / `_iscsiadm_clear_chap`) is updated at the
top of the next outer iteration (step 2), not inline in the recovery path.
Credentials are re-read at the top of each iteration (step 1), so the next
attempt automatically picks up any password that `target_update_chap` just
synced.

---

## Target Update Command

### Motivation

The recovery path inside `volume_stage_iscsi` previously called
`volume_publish` to push refreshed CHAP credentials to the JovianDSS target.
`volume_publish` runs the full `jdssc targets create` → `ensure_target_volume`
flow: target existence check, LUN attachment check, VIP assignment, then
CHAP credential update. All steps except the last are redundant — they were
completed moments earlier in the same `volume_activate` call.

Additionally, `volume_publish` re-resolves the target IQN from `$tgname` and
`$volname`, even though the resolved `$targetname` string is already in scope
inside `volume_stage_iscsi`.

The `target <name> update` command replaces this with ~3 REST calls that
update only the CHAP state of an existing named target.

### jdssc CLI — `target.py`

`target.py` (singular target operations) already exists with `get` and
`delete` actions. The `update` action is added to the same module.

The `update` subcommand accepts:

| Flag | Description |
|---|---|
| `--chap-user` | CHAP username to set on the target |
| `--chap-password` | CHAP password to set on the target |
| `--no-chap` | Disable CHAP: clear `incoming_users_active` and remove all CHAP users |

Validation rules:
- `--chap-user` and `--chap-password` must be provided together; supplying only one is a CLI error (exit 1).
- `--no-chap` is mutually exclusive with `--chap-user` and `--chap-password`; combining them is a CLI error (exit 1).
- Providing none of the three flags is a CLI error (exit 1); the operator must state intent explicitly.

### Driver — `driver.py`

New public method `update_target(target_name, provider_auth=None)`.

Behaviour when `provider_auth` is set (`"CHAP <user> <pass>"`):

1. `get_target(target_name)` — read current state; raises
   `JDSSResourceNotFoundException` if the target does not exist.
2. `get_target_user(target_name)` — read current CHAP users. The
   `/incoming-users` endpoint returns 200 + empty list when no users are
   configured, or 404 (raising `JDSSResourceNotFoundException`) when the
   target has never had any user configuration; both cases are treated as
   "no existing users" and the deletion loop is skipped.
3. Delete all existing users unconditionally, then call
   `_set_target_credentials` to create the new user. Unlike
   `_ensure_target_volume_lun`, there is no early-return when the username
   matches — this ensures password-only rotation is applied correctly.
4. If `incoming_users_active` is not already `True`:
   `set_target_incoming_users_active(target_name, True)`.

Behaviour when `provider_auth` is `None` (CHAP disable):

1. If `incoming_users_active` is `True`:
   `set_target_incoming_users_active(target_name, False)` — target stops
   enforcing auth immediately, before user entries are removed.
2. `get_target_user` and `delete_target_user` for each existing user.

This logic is a direct extraction of the CHAP block already present in
`_ensure_target_volume_lun`. No new behaviour is introduced.

No changes to `rest.py` — all required methods already exist.

### Common.pm — `target_update_chap` and recovery path

`target_update_chap($ctx, $targetname)` is added to `Common.pm` as the single
function responsible for syncing CHAP state on an existing named target. It
reads `chap_enabled` from config and dispatches accordingly:

```perl
sub target_update_chap {
    my ($ctx, $targetname) = @_;
    my $pool = get_pool($ctx);
    my $cmd  = ['pool', $pool, 'target', $targetname, 'update'];
    if (get_chap_enabled($ctx)) {
        my $chap_user = get_chap_user_name($ctx);
        my $chap_pass = get_chap_user_password($ctx);
        die "chap_user_name is required when chap_enabled is set\n"
            unless defined $chap_user && length($chap_user);
        die "chap_user_password is required when chap_enabled is set\n"
            unless defined $chap_pass;
        push @$cmd, '--chap-user', $chap_user, '--chap-password', $chap_pass;
    } else {
        push @$cmd, '--no-chap';
    }
    my $last_err;
    for my $attempt (1 .. 2) {
        eval { joviandss_cmd($ctx, $cmd, 30); };
        last unless $@;
        $last_err = $@;
        debugmsg($ctx, 'warn',
            "target_update_chap attempt ${attempt} failed for "
            . "${targetname}: ${last_err}");
    }
    die $last_err if $last_err;
}
```

The command is retried once on failure before propagating the error. The
function uses the resolved `$targetname` IQN directly, avoiding the
re-resolution done by `volume_publish`. It is the only call site for
`jdssc target <name> update` from the plugin side.

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
2. Next activation: `volume_publish` passes new credentials to jdssc. If the
   username is unchanged the name-match skip applies and the JovianDSS target
   still holds the old password.
3. `volume_stage_iscsi` (step 1) reads the new password from the `.pw` file
   and configures the node DB (step 2) with it. Login (step 3) fails with
   exit code 24 because the JovianDSS target still holds the old credential.
   Step 4 calls `target_update_chap`, which pushes the new password to
   JovianDSS and sets `$chap_recovery_done = 1`.
4. The outer loop retries. Step 1 re-reads the `.pw` file (same new password).
   Step 2 re-applies `_iscsiadm_set_chap` with the new password. Step 3 login
   succeeds — credentials now match on both sides.

**Rotation mid-flight (password changed while VM start is in progress):**

If the operator updates `chap_user_password` after `volume_stage_iscsi` has
already read the old password but before `--login` is issued, the login will
fail with exit code 24. Step 4 calls `target_update_chap`, which pushes the
new password to JovianDSS. On the next outer iteration, step 1 re-reads the
`.pw` file (which now holds the new password), step 2 updates the node DB, and
step 3 login succeeds.

Rotation therefore takes effect automatically in both cases without manual
intervention.

### Snapshot targets

Snapshot volumes are published via `volume_publish` with `--snapshot` set.
The same CHAP block applies regardless of snapshot flag — the target is
created with `use_chap=True` when credentials are provided. No special
handling is required.

---

## `incoming_users_active` Flag Synchronisation

### Finding

Live testing revealed that enabling CHAP on an existing target via
`_ensure_target_volume_lun` did not set `incoming_users_active: true` on the
JovianDSS target. The flag remained `false` even after `_set_target_credentials`
successfully added the CHAP user. Conversely, disabling CHAP (removing the
user) left `incoming_users_active: true` on the target.

The root causes in the original `_ensure_target_volume_lun` code:

1. **Early return skips flag check.** When the correct CHAP user was already
   present (`users[0]['name'] == chap_cred['name']`), the function returned
   immediately without ever inspecting or updating `incoming_users_active`.

2. **No flag update after credential set.** After calling
   `_set_target_credentials`, the code did not follow up with an
   `incoming_users_active` update.

3. **No CHAP-disable path.** When `provider_auth is None`, the code did
   nothing — it neither removed existing CHAP users nor cleared
   `incoming_users_active`.

During testing, iSCSI login still succeeded with `incoming_users_active: false`
because JovianDSS does not enforce authentication when the flag is false,
regardless of whether CHAP users are attached. However, this is the wrong
state: a target with CHAP users but `incoming_users_active: false` accepts
unauthenticated connections, defeating the purpose of CHAP.

### Fix

The `PUT /san/iscsi/targets/<target_name>` endpoint (already used by
`set_target_assigned_vips`) accepts `incoming_users_active` in the request
body. A new `set_target_incoming_users_active(target_name, active)` method is
added to `rest.py` and called from `_ensure_target_volume_lun` in `driver.py`.

**`rest.py` addition:**

```python
def set_target_incoming_users_active(self, target_name, active):
    req = "/san/iscsi/targets/%s" % target_name
    jdata = {"name": target_name, "incoming_users_active": active}
    resp = self.rproxy.pool_request('PUT', req, json_data=jdata, apiv=4)
    if resp['error'] is None and resp['code'] in (200, 201, 204):
        return
    if resp['code'] == 404:
        raise jexc.JDSSResourceNotFoundException(res=target_name)
    self._general_error(req, resp)
```

**`driver.py` — `_ensure_target_volume_lun` CHAP block (replacing the original):**

```python
if provider_auth is not None:
    (__, auth_username, auth_secret) = provider_auth.split()
    volume_publication_info['username'] = auth_username
    volume_publication_info['password'] = auth_secret
    chap_cred = {"name": auth_username, "password": auth_secret}
    try:
        users = self.ra.get_target_user(tname)
        if not (len(users) == 1 and users[0]['name'] == chap_cred['name']):
            for user in users:
                self.ra.delete_target_user(tname, user['name'])
            self._set_target_credentials(tname, chap_cred)
        # Sync flag regardless of whether credentials changed.
        if not target_data.get('incoming_users_active', False):
            self.ra.set_target_incoming_users_active(tname, True)
    except jexc.JDSSException as jerr:
        self.ra.delete_target(tname)
        raise jerr
else:
    # CHAP disabled — remove users and clear flag.
    try:
        users = self.ra.get_target_user(tname)
        for user in users:
            self.ra.delete_target_user(tname, user['name'])
        if target_data.get('incoming_users_active', False):
            self.ra.set_target_incoming_users_active(tname, False)
    except jexc.JDSSResourceNotFoundException:
        pass
```

Key changes from the original:
- Credentials are replaced only when the username differs (name-match skip).
  Password-only rotation is handled by `target update` in the recovery path or
  via an explicit `pvesm set` call — not on every `volume_publish`, to minimise
  REST calls.
- After ensuring credentials, `incoming_users_active` is set to `true` if it
  was not already.
- An `else` branch handles the CHAP-disable case: removes users and sets the
  flag to `false`.

This also resolves **Open Question 4** (see below): no new REST endpoint was
required — the existing `PUT` target endpoint already accepts
`incoming_users_active`.

---

## Error Handling

| Situation | Behaviour |
|---|---|
| `chap_enabled=1` but `chap_user_name` not set | `die "chap_user_name not set\n"` in `volume_publish` and `volume_stage_iscsi` |
| `chap_enabled=1` but `chap_user_password` not set (missing .pw entry) | `die "chap_user_password not set\n"` in same locations |
| `iscsiadm -o update` fails for auth param | `run_command` raises; `volume_stage_iscsi` propagates the error; login is not attempted |
| `iscsiadm --login` fails with exit code 24 (`authorization failure`) | Host added to `@chap_failed`. After all pending hosts attempted, step 4 calls `target_update_chap` once (sets `$chap_recovery_done = 1`). Outer loop retries; step 1 re-reads credentials, step 2 re-applies node DB update. |
| Second CHAP auth failure (after `target_update_chap` already ran) | Fatal — `die "CHAP authentication failed ... check CHAP configuration"`. `$chap_recovery_done` flag prevents further `target_update_chap` calls. Operator must verify credentials and target state. |
| Target exists without CHAP, `chap_enabled` is now true | Next `volume_publish` sets CHAP user and `incoming_users_active: true` on the target. Initiator supplies credentials at next login. No recovery path needed — login succeeds because the target now enforces CHAP and the initiator provides credentials. |
| Target exists with CHAP, `chap_enabled` is now false | `volume_publish` runs the `else` branch of `_ensure_target_volume_lun`: removes users and clears `incoming_users_active`. If this runs before `volume_stage_iscsi`, login succeeds without credentials. If `volume_publish` ran with the old config (CHAP enabled) and config changed mid-flight, `volume_stage_iscsi` supplies no credentials, target still enforces CHAP, login fails with exit code 24. Recovery: `target_update_chap` issues `--no-chap`, target disables enforcement, retry login succeeds. |

---

## Files Changed

| File | Change |
|---|---|
| `OpenEJovianDSSPlugin.pm` | Add `chap_enabled`, `chap_user_name` to `properties()` and `options`; add `chap_user_password` to `sensitive-properties`; extend `on_add_hook` and `on_update_hook` |
| `OpenEJovianDSS/Common.pm` | Add `_password_file_set_key`, `_password_file_delete_key`, `_password_file_get_key` helpers; refactor existing password functions to use them; add `get_chap_enabled`, `get_chap_user_name`, `get_chap_user_password`, `password_file_set_chap_password`, `password_file_delete_chap_password`; add `target_update_chap` (syncs JovianDSS target CHAP state, handles both enable and disable); add `_iscsiadm_clear_chap` (resets node DB authmethod to None); extend `volume_publish` and `volume_stage_iscsi`; `volume_stage_iscsi` refactored: credentials read inside outer loop (step 1), `%host_db_ready` avoids redundant node-DB setup, CHAP failures collected in `@chap_failed` (step 3), single `target_update_chap` call in step 4 with `$chap_recovery_done` guard |
| `jdssc/jdssc/targets.py` | Add `--chap-user` and `--chap-password` arguments to `create` subcommand; construct and pass `provider_auth` to `ensure_target_volume` |
| `jdssc/jdssc/pool.py` | Add `target` (singular) to dispatch table and subparser so `jdssc pool <pool> target <IQN> <action>` is routable |
| `jdssc/jdssc/target.py` | Fix `self.va` → `self.ta` dispatch bug; rename class to `Target`; implement `get`, `delete`, `update` methods; add `--chap-user` / `--chap-password` / `--no-chap` flags to `update` |
| `jdssc/jdssc/jovian_common/driver.py` | Add `get_target()`, `delete_target()` public thin wrappers; add `update_target(target_name, provider_auth)` — always replaces credentials unconditionally (no name-match skip); `_ensure_target_volume_lun` CHAP block rewritten to sync `incoming_users_active` and handle CHAP-disable path; `_ensure_target_volume_lun` retains name-match skip for efficiency (password-only rotation handled lazily via recovery path) |
| `jdssc/jdssc/jovian_common/rest.py` | Add `set_target_incoming_users_active()`; required by `_ensure_target_volume_lun` flag sync and `update_target` |

No changes required to:
- `OpenEJovianDSSNFSPlugin.pm` — NFS plugin does not use iSCSI targets

---

## Post-Implementation Refactoring

The following changes were applied to `Common.pm` after the initial
implementation to improve naming clarity and eliminate magic strings.

### Path constants (`use constant`)

Three module-level path variables were converted from `my $VAR` to
`use constant`:

```perl
use constant {
    PLUGIN_LOCAL_STATE_DIR          => '/etc/joviandss/state',
    PLUGIN_GLOBAL_STATE_DIR         => '/etc/pve/priv/joviandss/state',
    PLUGIN_GLOBAL_PASSWORD_FILE_DIR => '/etc/pve/priv/storage/joviandss',
};
```

`PLUGIN_GLOBAL_PASSWORD_FILE_DIR` was introduced at this point to replace the
hardcoded string `"/etc/pve/priv/storage/joviandss"` that appeared in
`get_password_file_path` and `_password_file_set_key`.

### Function rename: `get_password_file_name` → `get_password_file_path`

The function was renamed to reflect that it returns a file path string, not a
file descriptor or bare filename. Updated in `Common.pm`, `NFSCommon.pm`
(definition, export list, and all call sites).

### Variable rename: `$pwfile` → `$pwfile_path`

Local variables assigned from `get_password_file_path` were renamed to
`$pwfile_path` to make it explicit that the value is a path string, not a file
handle. Applied consistently across all four call sites in `Common.pm` and
three in `NFSCommon.pm`.

### `_password_file_delete_key`: missing-file guard changed to `die`

The early-return guard on a missing password file was strengthened from a
silent `return` to a hard `die`:

```perl
# before
return unless -f $pwfile_path;

# after
die "password file '$pwfile_path' does not exist\n" unless -f $pwfile_path;
```

Deleting a key from a file that does not exist indicates a caller bug (the
file should have been created by `_password_file_set_key` before this function
is called). Silently returning masked the problem; `die` surfaces it.

### Variable rename: `$out` → `$password_file_data` in `_password_file_delete_key`

The temporary variable that accumulates the serialised key/value pairs was
renamed to `$password_file_data` for clarity. The `join`/`map` one-liner was
also rewritten as an explicit loop to improve readability:

```perl
# before
my $out = join('', map { "$_ $config{$_}\n" } sort keys %config);
PVE::Tools::file_set_contents($pwfile_path, $out, 0600, 1);

# after
my $password_file_data = '';
for my $k (sort keys %config) {
    $password_file_data .= "$k $config{$k}\n";
}
PVE::Tools::file_set_contents($pwfile_path, $password_file_data, 0600, 1);
```

### `volume_stage_iscsi` — server/host call separation

The CHAP recovery logic inside `volume_stage_iscsi` was refactored to cleanly
separate server-side (JovianDSS REST) calls from per-host (`iscsiadm`) calls:

**Before:** `target_update_chap` was called inline inside the per-host login
loop, immediately followed by `_iscsiadm_set_chap` / `_iscsiadm_clear_chap`
and an inline retry `--login`. This mixed a single server-side REST call into a
loop that ran once per host, and retried login inline without going back through
the credential-read path.

**After (4-step structure):**

- **Step 1 (credential read):** `get_chap_enabled`, `get_chap_user_name`,
  `get_chap_user_password` — once per outer attempt, before any per-host work.
  Placed inside the outer loop so the next iteration automatically picks up
  credentials synced by `target_update_chap`.
- **Step 2 (node DB setup):** `iscsiadm -o new` and `-o update` run once per
  host (`%host_db_ready` flag); `_iscsiadm_set_chap` / `_iscsiadm_clear_chap`
  run every attempt to keep the node DB current.
- **Step 3 (login pass):** `iscsiadm --login` for each pending host; CHAP
  authorization failures collected in `@chap_failed` — no inline recovery.
- **Step 4 (CHAP recovery):** if `@chap_failed` is non-empty, call
  `target_update_chap` exactly once (`$chap_recovery_done` guard); if it was
  already called and auth still fails, `die` immediately.

Key properties of the new design:
- `target_update_chap` is called at most once per `volume_stage_iscsi`
  invocation regardless of how many hosts failed.
- No inline retry loop in step 4; the outer loop handles the retry, ensuring
  credential re-read and node-DB update happen before the next login attempt.
- `$chap_recovery_done` prevents repeated REST calls on genuine
  misconfiguration; instead of silently looping, the function dies after the
  second CHAP failure.

---

## Open Questions

1. **Credential validation at property-set time** — should the plugin validate
   password length (≥12, ≤16 bytes) in the `properties()` definition, or
   accept that JovianDSS will reject invalid lengths via REST error?

2. ~~**CHAP disable with active targets**~~ — **Resolved.** The recovery path
   now handles CHAP-disable mid-flight: when exit code 24 is detected and
   `chap_enabled=0`, `target_update_chap` issues `--no-chap` to clear
   enforcement on the JovianDSS target, and login is retried without
   credentials. See the Authorization Failure — Error and Recovery section.

3. **`--chap-credentials-file` for jdssc** — passing credentials via argv
   exposes them in `/proc/<pid>/cmdline`. A file-based argument would close
   this window without requiring stdin changes to `joviandss_cmd`. Tracked as
   a follow-up to C-3 from the security review.

4. ~~**`incoming_users_active` flag on existing targets**~~ — **Resolved.**
   The `PUT /san/iscsi/targets/<name>` endpoint accepts `incoming_users_active`
   in the request body. `set_target_incoming_users_active()` was added to
   `rest.py` and called from the updated `_ensure_target_volume_lun` in
   `driver.py`. See the `incoming_users_active` Flag Synchronisation section.

5. ~~**`target update` with no flags**~~ — **Resolved.** A dedicated
   `--no-chap` flag is added to make CHAP-disable intent explicit. Providing
   none of `--chap-user/--chap-password` or `--no-chap` is a CLI error
   (exit 1). This prevents accidental CHAP removal from a forgotten argument.
