#    Copyright (c) 2026 Open-E, Inc.
#    All Rights Reserved.
#
#    Licensed under the Apache License, Version 2.0 (the "License"); you may
#    not use this file except in compliance with the License.

package OpenEJovianDSS::Semaphore;

# [PATCH PL-18] Cluster-wide counting semaphore for plugin-level operation
# throttling, keyed by JDSS physical host serial number.
#
# Purpose: Cap the number of concurrent storage-modifying operations against
#   a given physical JDSS host (identified by `serial_number` from
#   /api/v4/product), counted ACROSS ALL PVE NODES IN THE CLUSTER. This
#   eliminates the cross-pool / cross-node race window that PL-17 v3
#   (per-PVE-node scope) still allowed.
#
# Backpressure to upstream callers (qm clone, qmrestore, snapshot loops):
#     - Linux multipathd path-registration latency under burst
#     - kernel iSCSI session login race
#     - JDSS REST connection pool saturation
#     - SCST scstadmin contention
#     - ZFS module locks (namespace_lock, dsl_pool_config_lock, txg_sync)
#       — GLOBAL on the JDSS host, shared by all pools on that head
#     - JDSS internal config DB cross-pool races observed empirically
#       (e.g. delete_snapshot on Pool-0 returning errors referencing Pool-1
#       target config files under concurrent ops from different PVE nodes)
#
# Primitive:
#     - State file in pmxcfs: /etc/pve/priv/joviandss-sem/host-<KEY>.json
#       (auto-replicated cluster-wide via corosync)
#     - Critical section guarded by an mkdir-based cluster mutex on
#       /etc/pve/priv/lock/joviandss-sem-<KEY> — same mkdir-atomicity
#       primitive that all PVE::Cluster::cfs_lock_* helpers use internally.
#       We can't use cfs_lock_file directly because it enforces a whitelist
#       of pre-registered file names that doesn't include ours.
#     - State holds a list of current holders, each tagged with pid + host
#       + acquired_at + storeid for diagnostics
#
# Scope: PER physical JDSS host, CLUSTER-WIDE.
#     Two storeids whose REST endpoints resolve to the same JDSS serial
#     share one slot pool, regardless of which PVE node they run on.
#     Two storeids whose endpoints resolve to DIFFERENT serials are fully
#     independent — each physical JDSS host has its own slot pool.
#
# Liveness (recovering slots from crashed processes):
#     - Local holder (host == my hostname): kill(0, pid) — fast POSIX check
#       on each acquire. Immediate cleanup on crash, kill, OOM.
#     - Remote holder (different host): timeout-based. Entries older than
#       $MAX_OP_TIME are swept on next acquire. If a remote PVE node dies
#       with a slot held, cluster will be over-throttled for up to
#       MAX_OP_TIME seconds. Acceptable: node crashes are rare and the
#       window is bounded.
#
# Disable: set max_parallel_volume_ops=0 in storage.cfg, or
#     PL17_SEMAPHORE_DISABLE=1 (legacy name, kept for compatibility) or
#     PL18_SEMAPHORE_DISABLE=1 in pvedaemon environment.

use strict;
use warnings;

use Fcntl qw(:DEFAULT);
use File::Path qw(make_path);
use Sys::Hostname qw(hostname);
use Time::HiRes qw(time sleep);
use JSON qw(decode_json encode_json);

use PVE::Tools qw(file_set_contents);

# pmxcfs paths: auto-replicated cluster-wide, /etc/pve/priv is root-only.
my $STATE_DIR     = '/etc/pve/priv/joviandss-sem';
my $LOCK_DIR_BASE = '/etc/pve/priv/lock';
# Prefix for our cluster-wide mutex names inside $LOCK_DIR_BASE.
my $LOCK_NAME_PREFIX = 'joviandss-sem-';

# Stale-entry timeout for REMOTE holders only. Local stale entries are
# detected immediately via kill(0). Must exceed the longest realistic
# single storage operation: 1h covers TB-scale clone / backup / restore.
my $MAX_OP_TIME = 3600;

# cfs_lock_file timeout per critical section. The critical section itself
# is tiny (read+decide+write a small JSON file), 30s is generous.
my $CFS_LOCK_TIMEOUT = 30;

sub _debugmsg {
    my ($ctx, $level, $msg) = @_;
    return unless $ctx;
    eval {
        require OpenEJovianDSS::Common;
        OpenEJovianDSS::Common::debugmsg($ctx, $level, $msg);
    };
}

# Cluster-wide mutex built on pmxcfs mkdir atomicity. Used by every
# PVE::Cluster::cfs_lock_* helper internally — mkdir on /etc/pve/priv/lock/<name>
# is synchronized by corosync across all PVE nodes (only one node can
# create the directory; the others get EEXIST). Touching utime is the
# documented "cfs unlock request" hint that wakes other waiters.
#
# We use our own primitive (instead of cfs_lock_file) because that helper
# enforces a whitelist of pre-registered file names in pmxcfs's $observed
# map and rejects arbitrary names.
sub _cluster_lock {
    my ($lock_name, $timeout, $code) = @_;
    my $lock_path = "${LOCK_DIR_BASE}/${LOCK_NAME_PREFIX}${lock_name}";

    my $deadline = time() + $timeout;
    my $got_lock = 0;
    while (1) {
        if (mkdir($lock_path)) {
            $got_lock = 1;
            last;
        }
        if (time() >= $deadline) {
            die "PL-18 cluster lock timeout (${timeout}s) on '${lock_name}'\n";
        }
        # pmxcfs convention: utime() on a held lock signals "please release".
        utime(0, 0, $lock_path);
        sleep(1);
    }

    my $result;
    my $err;
    eval { $result = $code->(); };
    $err = $@;

    rmdir($lock_path);

    die $err if $err;
    return $result;
}

sub _state_path {
    my ($host_key) = @_;
    return "${STATE_DIR}/host-${host_key}.json";
}

sub _read_state {
    my ($host_key) = @_;
    my $path = _state_path($host_key);
    return { holders => [] } unless -f $path;
    open(my $fh, '<', $path) or return { holders => [] };
    local $/;
    my $data = <$fh>;
    close($fh);
    return { holders => [] } unless defined($data) && length($data);
    my $state = eval { decode_json($data) };
    if ($@ || !$state || ref($state) ne 'HASH') {
        return { holders => [] };
    }
    $state->{holders} //= [];
    return $state;
}

sub _write_state {
    my ($host_key, $state) = @_;
    unless (-d $STATE_DIR) {
        eval { make_path($STATE_DIR, { mode => 0700 }) };
    }
    my $path = _state_path($host_key);
    # pmxcfs supports atomic writes via file_set_contents (PVE helper).
    # cluster replication happens after fsync.
    file_set_contents($path, encode_json($state));
}

# Filter the holders list, keeping only entries we believe are still alive.
#   - Local entries (host == my hostname): test via kill(0, pid).
#   - Remote entries: timestamp-based timeout.
sub _filter_alive {
    my ($holders, $my_host, $now) = @_;
    my @alive;
    for my $h (@$holders) {
        next unless ref($h) eq 'HASH' && $h->{pid} && $h->{host};
        if ($h->{host} eq $my_host) {
            push @alive, $h if kill(0, $h->{pid});
        } else {
            my $age = $now - ($h->{acquired_at} // 0);
            push @alive, $h if $age < $MAX_OP_TIME;
        }
    }
    return \@alive;
}

# Returns a guard object. Release on scope exit (DESTROY) or explicit
# release(). DOES NOT inherit across fork — children must NOT release the
# parent's slot. We tag every holder with (pid, host), so the destructor
# in a forked child sees a mismatching pid and becomes a no-op.
#
# Arguments (hash):
#   host_key   - JDSS physical host id, e.g. 'J0002465' (from Common::jd_host_key)
#   storeid    - storage id, kept for diagnostics
#   max_slots  - integer, 0 = disabled (returns no-op guard immediately)
#   timeout    - acquire timeout in seconds
#   ctx        - optional, for debug logging
sub acquire {
    my ($class, %args) = @_;

    my $host_key  = $args{host_key}  // die "PL-18 sem acquire: host_key required\n";
    my $storeid   = $args{storeid}   // '<unknown>';
    my $max_slots = $args{max_slots} // 4;
    my $timeout   = $args{timeout}   // 600;
    my $ctx       = $args{ctx};

    # Disabled mode (env vars or max=0). Legacy PL17_ var kept for compatibility.
    if ($ENV{PL17_SEMAPHORE_DISABLE} || $ENV{PL18_SEMAPHORE_DISABLE} || $max_slots <= 0) {
        return bless {
            disabled => 1,
            host_key => $host_key,
            storeid  => $storeid,
        }, $class;
    }

    my $my_host  = hostname();
    my $my_pid   = $$;
    my $start    = time();
    my $deadline = $start + $timeout;
    my $poll     = 0.1;
    my $logged_wait = 0;
    my $lock_name = $host_key;   # actual path: $LOCK_DIR_BASE/$LOCK_NAME_PREFIX$host_key

    while (1) {
        my $got_slot = 0;
        my $cs_err;
        eval {
            _cluster_lock($lock_name, $CFS_LOCK_TIMEOUT, sub {
                my $state = _read_state($host_key);
                my $now = time();
                $state->{holders} = _filter_alive($state->{holders}, $my_host, $now);
                if (scalar(@{$state->{holders}}) < $max_slots) {
                    push @{$state->{holders}}, {
                        pid         => $my_pid,
                        host        => $my_host,
                        acquired_at => $now,
                        storeid     => $storeid,
                    };
                    _write_state($host_key, $state);
                    $got_slot = 1;
                }
            });
        };
        $cs_err = $@;

        if ($got_slot) {
            my $waited = time() - $start;
            _debugmsg($ctx, 'debug', sprintf(
                "PL-18 sem acquired host=%s storeid=%s waited=%.2fs max=%d (cluster-wide)",
                $host_key, $storeid, $waited, $max_slots));
            return bless {
                host_key    => $host_key,
                storeid     => $storeid,
                my_host     => $my_host,
                my_pid      => $my_pid,
                ctx         => $ctx,
                acquired_at => time(),
            }, $class;
        }

        if ($cs_err) {
            _debugmsg($ctx, 'warn',
                "PL-18 sem: cfs_lock_file critical section error ($cs_err)");
        }

        if (!$logged_wait) {
            _debugmsg($ctx, 'debug', sprintf(
                "PL-18 sem all slots busy, waiting (host=%s storeid=%s max=%d timeout=%ds)",
                $host_key, $storeid, $max_slots, $timeout));
            $logged_wait = 1;
        }

        if (time() >= $deadline) {
            die sprintf(
                "PL-18 semaphore timeout: host=%s storeid=%s max=%d waited=%ds — "
              . "upstream contention or stuck operation cluster-wide\n",
                $host_key, $storeid, $max_slots, $timeout);
        }

        sleep($poll);
        $poll *= 1.3;
        $poll = 1.0 if $poll > 1.0;   # cap at 1s
    }
}

sub release {
    my ($self) = @_;
    return if $self->{disabled};
    return if $self->{released};

    my $host_key = $self->{host_key};
    my $my_pid   = $self->{my_pid};
    my $my_host  = $self->{my_host};
    return unless $host_key && $my_pid && $my_host;

    # If we're in a forked child whose pid != my_pid recorded at acquire,
    # do not release the parent's slot.
    if ($$ != $my_pid) {
        $self->{released} = 1;
        return;
    }

    my $lock_name = $host_key;   # actual path: $LOCK_DIR_BASE/$LOCK_NAME_PREFIX$host_key
    my $err;
    eval {
        _cluster_lock($lock_name, $CFS_LOCK_TIMEOUT, sub {
            my $state = _read_state($host_key);
            $state->{holders} = [
                grep {
                    !(ref($_) eq 'HASH'
                      && ($_->{pid} // 0)    == $my_pid
                      && ($_->{host} // '')  eq $my_host)
                } @{$state->{holders}}
            ];
            _write_state($host_key, $state);
        });
    };
    $err = $@;

    if ($err) {
        _debugmsg($self->{ctx}, 'warn',
            "PL-18 sem: release cfs_lock failed ($err) — slot will be reclaimed by stale sweep");
    } elsif ($self->{ctx}) {
        my $held = time() - $self->{acquired_at};
        _debugmsg($self->{ctx}, 'debug', sprintf(
            "PL-18 sem released host=%s storeid=%s held=%.2fs",
            $host_key, $self->{storeid}, $held));
    }
    $self->{released} = 1;
}

sub DESTROY {
    my $self = shift;
    $self->release if ref $self && !$self->{disabled};
}

1;
