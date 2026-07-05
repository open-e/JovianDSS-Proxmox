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

use File::Basename ();
use File::Path     qw(make_path);
use File::stat     ();
use Time::HiRes    ();
use PVE::Cluster   ();
use PVE::Tools     qw(lock_file);

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
use constant LOCK_CLASS_JDSSC_GENERAL_ACQUIRE_TIMEOUT => 600;    # = PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX
use constant LOCK_CLASS_JDSSC_INFO_ACQUIRE_TIMEOUT    => 10;
# Raised from 10 with the volume-activation design: a waiter must outlast one
# full worst-case command hold (MULTIPATH_CMD_TIMEOUT_MAX + KILL_GRACE +
# BACKSTOP_MARGIN = 40 s ladder) with real headroom; a deeper queue can still
# time a waiter out — that is the reactivation cycle's contention class
# (lock_error_acquire), retried without teardown.
use constant LOCK_CLASS_MULTIPATH_ACQUIRE_TIMEOUT     => 60;
use constant LOCK_CLASS_VM_ACQUIRE_TIMEOUT            => 600;
use constant LOCK_CLASS_STORAGE_ACQUIRE_TIMEOUT       => 600;

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
use constant LOCK_CLASS_VM_HOLD_TIMEOUT            => 1320;
use constant LOCK_CLASS_STORAGE_HOLD_TIMEOUT       => 1320;

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
# SUBSTRING match, so outer error prefixing (e.g. _cluster_lock_attempt's
# machinery prefix) survives. Any future must-not-swallow lock error joins by
# adopting the prefix.
use constant LOCK_FATAL_ERROR_MARKER => 'joviandss-lock-fatal:';

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
# Held-lock registry: re-entry guard, keep-alive refresh, hold deadline
# ---------------------------------------------------------------------------
#
# $ctx->{_held_locks} is initialized to [] in Common::new_ctx. Records are
# added by _lock_enter BEFORE acquisition (the cluster poll loop needs the
# in-flight target registered) and removed BY PATH by _lock_leave — never a
# LIFO pop.

sub _lock_enter {
    my ($ctx, $backend, $path) = @_;

    for my $lock (@{ $ctx->{_held_locks} }) {
        next if $lock->{path} ne $path;
        Carp::confess(
            "LOCK BUG: '$path' is already held — re-locking it is forbidden and "
          . "would deadlock; this must never happen, please report it to the dev "
          . "team.\n\n=== held since ===\n$lock->{acquired_at}\n"
          . "=== re-lock attempted here ===" );    # confess appends the current stack
    }

    push @{ $ctx->{_held_locks} },
        { backend     => $backend,
          path        => $path,
          acquired_at => Carp::longmess("acquired '$path'"),
          deadline    => undef };    # armed at acquisition by _lock_arm_deadline
}

sub _lock_leave {
    my ($ctx, $path) = @_;

    @{ $ctx->{_held_locks} } = grep { $_->{path} ne $path } @{ $ctx->{_held_locks} };
}

# Arm the wall-clock hold deadline for a registered lock. Called at the top of
# the locked body — the lock is held at that point, so this marks the start of
# the hold. Never call it from _lock_enter: that precedes the acquisition wait,
# and a contended cluster acquisition (whose acquire bound far exceeds its hold
# cap) would die on its first refresh.
sub _lock_arm_deadline {
    my ($ctx, $path, $max_hold) = @_;

    return if !$max_hold;

    for my $lock (@{ $ctx->{_held_locks} }) {
        next if $lock->{path} ne $path;
        $lock->{deadline} = time() + $max_hold;
        last;
    }
}

# Backend-agnostic keep-alive AND wall-clock hold-cap enforcement — called by
# run_refreshed around every locked body and by the cluster poll loop each
# iteration. $skip_path is a lock being acquired right now: it is skipped so
# the acquisition's utime(0,0) stale-poke is not overwritten with a fresh
# mtime (and it has no deadline yet).
sub refresh_locks {
    my ($ctx, $skip_path) = @_;

    for my $lock (@{ $ctx->{_held_locks} }) {
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
}

# Exception-safe refresh bracket around a locked body: the post-refresh runs
# even if the body dies, so a held lock is never left un-refreshed right before
# a retry sleep. Returns a single scalar/ref — see the design's Return
# convention (lock_file runs $code in scalar context; never wantarray here).
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

# run_bounded($max_hold, $code, @param) — pure-Perl-hang backstop: run the held
# body under a hold alarm. Overrun → die → lock releases on unwind. $max_hold
# 0/undef → no cap. Outer alarm saved/restored. Nested alarm users
# (run_command, lock_file waits) suspend this alarm — the wall-clock hold bound
# is the deadline check in refresh_locks, not this. Deliberately NO kill here:
# this wrapper owns no process (a runaway jdssc is killed by run_command's own
# timeout); its enforcement is the die, whose unwind is what releases the lock.
sub run_bounded {
    my ($max_hold, $code, @param) = @_;

    return $code->(@param) unless $max_hold;

    my $prev = alarm(0);                 # suspend any outer alarm
    my $res;
    my $ok = eval {
        local $SIG{ALRM} =
            sub { die LOCK_FATAL_ERROR_MARKER
                    . " lock hold exceeded ${max_hold}s — aborting to release the lock\n" };
        alarm($max_hold);
        $res = $code->(@param);
        alarm(0);
        1;
    };
    my $err = $@;
    alarm(0);
    alarm($prev) if $prev;               # restore outer alarm (best-effort)
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
# Three shapes escape to callers:
#   - "got lock request timeout"  — cluster backend, acquire budget spent
#     (_cluster_lock_path's final error; its internal "acquire timeout" is
#     normally consumed by the retry loop)
#   - "acquire timeout"           — cluster backend, single-attempt form
#   - "can't lock file '...' - got timeout" — node backend (PVE::Tools::
#     lock_file flock wait); the "can't lock file" prefix is REQUIRED here:
#     a bare "got timeout" is run_command's process-timeout die and must
#     never classify as lock contention.
sub lock_error_acquire {
    my ($err) = @_;

    return 0 if !defined $err;
    return 1 if $err =~ /got lock request timeout/;
    return 1 if $err =~ /acquire timeout/;
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
# Cluster-wide lock — single acquisition attempt  (pmxcfs atomic mkdir)
# ---------------------------------------------------------------------------
#
# Modelled on the private $cfs_lock closure in PVE::Cluster
# (pve-cluster/src/PVE/Cluster.pm:601) with these differences:
#
#   1. Retry-friendly acquisition error string ("acquire timeout") so that
#      _cluster_lock_path can detect and retry acquisition-only failures.
#
#   2. Quorum check on lock failure: if the lock was never acquired, test
#      the write bit on /etc/pve/local (pmxcfs clears it on quorum loss)
#      and replace the generic timeout with "no quorum!\n".
#
#   3. $is_code_err flag: set to 1 after cfs_update() and before $code so
#      that errors from $code are re-raised as-is while lock-machinery errors
#      (including cfs_update failures) are prefixed with
#      "joviandss-lock '$lockid' error: ...".
#
#   4. Deadline-based acquisition accounting: any inter-poll sleep — fixed,
#      backed-off or jittered — charges itself against the budget (no
#      per-sleep bookkeeping).
#
#   5. Poll backoff + jitter, driven by the PROXMOX_CLUSTER_POLL_* constants:
#      contending nodes spread out instead of polling in lockstep, and a
#      long-held lock backs the loop off toward the cap.
#
#   6. Each iteration refreshes every OTHER lock this $ctx already holds
#      (refresh_locks with the in-flight target skipped), so queueing behind a
#      contended lock never lets an already-held outer lock be stale-reclaimed
#      while its owner is alive.
#
#   7. NO internal execution alarm around $code: the per-class hold cap
#      (run_bounded + the refresh_locks deadline, with the cluster-backend
#      alarm ceiling applied in _lock_exec) supersedes the old hardcoded 119 s
#      alarm.
#
#   8. NO registry bookkeeping here: _lock_enter/_lock_leave in _lock_exec own
#      $ctx->{_held_locks} (registered before acquisition, removed by path).
#
# Returns result of $code on success ($@ = undef).
# Returns undef and sets $@ on any failure.

sub _cluster_lock_attempt {
    my ($ctx, $lockdir, $lockpath, $lockid, $timeout, $code, @param) = @_;

    my $prev_alarm  = alarm(0);    # suspend any outer alarm
    my $got_lock    = 0;
    my $is_code_err = 0;
    my $res;

    eval {
        make_path($lockdir);
        die "pve cluster filesystem not online\n" if !-d $lockdir;

        my $timeout_err = sub { die "acquire timeout\n" };
        local $SIG{ALRM} = $timeout_err;

        my $deadline = time() + $timeout;
        my $base     = OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_BASE_SLEEP();

        while (1) {
            my $remaining = $deadline - time();
            $timeout_err->() if $remaining <= 0;

            alarm( int($remaining) + 1 );    # guard a wedged FUSE mkdir
            $got_lock = mkdir($lockpath);    # atomic on pmxcfs
            alarm(0);

            last if $got_lock;

            OpenEJovianDSS::Common::debugmsg($ctx, 'debug',
                "waiting for joviandss lock '$lockid'");

            utime(0, 0, $lockpath);          # signal pmxcfs to release a stale lock
            refresh_locks($ctx, $lockpath);  # keep our held outer locks alive

            Time::HiRes::sleep(
                $base + rand(OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_JITTER_MAX()) );
            $base += OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_BACKOFF_STEP();
            $base  = OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_SLEEP_CAP()
                if $base > OpenEJovianDSS::Common::PROXMOX_CLUSTER_POLL_SLEEP_CAP();
        }

        PVE::Cluster::cfs_update();          # ensure latest cluster state

        $is_code_err = 1;                    # errors from here on are from $code
        $res = &$code(@param);
    };

    my $err = $@;

    # If we never got the lock, check whether quorum was lost.
    # pmxcfs clears the write bit on /etc/pve/local when quorum is lost.
    # Ref: PVE::Cluster::check_cfs_quorum (pve-cluster/src/PVE/Cluster.pm:116)
    if (!$got_lock) {
        my $st = File::stat::lstat("/etc/pve/local");
        my $quorate = ($st && (($st->mode & 0200) != 0));
        $err = "no quorum!\n" if !$quorate;
    }

    rmdir $lockpath if $got_lock;            # release lock; safe even on error
    alarm($prev_alarm);                      # restore outer alarm

    if ($err) {
        # Code errors are re-raised as-is; lock machinery errors are prefixed.
        # Mirrors $cfs_lock error handling (pve-cluster/src/PVE/Cluster.pm:662).
        if (ref($err) eq 'PVE::Exception' || $is_code_err) {
            $@ = $err;
        } else {
            $@ = "joviandss-lock '$lockid' error: $err";
        }
        return undef;
    }

    $@ = undef;
    return $res;
}

# ---------------------------------------------------------------------------
# Cluster-wide lock — acquisition-timeout retry wrapper
# ---------------------------------------------------------------------------
#
# Retries _cluster_lock_attempt on acquisition timeout only (safe: the lock was
# never acquired and no code ran) until the acquire budget is spent, then gives
# up with "got lock request timeout". Keeps _cluster_lock_attempt's convention:
# returns the result of $code on success ($@ = undef), returns undef and sets
# $@ on any failure — _lock_exec converts that to a die.

sub _cluster_lock_path {
    my ($ctx, $lockpath, $timeout, $code, @param) = @_;

    my $lockdir = File::Basename::dirname($lockpath);
    my $lockid  = File::Basename::basename($lockpath);

    my $deadline = time() + $timeout;

    while (1) {
        my $remaining = $deadline - time();
        if ($remaining <= 0) {
            $@ = "joviandss-lock '$lockid' error: got lock request timeout\n";
            return undef;
        }

        my $res = _cluster_lock_attempt($ctx, $lockdir, $lockpath, $lockid,
                                        $remaining, $code, @param);

        # Success: $@ is undef (set by _cluster_lock_attempt on success).
        return $res if !$@;

        # Acquisition timeout → retry while budget remains. Anything else
        # (code error, quorum loss, hold-cap death) → propagate immediately.
        return undef if $@ !~ /acquire timeout/;
    }
}

# ---------------------------------------------------------------------------
# The explicit-path lock primitive
# ---------------------------------------------------------------------------

# _lock_exec($ctx, $backend, $path, $timeout, $max_hold, $code, @param)
# Exclusive only. Dispatches by backend, brackets the work with the re-entry
# guard, arms the hold deadline at the top of the locked body, and wraps the
# body in run_bounded + run_refreshed — so with_lock auto-caps and
# auto-refreshes; callers never do either manually.
sub _lock_exec {
    my ($ctx, $backend, $path, $timeout, $max_hold, $code, @param) = @_;

    _lock_enter($ctx, $backend, $path);    # re-entry guard + register in _held_locks

    # Cluster-backend alarm ceiling: a wedged pure-Perl holder reaches no
    # cooperation point, so only the alarm can stop it — and on pmxcfs it must
    # die BEFORE a waiter could stale-reclaim at CFS_LOCK_TIMEOUT. The constant
    # is the ceiling; it applies even when the class cap is 0 (a
    # backend-correctness invariant, not a class property). The wall-clock
    # deadline keeps the full class cap.
    my $alarm_cap = $max_hold;
    if ( $backend eq 'cluster' ) {
        my $ceiling = OpenEJovianDSS::Common::PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX();
        if ( !$alarm_cap || $alarm_cap > $ceiling ) {
            $alarm_cap = $ceiling;
        }
    }
    my $body = sub {
        _lock_arm_deadline($ctx, $path, $max_hold);
        return run_bounded($alarm_cap, sub { run_refreshed($ctx, $code, @param) });
    };

    my $res;
    my $ok = eval {
        if ($backend eq 'cluster') {
            $res = _cluster_lock_path($ctx, $path, $timeout, $body);
            die $@ if $@;   # _cluster_lock_path signals failure via undef + $@
        } else { # node
            $timeout ||= 10;   # last-resort fallback; per-class default already applied in with_lock
            make_path( File::Basename::dirname($path) );   # <path>/private/lock may not exist yet
            $res = PVE::Tools::lock_file($path, $timeout, $body);    # flock LOCK_EX
            die $@ if $@;   # lock_file signals acquisition failure / $code die via $@, not by dying
        }
        1;
    };
    my $err = $@;
    _lock_leave($ctx, $path);              # unregister (backend has already released)
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
