#    Copyright (c) 2024 Open-E, Inc.
#    All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License. You may obtain
#    a copy of the License at
#
#         http://www.apache.org/licenses/LICENSE-2.0
#
#    Unless required by applicable law or agreed to in writing, software
#    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
#    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
#    License for the specific language governing permissions and limitations
#    under the License.

package OpenEJovianDSS::Lock;

# Scope-typed lock primitive shared by the iSCSI and NFS plugins — see
# docs/design/multi-layer-lock-design.md (the accepted design this module
# implements).
#
# One public entry point, with_lock($ctx, $lock_class, $id, ...), serves every
# lock: the per-VM / per-storage method locks and the per-jdssc-invocation
# component locks (jdssc_general / jdssc_info, reserved multipath). A lock's
# scope comes from its class's <class>_lock_type storage.cfg property (per-class
# default otherwise); two backends implement it: pmxcfs mkdir (cluster reach,
# CFS_LOCK_TIMEOUT idle expiry) and node-local flock (never expires, freed on
# process death). All held locks share one registry in $ctx->{_held_locks} —
# the re-entry guard, the keep-alive refresh and the hold-cap deadline all
# operate on it, which is why one $ctx must thread through a whole locked
# operation (never new_ctx under a held lock).

use strict;
use warnings;

use Carp ();
use Exporter 'import';

use Fcntl          qw(LOCK_EX);
use File::Basename ();
use File::Path     qw(make_path);
use File::stat     ();
use Time::HiRes    ();
use PVE::Cluster   ();
use PVE::Tools     ();   # run_with_timeout bounds the node flock wait

our @EXPORT_OK = qw(
    with_lock
);

our %EXPORT_TAGS = ( all => [@EXPORT_OK] );

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Cluster-wide lock root: the standard pmxcfs lock namespace.
# pmxcfs tracks ltime and auto-expires stale locks only for entries under
# priv/lock/, so all cluster locks must live here.
sub _cluster_lockdir {
    return "/etc/pve/priv/lock";
}

# ---------------------------------------------------------------------------
# Per-class constants
# ---------------------------------------------------------------------------
#
# Every per-class value is a FLAT, individually named constant — greppable,
# referenceable directly, compile-time checked where used by name. The LOCK_*
# maps below only WIRE those constants to their class keys: the maps exist
# because the class arrives as a runtime variable and needs a lookup — no value
# is ever defined inside a map.

# default scope per class
use constant LOCK_CLASS_JDSSC_GENERAL_DEFAULT_TYPE => 'cluster';
use constant LOCK_CLASS_JDSSC_INFO_DEFAULT_TYPE    => 'node';
use constant LOCK_CLASS_MULTIPATH_DEFAULT_TYPE     => 'node';
use constant LOCK_CLASS_VM_DEFAULT_TYPE            => 'vm';
use constant LOCK_CLASS_STORAGE_DEFAULT_TYPE       => 'storage';

# seconds to WAIT to acquire, per class
use constant LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT => 1200;    # = PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX
use constant LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT    => 40;
# Raised from 10 with the volume-activation design: a waiter must outlast one
# full worst-case command hold (MULTIPATH_CMD_TIMEOUT_MAX + KILL_GRACE +
# BACKSTOP_MARGIN = 40 s ladder) with real headroom; a deeper queue can still
# time a waiter out — that is the reactivation cycle's contention class
# (lock_error_acquire), retried without teardown.
use constant LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT     => 60;
# Raised from 600: on shared storage these resolve to the cluster backend and
# can face long cluster-wide contention, so a waiter needs headroom to outlast
# a lengthy hold (up to the 1320 s hold cap) instead of timing out into the
# reactivation cycle's contention class. Matches the jdssc_general wait. The
# same value applies harmlessly on the node backend (non-shared storage).
use constant LOCK_CLASS_VM_ACQUIRE_TIMEOUT            => 1200;
use constant LOCK_CLASS_STORAGE_ACQUIRE_TIMEOUT       => 1200;

# hold cap: run_bounded alarm + refresh_locks deadline. The jdssc caps sit just
# above run_command's kill (PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX + 1) so a
# legitimate maximal run never trips enforcement, yet below CFS_LOCK_TIMEOUT.
use constant LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT => 119;
use constant LOCK_CLASS_JDSSC_INFO_HOLD_TIMEOUT    => 119;
use constant LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT     => 60;
# Raised from 600 with the volume-activation design: the whole reactivation
# cycle (pessimistic four-cycle budget plus the pre-final-cycle session probe,
# ~13–17 min worst) must fit inside the method-lock deadline with headroom
# instead of dying mid-recovery; the deadline stays the loud backstop beyond
# that (its die carries LOCK_FATAL_ERROR_MARKER and is never absorbed).
use constant LOCK_CLASS_VM_HOLD_TIMEOUT            => 1620;
use constant LOCK_CLASS_STORAGE_HOLD_TIMEOUT       => 1620;

# class-key → constant wiring, used by the getters for runtime dispatch.
# LOCK_DEFAULT_TYPE's key set doubles as the valid-class list (with_lock dies
# on any other key).
use constant LOCK_DEFAULT_TYPE => {
    jdssc_general => LOCK_CLASS_JDSSC_GENERAL_DEFAULT_TYPE,
    jdssc_info    => LOCK_CLASS_JDSSC_INFO_DEFAULT_TYPE,
    multipath     => LOCK_CLASS_MULTIPATH_DEFAULT_TYPE,
    vm            => LOCK_CLASS_VM_DEFAULT_TYPE,
    storage       => LOCK_CLASS_STORAGE_DEFAULT_TYPE,
};
use constant LOCK_CLASS_ACQUIRE_TIMEOUT => {
    jdssc_general => LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT,
    jdssc_info    => LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT,
    multipath     => LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT,
    vm            => LOCK_CLASS_VM_ACQUIRE_TIMEOUT,
    storage       => LOCK_CLASS_STORAGE_ACQUIRE_TIMEOUT,
};
use constant LOCK_CLASS_HOLD_TIMEOUT => {
    jdssc_general => LOCK_CLASS_JDSSC_GENERAL_HOLD_TIMEOUT,
    jdssc_info    => LOCK_CLASS_JDSSC_INFO_HOLD_TIMEOUT,
    multipath     => LOCK_CLASS_MULTIPATH_HOLD_TIMEOUT,
    vm            => LOCK_CLASS_VM_HOLD_TIMEOUT,
    storage       => LOCK_CLASS_STORAGE_HOLD_TIMEOUT,
};

# Explicit lock-class property names — NO runtime "${class}_lock_*" key
# building. Every storage.cfg property a class understands is spelled out here,
# so each name is greppable and adding a class is a deliberate row, not a key
# conjured from string interpolation.
use constant LOCK_CLASS_PROPERTY => {
    jdssc_general => { type => 'jdssc_general_lock_type', dir => 'jdssc_general_lock_path',
                       acquire => 'jdssc_general_lock_acquire_timeout', hold => 'jdssc_general_lock_hold_timeout' },
    jdssc_info    => { type => 'jdssc_info_lock_type',    dir => 'jdssc_info_lock_path',
                       acquire => 'jdssc_info_lock_acquire_timeout',    hold => 'jdssc_info_lock_hold_timeout' },
    multipath     => { type => 'multipath_lock_type',     dir => 'multipath_lock_path',
                       acquire => 'multipath_lock_acquire_timeout',     hold => 'multipath_lock_hold_timeout' },
    vm            => { type => 'vm_lock_type',            dir => 'vm_lock_path',
                       acquire => 'vm_lock_acquire_timeout',            hold => 'vm_lock_hold_timeout' },
    storage       => { type => 'storage_lock_type',       dir => 'storage_lock_path',
                       acquire => 'storage_lock_acquire_timeout',       hold => 'storage_lock_hold_timeout' },
};

# Marker prefixed to every lock-machinery die that must never be swallowed by
# best-effort machinery — today the two hold-enforcement dies (refresh_locks's
# hold-cap overrun, run_bounded's hold alarm). lock_error_fatal detects it by
# SUBSTRING match, so outer error prefixing (e.g. _lock_acquire_cluster's
# machinery prefix) survives. Any future must-not-swallow lock error joins by
# adopting the prefix.
use constant LOCK_FATAL_ERROR_MARKER => 'joviandss-lock-fatal:';

# Alarm bound on the cluster-backend rmdir in _lock_divest: release runs on
# unwind paths where a wedged FUSE call would otherwise hang the process
# while it still believes it holds the lock. On expiry the dir is left for
# the waiters' normal utime(0,0) stale reclaim. (Table 9 in the design doc.)
use constant LOCK_DIVEST_GUARD_TIMEOUT => 5;

# ---------------------------------------------------------------------------
# Per-class property getters
# ---------------------------------------------------------------------------

# Read a class's explicit scfg property for one attribute (undef if the class
# declares none). Two-step lookup on purpose: a one-step
# ->{$lock_class}{$attr} on an unknown class would AUTOVIVIFY an empty hash
# inside the shared LOCK_CLASS_PROPERTY constant.
sub _lock_class_scfg {
    my ($ctx, $lock_class, $attr) = @_;

    my $props = LOCK_CLASS_PROPERTY->{$lock_class} or return undef;
    my $prop  = $props->{$attr}                    or return undef;

    return $ctx->{scfg}{$prop};
}

# Each getter resolves one attribute for a class: the operator's explicit
# <class>_lock_<attr> override from storage.cfg (looked up by literal name via
# LOCK_CLASS_PROPERTY), else the class's flat default constant via the wiring
# map. No trailing global fallbacks: with_lock has already validated the class
# against LOCK_DEFAULT_TYPE, and the LOCK_* maps are key-complete by invariant.

sub get_lock_class_type {
    my ($ctx, $lock_class) = @_;

    my $type = _lock_class_scfg($ctx, $lock_class, 'type')
            // LOCK_DEFAULT_TYPE->{$lock_class};

    # 'vm' / 'storage' are structural to their namesake classes (the class id
    # keys the lock name); component classes accept 'node' / 'cluster' only.
    die "invalid ${lock_class}_lock_type '$type'\n"
        unless $type eq 'node' || $type eq 'cluster' || $type eq $lock_class;

    return $type;
}

sub get_lock_class_dir {
    my ($ctx, $lock_class) = @_;

    return _lock_class_scfg($ctx, $lock_class, 'dir');    # undef → backend default dir
}

sub get_lock_class_acquire_timeout {
    my ($ctx, $lock_class) = @_;

    return _lock_class_scfg($ctx, $lock_class, 'acquire')
        // LOCK_CLASS_ACQUIRE_TIMEOUT->{$lock_class};
}

sub get_lock_class_hold_timeout {
    my ($ctx, $lock_class) = @_;

    return _lock_class_scfg($ctx, $lock_class, 'hold')
        // LOCK_CLASS_HOLD_TIMEOUT->{$lock_class};
}

# ---------------------------------------------------------------------------
# Scope-to-path resolution
# ---------------------------------------------------------------------------

# Maps the resolved (scope, class, id) → (backend, lock path) — the one place
# lock paths are built; callers pass a class + id, never a path or a scope.
sub _lock_resolve {
    my ($ctx, $type, $lock_class, $id) = @_;

    # id-keyed classes: 'vm' is keyed by the vmid (passed as $id); 'storage' by
    # the storeid (intrinsic to $ctx). Singleton classes have no id.
    my $key = $lock_class eq 'storage' ? $ctx->{storeid} : $id;
    $key = OpenEJovianDSS::Common::safe_word(
               OpenEJovianDSS::Common::clean_word($key), "lock id") if defined $key;
    my $name = defined $key ? "joviandss-lock-${lock_class}-${key}"
                            : "joviandss-lock-${lock_class}";

    # Directory is set by the resolved backend; node = this host's local
    # /run/lock tmpfs (already per-PVE-server), cluster = pmxcfs, non-shared
    # vm/storage = the storage's own directory.
    my ($backend, $default_dir) =
          $type eq 'node'    ? ('node',    '/run/lock')
        : $type eq 'cluster' ? ('cluster', _cluster_lockdir())
        : OpenEJovianDSS::Common::get_shared($ctx)
                             ? ('cluster', _cluster_lockdir())
        :                      ('node',    OpenEJovianDSS::Common::get_path($ctx) . '/private/lock');

    my $dir = get_lock_class_dir($ctx, $lock_class) // $default_dir;
    return ($backend, "$dir/$name");
}

# ---------------------------------------------------------------------------
# Held-lock registry: commission → acquire → divest → decommission
# ---------------------------------------------------------------------------
#
# $ctx->{_held_locks} is initialized to [] in Common::new_ctx. One record per
# lock, the single store every phase enriches: _lock_ctx_commission freezes
# the timing policy BEFORE acquisition (the cluster poll loop needs the
# in-flight target registered), _lock_acquire flips owned / parks the node fh
# / arms the deadline, _lock_divest clears them, _lock_ctx_decommission
# removes the record — BY PATH, never a LIFO pop.

# The registry record for a commissioned lock id (undef when none).
sub _lock_record {
    my ($ctx, $lock_id) = @_;

    for my $lock (@{ $ctx->{_held_locks} }) {
        return $lock if $lock->{path} eq $lock_id;
    }
    return undef;
}

# _lock_ctx_commission($ctx, $backend, $path, $timeout, $max_hold) → $lock_id
#
# Commissioned = REGISTERED + GUARDED, NOT owned: the record must exist
# before the acquisition wait so the re-entry guard can fire and the poll
# loop can refresh the OTHER held locks around it. Ownership begins in
# _lock_acquire, and the wall-clock hold clock starts there too — arming the
# deadline here would charge a contended acquisition (whose acquire bound
# far exceeds its hold cap) against the hold budget.
#
# Resolve-and-freeze: every timing number this lock will ever use is
# computed HERE, once, into the record — the acquire wait budget, the hold
# cap, and the alarm cap (cluster backend: ceilinged at
# PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX even when the class cap is 0 — a wedged
# pure-Perl holder reaches no cooperation point, so only the alarm can stop
# it, and on pmxcfs it must die before a waiter stale-reclaims at
# CFS_LOCK_TIMEOUT; a pmxcfs-correctness invariant, not a class property).
# Downstream phases read the record and are never handed a number.
sub _lock_ctx_commission {
    my ($ctx, $backend, $path, $timeout, $max_hold) = @_;

    for my $lock (@{ $ctx->{_held_locks} }) {
        next if $lock->{path} ne $path;
        Carp::confess(
            "LOCK BUG: '$path' is already held — re-locking it is forbidden and "
          . "would deadlock; this must never happen, please report it to the dev "
          . "team.\n\n=== held since ===\n$lock->{acquired_at}\n"
          . "=== re-lock attempted here ===" );    # confess appends the current stack
    }

    my $alarm_cap = $max_hold;
    if ( $backend eq 'cluster' ) {
        my $ceiling = OpenEJovianDSS::Common::PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX();
        $alarm_cap = $ceiling if !$alarm_cap || $alarm_cap > $ceiling;
    }

    push @{ $ctx->{_held_locks} },
        { backend         => $backend,
          path            => $path,
          acquire_timeout => $timeout,
          max_hold        => $max_hold,
          alarm_cap       => $alarm_cap,
          owned           => 0,
          fh              => undef,   # node backend: parked by _lock_acquire
          deadline        => undef,   # armed by _lock_acquire at ownership
          acquired_at     => Carp::longmess("commissioned '$path'") };

    return $path;    # the lock id IS the resolved path (unique per the guard)
}

# _lock_ctx_decommission($ctx, $lock_id) — the FINALIZER: never dies, runs
# exactly once per commission, on every path. The happy path and the
# body-death path have both divested explicitly by the time it runs, so a
# still-owned record here means an impossible path executed — divest with a
# loud warn and keep going (a die here would mask the original error).
sub _lock_ctx_decommission {
    my ($ctx, $lock_id) = @_;

    my $lock = _lock_record($ctx, $lock_id) or return;

    if ($lock->{owned}) {
        eval { OpenEJovianDSS::Common::debugmsg($ctx, 'warning',
            "LOCK BUG: '$lock_id' still owned at decommission — released by "
          . "the finalizer; this path must not exist, please report it") };
        _lock_divest($ctx, $lock_id);
    }

    @{ $ctx->{_held_locks} } =
        grep { $_->{path} ne $lock_id } @{ $ctx->{_held_locks} };
    return;
}

# Backend-agnostic keep-alive AND wall-clock hold-cap enforcement — called by
# run_refreshed around every locked body and by the cluster poll loop each
# iteration. Only OWNED records participate: a not-yet-owned record is the
# in-flight acquisition target (its utime(0,0) stale-poke must not be
# overwritten with a fresh mtime), and a divested-not-yet-decommissioned
# record has nothing left to keep alive. $skip_path additionally names the
# poll loop's own target, and suppresses the alarm re-arm below.
sub refresh_locks {
    my ($ctx, $skip_path) = @_;

    for my $lock (@{ $ctx->{_held_locks} }) {
        next if !$lock->{owned};
        next if defined $skip_path && $lock->{path} eq $skip_path;

        # Wall-clock hold cap: overrun → die → the normal exception-safe
        # unwind releases everything held. The marker keeps this die out of
        # every best-effort eval (lock_error_fatal).
        die LOCK_FATAL_ERROR_MARKER
          . " lock '$lock->{path}' held past its hold cap — aborting to release it\n"
            if $lock->{deadline} && time() > $lock->{deadline};

        if ($lock->{backend} eq 'cluster') {
            utime(undef, undef, $lock->{path});    # pmxcfs: reset the CFS_LOCK_TIMEOUT idle timer
        }
        # 'node' (flock): no-op — never expires
    }

    # Re-arm the innermost active hold alarm (see run_bounded): a refresh is
    # proof of cooperation, so the wedge budget restarts. The alarm thereby
    # measures un-suspended Perl time SINCE THE LAST COOPERATION POINT, not
    # since acquisition — a long, cooperating hold (sleep-wait loops under
    # the vm lock) must not burn the budget the wedge backstop needs, and
    # every refresh here has just utime'd ALL owned cluster dirs, so the
    # alarm and the pmxcfs stale-reclaim clocks restart from the same epoch.
    # NOT done for the poll-loop calls ($skip_path set): during a cluster
    # acquisition the poll owns the alarm for its per-attempt mkdir bound
    # and restores the suspended state itself.
    if ( !defined $skip_path ) {
        my $inner = _lock_alarm_innermost($ctx);
        alarm( $inner->{alarm_cap} ) if $inner;
    }
}

# Exception-safe refresh bracket around a locked body: the post-refresh runs
# even if the body dies, so a held lock is never left un-refreshed right before
# a retry sleep. Returns a single scalar/ref — see the design's Return
# convention (the lock brackets run $code in scalar context; never wantarray).
sub run_refreshed {
    my ($ctx, $code, @param) = @_;

    refresh_locks($ctx);
    my $res;
    my $ok  = eval { $res = $code->(@param); 1 };
    my $err = $@;
    refresh_locks($ctx);
    die $err if !$ok;
    return $res;
}

# Innermost armed alarm section = the LAST commissioned record that is owned
# with a nonzero alarm cap. $exclude_id lets run_bounded's exit find its
# ENCLOSING section (the caller's own record is still owned at that instant).
# Sections nest in commission order because _lock_exec is run_bounded's sole
# caller — a load-bearing invariant: do not add other call sites.
sub _lock_alarm_innermost {
    my ($ctx, $exclude_id) = @_;

    for my $lock ( reverse @{ $ctx->{_held_locks} } ) {
        next if defined $exclude_id && $lock->{path} eq $exclude_id;
        return $lock if $lock->{owned} && $lock->{alarm_cap};
    }
    return undef;
}

# run_bounded($ctx, $lock_id, $code, @param) — pure-Perl-hang backstop for
# the section holding $lock_id: runs the held body under a hold alarm read
# from the record (alarm_cap 0 → no alarm section: the enclosing section's
# alarm, if any, keeps ticking). Overrun → die → lock releases on unwind.
# Nested alarm users (run_command, run_with_timeout waits) suspend this alarm
# — the wall-clock hold bound is the deadline check in refresh_locks, not this.
#
# The alarm budget is SINCE THE LAST COOPERATION POINT, not since acquisition:
# every refresh_locks re-arms the innermost armed section (a refresh proves
# the holder is not wedged and resets the pmxcfs stale-reclaim clocks the
# alarm exists to beat, so both clocks restart from the same epoch). On exit
# the ENCLOSING section is re-armed to its full cap — exiting a section is a
# cooperation point (the body's guaranteed post-refresh ran moments earlier);
# restoring the remainder frozen at entry would leave the outer alarm
# stale-depleted after a long, cooperative inner section. With no enclosing
# section, the suspended foreign alarm (e.g. PVE core's own run_with_timeout)
# is restored untouched.
#
# Deliberately NO kill here: this wrapper owns no process (a runaway jdssc is
# killed by run_command's own timeout); its enforcement is the die, whose
# unwind is what releases the lock.
sub run_bounded {
    my ($ctx, $lock_id, $code, @param) = @_;

    my $lock = _lock_record($ctx, $lock_id)
        or Carp::confess("LOCK BUG: run_bounded('$lock_id') without a "
                       . "commissioned record");
    my $cap = $lock->{alarm_cap};
    return $code->(@param) unless $cap;

    my $prev = alarm(0);                 # suspend any outer/foreign alarm
    my $res;
    my $ok = eval {
        local $SIG{ALRM} =
            sub { die LOCK_FATAL_ERROR_MARKER
                    . " lock '$lock_id' hold exceeded ${cap}s — aborting to "
                    . "release it\n" };
        alarm($cap);
        $res = $code->(@param);
        alarm(0);
        1;
    };
    my $err = $@;
    alarm(0);
    my $enclosing = _lock_alarm_innermost($ctx, $lock_id);
    if    ($enclosing) { alarm( $enclosing->{alarm_cap} ) }  # exit = cooperation point
    elsif ($prev)      { alarm($prev) }                      # foreign alarm untouched
    die $err if !$ok;
    return $res;
}

# ---------------------------------------------------------------------------
# Error classification helpers (volume-activation-with-reactivation design)
# ---------------------------------------------------------------------------

# True when $err is a lock-machinery die that must never be swallowed by
# best-effort machinery (hold-cap overrun, hold alarm): the locks protecting
# the operation can no longer be trusted, so recovery machinery must rethrow
# instead of absorbing it. Substring match — outer error prefixing survives.
# Returns false for acquisition timeouts: those report contention for a lock
# not yet held and stay retryable (lock_error_acquire).
sub lock_error_fatal {
    my ($err) = @_;

    return 0 if !defined $err;
    return index($err, LOCK_FATAL_ERROR_MARKER) >= 0 ? 1 : 0;
}

# True when $err is a lock ACQUISITION timeout — a lock that was NEVER
# obtained: nothing was modified under it and every held lock is still valid
# (the reactivation cycle's contention class, retried without teardown).
# Both shapes are OUR canonical strings, emitted by _lock_acquire_*:
#   - "got lock request timeout"  — cluster backend (_lock_acquire_cluster);
#     deliberately NOT the literal "got timeout", so cluster contention
#     stays out of joviandss_cmd's timeout-retry class
#   - "can't lock file '...' - got timeout" — node backend
#     (_lock_acquire_node); the "can't lock file" prefix is REQUIRED here:
#     a bare "got timeout" is run_command's process-timeout die and must
#     never classify as lock contention.
sub lock_error_acquire {
    my ($err) = @_;

    return 0 if !defined $err;
    return 1 if $err =~ /got lock request timeout/;
    return 1 if $err =~ /can't lock file '[^']*' - got timeout/;
    return 0;
}

# Seconds until the nearest hold deadline among the locks held in
# $ctx->{_held_locks} (undef when none is armed); read-only on the registry.
# Backs the reactivation cycle's pre-cycle budget check.
sub lock_deadline_remaining {
    my ($ctx) = @_;

    my $remaining;
    for my $lock (@{ $ctx->{_held_locks} }) {
        next unless $lock->{deadline};
        my $left = $lock->{deadline} - time();
        $remaining = $left if !defined($remaining) || $left < $remaining;
    }
    return $remaining;
}

# ---------------------------------------------------------------------------
# Acquisition and release — the world-touching phases
# ---------------------------------------------------------------------------

# _lock_acquire($ctx, $lock_id) → $lock_id
#
# Blocks up to the record's acquire budget taking exclusive ownership; DIES
# on any failure — it never returns undef/false. On success, and only then,
# it sets owned=1 and arms the hold deadline as its final act: ownership and
# its wall-clock clock start together. Requires a commissioned record
# (confess otherwise: an unregistered cluster lock would never be refreshed,
# and a waiter would stale-reclaim it while held). Acquisition errors
# originate here, in a frame where no caller code has ever run — no
# classification of acquire-vs-body errors exists or is needed.
sub _lock_acquire {
    my ($ctx, $lock_id) = @_;

    my $lock = _lock_record($ctx, $lock_id)
        or Carp::confess("LOCK BUG: _lock_acquire('$lock_id') without "
                       . "_lock_ctx_commission");

    # Cooperation point: don't START a wait the enclosing budget has already
    # outlived — an expired outer hold deadline dies HERE with the true
    # hold-cap fatal (not disguised as inner contention after a doomed
    # wait). Also utimes the outer cluster dirs and re-arms the enclosing
    # alarm, so the node backend enters its blind kernel block with every
    # clock freshly reset. The target record is owned=0 and is skipped
    # naturally.
    refresh_locks($ctx);

    # The backends flip owned=1 THEMSELVES, at the instant of mkdir/flock
    # success — so a die anywhere after that instant (cfs_update, a signal
    # in the dispatcher, the caller's frames) finds the flag set and the
    # sequencer's unconditional divest releases correctly. The only
    # unreleased window left is the single assignment between the syscall
    # returning and the flag flip — irreducible without signal masking;
    # stale reclaim / process death remain the backstops (accepted residual,
    # Open question #2).
    $lock->{backend} eq 'cluster'
        ? _lock_acquire_cluster($ctx, $lock)
        : _lock_acquire_node($ctx, $lock);

    $lock->{deadline} = time() + $lock->{max_hold} if $lock->{max_hold};
    return $lock_id;
}

# Cluster backend: pmxcfs atomic mkdir with deadline-accounted polling.
# Modelled on the private $cfs_lock closure in PVE::Cluster
# (pve-cluster/src/PVE/Cluster.pm:601) with these differences: quorum check
# on acquisition failure (pmxcfs clears the write bit on /etc/pve/local);
# deadline-based accounting (any inter-poll sleep charges itself against the
# budget); poll backoff + jitter via the PROXMOX_CLUSTER_POLL_* constants
# (contending nodes spread out instead of polling in lockstep); each
# iteration refreshes every OTHER held lock (refresh_locks with the target
# skipped) so queueing never lets an already-held outer lock go stale; and
# no execution alarm — the body is not run here at all.
#
# Dies with the canonical "got lock request timeout" (machinery-prefixed).
# Deliberately NOT the literal "got timeout": cluster contention must stay
# out of joviandss_cmd's timeout-retry class and fail loud instead.
sub _lock_acquire_cluster {
    my ($ctx, $lock) = @_;

    my $lockpath = $lock->{path};
    my $lockdir  = File::Basename::dirname($lockpath);
    my $lockid   = File::Basename::basename($lockpath);

    my $prev_alarm = alarm(0);    # suspend the enclosing alarm for the WAIT only
    my $got_lock   = 0;

    my $ok = eval {
        make_path($lockdir);
        die "pve cluster filesystem not online\n" if !-d $lockdir;

        my $timeout_err = sub { die "got lock request timeout\n" };
        local $SIG{ALRM} = $timeout_err;

        my $deadline = time() + $lock->{acquire_timeout};
        my $base     = OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_BASE_SLEEP();

        while (1) {
            my $remaining = $deadline - time();
            $timeout_err->() if $remaining <= 0;

            alarm( int($remaining) + 1 );    # guard a wedged FUSE mkdir
            $got_lock = mkdir($lockpath);    # atomic on pmxcfs
            alarm(0);

            if ($got_lock) {
                $lock->{owned} = 1;    # ownership recorded at the syscall's
                last;                  # success — see _lock_acquire
            }

            OpenEJovianDSS::Common::debugmsg($ctx, 'debug',
                "waiting for joviandss lock '$lockid'");

            utime(0, 0, $lockpath);          # signal pmxcfs to release a stale lock
            refresh_locks($ctx, $lockpath);  # keep our held outer locks alive

            # Deadline-aware pacing, jittered in EVERY case so contending
            # nodes never poll in lockstep. Far from the deadline: linear
            # backoff with a fixed jitter bound (desynchronises a long wait).
            # Inside the final window: HALVE the interval each iteration down
            # to the floor, with a jitter proportional to the (shrinking)
            # interval, converging on aggressive polling that grabs the lock
            # the instant it frees.
            if ( $remaining
                <= OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_FINAL_WINDOW() )
            {
                Time::HiRes::sleep( $base );
                $base = $base / 2;
                $base = OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_FINAL_SLEEP()
                    if $base < OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_FINAL_SLEEP();
            }
            else {
                Time::HiRes::sleep(
                    $base + rand(OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_JITTER_MAX()) );
                $base += OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_BACKOFF_STEP();
                $base  = OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_SLEEP_CAP()
                    if $base > OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_SLEEP_CAP();
            }
        }

        PVE::Cluster::cfs_update();          # fresh cluster view for the body
        1;
    };
    my $err = $@;
    alarm(0);
    alarm($prev_alarm) if $prev_alarm;       # wait over — enclosing alarm resumes

    if (!$ok) {
        if (!$got_lock) {
            # Never acquired: distinguish quorum loss from plain contention.
            # Ref: PVE::Cluster::check_cfs_quorum (pve-cluster/src/PVE/Cluster.pm:116)
            my $st = File::stat::lstat("/etc/pve/local");
            $err = "no quorum!\n" if !($st && (($st->mode & 0200) != 0));
        }
        # else: cfs_update died AFTER mkdir — owned is already set, so the
        # sequencer's unconditional _lock_divest releases the dir; no local
        # rollback needed.
        #
        # PVE::Exception objects re-raised as-is (mirrors $cfs_lock,
        # pve-cluster/src/PVE/Cluster.pm:662); plain machinery errors are
        # prefixed.
        die ref($err) ? $err : "joviandss-lock '$lockid' error: $err";
    }
    return;
}

# Node backend: exclusive flock, taken directly (decision 2026-07-05:
# PVE::Tools::lock_file is a run-callback wrapper and cannot express a
# separable acquire; its per-PID re-entry counter is unreachable behind our
# guard, and its internal 10 s timeout default is unreachable behind
# with_lock's per-class resolution). run_with_timeout still bounds the wait.
#
# The error wording KEEPS the exact lock_file shape — "can't lock file
# '<path>' - got timeout" — so lock_error_acquire's pattern is unchanged and
# node-lock contention stays in joviandss_cmd's timeout-retry class; the
# string is now OURS, no longer PVE wording we merely depend on.
sub _lock_acquire_node {
    my ($ctx, $lock) = @_;

    my $lockpath = $lock->{path};
    make_path( File::Basename::dirname($lockpath) );   # <path>/private/lock may not exist yet

    open( my $fh, '>>', $lockpath )
        or die "joviandss-lock error: can't open lock file '$lockpath' - $!\n";

    my $ok = eval {
        PVE::Tools::run_with_timeout( $lock->{acquire_timeout},
            sub { flock( $fh, LOCK_EX ) or die "flock failed - $!\n" } );
        1;
    };
    if (!$ok) {
        my $err = $@;
        close($fh);
        die "can't lock file '$lockpath' - $err";
    }

    $lock->{fh}    = $fh;    # parked in the record; _lock_divest closes it
    $lock->{owned} = 1;      # ownership recorded at the flock's success
    return;
}

# _lock_divest($ctx, $lock_id) — end exclusive ownership. NEVER dies (it
# runs on unwind paths where a die would mask the original error): failures
# are warned and the artifact is left to the backend's own recovery — a
# leftover pmxcfs dir is stale-reclaimed via waiters' utime(0,0) pokes, a
# leaked fd is dropped by the kernel on process exit. Idempotent via the
# record's owned flag.
sub _lock_divest {
    my ($ctx, $lock_id) = @_;

    my $lock = _lock_record($ctx, $lock_id) or return;
    return if !$lock->{owned};

    if ($lock->{backend} eq 'cluster') {
        # Bounded rmdir: a wedged FUSE call must not hang the unwind at
        # exactly the moment things are already failing.
        my $prev = alarm(0);
        my $ok = eval {
            local $SIG{ALRM} = sub { die "got timeout\n" };
            alarm( LOCK_DIVEST_GUARD_TIMEOUT );
            rmdir $lock->{path};
            alarm(0);
            1;
        };
        alarm(0);
        alarm($prev) if $prev;
        eval { OpenEJovianDSS::Common::debugmsg($ctx, 'warning',
            "rmdir of lock '$lock->{path}' failed — left for stale reclaim") }
            if !$ok || -d $lock->{path};
    }
    else {
        close( $lock->{fh} ) if $lock->{fh};    # kernel drops the flock
        $lock->{fh} = undef;
    }

    $lock->{owned}    = 0;
    $lock->{deadline} = undef;    # the hold clock ends with ownership
    return;
}

# ---------------------------------------------------------------------------
# The explicit-path lock primitive — the phase sequencer
# ---------------------------------------------------------------------------

# _lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param)
# Exclusive only. Two nested brackets, each with a single owner: OUTER
# bookkeeping (commission → decommission, the latter a never-dying finalizer
# that runs on every path) and INNER ownership (acquire → divest — divest
# runs explicitly for both anticipated outcomes, success and body death, so
# the finalizer's divest branch stays a pure anomaly tripwire). All timing
# policy is frozen into the registry record at commission; every later phase
# reads the record and is never handed a number.
sub _lock_exec {
    my ($ctx, $backend, $path, $timeout, $max_hold, $code, @param) = @_;

    # registry + re-entry guard; commissioned = registered, NOT owned
    my $lock_id = _lock_ctx_commission($ctx, $backend, $path, $timeout, $max_hold);

    my $res;
    my $ok = eval {
        # blocks per the record; dies on failure; the backend flips owned=1
        # at the instant of mkdir/flock success, so ANY later die in this
        # eval — the id cross-check, a signal landing between acquire and
        # run_bounded's alarm suspension, cfs_update, the body, a hold-cap
        # death — routes through the one divest below
        my $lock_id_acquired = _lock_acquire($ctx, $lock_id);
        Carp::confess( "LOCK BUG: acquired '" . ( $lock_id_acquired // 'undef' )
                     . "' != commissioned '$lock_id'" )
            if !defined($lock_id_acquired) || $lock_id_acquired ne $lock_id;

        $res = run_bounded($ctx, $lock_id,
                 sub { run_refreshed($ctx, $code, @param) });
        1;
    };
    my $err = $@;                        # capture BEFORE divest can clobber $@

    # Unconditional: the ONE release site for every outcome. The owned-guard
    # inside is load-bearing — after a failed acquisition it is a no-op, and
    # it must be (the lock dir/flock belongs to the CURRENT holder).
    _lock_divest($ctx, $lock_id);

    _lock_ctx_decommission($ctx, $lock_id);   # FINALIZER — never dies; a
                                              # divest in there means an
                                              # impossible path executed

    die $err if !$ok;
    return $res;    # single scalar/ref — see the design's Return convention
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# with_lock($ctx, $lock_class, $id, $timeout, $code, @param)
#   $lock_class  the lock class: 'jdssc_general' | 'jdssc_info' | 'multipath' |
#                'vm' | 'storage'
#   $id          sub-key within the class (the vmid for 'vm'); undef for
#                singleton classes ('storage' is keyed by $ctx->{storeid})
#   $timeout     seconds to wait for acquisition, or undef →
#                <lock_class>_lock_acquire_timeout → per-class default
#   $code        coderef run while the lock is held (every held lock is
#                auto-refreshed around it — the caller never refreshes manually)
#   @param       trailing args forwarded to $code
#
# All locks are exclusive. Returns the result of $code; dies on failure
# (acquisition or $code). The lock is always released before an error
# propagates.
sub with_lock {
    my ($ctx, $lock_class, $id, $timeout, $code, @param) = @_;

    die "unknown lock class '$lock_class'\n"    # fail loud — the maps have no fallbacks
        if !exists LOCK_DEFAULT_TYPE->{$lock_class};

    my $type     = get_lock_class_type($ctx, $lock_class);              # scope
    $timeout   //= get_lock_class_acquire_timeout($ctx, $lock_class);   # wait-to-acquire
    my $max_hold = get_lock_class_hold_timeout($ctx, $lock_class);      # hold cap (alarm + deadline)
    my ($backend, $path) = _lock_resolve($ctx, $type, $lock_class, $id);
    return _lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param);
}

1;
