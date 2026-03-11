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

use File::Path qw(make_path);
use PadWalker  qw(peek_sub);
use PVE::Cluster ();
use PVE::Tools qw(lock_file);

our @EXPORT_OK = qw(
    cluster_lock
    lock_storage
    lock_vm
    lock_volume
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

# Node-local lock root: standard Proxmox lock directory.
sub _node_lockdir { return "/var/lock/pve-manager" }

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
# Cluster-wide lock  (pmxcfs atomic mkdir)
# ---------------------------------------------------------------------------
#
# Replicates the private $cfs_lock closure from PVE::Cluster using a
# plugin-specific directory instead of /etc/pve/priv/lock/.
#
# The pmxcfs filesystem guarantees that mkdir(2) is atomic across all cluster
# nodes — the same primitive used by every PVE::Cluster::cfs_lock_* function.
#
# pmxcfs automatically releases lock directories that have not been touched
# for ~120s.  We therefore impose a 60s execution timeout after acquiring the
# lock, matching the PVE::Cluster convention, to stay safely within that
# window and leave room to abort the task.
#
# Args:
#   $storeid  — storage id (used to scope the lock directory)
#   $lockid   — unique lock name within this storage (safe filename component)
#   $timeout  — seconds to wait for lock acquisition (default 30)
#   $code     — code ref to execute while holding the lock
#   @param    — extra arguments forwarded to $code

sub _cluster_lock {
    my ($storeid, $lockid, $timeout, $code, @param) = @_;

    $timeout //= 30;

    my $lockdir  = _cluster_lockdir($storeid);
    my $lockpath = "$lockdir/$lockid";

    my $prev_alarm = alarm(0);    # suspend any outer alarm
    my $got_lock   = 0;
    my $res;

    eval {
        make_path($lockdir);      # idempotent; creates intermediate dirs too
        die "pve cluster filesystem not online\n" if !-d $lockdir;

        my $timeout_err = sub { die "joviandss lock '$lockid' acquire timeout\n" };
        local $SIG{ALRM} = $timeout_err;

        while (1) {
            alarm($timeout);
            $got_lock = mkdir($lockpath);  # atomic on pmxcfs
            $timeout  = alarm(0) - 1;     # account for 1s sleep below

            last if $got_lock;

            $timeout_err->() if $timeout <= 0;

            print STDERR "waiting for joviandss lock '$lockid' ...\n";
            utime(0, 0, $lockpath);        # tell pmxcfs to release stale lock
            sleep(1);
        }

        # Hard execution timeout: must complete before pmxcfs drops the lock.
        local $SIG{ALRM} = sub {
            die "joviandss lock '$lockid' execution timed out\n";
        };
        alarm(60);

        # Ensure we see the latest cluster state before doing any work.
        PVE::Cluster::cfs_update();

        $res = &$code(@param);

        alarm(0);
    };

    my $err = $@;
    rmdir $lockpath if $got_lock;  # release lock; safe even on error
    alarm($prev_alarm);            # restore outer alarm
    die $err if $err;
    return $res;
}

# ---------------------------------------------------------------------------
# Node-local lock  (POSIX flock)
# ---------------------------------------------------------------------------
#
# Uses PVE::Tools::lock_file which holds an exclusive flock on a file in
# /var/lock/pve-manager/.  Suitable for non-shared storage where all
# operations on a given storage happen on a single Proxmox node.
#
# The lock is re-entrant within the same process (PVE::Tools tracks handles
# per PID).
#
# Args: same as _cluster_lock

sub _node_lock {
    my ($storeid, $lockid, $timeout, $code, @param) = @_;

    my $lockdir  = _node_lockdir();
    mkdir $lockdir;    # ensure dir exists; ignore error if already present

    my $lockfile = "$lockdir/joviandss-${storeid}-${lockid}";

    my $res = PVE::Tools::lock_file($lockfile, $timeout, $code, @param);
    die $@ if $@;
    return $res;
}

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

# lock_storage($storeid, $shared, $timeout, $code, @param)
#
# Storage-level lock — serializes all operations on a given storage instance.
# Direct replacement for cluster_lock_storage in storage plugins.
#
# Uses cluster-wide locking when $shared is true, node-local flock otherwise.
#
# Lock granularity: per storage  →  storage
# Lock path (cluster): /etc/pve/priv/storage/joviandss/<storeid>/locks/storage
# Lock path (node):    /var/lock/pve-manager/joviandss-<storeid>-storage

sub lock_storage {
    my ($storeid, $shared, $timeout, $code, @param) = @_;

    my $lockid = "storage";

    if ($shared) {
        return _cluster_lock($storeid, $lockid, $timeout, $code, @param);
    }
    return _node_lock($storeid, $lockid, $timeout, $code, @param);
}

# lock_vm($storeid, $shared, $vmid, $timeout, $code, @param)
#
# Serializes operations that target the same VM's volumes on a given storage.
# Concurrent operations for different VMIDs proceed independently.
#
# Uses cluster-wide locking when $shared is true (storage accessible from
# multiple nodes), node-local flock otherwise.
#
# Lock granularity: per VM  →  vm-<vmid>
# Lock path (cluster): /etc/pve/priv/storage/joviandss/<storeid>/locks/vm-<vmid>
# Lock path (node):    /var/lock/pve-manager/joviandss-<storeid>-vm-<vmid>

sub lock_vm {
    my ($storeid, $shared, $vmid, $timeout, $code, @param) = @_;

    my $lockid = "vm-" . _sanitize_lockid($vmid);

    if ($shared) {
        return _cluster_lock($storeid, $lockid, $timeout, $code, @param);
    }
    return _node_lock($storeid, $lockid, $timeout, $code, @param);
}

# lock_volume($storeid, $shared, $volname, $timeout, $code, @param)
#
# Serializes operations on a specific volume (activate/deactivate, resize,
# snapshot, etc.).  Concurrent operations on different volumes proceed
# independently.
#
# Uses cluster-wide locking when $shared is true, node-local flock otherwise.
#
# Lock granularity: per volume  →  vol-<sanitized_volname>
# Lock path (cluster): /etc/pve/priv/storage/joviandss/<storeid>/locks/vol-<volname>
# Lock path (node):    /var/lock/pve-manager/joviandss-<storeid>-vol-<volname>

sub lock_volume {
    my ($storeid, $shared, $volname, $timeout, $code, @param) = @_;

    my $lockid = "vol-" . _sanitize_lockid($volname);

    if ($shared) {
        return _cluster_lock($storeid, $lockid, $timeout, $code, @param);
    }
    return _node_lock($storeid, $lockid, $timeout, $code, @param);
}

# ---------------------------------------------------------------------------
# Dispatch table for cluster_lock
# ---------------------------------------------------------------------------
#
# Maps PVE::Storage calling function name → lock type and which closure
# variable holds the lock key.
#
# 'var'          — name of the variable captured by the PVE::Storage closure
# 'type'         — 'vm' or 'volume'
# 'from_volname' — if true, extract vmid from the volname variable via regex
#                  instead of using the variable value directly as the key

my %_DISPATCH = (
    vdisk_alloc       => { type => 'vm',     var => '$vmid'        },
    vdisk_free        => { type => 'vm',     var => '$volname',    from_volname => 1 },
    vdisk_clone       => { type => 'vm',     var => '$vmid'        },
    vdisk_create_base => { type => 'vm',     var => '$volname',    from_volname => 1 },
    rename_volume     => { type => 'vm',     var => '$target_vmid' },
    rename_snapshot   => { type => 'volume', var => '$volname'     },
);

# Extract vmid from a standard Proxmox volume name.
# Handles: vm-<N>-disk-*, base-<N>-disk-*, subvol-<N>-*
sub _vmid_from_volname {
    my ($volname) = @_;
    my ($vmid) = $volname =~ /^(?:vm|base|subvol)-(\d+)-/;
    return $vmid;
}

# cluster_lock($storeid, $shared, $timeout, $caller, $func, @param)
#
# Smart dispatch: uses the PVE::Storage caller function name and PadWalker
# to determine per-VM or per-volume lock granularity, falling back to
# storage-level lock for unknown callers.
#
# $caller — bare PVE::Storage function name (e.g. "vdisk_alloc"), extracted
#            by the plugin's cluster_lock_storage via caller(1).
# $func   — the anonymous closure passed to cluster_lock_storage.

sub cluster_lock {
    my ($storeid, $shared, $timeout, $caller, $func, @param) = @_;

    my $dispatch = $_DISPATCH{$caller};
    if ($dispatch) {
        my $vars = peek_sub($func);
        my $raw  = exists $vars->{ $dispatch->{var} }
                 ? ${ $vars->{ $dispatch->{var} } }
                 : undef;

        if (defined $raw) {
            my $key = $dispatch->{from_volname} ? _vmid_from_volname($raw) : $raw;

            if (defined $key) {
                if ($dispatch->{type} eq 'vm') {
                    return lock_vm($storeid, $shared, $key, $timeout, $func, @param);
                } else {
                    return lock_volume($storeid, $shared, $key, $timeout, $func, @param);
                }
            }
        }
    }

    # Fallback: storage-level lock for unknown or unresolvable callers.
    return lock_storage($storeid, $shared, $timeout, $func, @param);
}

1;
