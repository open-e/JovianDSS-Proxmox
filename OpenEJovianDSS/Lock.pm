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

use strict;
use warnings;

use Exporter 'import';

use File::Path  qw(make_path);
use File::stat  ();
use PVE::Cluster ();
use PVE::Tools  qw(lock_file);

our @EXPORT_OK = qw(
    lock_storage
    lock_vm
);

our %EXPORT_TAGS = ( all => [@EXPORT_OK] );

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

# Cluster-wide lock root: one directory per storage instance.
# Lock entries are subdirectories created atomically via mkdir on pmxcfs.
sub _cluster_lockdir {
    my ($storeid) = @_;
    return "/etc/pve/priv/storage/joviandss/${storeid}/locks";
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

# Replace characters that are not safe in a filename/lockid with '_'.
sub _sanitize_lockid {
    my ($s) = @_;
    $s =~ s/[^a-zA-Z0-9\-_]/_/g;
    return $s;
}

# ---------------------------------------------------------------------------
# Cluster-wide lock — single acquisition attempt  (pmxcfs atomic mkdir)
# ---------------------------------------------------------------------------
#
# Modelled on the private $cfs_lock closure in PVE::Cluster
# (pve-cluster/src/PVE/Cluster.pm:601) with three additions:
#
#   1. Retry-friendly acquisition error string ("acquire timeout") so that
#      _cluster_lock can detect and retry acquisition-only failures.
#
#   2. Quorum check on lock failure: if the lock was never acquired, test
#      the write bit on /etc/pve/local (pmxcfs clears it on quorum loss)
#      and replace the generic timeout with "no quorum!\n".
#
#   3. $is_code_err flag: set to 1 after cfs_update() and before $code so
#      that errors from $code are re-raised as-is while lock-machinery errors
#      (including cfs_update failures and execution timeout) are prefixed with
#      "joviandss-lock '$lockid' error: ...".
#
# The execution alarm is set to 60s — safely within pmxcfs's ~120s stale-lock
# release window, matching the PVE::Cluster convention.
#
# Returns result of $code on success ($@ = undef).
# Returns undef and sets $@ on any failure.

sub _cluster_lock_attempt {
    my ($lockdir, $lockpath, $lockid, $timeout, $code, @param) = @_;

    my $prev_alarm  = alarm(0);    # suspend any outer alarm
    my $got_lock    = 0;
    my $is_code_err = 0;
    my $res;

    eval {
        make_path($lockdir);
        die "pve cluster filesystem not online\n" if !-d $lockdir;

        my $timeout_err = sub { die "acquire timeout\n" };
        local $SIG{ALRM} = $timeout_err;

        while (1) {
            alarm($timeout);
            $got_lock = mkdir($lockpath);    # atomic on pmxcfs
            $timeout  = alarm(0) - 1;       # deduct elapsed; sleep costs 1s

            last if $got_lock;

            $timeout_err->() if $timeout <= 0;

            print STDERR "waiting for joviandss lock '$lockid' ...\n";
            utime(0, 0, $lockpath);          # signal pmxcfs to release stale lock
            sleep(1);
        }

        # Hard execution timeout: pmxcfs drops locks not touched for ~120s.
        # We use 60s to stay safely within that window (matching PVE::Cluster).
        # $is_code_err is set after cfs_update() so that a cfs_update timeout
        # is classified as a lock-machinery error (prefixed), not a code error.
        local $SIG{ALRM} = sub { die "execution timed out\n" };
        alarm(60);

        PVE::Cluster::cfs_update();          # ensure latest cluster state

        $is_code_err = 1;                    # errors from here on are from $code
        $res = &$code(@param);

        alarm(0);
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
# Cluster-wide lock — retry loop
# ---------------------------------------------------------------------------
#
# Wraps _cluster_lock_attempt with a retry strategy suited to JovianDSS
# operations, which can hold a lock for 30-90s under concurrent load.
#
# If $timeout is defined:  single attempt with that timeout, no retry.
# If $timeout is undef:    retry loop — up to 600s total, 120s per attempt,
#                          retrying only on acquisition timeout (safe to retry
#                          because the lock was never acquired and no code ran).
#
# Returns result of $code on success; returns undef and sets $@ on failure.

sub _cluster_lock {
    my ($storeid, $lockid, $timeout, $code, @param) = @_;

    my $lockdir  = _cluster_lockdir($storeid);
    my $lockpath = "$lockdir/$lockid";

    my $explicit    = defined $timeout;
    my $max_total   = 600;
    my $per_attempt = 120;
    my $start       = time();

    while (1) {
        my $attempt;
        if ($explicit) {
            $attempt = $timeout;
        } else {
            my $remaining = $max_total - (time() - $start);
            if ($remaining <= 10) {
                $@ = "joviandss-lock '$lockid' error: got lock request timeout\n";
                return undef;
            }
            $attempt = ($per_attempt < $remaining) ? $per_attempt : int($remaining);
        }

        my $res = _cluster_lock_attempt($lockdir, $lockpath, $lockid, $attempt, $code, @param);

        # Success: $@ is undef (set by _cluster_lock_attempt on success).
        return $res if !$@;

        my $err = $@;

        # Acquisition timeout without explicit deadline → safe to retry.
        # Matches "joviandss-lock '...' error: acquire timeout\n" from _cluster_lock_attempt.
        next if !$explicit && $err =~ /acquire timeout/;

        # Anything else (code error, execution timeout, quorum loss,
        # explicit-deadline expiry) → propagate immediately.
        return undef;
    }
}

# ---------------------------------------------------------------------------
# Node-local lock  (POSIX flock)
# ---------------------------------------------------------------------------
#
# Uses PVE::Tools::lock_file which holds an exclusive flock on a file under
# <path>/private/lock/.  Suitable for non-shared storage where all operations
# on a given storage happen on a single Proxmox node.
#
# Re-entrant within the same process: PVE::Tools::lock_file_full tracks open
# handles per PID in $lock_handles->{$$} and skips re-acquisition if the same
# file is already locked by the current process.
#
# $timeout defaults to 600s (not PVE::Tools' 10s default) because JovianDSS
# operations can hold the lock for 30-90s under concurrent load.

sub _node_lock {
    my ($path, $lockid, $timeout, $code, @param) = @_;

    # Substitute a large default; PVE::Tools' 10s default is too short for
    # JovianDSS operations that can legitimately take 30-90s under load.
    $timeout //= 600;

    my $lockdir  = "$path/private/lock";
    make_path($lockdir);

    my $lockfile = "$lockdir/$lockid";

    my $res = PVE::Tools::lock_file($lockfile, $timeout, $code, @param);
    return undef if $@;    # $@ set by lock_file; caller must die $@ if $@
    return $res;
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# lock_storage($storeid, $path, $shared, $timeout, $code, @param)
#
# Storage-level lock — serializes all operations on a given storage instance.
# Used as a fallback for methods not covered by lock_vm.
#
# $storeid — storage id (scopes the cluster lock directory)
# $path    — value of the `path` property from storage.cfg (e.g. /mnt/pve/jdss-Pool-2);
#            used as root for node-local lock files
# $shared  — true → cluster-wide pmxcfs mkdir lock; false → node-local flock
# $timeout — cluster: undef = retry loop up to 600s; defined = single attempt.
#            node-local: undef = 600s default; defined = that many seconds.
#
# Lock path (cluster): /etc/pve/priv/storage/joviandss/<storeid>/locks/storage
# Lock path (node):    <path>/private/lock/storage

sub lock_storage {
    my ($storeid, $path, $shared, $timeout, $code, @param) = @_;

    my $lockid = "storage";

    if ($shared) {
        return _cluster_lock($storeid, $lockid, $timeout, $code, @param);
    }
    return _node_lock($path, $lockid, $timeout, $code, @param);
}

# lock_vm($storeid, $path, $shared, $vmid, $timeout, $code, @param)
#
# Per-VM lock — serializes operations that target the same VM's volumes.
# Concurrent operations for different VMIDs proceed independently.
#
# Lock path (cluster): /etc/pve/priv/storage/joviandss/<storeid>/locks/vm-<vmid>
# Lock path (node):    <path>/private/lock/vm-<vmid>

sub lock_vm {
    my ($storeid, $path, $shared, $vmid, $timeout, $code, @param) = @_;

    my $lockid = "vm-" . _sanitize_lockid($vmid);

    if ($shared) {
        return _cluster_lock($storeid, $lockid, $timeout, $code, @param);
    }
    return _node_lock($path, $lockid, $timeout, $code, @param);
}

1;
