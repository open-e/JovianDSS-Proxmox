# JWT REST Authentication and JovianDSS Version Selection — Design Document (PROPOSED)

> **Status: proposed (2026-09-24); token handling decided (2026-09-25).**
> Adds the storage property **`joviandss_version`** (`1` or `2`, default `1`).
> Version 1 keeps HTTP Basic authentication as is. Version 2 authenticates with
> a **JWT access token** from `POST /api/v4/auth/login`, cached between `jdssc`
> runs in **`<storeid>.token`** next to the storage's `.pw` file. **`jdssc`
> creates and updates the token file; the Perl plugin deletes it when the
> storage record is removed.**
>
> [0005](0005-password-resolution-through-ctx.md) and
> [0008](0008-sensitive-data-transfer-control.md) are not edited; their
> extensions are recorded in
> [Relationship to Other Work](#relationship-to-other-work). The version 2 API
> is undocumented; all version 2 facts were observed on a live version 2
> appliance (`172.28.4.98`) and a live version 1 appliance (`192.168.28.102`)
> from the pve-91 cluster.

## Table of Contents

- [Overview](#overview)
- [Problem](#problem)
- [Background](#background)
  - [Version_1_appliance](#version-1-appliance)
  - [Version_2_appliance](#version-2-appliance)
  - [The_password_file](#the-password-file)
- [Key_Observation](#key-observation)
- [Design](#design)
  - [Responsibilities](#responsibilities)
  - [joviandss_version](#joviandss_version)
  - [Control_port_default](#control-port-default)
  - [jdssc_flags](#jdssc-flags)
  - [REST_proxy](#rest-proxy)
  - [Mismatch_diagnostics](#mismatch-diagnostics)
  - [Token_file](#token-file)
  - [user_name](#user_name)
- [Alternatives_Considered](#alternatives-considered)
- [Consequences](#consequences)
- [Risks_Backward_Compatibility](#risks--backward-compatibility)
- [Files_That_Would_Change](#files-that-would-change)
- [Testing](#testing)
- [Relationship_to_Other_Work](#relationship-to-other-work)
- [Open_Questions](#open-questions)

## Overview
[Overview](#overview)

A new JovianDSS generation no longer accepts HTTP Basic authentication. A
client exchanges the admin password for a short-lived JWT access token and
sends it as `Authorization: Bearer <token>`. The plugin sends Basic on every
request, so every `jdssc` call against the new appliance fails, and the plugin
does not recognise the failure as an authentication error.

Both generations will be in the field side by side. The plugin must support
both, and the operator must say which one a storage talks to:

| Plugin name   | Authentication                     | Default REST port |
|---------------|------------------------------------|-------------------|
| **version 1** | HTTP Basic, on every request       | 82                |
| **version 2** | JWT Bearer token from `auth/login` | 443               |

The Perl plugin starts a new `jdssc` process per operation, so a token is worth
obtaining only if it is kept between processes. Token persistence is therefore
part of this change.

---

## Problem
[Problem](#problem)

- **Basic is hardcoded.** The session always carries Basic credentials
  ([`rest_proxy.py:121-125`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L121-L125)).
- **The version 2 401 is not recognised.** `_send` treats only the version 1
  text body `401 unauthorized` as an authentication failure
  ([`rest_proxy.py:280-285`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L280-L285));
  version 2's JSON 401 is returned as an ordinary REST error.
- **The default port is wrong for version 2.** `control_port` defaults to 82
  ([`Common.pm:280`](../../OpenEJovianDSS/Common.pm#L280),
  [`:510-516`](../../OpenEJovianDSS/Common.pm#L510-L516)); version 2 listens
  only on 443.
- **Nothing identifies the API generation**, so the proxy cannot choose.
- **`jdssc` keeps no state between runs**
  ([`rest_proxy.py:116`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L116)).

---

## Background
[Background](#background)

No version 2 API documentation exists; the last specification
(`jdss-rest-api-spec`, `v4/`) has no token endpoint. Everything below was
observed with `curl`.

### Version 1 appliance
[Version_1_appliance](#version-1-appliance)

- Apache enforces Basic in front of the API. Any request without valid
  credentials, `POST /api/v4/auth/login` included, gets `401`,
  `WWW-Authenticate: Basic`, `text/html` body `401 unauthorized`.
- REST on port 82 (TLS); 443 answers `404`.

### Version 2 appliance
[Version_2_appliance](#version-2-appliance)

- Tornado on port **443** (TLS); port 82 is closed. `/api/v3` is gone (unused
  by the plugin: every call passes `apiv=4`).
- The token check runs **before routing**: without a valid token every path
  except `auth/login` gets `401` + `WWW-Authenticate: Bearer`, whether the
  path exists or not.
- 401 bodies use the normal JSON envelope, class
  `rest.auth.exceptions.AuthenticationError`. Observed messages:
  `Authorization header must use Bearer scheme`, `Bearer token is missing`,
  `Invalid JWT format`, `Only access tokens are allowed`,
  `Only refresh tokens are allowed`, `JWT has been revoked`,
  `Invalid credentials`.

Confirmed endpoints (`auth/me` and `auth/whoami` return `404` with a valid
token; nothing else was found):

| Endpoint                    | Credential               | Body                      | Result                                         |
|-----------------------------|--------------------------|---------------------------|------------------------------------------------|
| `POST /api/v4/auth/login`   | none                     | `{"password": "<admin>"}` | `200`, new access + refresh token              |
| `POST /api/v4/auth/refresh` | `Bearer <refresh token>` | `{}` or empty             | `200`, new pair; old refresh token **revoked** |
| `POST /api/v4/auth/logout`  | `Bearer <refresh token>` | `{}`                      | `200`; revokes the refresh token **only**      |

- **Login accepts only `password`.** Other fields are rejected; `username` is
  accepted but makes login fail. The token is issued for subject `admin`.
- **Login response `data`:** `access_token`, `token_type` (`bearer`),
  `expires_in` (`900`), `expires_at`, `server_time`, `refresh_token`,
  `refresh_expires_in` (`2592000`, 30 days), `refresh_expires_at`, `claims`.
  Tokens are RS256 JWTs with a `kid` header; the access token carries `exp`.
- **Wrong password:** `401`, `WWW-Authenticate: Bearer`, `Invalid credentials`.
- **Refresh tokens are single-use.**
- **Cost:** login ≈ 215 ms; an authenticated `GET /pools` ≈ 15 ms.

### The password file
[The_password_file](#the-password-file)

The token file is modelled on the `.pw` file
([0005](0005-password-resolution-through-ctx.md),
[0008](0008-sensitive-data-transfer-control.md)):

- **Path:** `/etc/pve/priv/storage/<plugin type>/<storeid>.pw`
  ([`Common.pm:170`](../../OpenEJovianDSS/Common.pm#L170),
  [`:624-636`](../../OpenEJovianDSS/Common.pm#L624-L636)) — on pmxcfs:
  replicated to all nodes, root-only, `0600`, read-only without quorum.
- **Format:** `key value` per line (`user_password`, `chap_user_password`).
- **Written only by Perl** (`_password_file_set_key`,
  [`Common.pm:655-680`](../../OpenEJovianDSS/Common.pm#L655-L680)) from the
  storage hooks; **read by `jdssc`** via `--sensitive-file`
  (`load_sensitive_file`,
  [`cli_common.py:74-91`](../../jdssc/jdssc/cli_common/cli_common.py#L74-L91)).
- **No code lists the directory**, so a second file type there affects nothing.

---

## Key Observation
[Key_Observation](#key-observation)

1. **A request sent to the wrong generation identifies the right one** —
   `WWW-Authenticate: Basic` versus `Bearer`. The operator *states* the
   version; the proxy *checks* it for free and names the fix
   ([Mismatch diagnostics](#mismatch-diagnostics)).
2. **The plugin already holds the password, a stronger credential than any
   token.** So only the 15-minute access token is worth caching, it can sit in
   the same protected directory, and since any valid token is as good as
   another, concurrent writers need no lock.

---

## Design
[Design](#design)

### Responsibilities
[Responsibilities](#responsibilities)

| Concern                                                        | Owner                                     |
|----------------------------------------------------------------|-------------------------------------------|
| `joviandss_version` property, getter, per-version port default | Perl (`Common.pm`, plugins)               |
| Passing `--joviandss-version` and (version 2) `--token-file`   | Perl (`joviandss_cmd`)                    |
| Login, Bearer header, re-authentication, mismatch diagnostics  | `jdssc` (`rest_proxy.py`)                 |
| **Creating and updating** `<storeid>.token`                    | **`jdssc`** (`rest_proxy.py`)             |
| **Deleting** `<storeid>.token` on storage removal              | **Perl** (`on_delete_hook`, both plugins) |
| The `.pw` file                                                 | Perl, unchanged; `jdssc` only reads it    |

### `joviandss_version`
[joviandss_version](#joviandss_version)

Registered once, in the iSCSI plugin (the NFS plugin declares no properties,
[`OpenEJovianDSSNFSPlugin.pm:92-97`](../../OpenEJovianDSSNFSPlugin.pm#L92-L97)),
and listed in both plugins' `options` as `{ optional => 1 }`:

```perl
joviandss_version => {
    description => 'JovianDSS REST API generation: 1 = HTTP Basic, 2 = JWT token',
    type        => 'integer',
    enum        => [ 1, 2 ],
    default     => OpenEJovianDSS::Common::get_default_joviandss_version(),
},
```

```perl
DEFAULT_JOVIANDSS_VERSION => 1,
sub get_joviandss_version {
    my ($ctx) = @_;
    return int( $ctx->{scfg}{joviandss_version} || DEFAULT_JOVIANDSS_VERSION );
}
```

- **Default `1`:** existing storages need no migration.
- **Not `fixed`:** after an in-place appliance upgrade the operator runs
  `pvesm set <storeid> --joviandss_version 2`.
- **A number, not a release name:** it names the authentication contract; the
  next contract change becomes `3`.

### Control port default
[Control_port_default](#control-port-default)

`get_control_port` falls back to 82 for version 1 and 443 for version 2; an
explicit `control_port` always wins:

```perl
DEFAULT_CONTROL_PORT_V2 => 443,
my $default = get_joviandss_version($ctx) >= 2
            ? DEFAULT_CONTROL_PORT_V2 : DEFAULT_CONTROL_PORT;
my $port = $ctx->{scfg}{control_port} || $default;
```

The schema's `default => 82`
([`OpenEJovianDSSPlugin.pm:267-272`](../../OpenEJovianDSSPlugin.pm#L267-L272))
is removed; the description names both defaults
([Risk 5](#risks--backward-compatibility)). The proxy's own fallback
([`rest_proxy.py:76`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L76))
becomes version-dependent the same way.

### `jdssc` flags
[jdssc_flags](#jdssc-flags)

| Flag                        | Passed by `joviandss_cmd` | Copied to                  | Meaning                     |
|-----------------------------|---------------------------|----------------------------|-----------------------------|
| `--joviandss-version {1,2}` | always                    | `cfg['joviandss_version']` | API generation; default `1` |
| `--token-file <path>`       | version 2 only            | `cfg['jovian_token_file']` | token cache path            |

Both values are non-secret, so they go on `argv` and may appear in the logged
`args` dict; 0008's `argv` rule covers passwords only. `unify_config_options`
([`jdssc:286`](../../jdssc/bin/jdssc#L286)) copies them into `cfg`; a `-c`
YAML config may also set `joviandss_version`, and the flag wins. The token
itself never enters `args` or `cfg`.

### REST proxy
[REST_proxy](#rest-proxy)

All changes are inside `JovianDSSRESTProxy`; `rest.py` and callers are
unchanged.

**Version 1.** `_get_session` sets Basic as today and the
`401 unauthorized` → `exit(1)` path stays ([Open Question 4](#open-questions)).
The only addition is the [mismatch check](#mismatch-diagnostics) for a `Bearer`
401. No token file is touched.

**Version 2.** `_get_session` sets neither `session.auth` nor an
`Authorization` header. Per run:

1. **Start.** If `--token-file` names an existing file, adopt its token when
   its `exp` is more than 60 s away ([Reading](#reading)).
2. **First request without a token.** Log in on the active host, set the
   Bearer header, write the token file ([Writing](#writing)).
3. **`401` + JSON `AuthenticationError` on a data request.** `_send` raises
   the private `_TokenRejected`; `request` drops the token, logs in again on
   the same host, writes the token file and resends — **once**. A second
   rejection raises `JDSSAuthenticationException`.
4. **Login answered `401`.** Raise `JDSSAuthenticationException` at once, with
   the wrong-password or [mismatch](#mismatch-diagnostics) message.

```python
def _login(self):
    addr = self._get_base_url(4) + '/auth/login'
    resp = self.session.post(addr,
                             data=json.dumps({'password': self.password}),
                             headers={'Authorization': None},
                             timeout=(self.connect_timeout, self.read_timeout))
    if resp.status_code == 401:
        self._raise_auth_error(resp)
    self._use_token(resp.json()['data']['access_token'])
    self._store_token()

def _use_token(self, token):
    self.token = token
    self.session.headers['Authorization'] = 'Bearer ' + token

# request(), inside the per-host try, before prepare_request (rest_proxy.py:178)
if self.jdss_version >= 2 and self.token is None:
    self._login()
pr = self.session.prepare_request(r)
```

- **Login runs inside the per-host `try`.** An unreachable controller, or a
  login answer that is neither `200` nor `401`, fails over and is retried like
  any request. Only a `401` is terminal.
- **Failover keeps the token.** Whether controllers accept each other's tokens
  is unknown ([Open Question 1](#open-questions)); step 3 covers a rejection.
- **The refresh token is discarded.** Re-login replaces refresh.
- **Authentication failures are terminal.** `request` retries every exception
  across all hosts, up to 17 rounds
  ([`rest_proxy.py:197-201`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L197-L201)).
  An `except jexc.JDSSAuthenticationException: raise` clause goes before the
  generic one, so a wrong password costs one attempt, not dozens.

### Mismatch diagnostics
[Mismatch_diagnostics](#mismatch-diagnostics)

Detection keys on the `WWW-Authenticate` scheme, not on message text. Every
row but the last raises `JDSSAuthenticationException`:

| Configured | Appliance | Response                                     | Raised message                                                                |
|------------|-----------|----------------------------------------------|-------------------------------------------------------------------------------|
| 2          | 2         | login `401`, `Bearer`, `Invalid credentials` | `REST authentication failed: invalid user_password`                           |
| 2          | 1         | login `401`, `Basic`                         | `appliance at <host> uses HTTP Basic authentication; set joviandss_version 1` |
| 1          | 2         | `401`, `Bearer`                              | `appliance at <host> requires token authentication; set joviandss_version 2`  |
| 1          | 1         | `401`, `Basic`, `401 unauthorized`           | unchanged (`exit(1)`)                                                         |

### Token file
[Token_file](#token-file)

```
/etc/pve/priv/storage/<plugin type>/<storeid>.token
user_access_token <jwt>
```

- **Mirrors the `.pw` file:** same directory (path from a new
  `get_token_file_path($storage_type, $storeid)` beside
  `get_password_file_path`,
  [`Common.pm:631-636`](../../OpenEJovianDSS/Common.pm#L631-L636)), same
  `key value` format, parsed by `load_sensitive_file`. Replicated to all
  nodes, so the cluster shares one token.
- **Only the access token** is stored, never the refresh token
  ([Alternatives Considered](#alternatives-considered)).
- **Absent is normal:** version 1 storages never have it; a version 2 storage
  gets it on its first login. Missing, empty or unreadable means "log in".

#### Reading
[Reading](#reading)

```python
TOKEN_REUSE_MARGIN = 60   # seconds a cached token must still be valid

def _token_exp(token):
    """exp claim, read without verification; 0 if unreadable."""
    try:
        payload = token.split('.')[1]
        payload += '=' * (-len(payload) % 4)
        return int(json.loads(base64.urlsafe_b64decode(payload))['exp'])
    except (IndexError, KeyError, TypeError, ValueError):
        return 0

self.token_file = config.get('jovian_token_file')
if self.token_file and os.path.exists(self.token_file):
    cached = ccom.load_sensitive_file(self.token_file).get('user_access_token')
    if cached and _token_exp(cached) - time.time() > TOKEN_REUSE_MARGIN:
        self._use_token(cached)
```

- The existence check avoids the error `load_sensitive_file` logs for a file
  it cannot open
  ([`cli_common.py:89-90`](../../jdssc/jdssc/cli_common/cli_common.py#L89-L90)).
- `exp` is only a hint; the appliance verifies every request. A bad `exp` or
  clock skew costs one rejected request or one extra login.
- Without `--token-file` (e.g. `jdssc` run by hand) nothing is read or
  written; the token lives in memory only.

#### Writing
[Writing](#writing)

After every successful login `jdssc` replaces the file by temporary file +
rename, as `PVE::Tools::file_set_contents` does:

```python
def _store_token(self):
    if not self.token_file:
        return
    tmp = '%s.tmp.%d' % (self.token_file, os.getpid())
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, 'w') as tf:
            tf.write('user_access_token %s\n' % self.token)
        os.rename(tmp, self.token_file)
    except OSError as err:
        LOG.warning("REST access token not cached: %s", err.strerror)
        with contextlib.suppress(OSError):
            os.unlink(tmp)
```

- **Atomic:** readers see the old or the new file, never a partial one.
- **No lock:** concurrent writers on any node each write a valid token; the
  last rename wins at the cost of one redundant login.
- **Never fatal:** a failed write (e.g. pmxcfs read-only without quorum) only
  warns, without the token; the run keeps its in-memory token.
- **Frequency:** once per login — in steady state about once per token
  lifetime per storage, cluster-wide.

#### Removal
[Removal](#removal)

Both `on_delete_hook`s
([`OpenEJovianDSSPlugin.pm:2357`](../../OpenEJovianDSSPlugin.pm#L2357),
[`OpenEJovianDSSNFSPlugin.pm:1056`](../../OpenEJovianDSSNFSPlugin.pm#L1056))
call a new `token_file_delete($storage_type, $storeid)` beside
`password_file_delete`. This is the only place Perl modifies the token file;
changing `user_password`, `joviandss_version` or any other property leaves it
in place ([Risk 2](#risks--backward-compatibility)).

### `user_name`
[user_name](#user_name)

Version 2 login takes only the password and always authenticates as `admin`.
`user_name` stays required ([`Common.pm:1371`](../../OpenEJovianDSS/Common.pm#L1371),
[`jdssc:98-102`](../../jdssc/bin/jdssc#L98-L102)) because version 1 uses it;
under version 2 it is ignored and documented as unused
([Open Question 2](#open-questions)).

---

## Alternatives Considered
[Alternatives_Considered](#alternatives-considered)

- **Auto-detect the version.** Rejected as the mechanism (kept as the check):
  one guaranteed-failing request per run on version 1, and port probing that
  is slow when a controller is down.
- **Store the token as a key in the `.pw` file.** Rejected: `jdssc` would have
  to rewrite the password file, and a rewrite racing an operator's password
  change can restore the old password. Preventing that needs PVE's
  `storage.cfg` lock, which only Perl can take. A separate file has no such
  race.
- **Cache the refresh token.** Rejected: single-use, so concurrent runs would
  revoke each other's tokens unless every refresh were locked; a 30-day
  credential; and it saves nothing, because the plugin has the password.
- **Refresh inside a run, or logout after login.** Rejected: re-login costs
  the same as refresh without tracking a single-use token; logout does not
  revoke the access token ([Open Question 6](#open-questions)).

---

## Consequences
[Consequences](#consequences)

- `joviandss_version 2` plus the existing `user_password` is enough for a
  version 2 appliance; no `control_port` line is needed.
- Existing storages (version 1 appliances) behave exactly as before.
- A wrong version setting fails on the first call with a message naming the
  value to set. A wrong password fails after one attempt at the first login
  that uses it; while a cached token is valid no login happens
  ([Risk 2](#risks--backward-compatibility)).
- A version 2 storage logs in about once per token lifetime across the whole
  cluster. Extra logins: after a failover to a controller that rejects the
  token, and, without quorum, on every run once the cached token has expired.
- Each version 2 storage gains `<storeid>.token`; `.pw` is unchanged.

---

## Risks & Backward Compatibility
[Risks_Backward_Compatibility](#risks--backward-compatibility)

**Preserved:** version 1 behaviour, apart from the new mismatch message;
password delivery through `--sensitive-file`; the `.pw` file's content, format
and writers; all proxy callers.

1. **The undocumented version 2 API changes.** *Guard:* the contract lives in
   `_login`, `_token_exp` and `_raise_auth_error`, pinned by unit tests; ask
   the developers for the specification.
2. **A password change does not invalidate the cached token.** The old token
   is used until it expires (≤ 15 min), so a *wrong* new password is reported
   up to 15 min late. The password itself is never at risk
   ([Open Question 8](#open-questions)).
3. **Token leakage.** The token is a live credential for 15 minutes. It exists
   in exactly three places, each protected like the password: the proxy's
   memory, the token file and its temporary file (`/etc/pve/priv/…`, which
   pmxcfs keeps root-only whatever mode is passed), and the TLS connection.
   Every path that could expose it was checked:

   | Path                                  | Finding                                                                                                                                                  | Measure                                                                                                           |
   |---------------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
   | `argv`, Perl `cmd_log_output`         | Perl logs the full `jdssc` command line ([`Common.pm:1489`](../../OpenEJovianDSS/Common.pm#L1489))                                                       | only the token file *path* is passed                                                                              |
   | `args` dict                           | dumped at debug level ([`nas_snapshots.py:93`](../../jdssc/jdssc/nas_snapshots.py#L93), [`targets.py:61`](../../jdssc/jdssc/targets.py#L61))             | the token never enters `args` or `cfg`; the proxy reads it from the file                                          |
   | REST results                          | `rest.py` logs the dict `_send` returns ([`:117`](../../jdssc/jdssc/jovian_common/rest.py#L117), [`:238`](../../jdssc/jdssc/jovian_common/rest.py#L238)) | `_login` calls `session.post` directly, never `request`/`_send`, and keeps only `access_token`                    |
   | request debug lines                   | commented out ([`rest_proxy.py:166-169`](../../jdssc/jdssc/jovian_common/rest_proxy.py#L166-L169)); would print the login body                           | stay off; if revived, must omit headers and bodies                                                                |
   | exception text, top-level traceback   | `jdssc` logs the exception with `exc_info` ([`jdssc:446`](../../jdssc/bin/jdssc#L446))                                                                   | `_raise_auth_error` builds messages from status + `WWW-Authenticate` only; the store warning logs `strerror` only |
   | stdout / stderr → Perl `$msg`, `$err` | Perl captures both and puts `$err` in `die` messages                                                                                                     | nothing prints the token; the store warning is `WARNING`, below the stderr handler's `ERROR` level                |
   | HTTP library logging                  | urllib3 logs URLs only; header/body dumping (`http.client` debuglevel) is never enabled                                                                  | none needed                                                                                                       |

   A unit test captures the full log of a version 2 run and asserts it holds
   neither token nor password, pinning every row. Not covered, as for the
   password today: process memory and core dumps, and an interposer when
   `ssl_cert_verify 0` disables certificate checks.
4. **Controller-bound tokens** ([Open Question 1](#open-questions)): nodes on
   different controllers overwrite each other's token — one login per run,
   never an error.
5. **`control_port` loses its schema default.** A per-version default cannot
   be declared, so the "schema default equals constant" rule
   `tests/jdssc_rest_config_test.pl` applies to the REST settings cannot cover
   it; a per-version getter test pins it instead.
6. **A version 2 storage created without `joviandss_version 2`** fails with a
   connection error on port 82, before any diagnostic. *Guard:* the docs lead
   with the setting; `JDSSCommunicationFailure`'s message hints at
   `joviandss_version` and `control_port`.
7. **Account lockout** ([Open Question 3](#open-questions)): one attempt per
   run here; if lockout exists, `joviandss_cmd` must also stop retrying runs
   on an authentication failure.

---

## Files That Would Change
[Files_That_Would_Change](#files-that-would-change)

| File                                                                 | Change                                                                                                            |
|----------------------------------------------------------------------|-------------------------------------------------------------------------------------------------------------------|
| [`OpenEJovianDSSPlugin.pm`](../../OpenEJovianDSSPlugin.pm)           | `joviandss_version` property + option; `control_port` drops `default`; `on_delete_hook` calls `token_file_delete` |
| [`OpenEJovianDSSNFSPlugin.pm`](../../OpenEJovianDSSNFSPlugin.pm)     | `joviandss_version` option; `on_delete_hook` calls `token_file_delete`                                            |
| [`Common.pm`](../../OpenEJovianDSS/Common.pm)                        | version constant + getters; per-version port default; token path + delete helpers; both flags in `joviandss_cmd`  |
| [`bin/jdssc`](../../jdssc/bin/jdssc)                                 | `--joviandss-version`, `--token-file`; copied into `cfg`                                                          |
| [`rest_proxy.py`](../../jdssc/jdssc/jovian_common/rest_proxy.py)     | version switch; token read/write; login, re-login and mismatch helpers; terminal auth errors                      |
| [`exception.py`](../../jdssc/jdssc/jovian_common/exception.py)       | `JDSSAuthenticationException`; hint in `JDSSCommunicationFailure`                                                 |
| `jdssc/tests/test_rest_auth.py`                                      | new ([Testing](#testing))                                                                                         |
| [`jdssc_rest_config_test.pl`](../../tests/jdssc_rest_config_test.pl) | version getter/forwarding; `--token-file` for version 2 only; per-version port default                            |
| [`api_compat_test.pl`](../../tests/api_compat_test.pl)               | storage removal deletes the token file; password/CHAP changes leave it                                            |
| [`nfs_api_compat_test.pl`](../../tests/nfs_api_compat_test.pl)       | same, NFS plugin                                                                                                  |
| [`Plugin-configuration.md`](../Plugin-configuration.md)              | `joviandss_version`; per-version `control_port` default; `user_name` unused by version 2                          |
| [`Plugin-configuration-NFS.md`](../Plugin-configuration-NFS.md)      | same                                                                                                              |
| Quick-Start documents                                                | `joviandss_version 2` for version 2 appliances                                                                    |
| `docs/design/0010-jwt-rest-authentication-design.md`                 | this document                                                                                                     |

---

## Testing
[Testing](#testing)

**`jdssc/tests/test_rest_auth.py`** (stubbed session, token file in a temp dir):

| Case                                        | Expected                                                                             |
|---------------------------------------------|--------------------------------------------------------------------------------------|
| version 1                                   | Basic set; no login; token file untouched                                            |
| version 2, no token file                    | one `auth/login` with `{"password": …}`; Bearer on next request; file written `0600` |
| version 2, cached token valid > 60 s        | no login; cached token sent; file not rewritten                                      |
| version 2, cached token expiring/unreadable | one login up front; file rewritten                                                   |
| version 2, JSON 401 on a data request       | one re-login, one resend, file rewritten; second 401 → `JDSSAuthenticationException` |
| version 2, `_next_host`                     | same token presented to the new host                                                 |
| version 2, login `401 Invalid credentials`  | `JDSSAuthenticationException` after one attempt                                      |
| version 2, read-only token directory        | warning without the token; run succeeds                                              |
| version 2, no `--token-file`                | login; nothing read or written                                                       |
| both mismatch rows                          | message names the right `joviandss_version`                                          |
| any version 2 run                           | log holds neither password nor token                                                 |

**Perl:** version getter default/override/forwarding; `--token-file` only for
version 2, at `<password dir>/<storeid>.token`; `get_control_port` 82/443 by
version and explicit override; `on_delete_hook` removes `.token`; password and
CHAP changes leave it.

**Live (pve-testing):** the existing iSCSI and NFS campaigns on a version 2
storage (`172.28.4.98`) and, for regression, a version 1 storage (Pool-2).
Plus: `.token` appears on every node after the first operation and its `jti`
stays constant until the token nears expiry; `pvesm remove` leaves neither
`.pw` nor `.token`; both mismatch configurations produce their diagnostic.

---

## Relationship to Other Work
[Relationship_to_Other_Work](#relationship-to-other-work)

Earlier documents are not edited; extensions are recorded here.

- [0005](0005-password-resolution-through-ctx.md): a sibling of the `.pw`
  file, `<storeid>.token`, same directory and format, own path helper, deleted
  with the storage.
- [0008](0008-sensitive-data-transfer-control.md): one new sensitive item, the
  **REST access token** — in `jdssc` memory and at rest in the token file
  (pmxcfs, `0600`), never on `argv` or in logs. `jdssc` still never writes the
  `.pw` file.
- [0006](0006-multi-layer-lock-design.md): no new lock or lock use.
- [0009](0009-nvmeof-plugin-design.md): an NVMe-oF plugin inherits this
  through the shared proxy and would likely default to `joviandss_version 2`.
- `jdss-rest-api-spec`: check [Background](#background) against a version 2
  specification once the developers provide one.

---

## Open Questions
[Open_Questions](#open-questions)

1. **Do HA controllers accept each other's tokens?** Either answer works
   ([Risk 4](#risks--backward-compatibility)).
2. **How do LDAP / AD users log in under version 2?**
3. **Does version 2 lock the account after failed logins?**
   ([Risk 7](#risks--backward-compatibility))
4. **Should version 1's `exit(1)` on 401 become `JDSSAuthenticationException`?**
   It would change version 1's existing wrong-password handling.
5. **Which JovianDSS release first requires `joviandss_version 2`?**
6. **Does an unused refresh token cost the appliance anything?** One is left
   per login.
7. **When should the default become `2`?** Only with release notes; it breaks
   version 1 storages relying on the default.
8. **Should a password change invalidate the cached token?**
   ([Risk 2](#risks--backward-compatibility)) A `jdssc`-only option: ignore a
   token file older than the `.pw` file (modification times).
