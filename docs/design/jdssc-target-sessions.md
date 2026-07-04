# jdssc Target Session Listing — Design Document (ACCEPTED, IMPLEMENTED)

> **Status: accepted (2026-07-03) — implemented (2026-07-03): all Table 3
> changes landed, unit tests added (`jdssc/tests/test_sessions.py`), and every
> semantics-table row verified end to end against the live `Pool-2` appliance
> (populated / idle / missing target, missing action, plain `get`). All open
> questions were resolved by live verification the same day.** Companion to
> [`volume-activation-with-reactivation.md`](volume-activation-with-reactivation.md)
> (in review — acceptance pending its
> [follow-ups](volume-activation-review-followups.md)): that design's
> recovery-detach gate (`_target_foreign_sessions`,
> its Open Question #1) consumes per-target session evidence from jdssc. A
> jdssc chain for it — CLI `target <iqn> get --sessions` →
> `driver.get_target_sessions` → `rest.get_target_sessions` — already exists
> in the tree; its REST layer's per-target endpoint, initially unverified,
> **was confirmed live against two appliances** (captures in
> [Background](#background-and-research)), so the REST and driver layers stay
> exactly as they are. What this design changes: the CLI moves onto a
> dedicated subcommand — **`pool <pool> target <iqn> sessions list`** (decided
> 2026-07-03) — the Perl invocation is fixed, and the output contract and
> empty/404 semantics are pinned by the verified captures.

## Table of Contents

- [Problem_Statement](#problem-statement)
- [Background_and_Research](#background-and-research)
- [Options_Considered](#options-considered)
- [Recommended_Solution](#recommended-solution)
- [Open_Questions](#open-questions)
- [New_Functions](#new-functions)
- [Changed_Functions](#changed-functions)
- [Relationship_to_Other_Designs](#relationship-to-other-designs)
- [Risks_and_Backward_Compatibility](#risks--backward-compatibility)
- [Files_That_Would_Change](#files-that-would-change-when-implemented)

## List of Tables

1. `tbl_session_fields` — **Session record fields** returned by the verified
   endpoints.
2. `tbl_layer_changes` — **Layer-by-layer changes**: what each jdssc layer does
   today vs. after this design.
3. `tbl_sessions_files_changed` — **Files that would change**.

---

## Problem Statement
[Problem_Statement](#problem-statement)

**What's needed.** The Proxmox plugin must be able to ask JovianDSS: *"which
initiators hold active iSCSI sessions on this specific target?"* The consumer
is the reactivation design's session-evidence gate — before the recovery
detach (`targets delete -v <volname>`) fires, the plugin verifies no **foreign**
initiator (another node — e.g. a live-migration source) is connected; any
foreign session, or a failed query, skips the detach (*no evidence, no
detach*).

**What's wrong today.** The jdssc chain for this query exists end to end —

- CLI: `pool <pool> target <iqn> get --sessions`
  (`jdssc/target.py:52–57, 79–95`),
- driver: `get_target_sessions(target_name)`
  (`jovian_common/driver.py:1650`),
- REST: `get_target_sessions(target_name)` requesting
  `GET /pools/<pool>/san/iscsi/targets/<target_name>/sessions`
  (`jovian_common/rest.py:658`) —

with three defects, one of which dissolved under live verification:

1. **The Perl consumer's invocation is broken outright** —
   `target_get_sessions` omits the `pool <pool>` prefix (`Common.pm:1634`),
   which jdssc's CLI rejects. The chain has never worked end to end.
2. **The CLI exposes the query as a flag on `get`** rather than as a proper
   sub-resource; decided 2026-07-03: the verb becomes `sessions list`.
3. **The REST layer's per-target URL was unverified** — this document was
   first drafted to rebase the chain onto the pool-wide sessions resource.
   **Live verification (2026-07-03, two appliances) then confirmed the
   per-target endpoint exists and behaves exactly as the code assumes**
   ([Background](#background-and-research)) — so the REST and driver layers
   stay as they are, and the design shrank to the CLI verb, the Perl
   invocation, and pinned semantics.

**Desired behavior.** A dedicated subcommand —

```
pool <pool> target <iqn> sessions list
```

— returns the target's sessions over the (now verified) per-target resource.
Sessions become a proper sub-resource of `target` (the jdssc nesting pattern:
`pool → target → sessions`, each level owning its actions) instead of a flag
on `get`; `list` leaves room for future session actions without reshaping the
verb. The in-tree `get --sessions` flag is **removed**, superseded by the
dedicated verb — it never had a working caller (defect 1), so nothing breaks.

**Non-goals.** No new session-manipulation verbs (kill/logout a session) —
`list` is the only subaction; the `sessions` sub-resource leaves room for
more without reshaping the CLI. No plugin-side (Perl) changes beyond the
one-line invocation update in `target_get_sessions` (`Common.pm:1634` — the
new verb, the `pool` prefix, and the `118, 5` bound literals giving way to
the reactivation design's `TARGET_SESSIONS_QUERY_TIMEOUT` /
`TARGET_SESSIONS_QUERY_RETRIES`, whose values live in that design's
Table 4b); its parser and every consumer above it are untouched.

---

## Background and Research
[Background_and_Research](#background-and-research)

**The verified endpoints (live captures, 2026-07-03 — appliance
`192.168.28.102` / `Pool-2` via node2, plus `172.28.140.170` /
`Pool-1-backup` for the empty-pool case; API v4).** Two session resources
exist, both returning `{"data": [...], "error": null}` with identical record
shapes:

*Per-target — the resource this design uses* (server-side filtering; the URL
`rest.get_target_sessions` already requests):

```
GET /api/v4/pools/Pool-2/san/iscsi/targets/iqn.…:vm-420-0/sessions   → 200
{"data": [{"target_name": "iqn.2025-04.proxmox.joviandss.iscsi:vm-420-0",
           "cid": "0", "ip": "172.29.143.18", "sid": "4957301003d0200",
           "initiator_name": "iqn.1993-08.org.debian:01:793c225e3c37"},
          {"target_name": "iqn.2025-04.proxmox.joviandss.iscsi:vm-420-0",
           "cid": "0", "ip": "172.30.143.18", "sid": "4977401003d0200",
           "initiator_name": "iqn.1993-08.org.debian:01:793c225e3c37"},
          {"target_name": "iqn.2025-04.proxmox.joviandss.iscsi:vm-420-0",
           "cid": "0", "ip": "172.29.143.17", "sid": "4962100003d0200",
           "initiator_name": "iqn.1993-08.org.debian:01:f4e662329db1"}],
 "error": null}

# session-less target (vm-405-0):                                    → 200
{"data": [], "error": null}

# nonexistent target:                                                → 404
{"data": null, "error": {"class": "opene.exceptions.ItemNotFoundError",
 "message": "Target iqn.2099-01.bogus:does-not-exist not exists.", …}}
```

*Pool-wide — verified as well, kept as background* (one list for all targets
of the pool; each record carries `target_name`; an empty pool answers
`200` + `{"data": [], "error": null}`):

```
GET /api/v4/pools/Pool-2/san/iscsi/targets/sessions                  → 200
{"data": [ …seven records: vm-100-0 ×2, vm-203-0 ×2, vm-420-0 ×3… ],
 "error": null}
```

**Table 1 — Session record fields** · `tbl_session_fields`

| Field | Example | Meaning |
|---|---|---|
| `target_name` | `iqn.2025-04.proxmox.joviandss.iscsi:vm-100-0` | full IQN of the target the session is attached to |
| `initiator_name` | `iqn.1993-08.org.debian:01:f4e662329db1` | the connected initiator's IQN — the field the foreign-session gate compares |
| `ip` | `172.30.143.17` | portal address this session runs over |
| `sid` | `45e0200003d0200` | session id — unique per session; the list has **one entry per session**, not per host |
| `cid` | `0` | connection id within the session |

Observed properties that shape the design:

- **One entry per session, keyed by `sid`.** A multipath node logs into every
  portal, so a single initiator routinely holds **multiple entries** for the
  same target — the `vm-420-0` capture shows two sessions from one initiator
  over two portals. Reconnects can add further sids, potentially repeating an
  IP. Consumers must therefore **group by `initiator_name` and deduplicate
  IPs** — initiator identity, not entry count, is the signal.
- **One target, many initiators.** `vm-420-0` shows sessions from two hosts
  simultaneously — the foreign-session condition the reactivation design's
  detach gate exists to detect.
- **Server-side filtering with an existence signal.** The per-target resource
  returns only the requested target's sessions; a session-less target answers
  `200` + `[]`, a missing target answers **404** with a machine-readable
  `ItemNotFoundError` — exactly the split
  `rest.get_target_sessions`' existing 404 →
  `JDSSResourceNotFoundException` handling expects. No `"data": null` on
  success and no `204` were observed anywhere.
- **The pool-wide sibling.** One list for every target of the pool (records
  carry `target_name`; empty pool → `200` + `[]`) — not used by this design,
  recorded as the pool-level diagnostic and the fallback shape
  (Options, B).

**The URL plumbing.** `rest_proxy.pool_request` prefixes every request with
`/pools/<pool>` (`jovian_common/rest_proxy.py:176`), so
`rest.get_target_sessions`' existing request string —
`/san/iscsi/targets/%s/sessions` (`rest.py:668`) — lands exactly on the
verified per-target URL; same shape as its neighbors (`get_target` uses
`/san/iscsi/targets/<iqn>`, `get_targets` uses `/san/iscsi/targets`,
`rest.py:646, 737`).

**The CLI output contract.** Today's `get --sessions` branch groups sessions
by initiator and prints one line per initiator:
`<initiator_iqn> <ip1>,<ip2>,...` (`target.py:90–94`). The Perl consumer
`target_get_sessions` (`Common.pm:1629–1653`) parses exactly this shape
(`split /\s+/, $line, 2`, then split the IP list on commas). This **line
format is kept verbatim** under the new `sessions list` verb — only the
spelling of the subcommand and the data source behind it move.

**CLI nesting precedent — the delegation pattern.** jdssc nests resources as
**separate modules, each owning its own class, dispatch dict and parser**:
`pool.py` declares bare subparsers (`add_parser('target', …)`,
`pool.py:81`) and delegates to `target.Target(args, uargs, jdss)`; one level
deeper, `volume.py` registers `'snapshots': self.snapshots` in its dispatch
dict and the handler is a one-liner —
`snapshots.Snapshots(self.args, self.uargs, self.jdss)` (`volume.py:278`) —
with `snapshots.py` parsing its own action (`add_subparsers(dest=
'snapshots_action')`, then `print_help()` + `sys.exit(1)` when the action is
missing; `required=True` on subparsers is used only at the `bin/jdssc` top
level). The chain works because every level parses with `parse_known_args`
and hands the leftover tokens (`uargs`) down. **`sessions` under `target`
follows exactly this pattern**: a bare `add_parser('sessions')` in
`target.py`, a one-line delegating handler, and a new `sessions.py` module
mirroring `snapshots.py` — so `pool <pool> target <iqn> sessions list` parses
the same way `pool <pool> volume <name> snapshots list` does today. (Verified
empirically against the target.py parser shape: the bare subparser consumes
`sessions`, `list` arrives in the leftovers, and a missing action parses as
`None` — feeding the `print_help()` + `sys.exit(1)` guard.)

---

## Options Considered
[Options_Considered](#options-considered)

**Option A — the per-target resource (chosen — after live verification).**
Keep `rest.get_target_sessions` requesting
`/san/iscsi/targets/<iqn>/sessions` and the driver as a passthrough. When
this document was first drafted the resource was unverified, and A was
rejected: an absent resource would 404 every query and silently close the
reactivation design's detach gate forever. **Live verification flipped it**
(Open Question #1 — resolved): the resource exists, filters server-side,
answers `[]` for an idle target, and 404s with `ItemNotFoundError` for a
missing one — exactly what the in-tree code already handles. Zero backend
change; the smallest possible diff.

**Option B — pool-wide fetch, filter in the driver (superseded).** The REST
layer would gain `get_targets_sessions()` mirroring the pool-wide endpoint,
with `driver.get_target_sessions(target_name)` filtering on `target_name`.
This was the draft's original choice while the per-target resource was
unverified — the pool-wide endpoint was the only verified one. Also confirmed
working (including the empty-pool `[]` case), but it costs a driver rewrite,
loses the explicit 404 existence signal, and scales with the pool's total
session count. Recorded as the fallback shape and the pool-level diagnostic;
not added now — no consumer needs it.

**Option C — try per-target first, fall back to pool-wide.** *Rejected:* two
code paths for one question — and the question (does the narrow resource
exist?) is now answered affirmatively, removing the fallback's reason to
exist.

---

## Recommended Solution
[Recommended_Solution](#recommended-solution)

**Table 2 — Layer-by-layer changes** · `tbl_layer_changes`

| Layer | Today | After |
|---|---|---|
| CLI (`target.py` + new `sessions.py`) | `pool <pool> target <iqn> get --sessions` → groups by initiator, prints `<initiator> <ip1>,<ip2>` per line | **`pool <pool> target <iqn> sessions list`** — `target.py` delegates to the new `sessions.py` module (the volume → snapshots pattern), same output lines (contract pinned); the `--sessions` flag on `get` is removed (superseded; it never had a working caller — the Perl invocation was broken) |
| driver (`driver.py`) | `get_target_sessions` → passthrough to the per-target REST call | **no change** — passthrough verified correct (its `:raises:` docstring included) |
| REST (`rest.py`) | `get_target_sessions` → `GET /san/iscsi/targets/<iqn>/sessions` | **no change** — URL, 404 → `JDSSResourceNotFoundException`, and empty-`[]` behavior all verified live |
| Perl (`Common.pm`) | `target_get_sessions` builds the CLI call (missing the `pool` prefix) and parses the lines | invocation becomes `['pool', $pool, 'target', $targetname, 'sessions', 'list']` with the `118, 5` bounds replaced by `TARGET_SESSIONS_QUERY_TIMEOUT` / `TARGET_SESSIONS_QUERY_RETRIES` — ships with the reactivation design's `Common.pm:1634` fix (values: its Table 4b); the parser is untouched |

The CLI addition follows the volume → snapshots delegation pattern
(`volume.py:278` / `snapshots.py`). In `target.py`, wiring only — an import,
a dispatch-dict entry, a bare subparser, a one-line handler:

```python
# target.py — top of file, with its sibling imports:
import jdssc.sessions as sessions

# __init__: 'sessions' joins the dispatch dict (target.py:30):
        self.ta = {'delete': self.delete,
                   'get': self.get,
                   'sessions': self.sessions,
                   'update': self.update}

# __parse(): bare subparser — the trailing tokens ('list') stay in uargs
# and flow to the child parser, as with every nested resource:
        parsers.add_parser('sessions')

# handler — pure delegation, like volume.py's snapshots():
    def sessions(self):
        sessions.Sessions(self.args, self.uargs, self.jdss)
```

The sub-resource lives in a **new module `sessions.py`**, mirroring
`snapshots.py` (class + dispatch dict + own `__parse` with the
missing-action `print_help()` exit; `prog=` names the resource — do not copy
`snapshots.py`'s stray `prog="Volume"`):

```python
# sessions.py — NEW module: target session commands.
import argparse
import logging
import sys

from jdssc.jovian_common import exception as jexc

"""Target session related commands."""

LOG = logging.getLogger(__name__)


class Sessions():
    def __init__(self, args, uargs, jdss):

        self.sa = {'list': self.list}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        if 'sessions_action' in self.args:
            self.sa[self.args.pop('sessions_action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Sessions")

        parsers = parser.add_subparsers(dest='sessions_action')

        parsers.add_parser('list')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.sessions_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def list(self):

        target_name = self.args['target_name']

        try:
            data = self.jdss.get_target_sessions(target_name)
        except jexc.JDSSResourceNotFoundException:
            LOG.error("Target %s not found", target_name)
            sys.exit(1)
        except jexc.JDSSException as jerr:
            LOG.error(jerr.message)
            sys.exit(1)

        # One record per SESSION (sid): a multipath initiator appears
        # once per portal it logged into, and reconnects can repeat an
        # ip under a new sid — group by initiator, dedupe ips (order
        # preserved).
        by_initiator = {}
        for s in data:
            ips = by_initiator.setdefault(s['initiator_name'], [])
            if s['ip'] not in ips:
                ips.append(s['ip'])
        for initiator, ips in by_initiator.items():
            print("{} {}".format(initiator, ','.join(ips)))
```

Style notes, pinned deliberately: the two `except` branches mirror `get()`'s
existing sessions branch verbatim (`JDSSResourceNotFoundException` →
"Target %s not found", then the general `LOG.error(jerr.message)` +
`sys.exit(1)` — `target.py:84–89`), rather than `snapshots.py`'s looser
`LOG.error(err)` + `exit(1)`; the `list` method name shadowing the builtin
matches `snapshots.py` (`def list(self)`) — established house style;
`target_name` arrives through `self.args` from `target.py`'s positional, the
same way `snapshots.py` reads `volume_name`.

**REST and driver layers: no code change.** `rest.get_target_sessions`
(`rest.py:658`) already requests the verified URL and already maps 404 →
`JDSSResourceNotFoundException`; `driver.get_target_sessions`
(`driver.py:1650`) is already the correct passthrough, `:raises:` docstring
included. Every behavior the CLI depends on is pinned by the live captures
in [Background](#background-and-research): sessions → `200` + records,
idle target → `200` + `[]`, missing target → `404` + `ItemNotFoundError`,
no `"data": null` on success, no `204`.

**Semantics — verified live, and their gate readings.** Three outcomes:

| `sessions list` outcome | Cause (verified) | Perl gate reading |
|---|---|---|
| lines on stdout, exit 0 | target has sessions (`200` + records) | initiators compared; any foreign → skip detach |
| no output, exit 0 | target exists, no sessions (`200` + `[]`) | no foreign sessions → detach may proceed |
| error, exit ≠ 0 | target missing (`404`), transport/pool failure, auth error, parse error | *no evidence, no detach* — skip |

A missing target lands in the loud branch (unlike the pool-wide alternative,
which cannot see it) — harmless for the gate: with the target gone there is
nothing to detach, and the final attempt's re-publish recreates it anyway.

**Output contract (pinned, machine-readable).** One line per initiator with
active sessions, portal IPs comma-joined and deduplicated — the line format
today's `get --sessions` branch prints (`target.py:90–94`), unchanged under
the new verb. For `vm-420-0` from the verified capture (three sessions, two
initiators):

```
iqn.1993-08.org.debian:01:793c225e3c37 172.29.143.18,172.30.143.18
iqn.1993-08.org.debian:01:f4e662329db1 172.29.143.17
```

An initiator's several sessions (one per portal, more after reconnects)
collapse into **one line** — session multiplicity is a transport detail; the
consumer keys on initiator identity. No sessions → no output, exit 0.
`sid`/`cid` are deliberately not printed; extending the format later is
additive (new flag), never a reshape of these lines.

---

## Open Questions
[Open_Questions](#open-questions)

All three resolved by live verification (2026-07-03, appliances
`192.168.28.102`/`Pool-2` and `172.28.140.170`/`Pool-1-backup`); captures in
[Background](#background-and-research).

1. **Does a per-target sessions resource exist? — resolved: yes.**
   `GET /api/v4/pools/<pool>/san/iscsi/targets/<iqn>/sessions` returns the
   target's sessions, server-filtered, in the same record shape as the
   pool-wide list. Consequence: the chosen option flipped from B (pool-wide
   + driver filter) to A (per-target, zero backend change) — see
   [Options Considered](#options-considered).
2. **Which API version? — resolved: v4 (decided).** `pool_request(…,
   apiv=4)` — exactly what `rest.get_target_sessions` already passes. Both
   verification appliances answered on v4; v4 is the pinned baseline. An
   appliance without it fails loud → the detach gate stays closed (*no
   evidence, no detach*) — safe.
3. **What do the empty cases return? — resolved.** Session-less target:
   `200` + `{"data": [], "error": null}`; empty pool (pool-wide sibling):
   the same `200` + `[]`; missing target: `404` +
   `{"data": null, "error": {"class": "opene.exceptions.ItemNotFoundError",
   …}}`. No `"data": null` on success and no `204` observed — the draft's
   defensive `or []` normalization and its 204 special-case are **not
   needed** and were dropped from the design.

---

## New Functions
[New_Functions](#new-functions)

In `jdssc/jdssc/sessions.py` (**new module**, mirroring `snapshots.py`):

- **`Sessions(args, uargs, jdss)`** — the `sessions` sub-resource of
  `target`: own dispatch dict (`{'list': self.list}`), own `__parse`
  (`add_subparsers(dest='sessions_action')`, missing action →
  `print_help()` + `sys.exit(1)` — the `snapshots.py` shape; no
  `required=True`, which only the `bin/jdssc` top level uses).
- **`Sessions.list()`** — fetches via `driver.get_target_sessions`
  (`target_name` from `target.py`'s positional through `self.args`), groups
  by `initiator_name`, dedupes IPs, prints the pinned lines. Error branches
  mirror `get()`'s existing sessions branch (`target.py:84–89`):
  `JDSSResourceNotFoundException` → "Target %s not found" + exit 1, general
  `JDSSException` → `LOG.error(jerr.message)` + `sys.exit(1)`.

No REST- or driver-layer functions are added — the existing
`rest.get_target_sessions` / `driver.get_target_sessions` pair is used
as-is (verified live; [Changed Functions](#changed-functions)).

---

## Changed Functions
[Changed_Functions](#changed-functions)

- **`rest.get_target_sessions`** (`jovian_common/rest.py:658`) and
  **`driver.get_target_sessions`** (`jovian_common/driver.py:1650`) —
  **unchanged**. Both were written against the per-target resource; live
  verification confirmed the URL, the 404 →
  `JDSSResourceNotFoundException` mapping, the empty-target `[]`, and the
  record shape. Their docstrings (including the driver's `:raises:` clause)
  stay accurate as written.
- **`target.py`** — wiring only: `import jdssc.sessions as sessions`, a
  `'sessions': self.sessions` dispatch-dict entry, a bare
  `parsers.add_parser('sessions')`, and the one-line delegating handler
  (the `volume.py:278` pattern); `get()` (`jdssc/target.py:79–95`) **loses
  the `--sessions` flag** and its sessions branch (superseded by the
  dedicated verb; it never had a working caller — the Perl invocation was
  broken), reverting `get` to pure target-data output. The output logic
  moves into `sessions.py` with
  one addition: IP deduplication within an initiator's line (reconnects can
  repeat an IP under a new `sid`); the line format itself is the pinned
  contract.

---

## Relationship to Other Designs
[Relationship_to_Other_Designs](#relationship-to-other-designs)

- [`volume-activation-with-reactivation.md`](volume-activation-with-reactivation.md)
  — the consumer: `_target_foreign_sessions` (its Open Question #1, second
  revision) calls `target_get_sessions` (`Common.pm:1629`), which shells out
  to the CLI subcommand this design makes real. That design owns the
  Perl-side change in full: the `Common.pm:1634` invocation fix and the
  query-bound constants (`TARGET_SESSIONS_QUERY_TIMEOUT` /
  `TARGET_SESSIONS_QUERY_RETRIES`, values in its Table 4b) — the two designs
  together make the gate functional end to end. Its *no evidence, no detach*
  rule is what makes this design's fail-loud error path safe.

---

## Risks & Backward Compatibility
[Risks_and_Backward_Compatibility](#risks--backward-compatibility)

1. **Verified baseline: API v4, two appliances.** The per-target resource,
   its empty-`[]` and 404 shapes, and the pool-wide sibling were all
   confirmed on `192.168.28.102`/`Pool-2` and `172.28.140.170`/
   `Pool-1-backup` (Open Questions — resolved). v4 is the pinned baseline
   (decided); an appliance without the resource fails loud and the
   consumer's gate fails safe (*no evidence, no detach*).
2. **Version skew between plugin and jdssc.** The plugin's invocation
   (`sessions list`, with the `pool` prefix — the reactivation design's
   `Common.pm:1634` fix) and this jdssc change ship together in one package,
   so no released combination mixes old verb with new CLI. A deployment
   running mismatched halves gets a parse error → non-zero exit → the gate's
   *no evidence, no detach* rule — fail safe, never a wrong detach.
3. **Removing `get --sessions` breaks no one.** The flag's only in-tree
   consumer is `Common.pm`'s `target_get_sessions`, whose invocation was
   itself broken (missing `pool` prefix) — there has never been a working
   caller of the flag. (Verified: `target.py:83` is the sole caller of
   `driver.get_target_sessions`, the driver is the sole caller of
   `rest.get_target_sessions`, and nothing under `tests/` references the
   chain.)
4. **Stale foreign sessions delay recovery — in the safe direction.** The
   appliance lists sessions as the target sees them: a crashed or fenced
   node's session can linger until iSCSI/TCP timeouts reap it. The gate then
   reads a foreign initiator and skips the detach, so the final activation
   attempt runs without the re-attach reset. Never a wrong detach — the
   trade is a delayed recovery until the appliance reaps the dead session
   (or the next activation retries). Accepted; consistent with the
   reactivation design's *no evidence, no detach* posture.
5. **Test coverage.** The chain had none; the implementation added
   `jdssc/tests/test_sessions.py`: the group-by-initiator + IP-dedup output
   contract pinned against the Table 1 `vm-420-0` capture, the reconnect
   dedup case, and the empty / missing-target / missing-action exits. (The
   driver is a passthrough under the chosen Option A — nothing to unit-test
   beyond the REST mirror, which the live captures verify.)

---

## Files That Would Change (when implemented)
[Files_That_Would_Change](#files-that-would-change-when-implemented)

**Table 3 — Files that would change** · `tbl_sessions_files_changed`

| File | Change |
|---|---|
| `jdssc/jdssc/jovian_common/rest.py` | **no change** — `get_target_sessions` verified live (URL, 404 → `JDSSResourceNotFoundException`, empty-`[]`) |
| `jdssc/jdssc/jovian_common/driver.py` | **no change** — `get_target_sessions` passthrough verified, docstring accurate |
| `jdssc/jdssc/sessions.py` | **new module** — `Sessions` class with the `list` action (line format from the `get --sessions` branch, plus per-initiator IP dedup); mirrors `snapshots.py` |
| `jdssc/jdssc/target.py` | wiring for the `sessions` sub-resource (import + dispatch entry + bare subparser + delegating handler); remove the `--sessions` flag from `get` |
| `OpenEJovianDSS/Common.pm` | `target_get_sessions` invocation → `['pool', $pool, 'target', $targetname, 'sessions', 'list']`, bounds → `TARGET_SESSIONS_QUERY_TIMEOUT` / `TARGET_SESSIONS_QUERY_RETRIES`, target name **untainted via `safe_word`** (taint-mode exec safety; the pattern accepts all legal iSCSI-name characters; `get_pool` already untaints the pool internally) — subsumes the reactivation design's `Common.pm:1634` fix (values in its Table 4b) |
| `docs/design/volume-activation-with-reactivation.md` | no further change — already tracks the final verb (`sessions list`), the per-target endpoint, and the query-bound constants (updated alongside this design's revisions) |
