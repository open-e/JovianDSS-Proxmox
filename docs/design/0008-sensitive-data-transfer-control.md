# Sensitive Data Transfer Control — Design Document (ACCEPTED, IMPLEMENTED)

> **Status: accepted — implemented and verified live on the pve-91 cluster.**
> Of the two drafted channels for delivering the REST and CHAP passwords to
> `jdssc` off `argv` — [Variant A (env)](#variant-a--environment-variables) and
> [Variant B (file)](#variant-b--credentials-file) — **B was chosen** (single
> source of truth) and implemented, together with
> [Part 2](#part-2--the-iscsiadm-vector)'s `iscsiadm` marker-swap. Closes the
> `jdssc`-path exposure of **A1** (secrets on `argv`) and **A2** (secrets in the
> log), the newly-found REST-password log dump, and the `iscsiadm` `argv` and
> death-string leaks. The A2
> [log-permission half](#relationship-to-other-work) remains separate, open work.
>
> Live verification (90 tests, see [Testing](#testing)) found **two
> implementation bugs**, both fixed and re-verified: a hardcoded node-DB path,
> and a `perl -T` taint failure that broke every container operation on CHAP
> storage. Both are recorded in [Part 2](#part-2--the-iscsiadm-vector) as
> constraints the mechanism must satisfy.

## Table of Contents

- [Overview](#overview)
- [Problem](#problem)
- [Proposition](#proposition)
- [Key_Observation](#key-observation)
  - [Sensitive_data](#sensitive-data)
    - [REST_admin_password](#rest-admin-password)
    - [CHAP_password](#chap-password)
  - [Exposure_vectors](#exposure-vectors)
    - [Process_arguments](#process-arguments)
    - [Log_content](#log-content)
    - [Log_file_access](#log-file-access)
    - [At_rest_stores](#at-rest-stores)
    - [Network_transport](#network-transport)
  - [The_chokepoint](#the-chokepoint)
- [Design](#design)
  - [Strategy](#strategy)
  - [Part_1_Off_argv_delivery_to_jdssc](#part-1--off-argv-delivery-to-jdssc)
    - [Shared_by_both_channels](#shared-by-both-channels)
    - [The_log_leak_corollary_A2_content_for_free](#the-log-leak-corollary-a2-content-for-free)
    - [Variant_A_environment_variables](#variant-a--environment-variables)
    - [Variant_B_credentials_file](#variant-b--credentials-file)
    - [Choosing_between_them](#choosing-between-them)
  - [Part_2_The_iscsiadm_vector](#part-2--the-iscsiadm-vector)
- [Alternatives_Considered](#alternatives-considered)
- [Function_Interface_Changes](#function--interface-changes)
- [Consequences](#consequences)
- [Risks_Backward_Compatibility](#risks--backward-compatibility)
- [Files_That_Changed](#files-that-changed)
- [Testing](#testing)
- [Relationship_to_Other_Work](#relationship-to-other-work)
- [Open_Questions](#open-questions)

## Overview
[Overview](#overview)

The plugin is two parts — a **Perl** storage plugin and the **Python `jdssc`
CLI** — serving volume data over **iSCSI** (driving the Linux iSCSI subsystem via
`iscsiadm`) and over **NFS** (REST only, no `iscsiadm`). Operating it requires
moving secrets **across these boundaries**: the REST admin password (Perl →
`jdssc`, every call, both storage types — and on to the appliance over TLS) and
the CHAP password (iSCSI only; Perl → `jdssc` at target setup, Perl → `iscsiadm`
at initiator login).

## Problem
[Problem](#problem)

Sensitive data should not be exposed to unauthorised processes.
Every sensitive data transfer is a leakage surface, and **before this change**
the secrets crossed as **command-line arguments** — world-readable through
`/proc/<pid>/cmdline` (`ps`) and echoed into the plugin log (findings **A1**,
secrets on `argv`; **A2**, secrets in the log).

## Proposition
[Proposition](#proposition)

Address the security implications and harden sensitive-data management against
leakage across each boundary.

## Key Observation
[Key_Observation](#key-observation)

The plugin handles two secrets, each leaking through a small, enumerable set of
vectors — the catalog this design must cover (a latent third credential,
`jdssc`-only, is noted under [Process arguments](#process-arguments)). The
chokepoint at the end is the pivot for the `jdssc` fix.

### Sensitive data
[Sensitive_data](#sensitive-data)

#### REST admin password
[REST_admin_password](#rest-admin-password)

The `user_password` that authenticates **every** `jdssc` REST call. Held at rest
in the per-storage `.pw` file (`/etc/pve/priv/storage/<type>/<storeid>.pw`,
`0600`).

#### CHAP password
[CHAP_password](#chap-password)

The `chap_user_password` for iSCSI initiator ↔ target authentication on CHAP
storages. Held in the `.pw` file (`0600`) and the open-iscsi node DB (`0600`).
The CHAP and REST *usernames* are not secret.

### Exposure vectors
[Exposure_vectors](#exposure-vectors)

The catalog below is the **pre-change** picture — the audit record this design
had to cover. Severity is the review's rating (HIGH / MEDIUM / LOW / INFO);
*Finding* ties a site to **A1** (secrets on `argv`), **A2** (secrets in the log),
or a **new** site the sensitive-data review surfaced; *Closed by* records what
actually removed it. Line references are to the pre-change code.

#### Process arguments
[Process_arguments](#process-arguments)

`/proc/<pid>/cmdline` (`ps -eo args`) is world-readable for a process's lifetime,
so any secret on a spawned command line is exposed to every local user. The
[REST](#rest-admin-password) and [CHAP](#chap-password) passwords currently ride
`argv`:

| Site | Secret | Severity | Finding | Closed by |
|---|---|---|---|---|
| `Common.pm` — `jdssc --user-password` | REST | HIGH | A1 | Part 1 |
| `Common.pm` — `jdssc --chap-password` (publish + target update) | CHAP | HIGH | A1 | Part 1 |
| `Common.pm` — `iscsiadm … -v <pass>` | CHAP | HIGH | A1 | Part 2 |

Latent, outside the plugin's paths: [`cifs.py:56-57`](../../jdssc/jdssc/cifs.py#L56-L57) takes a third
credential — the CIFS share password — on `argv`; no Perl code path invokes it
(INFO).

#### Log content
[Log_content](#log-content)

Secrets written into the plugin log text — persistent, and readable by every
local user given [log-file access](#log-file-access) below. Both the Perl and
`jdssc` layers reach it:

| Site | Secret | Severity | Finding | Closed by |
|---|---|---|---|---|
| [`nas_snapshots.py:93`](../../jdssc/jdssc/nas_snapshots.py#L93) — `jdssc` dumps `self.args` on NAS-snapshot create | REST | HIGH | new | Part 1 (value is now `None`) |
| `Common.pm` — un-`noerr`'d `run_command` death string carries `-v <pass>`; the `warn` and both `die`s also reach the **PVE task log** | CHAP | HIGH | new | Part 2 (only the marker is on `argv`) |
| `Common.pm` — `cmd_log_output` logs the `iscsiadm` line: `outfunc` at debug, `errfunc` on any stderr | CHAP | HIGH | A2 | Part 2 (same) |
| [`targets.py:60-64`](../../jdssc/jdssc/targets.py#L60-L64) — `jdssc` dumps the argparse `Namespace` on target create | CHAP | HIGH | A2 | Part 1 (value is now `None`) |

The `jdssc` dumps require debug logging (storage `debug 1`, or `loglvl` in the
`-c` config) and the `cmd_log_output` `outfunc` requires storage `debug 1`; the
`errfunc` and the death-string sites fire at the default `INFO` level
(`error`/`warn` ≤ `INFO`), so they need no `debug`. Lower-severity and latent sites, all **new**: [`rest.py:117`](../../jdssc/jdssc/jovian_common/rest.py#L117)
logs the whole appliance response, exposing CHAP only if the array echoes it back
(LOW); [`bin/jdssc:343`](../../jdssc/bin/jdssc#L343) parses the `-c` YAML config unguarded — a malformed
file's parse error can echo its `rest_api_password` line to stderr and on into
the task log (LOW, conditional); [`target.py:138`](../../jdssc/jdssc/target.py#L138) prints the raw target object to stdout (INFO, conditional);
[`rest_proxy.py:121-124`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L121-L124) is a commented-out request-body debug that would leak the
CHAP body if re-enabled (INFO, latent); [`driver.py:1310-1311`](../../jdssc/jdssc/jovian_common/driver.py#L1310-L1311) returns the CHAP
password inside the target-publication dict, one step from an existing `tinfo`
debug log ([`targets.py:410-412`](../../jdssc/jdssc/targets.py#L410-L412)) (INFO, latent); [`Common.pm:1326`](../../OpenEJovianDSS/Common.pm#L1326) re-throws
`jdssc` stderr verbatim (INFO, residual).

#### Log file access
[Log_file_access](#log-file-access)

The log is `0644` in a `0755` directory ([`Common.pm:1077`](../../OpenEJovianDSS/Common.pm#L1077); dir [`:1064-1065`](../../OpenEJovianDSS/Common.pm#L1064-L1065)) —
world-readable — so any secret reaching [the log](#log-content) is readable by
every local user (A2 permission half, **HIGH**). `jdssc` is a second creator of
the same file: its `RotatingFileHandler` ([`bin/jdssc:204-206`](../../jdssc/bin/jdssc#L204-L206)) re-creates it at
umask-derived `0644` on every rollover, keeping up to 5 world-readable backups.

#### At-rest stores
[At_rest_stores](#at-rest-stores)

The `.pw` file and the open-iscsi node DB hold the secrets at `0600`, root-only —
acceptable, not a leak. `storage.cfg` is weaker: it is `0640 root:www-data` —
readable by the web-server user, **not** `priv/`-protected — and an inline
password there is returned by the getters ([`Common.pm:634-640`](../../OpenEJovianDSS/Common.pm#L634-L640), [`:665-670`](../../OpenEJovianDSS/Common.pm#L665-L670))
(MEDIUM, new). On hosts below APIVER 11 (sensitive-properties starts at 11)
`pvesm set` delivers the passwords in `$opts_update` and PVE writes them into
`storage.cfg`.

**The two credentials are treated differently, on purpose.** The CHAP password
lives in the `.pw` file **only**: an inline one is refused outright
([`get_chap_user_password`](../../OpenEJovianDSS/Common.pm#L659)), so the operator
re-adds it through a channel that stores it protected. The REST password keeps
its read fallback with a warning
([`get_user_password`](../../OpenEJovianDSS/Common.pm#L634-L640)), so a
partially-migrated entry still resolves rather than becoming unreachable. Both
are pinned in the legacy block of
[`api_compat_test.pl`](../../tests/api_compat_test.pl).

**Deliberately not addressed by the plugin.** A hook *could* delete the password
keys from `$opts_update` after storing them, which would stop that write-back —
but the plugin does not rewrite the caller's update options. Doing so would have
it intervene in how the user configures the storage, and would leave PVE's record
disagreeing with what the operator asked for. On APIVER ≥ 11 (PVE 8.4+, which
covers every supported target of this change) the sensitive-properties mechanism
keeps the value out of `storage.cfg` anyway. The `.pw` file is authoritative on
read regardless. Pinned by unit tests in
[`api_compat_test.pl`](../../tests/api_compat_test.pl) and
[`nfs_api_compat_test.pl`](../../tests/nfs_api_compat_test.pl), which assert the
update options come back unmodified.

#### Network transport
[Network_transport](#network-transport)

The [REST password](#rest-admin-password) crosses to the appliance as an HTTP
Basic header on every call ([`rest_proxy.py:77`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L77)). With `ssl_cert_verify 0` — a
documented property, standard for self-signed appliances — TLS verification is
off and the header is readable in transit (LOW). Mitigation is operational
(verified certificates); out of scope for this design. The same layer also falls
back to a hardcoded `'admin'` password default ([`rest_proxy.py:64`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L64)) (INFO,
hygiene).

### The chokepoint
[The_chokepoint](#the-chokepoint)

`jdssc` is invoked from one place — `joviandss_cmd` (`Common.pm`), the chokepoint
from [0005](0005-password-resolution-through-ctx.md). Its `$jrun` closure
([`Common.pm:1284-1292`](../../OpenEJovianDSS/Common.pm#L1284-L1292)) is the only child spawn and `exec`s `jdssc` directly
(arrayref to `run_command`, no shell). So a secret can reach `jdssc` at this one
`exec` by any out-of-band channel, appended to nothing on `argv`; the two channels
below differ only in that transport, everything else
[shared](#shared-by-both-channels).

---

## Design
[Design](#design)

### Strategy
[Strategy](#strategy)

The two [secrets](#sensitive-data) leak across the [exposure vectors](#exposure-vectors)
above. Two part-changes, in priority order, close every HIGH site of the
[process-arguments](#process-arguments) and [log-content](#log-content) vectors;
the remaining vectors carry separable or operational fixes, recorded in the
catalog. Each part is a section below:

- **[Part 1 — Off-argv delivery to `jdssc`](#part-1--off-argv-delivery-to-jdssc)** —
  the main leak ([process arguments](#process-arguments), both secrets). Hand `jdssc`
  a reference to the credential, not the credential itself; it resolves the reference
  out-of-band.
- **[Part 2 — The `iscsiadm` vector](#part-2--the-iscsiadm-vector)** — the CHAP
  password on `iscsiadm`'s own `argv` and in the logs that echo it. Narrower,
  separable, its own mechanism.

Part 1 is the core — it closes A1 and A2 on the `jdssc` path at once, all secret
injection staying in `joviandss_cmd`. Part 2 is
[implementation-separable](#relationship-to-other-work) and closes the remaining
`iscsiadm` surface.

### Part 1 — Off-argv delivery to `jdssc`
[Part_1_Off_argv_delivery_to_jdssc](#part-1--off-argv-delivery-to-jdssc)

#### Shared by both channels
[Shared_by_both_channels](#shared-by-both-channels)

**Perl (`joviandss_cmd`).** Resolve the credentials into lexicals instead of onto
`argv`:

```perl
my $user_password = get_user_password($ctx);
die "JovianDSS REST user password is not provided.\n" if !defined($user_password);

my $chap_password;
$chap_password = get_chap_user_password($ctx) if get_chap_enabled($ctx);
```

The `--user-password` push and both `--chap-password` pushes are gone;
**`--chap-user` stays** — not a secret, and the "CHAP wanted" signal `jdssc` keys
on. The variants differ only in delivery: A would transport the lexicals; B (the
implemented one) points `jdssc` at their `.pw` source.

**jdssc.** Each secret resolves flag-first, channel-second, into a local:

```python
value = args.get('<flag>') or channel.get('<key>')   # never written back into args
```

- `--user-password` → optional (`required=False`); resolves from the channel when
  the flag is absent, and a password missing from *every* channel still errors.
- `--chap-password` → optional; resolves from the channel when `--chap-user` is
  present.
- The format-validation checks run on the resolved value, unchanged.

**Keep the flags accepted** (not required): direct / `pve-testing` invocations
and the upgrade window rely on them; an explicit flag wins over the channel.

#### The log-leak corollary (A2 content, for free)
[The_log_leak_corollary_A2_content_for_free](#the-log-leak-corollary-a2-content-for-free)

Two `jdssc`-side sites dump `argv`-derived values into the log: [`targets.py:60-64`](../../jdssc/jdssc/targets.py#L60-L64)
stringifies the argparse `Namespace` (`chap_password='<secret>'`), and
[`nas_snapshots.py:93`](../../jdssc/jdssc/nas_snapshots.py#L93) logs the whole accumulated `self.args` (which carries
`user_password`). Both leak *only* because the secret is present on `args`. With
`--chap-password` and `--user-password` off `argv` (either variant),
`args.chap_password` / `args.user_password` are `None` and both dumps go clean —
no redaction code. One hard rule: resolve into a **local**, never back into
`args`, or the secret re-enters the dump. This closes both `argv`-derived
`jdssc`-path content leaks (the known A2 `Namespace` dump and the newly-found
`self.args` dump) for free; the other, lower-severity `jdssc` log sites in
[Log content](#log-content) stay open regardless of the transport — out of scope
for this change.

#### Variant A — environment variables
[Variant_A_environment_variables](#variant-a--environment-variables)

The lexicals cross into `jdssc` through `%ENV`, scoped to the `exec` with `local`:

```perl
my $jrun = sub {
    local $ENV{JDSSC_USER_PASSWORD} = $user_password;
    local $ENV{JDSSC_CHAP_PASSWORD} = $chap_password if defined $chap_password;
    my $jcmd = [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ];
    $exitcode = run_command( $jcmd, … );
};
```

| env var | value | set when |
|---|---|---|
| `JDSSC_USER_PASSWORD` | `$user_password` | every call |
| `JDSSC_CHAP_PASSWORD` | `$chap_password` | `get_chap_enabled($ctx)` |

- **Tightest scope** — `local` inside `$jrun` keeps the secret out of the
  surrounding `with_lock` environment ([`Common.pm:1299`](../../OpenEJovianDSS/Common.pm#L1299)); auto-restores; persists
  across the internal retries (each re-invokes `$jrun`).
- **Not world-readable** — `/proc/<pid>/environ` is `0600`, owner-only, unlike
  `cmdline`.
- **Concurrency-safe** — workers are separate processes; calls within one are
  sequential.
- **First env secret** — no secret enters `%ENV` anywhere in the stack today; A
  introduces the first, bounded to the `exec`.

`JDSSC_CHAP_PASSWORD` is set for every call on a CHAP storage (ignored by
non-CHAP commands) — a root-only over-set that keeps the channel at one
chokepoint. **Adds:** two env vars, no files.

#### Variant B — credentials file
[Variant_B_credentials_file](#variant-b--credentials-file)

The secrets reach `jdssc` through the per-storage `.pw` file — the same store the
lexicals are resolved from — whose path is passed on `argv`; the path is not a
secret. `jdssc` reuses the existing `key value` format
([0005](0005-password-resolution-through-ctx.md)) so its parser stays one
function:

```
user_password <rest-pw>
chap_user_password <chap-pw>
```

**Perl** ([`joviandss_cmd`](../../OpenEJovianDSS/Common.pm#L1238-L1256)). Point
`jdssc` at the file. The file is **required**: a config that has none — an entry
from a plugin version before v0.10.10 that still carries the password inline in
`storage.cfg` — fails loudly and tells the operator to set the credentials, which
creates it:

```perl
my $storage_type = get_plugin_type($ctx);
my $pw_file = get_password_file_path( $storage_type, $storeid );
if ( !-f $pw_file ) {
    die "Unable to identify password file, please update user password and "
      . "CHAP password (if chap is used) to make it present\n";
}
push @$connection_options, '--sensitive-file', $pw_file;
```

Migrating such a config silently was considered and rejected on the same ground
as the [`storage.cfg` write-back](#at-rest-stores): the plugin does not rewrite
the operator's configuration behind their back. The trade is explicit — a legacy
inline-only entry stops working until its password is re-set, which is what the
message asks for and what `pvesm set --user_password <value>` does (the value
travels the sensitive channel straight into the `.pw` file). Pinned end to end by
`iscsi-plugin/config-change/legacy-inline-credentials-operational.yaml`.

**jdssc.** Add `--sensitive-file <path>`, parsed once by the shared
[`cli_common.load_sensitive_file`](../../jdssc/jdssc/cli_common/cli_common.py#L73):

```python
def load_sensitive_file(path):
    creds = {}
    ...
    key, _, val = line.strip().partition(' ')   # first space only: values may contain spaces
    if key and val:
        creds[key] = val
    return creds
```

Two consumers read it, each resolving into a **local**:

- **REST** — [`bin/jdssc`](../../jdssc/bin/jdssc#L297-L302) `unify_config_options`
  puts the value in `cfg['san_password']`, never back into `args`. Precedence:
  explicit `--user-password` > `--sensitive-file` > `-c` config file. A missing
  password after all three is a clean one-line error and `exit(1)`.
- **CHAP** — `_resolve_chap_password` in
  [`targets.py`](../../jdssc/jdssc/targets.py#L29) and
  [`target.py`](../../jdssc/jdssc/target.py#L30), consulted when `--chap-user` is
  present and no `--chap-password` was passed.

| passed on `argv` | value | secret? |
|---|---|---|
| `--sensitive-file` | the file path | no |
| file contents | `user_password` / `chap_user_password` | yes — `0600`, root-only |

**Adds:** one CLI arg (`--sensitive-file`) and the shared `cli_common` module; no
env vars, no per-call file, no writes at all on the read path.

#### Choosing between them
[Choosing_between_them](#choosing-between-them)

|                        | A (env)               | B (file)                       |
|------------------------|-----------------------|--------------------------------|
| Closes A1 + A2 content | yes                   | yes                            |
| New machinery          | two env vars          | one arg `--sensitive-file`     |
| Secret lifetime        | bounded to the `exec` | the `.pw` file at rest         |
| Coupling               | none                  | the pmxcfs `.pw` path          |
| Single source of truth | parallel channel      | reuses the `.pw` file/format   |
| Legacy inline config   | n/a                   | migrated into `.pw` on 1st use |

**Recommendation: A.** Equal on security (`environ` and the `.pw` file are both
root-only) and both make the [log corollary](#the-log-leak-corollary-a2-content-for-free)
free. A edges it on scope — the secret lives only for the `exec`, with no file path
on `argv` and no pmxcfs coupling. B is now nearly as light (one arg, a one-time
migration) and wins single-source-of-truth: it reuses the `.pw` file rather than
adding a parallel channel. **Decided: B** — single source of truth won
([Open Questions](#open-questions)).

### Part 2 — The iscsiadm vector
[Part_2_The_iscsiadm_vector](#part-2--the-iscsiadm-vector)

`_iscsiadm_set_chap` ([`Common.pm:2224-2244`](../../OpenEJovianDSS/Common.pm#L2224-L2244)) runs, per pending host on a cold
login, `iscsiadm … -o update -n node.session.auth.password -v <chap_pass>`.
`iscsiadm` offers no alternative: a value is settable only with `-n/-v` — no file,
env, or stdin. So the password can leave `iscsiadm`'s `argv` only by not asking
`iscsiadm` to set it.

Three exposures, of unequal weight:

- **[Log content](#log-content) (serious, persistent)** — `cmd_log_output`
  ([`Common.pm:2239-2240`](../../OpenEJovianDSS/Common.pm#L2239-L2240)) writes the full command line, including `-v <pass>`, to
  the `0644` log.
- **[Log content](#log-content) via the `run_command` death (serious, new)** — the
  `run_command` ([`Common.pm:2237`](../../OpenEJovianDSS/Common.pm#L2237)) carries no `noerr`, so an `iscsiadm` failure
  dies with the full argv (`-v <pass>`); the death string is logged via `warn`
  ([`Common.pm:4436`](../../OpenEJovianDSS/Common.pm#L4436)) and re-thrown via `die` ([`Common.pm:4548`](../../OpenEJovianDSS/Common.pm#L4548-L4550), [`:4558`](../../OpenEJovianDSS/Common.pm#L4558)) into the **PVE
  task log**. It never passes through `cmd_log_output`, so redaction there
  (mechanism (a)) does not catch it.
- **[Process arguments](#process-arguments) (narrow, transient)** — the `-v`
  value is on `argv` for the milliseconds
  `-o update` runs, and only on *cold* logins (a warm export never calls
  `_iscsiadm_set_chap`). The persisted value lands in the OS node DB
  (`<node-db>/<target>/<ip>,<port>,<tpgt>/default`, `0600` root-only, where
  `<node-db>` is `/var/lib/iscsi/nodes` on Debian 13 / older
  `/etc/iscsi/nodes`) — so only transit is exposed, not at-rest.

Three mechanisms, increasing completeness and cost:

#### (a) Redact — the fallback baseline (closes the `cmd_log_output` log half)

Redact the `auth.password` `-v` value in `cmd_log_output` before it logs. Tiny, no
open-iscsi coupling; closes the `cmd_log_output` **log** exposure but leaves the narrow `ps`
window, and does **not** close the `run_command`-death channel above — so on its
own it would also need `noerr => 1` on the `run_command`
([`Common.pm:2237`](../../OpenEJovianDSS/Common.pm#L2237)) to stop the death string
leaking. The chosen **(c)** makes both unnecessary — the real password never
reaches `iscsiadm` — so (a) stands only as the fallback if (c) is not taken.

#### (b) Write the node DB record file directly

Write `node.session.auth.password = <pass>` into the record's `default` file
(`0600`) ourselves instead of `iscsiadm -o update`. Off `argv`, but must
**construct the record path** (the `<ip>,<port>,<tpgt>` dir, tpgt not always known)
and **couples to open-iscsi's on-disk format**.

#### (c) Sentinel-swap — (b)'s off-`argv`, minus its coupling (chosen)

Let `iscsiadm` do the structural write with a throwaway token, then swap it:

1. Generate a unique random token — a v4 UUID.
2. `iscsiadm … -v <TOKEN>` — only the token reaches `argv`/the log.
3. `grep -rl <TOKEN>` over the node-DB root(s) to locate the record; swap the
   token for the real password with a mode-preserving literal edit.
4. Log in.

This keeps (b)'s off-`argv` property while dropping both costs: `iscsiadm` writes
the correct file/key/format (no format coupling) and the token self-locates the
file (no path/tpgt construction). The token is worthless — no login happens
between steps 2 and 3, so scraping it yields a dead string.

**In `Common.pm`.** `_iscsiadm_set_chap` sets the two non-secret keys directly,
then hands `iscsiadm` a token for the password key and swaps it into the record:

As implemented — [`_iscsiadm_set_chap`](../../OpenEJovianDSS/Common.pm#L2313),
[`_uuid_generate`](../../OpenEJovianDSS/Common.pm#L2251),
[`_iscsi_data_roots`](../../OpenEJovianDSS/Common.pm#L2269),
[`_iscsi_data_password_substitute`](../../OpenEJovianDSS/Common.pm#L2278):

```perl
sub _iscsiadm_set_chap {
    my ($ctx, $host, $targetname, $chap_user, $chap_pass) = @_;

    # authmethod + username are not secret — set on argv as before.
    _iscsiadm_node_set($ctx, $host, $targetname, 'node.session.auth.authmethod', 'CHAP');
    _iscsiadm_node_set($ctx, $host, $targetname, 'node.session.auth.username', $chap_user);

    # the password IS secret: iscsiadm gets a throwaway marker; the real value is
    # swapped into the record iscsiadm just wrote — never onto argv.
    my $uuid = _uuid_generate();
    _iscsiadm_node_set($ctx, $host, $targetname, 'node.session.auth.password', $uuid);
    _iscsi_data_password_substitute($ctx, $uuid, $chap_pass);
}

sub _uuid_generate {
    my $token = PVE::Tools::file_read_firstline('/proc/sys/kernel/random/uuid');
    die "failed to read a sentinel token from /proc\n" if !defined($token) || !length($token);
    # The capture untaints AND validates the format — see "Two constraints" below.
    return $1 if $token =~ /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})$/a;
    die "unexpected sentinel token format from /proc\n";
}

sub _iscsi_data_password_substitute {
    my ($ctx, $uuid, $real) = @_;

    my @roots = _iscsi_data_roots();          # both node-DB roots, existing ones only
    my @files;
    run_command([ 'grep', '-rlF', '--', $uuid, @roots ],
        outfunc => sub { my $l = shift; chomp $l; push @files, $l; },
        noerr => 1, timeout => 10);              # grep exits 1 on no match
    die "marker uuid not found under the open-iscsi node DB (@roots)\n" if !@files;

    my $roots_re = join '|', map { quotemeta } @roots;
    for my $file (@files) {
        # untaint + confine the grep-returned path to the node DB
        my ($safe) = $file =~ m{^((?:$roots_re)/[\w./:,+=\@-]+)$}a;
        die "unexpected node DB path returned by grep\n" if !defined($safe);

        my $mode    = (stat $safe)[2] & 07777;           # preserve 0600 root:root
        my $content = PVE::Tools::file_get_contents($safe);
        $content =~ s/\Q$uuid\E/$real/g;                 # match marker literally; insert pw verbatim
        PVE::Tools::file_set_contents($safe, $content, $mode);
    }
}
```

`_iscsiadm_node_set` is the existing per-key `iscsiadm -o update` wrapped in
`run_command`. Because the real password never reaches `iscsiadm` here, **(c)
subsumes (a) and the `noerr` fix on this path**: the command line and any death
string carry only the marker, so there is nothing to redact and nothing secret to
leak on failure.

**Two constraints live verification added.** Both were found only by running the
mechanism on a real node, and both are load-bearing:

1. **The node-DB root is not fixed.** open-iscsi ≥ 2.1.10 (Debian 13 / PVE 9)
   keeps records under `/var/lib/iscsi/nodes`; older releases use
   `/etc/iscsi/nodes`. A hardcoded path makes `grep` find nothing and every CHAP
   cold login die after its retry cycles. `_iscsi_data_roots` searches whichever
   roots exist.
2. **The marker and the record paths must be untainted.** `pct` runs
   `#!/usr/bin/perl -T`, where file input is tainted: a tainted value may not
   reach `exec` (the `iscsiadm` argv) and a tainted filename may not reach a
   file-modifying operation (`file_set_contents`). Both are cleared through
   regex captures, which validate at the same time. Without this, every
   *container* operation on CHAP storage fails while VM operations pass — `qm`,
   `pvesm` and `pvesh` do not run under `-T`.

Its cost is the step-3 edit, six edges:

1. **Swap in-process** — the swap is the one moment the real password is in hand,
   so it must not leave the Perl process: `sed -i "s/<token>/<pass>/"` would put
   the secret on a child `argv`, recreating A1 inside the fix. The Perl
   read-modify-write also keeps the record's `0600 root:root` deterministic — the
   stat'd mode is re-applied explicitly on write, not left to a tool's
   attribute-copying behavior.
2. **Literal, not regex** — the CHAP charset carries regex metacharacters, so the
   password is the `s///` **replacement** (inert there), never the pattern; the
   token is matched with `\Q…\E` (`$real` holds no `\`/`$` — outside the charset —
   so it inserts verbatim).
3. **Verbatim storage (verify)** — the swap needs the token stored byte-for-byte
   (node DB stores CHAP passwords plaintext; confirm `iscsiadm` accepts the UUID
   token — 36 chars, benign charset; the 12–255 rule is appliance-side).
4. **Uniqueness/scope** — a fresh UUID per call, unique by construction; replace all
   occurrences of *that* token.
5. **The set→swap window** — the record briefly holds the token; safe only because
   `_iscsiadm_set_chap` → swap → login is sequential and lock-held with no login in
   the gap (an invariant).
6. **Crash self-heals** — dying after step 2 leaves a non-working token password;
   the next activation overwrites it.

The pattern generalizes: any tool that takes a secret only on `argv` but persists
it verbatim to a root-only file can be handled this way.

#### Recommendation

**Chosen: sentinel-swap (c).** It takes the password off `iscsiadm`'s `argv`
entirely, closing the `ps` window **and** — because the command line and its death
string then carry only the token — subsuming both (a) and the `noerr` fix on this
path (nothing secret is left to redact, nothing secret to leak on failure). (b) is
rejected for its path/`tpgt` construction and on-disk-format coupling. The change
is implementation-separable but designed here so the full A1/A2 picture is on
record.

---

## Alternatives Considered
[Alternatives_Considered](#alternatives-considered)

The two channels in [Design](#design) are the finalists (env-vs-file weighed in
[Choosing](#choosing-between-them); **B** decided). Two
others were rejected first:

- **stdin** — `jdssc` uses stdin/stdout for `volume export`/`import` data;
  credentials would collide with the data path.
- **File-descriptor passing** — overkill for a single-chokepoint, same-host
  boundary; no benefit over env or a file.

---

## Function / Interface Changes
[Function_Interface_Changes](#function--interface-changes)

**Perl (`Common.pm`)** — signatures unchanged throughout:

- `joviandss_cmd` — the `--user-password` push is gone; it now requires the
  per-storage `.pw` file and pushes `--sensitive-file <path>`.
- `volume_publish` ([`:2171`](../../OpenEJovianDSS/Common.pm#L2171)) and recovery
  `target update` ([`:2219`](../../OpenEJovianDSS/Common.pm#L2219)) — `--chap-password`
  dropped, `--chap-user` kept as the enable signal.
- `_iscsiadm_set_chap` rewritten around the marker swap; new
  `_iscsiadm_node_set`, `_uuid_generate`, `_iscsi_data_roots`,
  `_iscsi_data_password_substitute`.

**jdssc:**

- `bin/jdssc` — `--user-password` → `required=False`; new `--sensitive-file`;
  resolution into `cfg['san_password']` with a clean `exit(1)` when no channel
  supplies a password.
- new `jdssc/cli_common/cli_common.py` — shared `load_sensitive_file`,
  `chap_user_name_check`, `chap_user_password_check` and the appliance CHAP
  patterns, replacing the per-module copies in `targets.py`/`target.py`.
- `targets.py` / `target.py` — `--chap-password` optional; `_resolve_chap_password`
  resolves into a local, never back into `args`.

**Variant A (not implemented, kept for the record):** `$jrun` would set
`local $ENV{JDSSC_USER_PASSWORD}` / `JDSSC_CHAP_PASSWORD` and jdssc would read
`os.environ`; two env vars, no CLI arg.

---

## Consequences
[Consequences](#consequences)

- **A1 closed, both halves** — no secret reaches `ps` from `jdssc` (Part 1) or
  from `iscsiadm` (Part 2); verified over ~900k sampled `argv` lines on two nodes.
- **A2 content closed, plus the new `self.args` dump** — with the passwords off
  `argv`, neither the [`targets.py`](../../jdssc/jdssc/targets.py#L60-L64) `Namespace`
  dump (CHAP) nor the [`nas_snapshots.py:93`](../../jdssc/jdssc/nas_snapshots.py#L93)
  `self.args` dump (REST) carries a secret — no redaction code. The `iscsiadm`
  command line and its death string carry only the marker.
- **Single chokepoint preserved** — all `jdssc`-bound secret injection stays in
  `joviandss_cmd`.
- **No new credential-at-rest** — passwords live in the `.pw` files exactly as
  before; only transport changed. No temp files, no env vars.
- **The `.pw` file became mandatory** — a legacy inline-only entry now fails with
  an explicit instruction instead of silently working; see
  [Risks](#risks--backward-compatibility).
- **Residual, separate work** — the A2 log-permission half (file/dir modes,
  rotation, packaging). The pre-APIVER-11 `storage.cfg` write-back is
  [deliberately not addressed](#at-rest-stores).

---

## Risks & Backward Compatibility
[Risks_Backward_Compatibility](#risks--backward-compatibility)

These cover Part 1; Part 2's risks are its [six edges](#part-2--the-iscsiadm-vector)
plus the [two constraints](#part-2--the-iscsiadm-vector) verification added.
Risks 2, 3 and 5 applied to the unimplemented Variant A and are kept for the
record; 7 is the implemented Variant B.

1. **Upgrade skew (safe).** Plugin and `jdssc` ship in one `.deb` but swap
   non-transactionally: after unpack, new `jdssc` is on disk while the old plugin
   runs until `postinst` restarts `pvedaemon`. In that window old-plugin →
   new-`jdssc` still passes the flags, which new `jdssc` accepts. The reverse never
   occurs (the plugin only becomes new after the restart, by which point `jdssc`
   already is). Keeping the flags accepted is what makes this safe.
2. **`run_command` passes `%ENV` (verify).** Assumes `PVE::Tools::run_command`
   does not scrub the environment (it inherits by default). Confirm for the
   installed `libpve-common-perl`; a scrub would fail loud ("password not
   provided").
3. **Env inheritance.** `jdssc`'s children would inherit the vars. `jdssc` is a
   pure `python-requests` client with no secret-bearing subprocess — an invariant
   to preserve.
4. **Resolve-into-locals is load-bearing.** Writing the resolved secret back into
   `args` (the `Namespace` or `self.args`) silently regresses the
   [log corollary](#the-log-leak-corollary-a2-content-for-free); the unit test
   pins it.
5. **Over-set `JDSSC_CHAP_PASSWORD`.** Set for every call on a CHAP storage, read
   only by CHAP subcommands; root-only, no effect — a simplicity trade.
6. **Failure semantics unchanged.** A missing REST password dies with the same
   message; `--chap-user` with no resolvable password errors.
7. **(Variant B) the `.pw` file is required.** An entry created before v0.10.10
   that still holds its password inline in `storage.cfg` has no `.pw` file, and
   every operation on it now dies with an instruction to re-set the credentials
   (which creates the file). This is the deliberate alternative to migrating it
   silently — see [Variant B](#variant-b--credentials-file). It also couples
   `jdssc` to the pmxcfs path. Pinned by
   `legacy-inline-credentials-operational.yaml`, which asserts the refusal, that
   its message names the remedy, and that re-setting the password repairs the
   entry.
8. **Taint mode is a live constraint, not a detail.** Any value the plugin puts
   on a child `argv`, and any filename it hands to a file-modifying operation,
   must be untainted — `pct` runs under `perl -T`. Values coming from a regex
   capture (as `_password_file_get_key` returns) are already clean; values read
   straight from a file are not. This is what broke every container operation on
   CHAP storage until it was fixed.

---

## Files That Changed
[Files_That_Changed](#files-that-changed)

| File | Change | part |
|---|---|---|
| [`OpenEJovianDSS/Common.pm`](../../OpenEJovianDSS/Common.pm#L1238-L1256) | `joviandss_cmd`: `--user-password` push replaced by `--sensitive-file <.pw path>`, required | 1 |
| [`OpenEJovianDSS/Common.pm`](../../OpenEJovianDSS/Common.pm#L2171) | `volume_publish` + recovery `target update` ([`:2219`](../../OpenEJovianDSS/Common.pm#L2219)): `--chap-password` dropped, `--chap-user` kept | 1 |
| [`OpenEJovianDSS/Common.pm`](../../OpenEJovianDSS/Common.pm#L2236-L2330) | `_iscsiadm_set_chap` rewritten around the marker swap; new `_iscsiadm_node_set`, `_uuid_generate`, `_iscsi_data_roots`, `_iscsi_data_password_substitute` | 2 |
| [`jdssc/bin/jdssc`](../../jdssc/bin/jdssc#L104-L116) | `--user-password` optional; `--sensitive-file` added; resolution into `cfg` with a clean `exit(1)` | 1 |
| [`jdssc/jdssc/cli_common/cli_common.py`](../../jdssc/jdssc/cli_common/cli_common.py) | **new** — shared `load_sensitive_file` + CHAP format checks | 1 |
| [`targets.py`](../../jdssc/jdssc/targets.py#L29), [`target.py`](../../jdssc/jdssc/target.py#L30) | `--chap-password` optional; `_resolve_chap_password` into a local; checks delegated to `cli_common` | 1 |
| [`jdssc/tests/test_sensitive_file.py`](../../jdssc/tests/test_sensitive_file.py) | **new** — loader, CHAP checks, resolution precedence, never-back-into-`args` | 1 |
| [`tests/api_compat_test.pl`](../../tests/api_compat_test.pl), [`tests/nfs_api_compat_test.pl`](../../tests/nfs_api_compat_test.pl) | assert the hooks leave `$opts_update` unmodified | — |
| `security/*.yaml` (4 testcases, `pve-testing`) | the `ps`/log/task-log assertions this change turns green | 1+2 |
| this document | — | — |

---

## Testing
[Testing](#testing)

Unit suites are green: **Perl 289/289** across 9 files, **pytest 139/139**.
Live verification ran 90 tests on the pve-91 cluster against the deployed build
(plan and full ledger: `pve-testing/testplans/0008-sensitive-data-live-verification.md`
and its `results/` file).

**What the live run proved:**

| Claim | Evidence |
|---|---|
| REST + CHAP off `jdssc` `argv` | ~900k sampled `argv` lines across 6 windows on 2 nodes — zero secret occurrences; every call carries `--sensitive-file` |
| CHAP off `iscsiadm` `argv` | cold-login sampling; the node-DB record holds the real password verbatim at `0600 root:root` while only a UUID marker can reach `argv` |
| REST out of the NFS snapshot log | the args dump reads `'user_password': None` in the window a `pct snapshot` writes |
| CHAP out of the PVE task log | zero hits under `/var/log/pve/tasks` |
| Flags still accepted | 29 `jdssc` CLI testcases that pass `--user-password`/`--chap-password` explicitly all still operate |
| Channels | flag / `--sensitive-file` / `-c` config each authenticate; none → one-line error, `exit(1)` |

**What it caught** — the two bugs in
[Part 2's constraints](#part-2--the-iscsiadm-vector): the hardcoded node-DB path
(every CHAP cold login failed) and the taint failure (every *container*
operation on CHAP storage failed while VM operations passed). Neither was
reachable by unit tests; both needed a real node.

**Still red by design:** the log file/dir permission assertions in
`security/no-secrets-in-log-nfs.yaml` and
`security/log-permissions-and-secret-redaction.yaml` — the A2 permission half is
[separate work](#relationship-to-other-work).

**Rewritten for this change:** `legacy-inline-credentials-operational.yaml` now
pins the refusal and the migration path rather than the old inline fallback
([Risk 7](#risks--backward-compatibility)); it has not yet been run live against
the new build.

---

## Relationship to Other Work
[Relationship_to_Other_Work](#relationship-to-other-work)

- [0005 password-resolution-through-ctx](0005-password-resolution-through-ctx.md)
  — provides `get_user_password` / `get_chap_user_password` and the
  `joviandss_cmd` chokepoint this design delivers the secrets at. Reads the same
  resolved credentials; does not touch storage.
- [0002 chap-auth-design](0002-chap-auth-design.md) — defined `--chap-user` /
  `--chap-password`; this retires `--chap-password` as a transport, keeps
  `--chap-user` as the enable signal.
- **A2 log-permission half (separate change, same finding)** — the log is created
  world-readable: dir `0755` ([`Common.pm:1064-1065`](../../OpenEJovianDSS/Common.pm#L1064-L1065)), file `0644` ([`Common.pm:1077`](../../OpenEJovianDSS/Common.pm#L1077)),
  the Python `RotatingFileHandler` at default umask ([`bin/jdssc:204-206`](../../jdssc/bin/jdssc#L204-L206)), and
  `debian/postinst` making the dir with no explicit mode; existing nodes already
  carry loose logs. Tightening to `0640`/`0750` must cover both writers, rotation,
  and packaging, at creation **and on existing files**; it is orthogonal to this
  transport change. This doc closes the log leak's *content*; that one its
  *access*.
- **A3 (done)** — deb ownership fixed via `dpkg-deb --root-owner-group`.

---

## Open Questions
[Open_Questions](#open-questions)

1. ~~**Env vs file — final call.**~~ **Resolved: B (credentials file)** — single
   source of truth won over A's tighter lifetime; implemented. The `JDSSC_*`
   env-var names are moot; [A](#variant-a--environment-variables) stays drafted
   should the trade-off change.
2. ~~**iscsiadm — which mechanism.**~~ **Resolved: marker-swap (c)**, which
   subsumes (a) and the `noerr` fix on this path; shipped with Part 1.
3. ~~**Bundle the A2 permission fix or ship separately?**~~ **Resolved:
   separately** — this change shipped without it, so the permission assertions
   are still red. The remaining work is scoped in
   [Relationship to Other Work](#relationship-to-other-work): both writers
   (Perl `sysopen` and the Python `RotatingFileHandler`), rotation, and the
   packaging `mkdir`, at creation **and** on existing files.
4. **Legacy inline-only entries.** Risk 7 makes them fail with an instruction
   rather than migrate silently, and the e2e testcase now pins that. If
   operators hit this in the field, revisit whether a one-time migration behind
   an explicit opt-in is worth it.
