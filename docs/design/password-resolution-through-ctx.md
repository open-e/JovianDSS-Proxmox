# Password Resolution Through `$ctx` — Design Document (IMPLEMENTED)

> **Status: implemented** (credential-resolution core). Landed in `Common.pm`,
> `NFSCommon.pm`, and both plugins: type-aware resolution (`PLUGIN_TYPE_*`,
> `get_plugin_type`, `get_plugin_password_dir`, type-aware `get_password_file_path`
> + the `make_path` fix); the credential **delete policy** (`user_password` is
> change-only, see [Credential delete policy](#credential-delete-policy--user_password-is-change-only));
> `Common::joviandss_cmd` dropping its now-dead `$password`; and retirement of the
> NFS credential duplication + `joviandss_cmd` wrapper — NFS now calls
> `Common::joviandss_cmd($ctx, …)` / `Common::password_file_*` directly. Validated by
> the unit suite under `pve-testing/testcases/unit/`.
>
> **Deferred to the jdssc-lock work:** the *Full `$ctx` threading inventory* below
> (re-signaturing the `NFSCommon` snapshot/mount helpers to receive the caller's
> `$ctx`). NFS jdssc calls currently run on a locally-built `$ctx` — correct for
> password resolution, but not yet sharing the method lock's `$ctx`.
>
> This is a **prerequisite** for the NFS side of the
> [jdssc execution lock](multi-layer-lock-design.md) (its Open Question #2):
> the jdssc lock's refresh and re-entry guard live on `$ctx->{_held_locks}`, so
> the jdssc call and the method lock must share one `$ctx`.

## Table of Contents

- [Overview](#overview)
- [Problem](#problem)
- [Key Observation](#key-observation)
- [Design](#design)
  - [Plugin-type constants](#plugin-type-constants--one-source-of-truth)
  - [`get_plugin_type`](#get_plugin_type--validated-type-accessor)
  - [`get_plugin_password_dir` / `get_password_file_path`](#get_plugin_password_dir--get_password_file_path--derive-the-directory-from-the-type)
  - [Retire the NFS duplication and the wrapper](#retire-the-nfs-duplication-and-the-wrapper)
  - [Credential delete policy](#credential-delete-policy--user_password-is-change-only)
- [Function Signature Change](#function-signature-change)
- [New Functions](#new-functions)
- [Obsolete Functions](#obsolete-functions)
- [Consequences](#consequences)
- [Relationship to Other Designs](#relationship-to-other-designs)
- [Risks & Backward Compatibility](#risks--backward-compatibility)
- [Files That Would Change](#files-that-would-change-when-implemented)
  - [NFS jdssc call-site migration](#must-be-addressed-nfs-jdssc-call-site-migration)
  - [Full `$ctx` threading inventory](#full-ctx-threading-inventory-jdssc-lock-prerequisite)
- [Open Questions](#open-questions)

## Overview

The iSCSI plugin (`type 'joviandss'`) and the NFS plugin (`type 'joviandss-nfs'`)
store the JovianDSS REST password in a per-storeid file, but in **different
directories**, so the NFS plugin carries its own copies of the credential
**read and write** helpers and an extra `joviandss_cmd` wrapper whose only job is
to inject the NFS password into the shared runner.

This document replaces that duplication with a single, **plugin-type-aware**
password resolution in `OpenEJovianDSS/Common.pm`, and lets NFS use the common
`joviandss_cmd` directly.

---

## Problem

- ~~**Duplicated credential code.**~~ **(Resolved.)** `OpenEJovianDSS/NFSCommon.pm`
  used to define its own `get_user_password`, `get_password_file_path`,
  `password_file_set_password`, and `password_file_delete` — the same logic as
  Common's, differing *only* in the directory. **All four are now retired**; Common's
  type-aware `get_password_file_path` / `get_user_password` serve both plugins.
- ~~**A wrapper that exists solely for the password.**~~ **(Resolved.)**
  `NFSCommon::joviandss_cmd` used to build a **fresh `$ctx`** via `new_ctx`, read the
  NFS password, and delegate to `Common::joviandss_cmd($ctx, …, $password)` — the
  explicit password was needed because Common's fallback (`get_user_password`) would
  otherwise read the **iSCSI** file. The wrapper is **retired**; NFS calls
  `Common::joviandss_cmd($ctx)` directly, and the type-aware fallback reads the
  correct file.
- ~~**The fresh `$ctx` breaks context threading.**~~ **(Resolved.)** The wrapper
  discarded the caller's `$ctx`, so an NFS jdssc call ran on a *different* `$ctx` than
  the NFS method lock — the (future) jdssc execution lock's `run_refreshed` /
  re-entry guard, which key on `$ctx->{_held_locks}`, could not have seen the outer
  method lock. With the wrapper gone **and** every `NFSCommon` snapshot/mount helper
  re-signatured to take `$ctx` (no fresh `new_ctx`), one `$ctx` now threads from each
  NFS method through to `Common::joviandss_cmd`.
- ~~**A broken NFS credential path.**~~ **(Resolved.)** The NFS plugin's *direct*
  jdssc call in `get_identity` (`joviandss_cmd($ctx, ["pool", $pool, "get"], …)`) went
  to `Common::joviandss_cmd` with **no password**, so it resolved the credential from
  Common's default — the **iSCSI** directory — which holds no file for an NFS storeid;
  the call got no password and died, leaving NFS `get_identity` non-functional. With
  type-aware resolution it now reads the NFS directory and `get_identity` works (see
  Risk #4).

---

## Key Observation

The password directory is just `/etc/pve/priv/storage/<plugin-type>`:

| plugin | `$scfg->{type}` | password file |
|---|---|---|
| iSCSI | `joviandss` | `/etc/pve/priv/storage/joviandss/<storeid>.pw` (`PLUGIN_GLOBAL_PASSWORD_FILE_DIR`, `Common.pm:154`) |
| NFS | `joviandss-nfs` | `/etc/pve/priv/storage/joviandss-nfs/<storeid>.pw` (`$NFS_PASSWORD_DIR`, `NFSCommon.pm:744`) |

`$scfg->{type}` is set by PVE from the storage's `type:` line, is present in
**every** plugin method (`status`, `alloc_image`, …) as `$ctx->{scfg}{type}`, and
is currently **unused** anywhere in the code. So the directory can be derived
directly from the type, and the two passwords distinguished by it.

---

## Design

### Plugin-type constants — one source of truth

The two type strings are defined **once** in Common, as constants, and reused
everywhere (the plugins' `type()` methods, `get_plugin_type`, anything keying on
type):

```perl
# Common.pm — add to the existing `use constant { … }` block
use constant {
    PLUGIN_TYPE_JOVIANDSS     => 'joviandss',
    PLUGIN_TYPE_JOVIANDSS_NFS => 'joviandss-nfs',
};
```

Each plugin's `type()` returns the matching constant instead of a bare literal,
so the string lives in exactly one place:

```perl
# OpenEJovianDSSPlugin.pm
sub type { return OpenEJovianDSS::Common::PLUGIN_TYPE_JOVIANDSS }

# OpenEJovianDSSNFSPlugin.pm
sub type { return OpenEJovianDSS::Common::PLUGIN_TYPE_JOVIANDSS_NFS }
```

### `get_plugin_type` — validated type accessor

A new Common getter (same convention as `get_shared` / `get_pool`) that returns
the plugin type and **fails loud** on anything unexpected, checking against the
constants:

```perl
sub get_plugin_type {
    my ($ctx) = @_;
    my $type = $ctx->{scfg}{type};

    if (!defined $type) {
        die "JovianDSS: storage 'type' is not set in scfg\n";
    }
    if ($type eq PLUGIN_TYPE_JOVIANDSS) {
        return PLUGIN_TYPE_JOVIANDSS;
    }
    if ($type eq PLUGIN_TYPE_JOVIANDSS_NFS) {
        return PLUGIN_TYPE_JOVIANDSS_NFS;
    }

    die "JovianDSS: unexpected storage type '$type'\n";
}
```

So any caller keying on type gets a guaranteed-valid value or a clear, actionable
death — never a silent fall-through to the wrong location. Each accepted type is
its own explicit branch returning its constant; anything else falls through to the
`die`. The plugins' `type()` and these branches both use the constants, so they
can't drift apart.

### `get_plugin_password_dir` / `get_password_file_path` — derive the directory from the type

The old `PLUGIN_GLOBAL_PASSWORD_FILE_DIR` was a *full, type-specific directory*
(hard-wired to `joviandss`). Its proper successor is **not** another constant but a
**type-aware accessor**, `get_plugin_password_dir($ctx)`, built on a single base
constant. `get_password_file_path` then derives from it, so the directory lives in
exactly one place:

```perl
# Common.pm — single base constant (in the `use constant { … }` block)
use constant { PLUGIN_PASSWORD_DIR_BASE => '/etc/pve/priv/storage' };

sub get_plugin_password_dir {
    my ($ctx) = @_;
    return PLUGIN_PASSWORD_DIR_BASE . '/' . get_plugin_type($ctx);
}

sub get_password_file_path {
    my ($ctx) = @_;
    return get_plugin_password_dir($ctx) . "/$ctx->{storeid}.pw";
}
```

Anything that needs the *directory* (notably `_password_file_set_key`'s `make_path`,
see Risk&nbsp;#1) calls `get_plugin_password_dir($ctx)`, and anything that needs the
*file* calls `get_password_file_path($ctx)` — the two can no longer disagree on the
location, because the file path is built from the directory accessor.

This reproduces the **existing** locations for both plugins exactly (iSCSI →
`/etc/pve/priv/storage/joviandss/…`, NFS → `/etc/pve/priv/storage/joviandss-nfs/…`),
so there is **no migration** — existing password files are already where the
unified function looks. `get_user_password` (`Common.pm:463`, via
`_password_file_get_key`) then works for both plugins unchanged.

### Retire the NFS duplication and the wrapper

- **Remove** the duplicated NFS credential code — `NFSCommon::get_user_password`,
  `get_password_file_path`, `password_file_set_password`, `password_file_delete`,
  and `$NFS_PASSWORD_DIR`. Common's `get_user_password` / `password_file_*` helpers
  cover NFS, since they all resolve the file via the unified `get_password_file_path`.
- **Remove** `NFSCommon::joviandss_cmd` — with credentials unified, NFS calls
  `OpenEJovianDSS::Common::joviandss_cmd($ctx, …)` directly with its already-built
  `$ctx`, exactly as it already does at `OpenEJovianDSSNFSPlugin.pm:229`.
- **Update the NFS call sites**:
  - jdssc: `:388` and `:921` from `NFSCommon::joviandss_cmd($scfg, $storeid, …)`
    to `joviandss_cmd($ctx, …)`. `:229` already has this call shape (no edit needed)
    — it only starts resolving the NFS password once the path is type-aware (Risk #4).
  - password write: `:1019`/`:1037` (`password_file_set_password`) from `NFSCommon::…`
    to `Common::…`.
  - password delete: `:1028` (`on_delete_hook`) → `Common::password_file_delete`;
    `:1040` (`on_update_hook` clearing `user_password`) →
    `Common::password_file_delete_user_password` (which **dies** — `user_password` is
    change-only; see [Credential delete policy](#credential-delete-policy--user_password-is-change-only)).

Because reads (`get_user_password`) and writes (`password_file_set_password` /
`password_file_delete`) now go through the **same** Common `get_password_file_path`,
the two sides can never disagree on the location.

### Credential delete policy — `user_password` is change-only

*(Already implemented in `Common.pm` and both plugins.)* The password file is created
on `on_add_hook` and removed **only** on `on_delete_hook` (storage-record deletion).
While the storage exists, `user_password` is mandatory — it can be **changed but
never cleared**:

- Clearing `user_password` on update routes to
  **`Common::password_file_delete_user_password($ctx)`**, which **dies**
  (`"user_password cannot be cleared; provide a new value or remove the storage"`).
  Both plugins' `on_update_hook` call it (named to mirror
  `password_file_delete_chap_password`).
- The optional `chap_user_password` *can* be cleared, via
  `password_file_delete_chap_password` → `_password_file_delete_key`.
- `_password_file_delete_key` removes a single key and, once no keys remain, drops the
  file through `password_file_delete` — so whole-file `password_file_delete` is the
  **single file-removal point**, reached on storage deletion (and, defensively, when
  the last key is gone, which cannot happen while `user_password` is mandatory).

---

## Function Signature Change

**One surviving function changes its parameter list:**

- `Common::joviandss_cmd` drops the trailing optional **`$password`**. The *only*
  caller that ever passed it was the retired `NFSCommon::joviandss_cmd`
  (`NFSCommon:790`); every other caller relies on the internal
  `get_user_password($ctx)` fallback. With the wrapper gone, the parameter is dead,
  so the signature becomes `($ctx, $cmd, $timeout, $retries, $force_debug_level)`.

> Scope note: the NFS `$ctx`-threading refactor *also* changes many `NFSCommon`
> helper signatures to take `$ctx` in place of `$scfg`/`$storeid`. Those are a
> jdssc-lock prerequisite rather than part of the credential change, so they are
> inventoried
> under [Files That Would Change](#files-that-would-change-when-implemented) →
> *Full `$ctx` threading inventory*, not counted here.

The remaining changes keep their signatures:

- **Behavior change, same signature:**
  - `Common::get_password_file_path($ctx)` — derives the dir via
    `get_plugin_password_dir($ctx)` (was the fixed `PLUGIN_GLOBAL_PASSWORD_FILE_DIR`),
    and through it `get_plugin_type` — so it now propagates `get_plugin_type`'s `die`.
  - `Common::_password_file_set_key($ctx, $key, $value)` — `make_path`s
    `get_plugin_password_dir($ctx)` (the type-aware dir), not the fixed constant.
  - `OpenEJovianDSSPlugin::type()` / `OpenEJovianDSSNFSPlugin::type()` — return the
    matching constant instead of a bare literal.
- **Caller switches to the `$ctx`-based Common variant** (the *called* function's
  signature is unchanged; only the *call shape* at the NFS site changes):
  - jdssc: `NFSCommon::joviandss_cmd($scfg, $storeid, …)` →
    `Common::joviandss_cmd($ctx, …)`.
  - password write/delete: `NFSCommon::password_file_*` →
    `Common::password_file_*($ctx, …)`.

---

## New Functions

- **`Common::get_plugin_type($ctx)`** — returns the validated plugin type; dies on
  an unset or unexpected `$scfg->{type}`.
- **`Common::get_plugin_password_dir($ctx)`** — returns the type-aware password
  **directory** for the storage, `PLUGIN_PASSWORD_DIR_BASE . '/' . get_plugin_type($ctx)`
  (e.g. `/etc/pve/priv/storage/joviandss-nfs`). It is the **single source of truth**
  for the directory: `get_password_file_path` appends `"/<storeid>.pw"` to it, and
  `_password_file_set_key`'s `make_path` creates it — so the file and its parent dir
  are derived from the same function and cannot diverge. It is the functional
  successor to the old `PLUGIN_GLOBAL_PASSWORD_FILE_DIR` constant (which was a fixed,
  iSCSI-only directory), and inherits `get_plugin_type`'s `die` on an unset/unexpected
  type.

  ```perl
  sub get_plugin_password_dir {
      my ($ctx) = @_;
      return PLUGIN_PASSWORD_DIR_BASE . '/' . get_plugin_type($ctx);
  }
  ```

- **`Common::password_file_delete_user_password($ctx)`** — *(already implemented)* the
  enforcement point for the change-only policy: it **dies**
  (`"user_password cannot be cleared…"`). Named to mirror
  `password_file_delete_chap_password`; both plugins' `on_update_hook` call it when
  `user_password` is cleared. See
  [Credential delete policy](#credential-delete-policy--user_password-is-change-only).

New constants in `Common.pm`:

- `PLUGIN_TYPE_JOVIANDSS` = `'joviandss'`, `PLUGIN_TYPE_JOVIANDSS_NFS` = `'joviandss-nfs'`
- `PLUGIN_PASSWORD_DIR_BASE` = `'/etc/pve/priv/storage'`

---

## Obsolete Functions

Removed from `OpenEJovianDSS/NFSCommon.pm` (their job moves to Common):

- **`NFSCommon::joviandss_cmd`** — NFS calls `Common::joviandss_cmd($ctx, …)`
  directly. This was the *only* caller that injected a password into
  `Common::joviandss_cmd`; with it gone, that function's trailing **`$password`
  parameter is obsolete and is removed** (see [Function Signature Change](#function-signature-change)).
- **`NFSCommon::get_user_password`** / **`NFSCommon::get_password_file_path`** — the
  read path is served by Common.
- **`NFSCommon::password_file_set_password`** / **`NFSCommon::password_file_delete`**
  — the write path is served by Common's equivalents.

Obsolete constants / vars:

- `Common::PLUGIN_GLOBAL_PASSWORD_FILE_DIR` — it was a full, type-specific directory,
  so its successor is the **`get_plugin_password_dir($ctx)`** accessor (type-aware),
  itself built on the new `PLUGIN_PASSWORD_DIR_BASE` constant — not a bare constant.
- `NFSCommon::$NFS_PASSWORD_DIR` — folded into the type-derived path.

---

## Consequences

- **One credential code path.** A single `get_user_password` /
  `get_password_file_path` in Common serves both plugins; the NFS copies disappear.
- **Removes the password-driven fresh `$ctx`.** With credentials unified, the NFS
  jdssc calls that went through the wrapper (`:388`, `:921`) run on the method's
  `$ctx` instead of the wrapper's throwaway one — the **prerequisite** for
  single-`$ctx` threading. The `NFSCommon` snapshot/mount helper layer still builds its own `$ctx`
  until the *Full `$ctx` threading inventory* (below) is done; only then do
  `run_refreshed` / the re-entry guard see the outer NFS method lock across the whole
  snapshot path.
- **NFS `get_identity` works.** The `:229` call now resolves the NFS password like
  every other NFS jdssc call, fixing the failure characterized in Risk #4.
- **No behavior change to storage locations** — same files, fewer code paths.

---

## Relationship to Other Designs

- [jdssc execution lock](multi-layer-lock-design.md) — this is the prerequisite
  for that design's **Open Question #2 (NFS parity)**: NFS can only share one
  `$ctx->{_held_locks}` with its method lock once it stops building a fresh `$ctx`
  for jdssc. This unification removes the **wrapper** (the password-driven fresh
  `$ctx`); the remaining fresh-`$ctx` sources — the `NFSCommon` snapshot/mount
  helpers — are inventoried under
  [Files That Would Change](#files-that-would-change-when-implemented) and finished
  with the lock work.

---

## Risks & Backward Compatibility

### Preserved (low risk)

- **iSCSI is unchanged.** Its password file was already
  `/etc/pve/priv/storage/joviandss/<storeid>.pw` — identical to the new
  type-derived path. Same file, same behavior.
- **No migration.** Both plugins' existing password files already sit at
  `/etc/pve/priv/storage/<type>/<storeid>.pw`; the unified resolver looks exactly
  where they already are.
- **Identical file format.** Both plugins already store the credential as
  `user_password <value>\n` and parse it with the same `^(\S+)\s+(.+)$` reader, so
  existing NFS `.pw` files are read by Common's `get_user_password` **without
  reformatting** — the unification is location-and-format compatible, not just
  location compatible.
- **Removing `PLUGIN_GLOBAL_PASSWORD_FILE_DIR` is contained.** It is referenced
  only inside `Common.pm` (its definition + `get_password_file_path` +
  `_password_file_set_key`) — no other module uses it, so removal can't break
  callers elsewhere.

### Risks

1. **(Highest — must not be missed) `_password_file_set_key`'s `make_path`.**
   `_password_file_set_key` (`Common.pm:411`) `make_path`s
   `PLUGIN_GLOBAL_PASSWORD_FILE_DIR` while writing to `get_password_file_path($ctx)`.
   Once the path is type-aware, an **NFS** credential *write* would create
   `…/joviandss` but write to `…/joviandss-nfs/<storeid>.pw` → the NFS directory is
   never created → the write fails. The fix is exactly why the directory gets its own
   accessor: `make_path(get_plugin_password_dir($ctx))`, so the created dir and the
   written file are derived from the same function and **cannot** diverge. This
   **must** land together with the path change; today the NFS write path makes its
   own dir, so this currently works.
2. **A new `die` in the credential path.** The old `get_password_file_path` never
   failed; the new one dies (via `get_plugin_type`) on an unset/unexpected
   `$scfg->{type}`. Verified: the credential path is reached only from plugin
   methods (no `.pl` / CLI callers), where PVE always sets `type` — so it should
   not fire in normal operation. Residual risk: a test harness or future tool that
   builds a partial `$ctx` would now die instead of getting the old default.
   Acceptable as a fail-loud guard, but it is a *new* hard-failure mode.
3. **NFS write semantics: overwrite → merge.** NFS's old
   `password_file_set_password` *overwrote* the file; Common's path
   (`_password_file_set_key`) *reads-merges-writes*. For NFS (only `user_password`,
   no CHAP) the result is identical — but if an NFS `.pw` ever held extra keys, the
   new code preserves them instead of clobbering. A behavior difference, not a
   regression in practice. **Delete changed separately** (already implemented; see
   [Credential delete policy](#credential-delete-policy--user_password-is-change-only)):
   clearing `user_password` now **dies** instead of removing the file, and whole-file
   `password_file_delete` is reached only on storage removal. For NFS this also fixes
   prior behavior where clearing `user_password` silently deleted the credential file.
4. **Line 229 is a *fix*, not a break (confirmed).** The "pool get" at
   `OpenEJovianDSSNFSPlugin.pm:229` is inside `get_identity`, in a 3-attempt loop
   where the call is `eval`-wrapped. With no password, `Common::joviandss_cmd` does
   `get_user_password($ctx)` → reads the **iSCSI** dir for an NFS storeid → the file
   does not exist → `undef` → `die "JovianDSS REST user password is not provided."`.
   That die is caught by the `eval`, retried 3×, then surfaces as
   `die "Unable to get identity info … after 3 attempts"`. So **NFS `get_identity` is
   currently non-functional**, and the type-aware password resolution repairs it —
   the change uncovers no previously-masked path (the path already fails today).
5. **`type()` gains a cross-module dependency.** Returning
   `OpenEJovianDSS::Common::PLUGIN_TYPE_*` makes the plugins' `type()` depend on
   Common being loaded. `use OpenEJovianDSS::Common` guarantees that, but `type()`
   is called early in PVE plugin registration — keep the `use` ordering intact.

---

## Files That Would Change (when implemented)

> **Implemented.** The four rows below (the credential-resolution core + delete
> policy) have landed. Only the *Full `$ctx` threading inventory* subsection further
> down remains, deferred to the jdssc-lock work.

| File | Change |
|---|---|
| `OpenEJovianDSS/Common.pm` | add `PLUGIN_TYPE_JOVIANDSS` / `PLUGIN_TYPE_JOVIANDSS_NFS` constants; add `get_plugin_type($ctx)` (validated against them); replace the `PLUGIN_GLOBAL_PASSWORD_FILE_DIR` constant with the `PLUGIN_PASSWORD_DIR_BASE` constant (`/etc/pve/priv/storage`) **plus** a `get_plugin_password_dir($ctx)` accessor (`<base>/<plugin-type>`), and derive `get_password_file_path` from it (`get_plugin_password_dir($ctx) . "/<storeid>.pw"`); update **every** user of the old constant — notably `_password_file_set_key` (`:411`), which must `make_path(get_plugin_password_dir($ctx))` (the same accessor the file path is built from), otherwise an NFS write lands in a directory that was never created |
| `OpenEJovianDSS/NFSCommon.pm` | **retire** `joviandss_cmd`, `get_user_password`, `get_password_file_path`, `password_file_set_password`, `password_file_delete`, `$NFS_PASSWORD_DIR` (folded into Common). **Retiring `joviandss_cmd` is not transparent** — its three *internal* callers (`snapshot_info:129`, `snapshot_publish:647`, `snapshot_unpublish:697`) must be rewritten to call `Common::joviandss_cmd($ctx, …)`; under the threading inventory they **stop** building their own `new_ctx` (`:124`/`:639`/`:687`) and receive the caller's `$ctx`, dropping the old `$scfg, $storeid` positionals — see the migration callout and threading inventory below |
| `OpenEJovianDSSPlugin.pm` | `type()` returns `OpenEJovianDSS::Common::PLUGIN_TYPE_JOVIANDSS` (the constant) |
| `OpenEJovianDSSNFSPlugin.pm` | `type()` returns `PLUGIN_TYPE_JOVIANDSS_NFS`; call `Common::joviandss_cmd($ctx, …)` directly (replace `NFSCommon::joviandss_cmd` at `:388`/`:921`; `:229` already has this shape, no edit — it starts working once the password path is type-aware, Risk #4); route password write through `Common::password_file_set_password` (`:1019`/`:1037`); password delete through `Common::password_file_delete` on `on_delete_hook` (`:1028`) and `Common::password_file_delete_user_password` (dies — `user_password` is change-only) on the `on_update_hook` clear branch (`:1040`) |
| `docs/design/password-resolution-through-ctx.md` | this document |

> **Already implemented** (the [credential delete policy](#credential-delete-policy--user_password-is-change-only),
> independent of the type-aware work above, and present across more rows than the
> NFS `:1040` cell suggests): in `Common.pm` —
> `password_file_delete_user_password($ctx)` (dies) and the `_password_file_delete_key`
> empty-branch routing through `password_file_delete`; in **both** plugins —
> `on_update_hook` clearing `user_password` → `Common::password_file_delete_user_password`.
> Everything else in this table is the to-implement type-aware resolution.

### Must be addressed: NFS jdssc call-site migration

Deleting `NFSCommon::joviandss_cmd` does **not** silently fall through to Common's
implementation — these call sites must be changed by hand:

- **No automatic switch.** A bare `joviandss_cmd(...)` inside `NFSCommon.pm`
  resolves to the *current package*. NFSCommon imports only `cmd_log_output`
  (`use OpenEJovianDSS::Common qw(cmd_log_output)`, `:35`) — **not** `joviandss_cmd`.
  Remove the local sub and those bare calls become an
  `Undefined subroutine &OpenEJovianDSS::NFSCommon::joviandss_cmd` runtime error.
- **Arguments differ.** Even if `joviandss_cmd` were imported, the internal callers
  pass the *old wrapper* signature `($scfg, $storeid, $cmd, …)`, while
  `Common::joviandss_cmd` expects `($ctx, $cmd, …)`. `$scfg` would bind to `$ctx`
  (`$ctx->{scfg}` → `undef`) and break immediately.

So each of the three internal callers must be edited explicitly:

| function | builds `$ctx` at | call to change |
|---|---|---|
| `snapshot_info` | `:124` | `:129` |
| `snapshot_publish` | `:639` | `:647` |
| `snapshot_unpublish` | `:687` | `:697` |

These three move to `OpenEJovianDSS::Common::joviandss_cmd($ctx, …)` as part of the
threading inventory below — where each **stops** building its own `new_ctx`
(`:124`/`:639`/`:687`) and receives the caller's `$ctx` instead. (Passing the
locally-built `$ctx` would already resolve the password correctly; threading goes
further by making the helper share the *method's* `$ctx`.)

### Full `$ctx` threading inventory (jdssc-lock prerequisite)

The three call sites above are only the *direct* jdssc callers. Across the
`NFSCommon` snapshot/mount helper layer, helpers take `$scfg` (usually with
`$storeid`) and **most rebuild their own `$ctx`** via `new_ctx`, so `$ctx` is
dropped at every plugin→NFSCommon boundary. The NFS plugin's locked methods (`_volume_snapshot_rollback`,
`_volume_snapshot_delete`, `_activate_volume`, `_deactivate_volume`, …) hold their
**method lock** on one `$ctx` but then call these helpers with `$scfg, $storeid`,
which build a *different* `$ctx`. For the [jdssc execution lock](multi-layer-lock-design.md)'s
`run_refreshed` / re-entry guard to see the outer method lock, **one `$ctx` must run
from method entry through the jdssc call** — i.e. these helper signatures change to
`($ctx, …)` and every caller passes the threaded `$ctx`.

This is a wider change than retiring the wrapper and belongs with the jdssc-lock
work, but it is inventoried here so the function list is complete.

**A. `NFSCommon` helpers to re-signature to receive the threaded `$ctx`** (today each
takes `$scfg` — usually plus `$storeid` — and, except `mount`, builds its own `$ctx`):

| helper | def | builds ctx | reaches `jdssc`? | priority |
|---|---|---|---|---|
| `snapshot_info` | :121 | :124 | **yes** (:129 direct) | required for lock |
| `snapshot_publish` | :636 | :639 | **yes** (:647 direct) | required for lock |
| `snapshot_unpublish` | :684 | :687 | **yes** (:697 direct) | required for lock |
| `snapshot_deactivate_unpublish` | :283 | :286 | **yes** → `snapshot_unpublish` (:302) | required for lock |
| `all_snapshots_deactivate_unpublish` | :330 | :333 | **yes** → `snapshot_deactivate_unpublish` (:364) | required for lock |
| `snapshot_activate` | :164 | :169 | no (`umount` :193) | threading hygiene |
| `snapshot_deactivate` | :243 | :246 | no | threading hygiene |
| `umount` | :542 | :545 | no | threading hygiene |
| `mount` | :523 | — (builds none) | no | threading hygiene |
| `path_is_mnt` | :382 | :385 | no | threading hygiene |
| `path_is_nfs` | :455 | :460 | no | threading hygiene |

`mount` builds no `$ctx` today; it gains a `$ctx` parameter like the rest and uses it
(e.g. for `debugmsg`). `path_is_mnt` / `path_is_nfs` currently build a storeid-less
`new_ctx($scfg, '')`; they instead receive the caller's `$ctx`. After this, **no
`NFSCommon` function builds its own `$ctx`** — all run on the threaded one.

**B. NFS-plugin call sites that must pass the threaded `$ctx`** (instead of
`$scfg, $storeid`), once the helpers above change:

- jdssc-direct (this change): `:388` (`volume_snapshot`), `:921` (`_volume_snapshot_delete`)
- `snapshot_info`: `:400`, `:699` — and **`volume_snapshot_info` (:393) builds no `$ctx`
  today**, so it must construct/thread one
- `snapshot_publish`: `:448`, `:786`
- `snapshot_activate`: `:457`, `:789`
- `snapshot_unpublish`: `:463`, `:646`, `:798`
- `snapshot_deactivate`: `:628`
- `snapshot_deactivate_unpublish`: `:857`, `:917`
- `all_snapshots_deactivate_unpublish`: `:872`
- `path_is_nfs`: `:213`, `:270`, `:770`; `path_is_mnt`: `:269`, `:296`; `mount`: `:278`; `umount`: `:297`

The locked `_impl` methods already receive `$ctx`; they currently re-extract
`$scfg = $ctx->{scfg}` / `$storeid = $ctx->{storeid}` to feed the helpers, so the
edit is "pass `$ctx`, drop the re-extraction." Storage-level methods (`status`,
`activate_storage`, `deactivate_storage`, `check_connection`) already build a `$ctx`
and likewise just need to pass it to `path_is_*` / `mount` / `umount`.

**C. Cross-helper calls inside `NFSCommon`** that also switch from `$scfg, $storeid`
to `$ctx`: `umount` (:193), `snapshot_deactivate` (:300), `snapshot_unpublish`
(:302), `snapshot_deactivate_unpublish` (:364).

---

## Open Questions

1. ~~**Write path**~~ — **resolved**: the NFS password write/delete sites call
   `Common::password_file_set_password` / `Common::password_file_delete`, which use
   the unified `get_password_file_path`; the NFS copies are retired. Reads and
   writes now share one path resolver, so they can't disagree.
2. ~~**Adding a type**~~ — **resolved**: case-based. Each accepted type is an
   explicit branch in `get_plugin_type` returning its constant
   (`PLUGIN_TYPE_JOVIANDSS` / `PLUGIN_TYPE_JOVIANDSS_NFS`); an unknown type falls
   through to the `die`. A new plugin type = a new constant + branch.
3. ~~**Directory base**~~ — **resolved**: a single `PLUGIN_PASSWORD_DIR_BASE`
   (`/etc/pve/priv/storage`) plus a `get_plugin_password_dir($ctx)` accessor
   (`<base>/<plugin-type>`); `get_password_file_path` appends `"/<storeid>.pw"` to
   that accessor. The old `PLUGIN_GLOBAL_PASSWORD_FILE_DIR` and `$NFS_PASSWORD_DIR`
   are removed.
