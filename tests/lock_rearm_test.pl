#!/usr/bin/perl
# Functional tests for OpenEJovianDSS::Lock's phase machinery:
# commission → acquire → run_bounded/run_refreshed → divest → decommission,
# with the registry-derived hold-alarm re-arm (budget measured since the
# last cooperation point) and real flock on the node backend.
#
# Self-contained: PVE modules are stubbed (run_with_timeout with real alarm
# semantics), locks live in a temp dir, a forked child provides contention.
# Run from the repo root:
#
#     perl tests/lock_rearm_test.pl        (~25 s wall time, real SIGALRM)

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/..";

use Fcntl qw(LOCK_EX LOCK_UN);
use File::Temp ();
use POSIX ();

BEGIN {
    $INC{'PVE/Cluster.pm'} = __FILE__;
    $INC{'PVE/Tools.pm'}   = __FILE__;
}
{
    package PVE::Cluster;
    sub import     { }
    sub cfs_update { }
}
{
    package PVE::Tools;
    sub import { }
    # Faithful stub of run_with_timeout: outer alarm suspended/restored,
    # dies "got timeout\n" on expiry — the semantics _lock_acquire_node
    # depends on.
    sub run_with_timeout {
        my ($timeout, $code, @param) = @_;
        die "got timeout\n" if $timeout <= 0;
        my $prev = alarm(0);
        my $res;
        my $ok = eval {
            local $SIG{ALRM} = sub { die "got timeout\n" };
            alarm($timeout);
            $res = $code->(@param);
            alarm(0);
            1;
        };
        my $err = $@;
        alarm(0);
        alarm($prev) if $prev;
        die $err if !$ok;
        return $res;
    }
}

use OpenEJovianDSS::Lock;

# Common must not be loaded (Lock calls it fully-qualified only at runtime
# for constants/debugmsg); provide the two constants + a silent debugmsg.
{
    package OpenEJovianDSS::Common;
    no warnings 'redefine';
    sub PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX  { 117 }
    sub PROXMOX_CLUSTER_POLL_BASE_SLEEP   { 0.05 }
    sub PROXMOX_CLUSTER_POLL_BACKOFF_STEP { 0.05 }
    sub PROXMOX_CLUSTER_POLL_JITTER_MAX   { 0.1 }
    sub PROXMOX_CLUSTER_POLL_SLEEP_CAP    { 0.2 }
    sub debugmsg { }
}

my $tmpdir = File::Temp::tempdir( CLEANUP => 1 );
my $tests  = 0;
my $failed = 0;

sub ok {
    my ( $cond, $name ) = @_;
    $tests++;
    print( ( $cond ? "ok" : "NOT ok" ) . " $tests - $name\n" );
    $failed++ unless $cond;
}

sub new_test_ctx { return { _held_locks => [] } }

sub commission_node {
    my ( $ctx, $name, %over ) = @_;
    return OpenEJovianDSS::Lock::_lock_ctx_commission(
        $ctx, 'node', "$tmpdir/$name",
        $over{timeout} // 5, exists $over{hold} ? $over{hold} : 4 );
}

# --- T1: full happy path on a real flock ------------------------------------
{
    my $ctx = new_test_ctx();
    my $id  = commission_node( $ctx, 'happy' );
    my $rec = OpenEJovianDSS::Lock::_lock_record( $ctx, $id );
    ok( $rec && !$rec->{owned} && !defined $rec->{deadline},
        "commissioned: registered, not owned, no deadline" );

    my $got = OpenEJovianDSS::Lock::_lock_acquire( $ctx, $id );
    ok( $got eq $id,                    "acquire returns the commissioned id" );
    ok( $rec->{owned} && $rec->{fh},    "owned with fh parked in the record" );
    ok( $rec->{deadline},               "deadline armed at acquisition" );

    my $res = OpenEJovianDSS::Lock::run_bounded( $ctx, $id, sub { 'body-ran' } );
    ok( $res eq 'body-ran',             "run_bounded runs the body (cap from record)" );

    OpenEJovianDSS::Lock::_lock_divest( $ctx, $id );
    ok( !$rec->{owned} && !defined $rec->{deadline} && !$rec->{fh},
        "divest: ownership, deadline and fh cleared" );
    OpenEJovianDSS::Lock::_lock_divest( $ctx, $id );    # idempotent
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
    ok( !OpenEJovianDSS::Lock::_lock_record( $ctx, $id ) && !@{ $ctx->{_held_locks} },
        "decommission removes the record (double divest harmless)" );
}

# --- T2: contended flock times out with the canonical, classifiable error ---
{
    my $lockpath = "$tmpdir/contended";
    my $pid      = fork();
    die "fork failed" if !defined $pid;
    if ( !$pid ) {    # child: hold the flock for 6 s
        open( my $fh, '>>', $lockpath ) or POSIX::_exit(1);
        flock( $fh, LOCK_EX ) or POSIX::_exit(1);
        sleep 6;
        POSIX::_exit(0);
    }
    sleep 1;          # let the child take it

    my $ctx = new_test_ctx();
    my $id  = OpenEJovianDSS::Lock::_lock_ctx_commission( $ctx, 'node', $lockpath, 2, 4 );
    my $start = time();
    my $ok    = eval { OpenEJovianDSS::Lock::_lock_acquire( $ctx, $id ); 1 };
    my $err     = $@;
    my $elapsed = time() - $start;
    ok( !$ok, "contended acquire dies" );
    ok( OpenEJovianDSS::Lock::lock_error_acquire($err),
        "error classifies as ACQUIRE contention" );
    ok( !OpenEJovianDSS::Lock::lock_error_fatal($err),
        "acquire contention is NOT lock-fatal" );
    ok( $elapsed >= 2 && $elapsed <= 4, "died at the acquire budget (${elapsed}s)" );
    my $rec = OpenEJovianDSS::Lock::_lock_record( $ctx, $id );
    ok( $rec && !$rec->{owned}, "never owned after failed acquire" );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
    waitpid( $pid, 0 );
}

# --- T3: cooperating hold outlives its cap (re-arm at refresh points) -------
{
    my $ctx = new_test_ctx();
    my $id  = commission_node( $ctx, 'rearm', hold => 3 );
    OpenEJovianDSS::Lock::_lock_acquire( $ctx, $id );
    my $rec = OpenEJovianDSS::Lock::_lock_record( $ctx, $id );
    $rec->{deadline} = time() + 30;    # deadline out of the way; alarm under test
    my $died = 0;
    eval {
        OpenEJovianDSS::Lock::run_bounded( $ctx, $id, sub {
            for ( 1 .. 3 ) {           # 6 s of 2 s segments under a 3 s cap
                sleep 2;
                OpenEJovianDSS::Lock::refresh_locks($ctx);
            }
        } );
        1;
    } or $died = 1;
    ok( !$died, "6 s of cooperating 2 s segments survive a 3 s alarm cap" );
    OpenEJovianDSS::Lock::_lock_divest( $ctx, $id );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
}

# --- T4: a wedge still dies at the cap, naming the lock ---------------------
{
    my $ctx = new_test_ctx();
    my $id  = commission_node( $ctx, 'wedge', hold => 2 );
    OpenEJovianDSS::Lock::_lock_acquire( $ctx, $id );
    my $start = time();
    my $ok = eval { OpenEJovianDSS::Lock::run_bounded( $ctx, $id, sub { sleep 10 } ); 1 };
    my $err     = $@;
    my $elapsed = time() - $start;
    ok( !$ok && OpenEJovianDSS::Lock::lock_error_fatal($err),
        "wedge dies with the lock-fatal marker" );
    ok( $err =~ /\Q$id\E/, "the alarm die NAMES the wedged lock" );
    ok( $elapsed >= 2 && $elapsed <= 4, "died at the cap (${elapsed}s)" );
    OpenEJovianDSS::Lock::_lock_divest( $ctx, $id );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
}

# --- T5: nested sections — exit re-arms the ENCLOSING section in full -------
{
    my $ctx = new_test_ctx();
    my $out = commission_node( $ctx, 'outer', hold => 4 );
    OpenEJovianDSS::Lock::_lock_acquire( $ctx, $out );
    OpenEJovianDSS::Lock::_lock_record( $ctx, $out )->{deadline} = time() + 30;
    my $died = 0;
    eval {
        OpenEJovianDSS::Lock::run_bounded( $ctx, $out, sub {
            sleep 2;    # burn half the outer budget
            my $in = commission_node( $ctx, 'inner', hold => 4 );
            OpenEJovianDSS::Lock::_lock_acquire( $ctx, $in );
            OpenEJovianDSS::Lock::run_bounded( $ctx, $in, sub { sleep 1 } );
            OpenEJovianDSS::Lock::_lock_divest( $ctx, $in );
            OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $in );
            sleep 3;    # > frozen remainder (2 s), < full cap (4 s)
        } );
        1;
    } or $died = 1;
    ok( !$died, "inner section exit re-armed the outer cap in full"
          . " (frozen-remainder restore would have fired)" );
    OpenEJovianDSS::Lock::_lock_divest( $ctx, $out );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $out );
}

# --- T6: poll-loop refresh ($skip_path) does NOT re-arm ----------------------
{
    my $ctx = new_test_ctx();
    my $id  = commission_node( $ctx, 'skip', hold => 3 );
    OpenEJovianDSS::Lock::_lock_acquire( $ctx, $id );
    OpenEJovianDSS::Lock::_lock_record( $ctx, $id )->{deadline} = time() + 30;
    my $start = time();
    my $ok = eval {
        OpenEJovianDSS::Lock::run_bounded( $ctx, $id, sub {
            sleep 2;
            OpenEJovianDSS::Lock::refresh_locks( $ctx, '/in-flight-target' );
            sleep 2;    # cumulative 4 > 3: must fire — no re-arm happened
        } );
        1;
    };
    my $elapsed = time() - $start;
    ok( !$ok && OpenEJovianDSS::Lock::lock_error_fatal($@),
        "skip-path refresh does not restart the alarm budget" );
    ok( $elapsed >= 3 && $elapsed <= 5, "fired on the un-restarted budget (${elapsed}s)" );
    OpenEJovianDSS::Lock::_lock_divest( $ctx, $id );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
}

# --- T7: deadline enforcement + finalizer tripwire ---------------------------
{
    my $ctx = new_test_ctx();
    my $id  = commission_node( $ctx, 'deadline', hold => 1 );
    OpenEJovianDSS::Lock::_lock_acquire( $ctx, $id );
    sleep 2;    # blow the 1 s deadline
    my $ok = eval { OpenEJovianDSS::Lock::refresh_locks($ctx); 1 };
    ok( !$ok && OpenEJovianDSS::Lock::lock_error_fatal($@),
        "expired hold deadline dies with the marker at a cooperation point" );

    # finalizer path: still owned (no explicit divest — simulates a bug path)
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
    ok( !OpenEJovianDSS::Lock::_lock_record( $ctx, $id ),
        "finalizer divested-and-removed a still-owned record without dying" );
}

# --- T8: re-lock of a commissioned path confesses ----------------------------
{
    my $ctx = new_test_ctx();
    my $id  = commission_node( $ctx, 'guard' );
    my $ok  = eval { commission_node( $ctx, 'guard' ); 1 };
    ok( !$ok && $@ =~ /LOCK BUG/, "re-commission of a held path confesses" );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
}

# --- T9: acquire without commission confesses --------------------------------
{
    my $ctx = new_test_ctx();
    my $ok  = eval { OpenEJovianDSS::Lock::_lock_acquire( $ctx, "$tmpdir/ghost" ); 1 };
    ok( !$ok && $@ =~ /LOCK BUG/, "bare acquire without commission confesses" );
}

# --- T10: foreign alarm handed back untouched --------------------------------
{
    my $ctx = new_test_ctx();
    my $id  = commission_node( $ctx, 'foreign', hold => 2 );
    OpenEJovianDSS::Lock::_lock_acquire( $ctx, $id );
    my $foreign = 0;
    local $SIG{ALRM} = sub { $foreign = 1 };
    alarm(60);
    OpenEJovianDSS::Lock::run_bounded( $ctx, $id, sub { sleep 1 } );
    OpenEJovianDSS::Lock::_lock_divest( $ctx, $id );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $id );
    my $remaining = alarm(0);
    ok( $remaining > 0 && $remaining <= 60 && !$foreign,
        "foreign alarm restored with its remainder (${remaining}s left)" );
}

# --- T11: acquire is a cooperation point — a wait the enclosing budget ------
# has already outlived dies BEFORE it starts, with the true hold-cap fatal
{
    my $lockpath = "$tmpdir/doomed";
    my $pid      = fork();
    die "fork failed" if !defined $pid;
    if ( !$pid ) {    # child: squat the flock so any real wait would block
        open( my $fh, '>>', $lockpath ) or POSIX::_exit(1);
        flock( $fh, LOCK_EX ) or POSIX::_exit(1);
        sleep 6;
        POSIX::_exit(0);
    }
    sleep 1;

    my $ctx   = new_test_ctx();
    my $outer = commission_node( $ctx, 'doomed-outer', hold => 30 );
    OpenEJovianDSS::Lock::_lock_acquire( $ctx, $outer );
    OpenEJovianDSS::Lock::_lock_record( $ctx, $outer )->{deadline} = time() - 1;

    my $inner = OpenEJovianDSS::Lock::_lock_ctx_commission( $ctx, 'node', $lockpath, 4, 4 );
    my $start = time();
    my $ok    = eval { OpenEJovianDSS::Lock::_lock_acquire( $ctx, $inner ); 1 };
    my $err     = $@;
    my $elapsed = time() - $start;
    ok( !$ok && OpenEJovianDSS::Lock::lock_error_fatal($err),
        "expired outer budget dies as hold-cap FATAL, not inner contention" );
    ok( $elapsed <= 1, "died before the wait started (${elapsed}s, holder still squatting)" );

    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $inner );
    OpenEJovianDSS::Lock::_lock_divest( $ctx, $outer );
    OpenEJovianDSS::Lock::_lock_ctx_decommission( $ctx, $outer );
    waitpid( $pid, 0 );
}

# --- T12: _lock_exec end-to-end — success returns the body result and ------
# releases; a second context can re-acquire the same path instantly
{
    my $path = "$tmpdir/exec-happy";
    my $ctx1 = new_test_ctx();
    my $out  = OpenEJovianDSS::Lock::_lock_exec( $ctx1, 'node', $path, 2, 4,
        sub { 'sequencer-ok' } );
    ok( $out eq 'sequencer-ok' && !@{ $ctx1->{_held_locks} },
        "_lock_exec returns the body result; registry empty after" );

    my $ctx2  = new_test_ctx();
    my $start = time();
    my $out2  = OpenEJovianDSS::Lock::_lock_exec( $ctx2, 'node', $path, 2, 4,
        sub { 'again' } );
    ok( $out2 eq 'again' && time() - $start <= 1,
        "released: a fresh ctx re-acquires the same path instantly" );
}

# --- T13: _lock_exec end-to-end — body death releases via the ONE ----------
# unconditional divest (no finalizer involvement), error propagates
{
    my $path = "$tmpdir/exec-die";
    my $ctx1 = new_test_ctx();
    my $ok   = eval {
        OpenEJovianDSS::Lock::_lock_exec( $ctx1, 'node', $path, 2, 4,
            sub { die "body exploded\n" } );
        1;
    };
    ok( !$ok && $@ eq "body exploded\n" && !@{ $ctx1->{_held_locks} },
        "body die propagates verbatim; registry empty after" );

    my $ctx2  = new_test_ctx();
    my $start = time();
    OpenEJovianDSS::Lock::_lock_exec( $ctx2, 'node', $path, 2, 4, sub { 1 } );
    ok( time() - $start <= 1,
        "released on the die path: instant re-acquisition" );
}

print $failed ? "FAILED: $failed of $tests\n" : "PASS: all $tests tests\n";
exit( $failed ? 1 : 0 );
