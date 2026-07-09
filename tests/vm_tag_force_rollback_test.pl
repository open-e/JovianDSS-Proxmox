#!/usr/bin/perl
# Functional tests for OpenEJovianDSS::Common's force-rollback tag reader:
# _vm_tag_force_rollback_read (tag parsing, pvesh invocation, error paths)
# and vm_tag_force_rollback_is_set (retry-on-transient, die-on-persistent).
#
# A wrong "absent" answer silently downgrades a forced rollback to a blocked
# one, so the absent/present boundary and the never-mistake-failure-for-absence
# contract are what these tests pin down.
#
# Self-contained: PVE modules, JSON and String::Util are stubbed (Common only
# needs decode_json here, backed by core JSON::PP); run_command is steered per
# test through $PVE::Tools::RUN_COMMAND; sleep is neutered so the retry tests
# do not spend 8 s in backoff. Runs anywhere perl does -- no node required.
# Run from the repo root:
#
#     perl tests/vm_tag_force_rollback_test.pl        (instant, no I/O)
#
# The tag payloads below were checked against a real pvesh on PVE 9.1.11:
# 'force-rollback' is an accepted tag, ',' is normalised to ';' on write, and
# spaces around the delimiter are stripped.  Cases that exercise commas or
# spaces are therefore defensive, and say so.

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/..";

# Must precede Common's compilation: only calls compiled after this override
# route through it.  Records the backoff Common asks for instead of taking it.
our @SLEPT;
BEGIN {
    *CORE::GLOBAL::sleep = sub { push @SLEPT, $_[0]; return 0 };
}

BEGIN {
    $INC{'String/Util.pm'} = __FILE__;
    $INC{'PVE/INotify.pm'} = __FILE__;
    $INC{'PVE/Tools.pm'}   = __FILE__;
    $INC{'JSON.pm'}        = __FILE__;
}
{
    # Imported but unused by Common.
    package String::Util;
    sub import { }
}
{
    package PVE::INotify;
    sub import   { }
    sub nodename { 'testnode' }
}
{
    package PVE::Tools;
    # Common binds run_command at compile time, so the exported sub must stay
    # a stable trampoline; tests swap the body via $RUN_COMMAND.
    our $RUN_COMMAND = sub { 0 };
    sub run_command       { return $RUN_COMMAND->(@_) }
    sub file_set_contents { }

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::run_command"}       = \&run_command;
        *{"${caller}::file_set_contents"} = \&file_set_contents;
    }
}
{
    package JSON;
    use JSON::PP ();
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::decode_json"} = \&JSON::PP::decode_json;
        *{"${caller}::from_json"}   = \&JSON::PP::decode_json;
        *{"${caller}::to_json"}     = \&JSON::PP::encode_json;
    }
}

use OpenEJovianDSS::Common;

my $tests  = 0;
my $failed = 0;

sub ok {
    # A bare `$x =~ /re/` argument yields the empty list on no-match, which
    # would slide $name into the $cond slot and pass vacuously.  Insist on
    # exactly two arguments so such a call is a hard error, not a green tick.
    die "ok() takes (cond, name); got " . scalar(@_) . " args -- wrap any "
      . "bare regex match in !!( ... )\n"
      if @_ != 2;

    my ( $cond, $name ) = @_;
    $tests++;
    print( ( $cond ? "ok" : "NOT ok" ) . " $tests - $name\n" );
    $failed++ unless $cond;
}

# --- test doubles for Common's two collaborators ----------------------------

our $VIRT_TYPE = 'qemu';    # what vmid_identify_virt_type reports
our @DEBUG;                 # captured debugmsg ( level, message ) pairs
our @CMDS;                  # every pvesh argv Common built

{
    no warnings 'redefine';
    *OpenEJovianDSS::Common::vmid_identify_virt_type = sub { return $VIRT_TYPE };
    *OpenEJovianDSS::Common::debugmsg =
        sub { my ( undef, $lvl, $msg ) = @_; push @DEBUG, [ $lvl, $msg ] };
}

sub reset_state {
    @SLEPT = ();
    @DEBUG = ();
    @CMDS  = ();
    $VIRT_TYPE = 'qemu';
}

# pvesh succeeds and prints $json on stdout
sub pvesh_returns {
    my ($json) = @_;
    $PVE::Tools::RUN_COMMAND = sub {
        my ( $cmd, %opt ) = @_;
        push @CMDS, $cmd;
        $opt{outfunc}->($_) for split( /\n/, $json );
        return 0;
    };
}

# pvesh fails with $exitcode and $stderr
sub pvesh_fails {
    my ( $exitcode, $stderr ) = @_;
    $PVE::Tools::RUN_COMMAND = sub {
        my ( $cmd, %opt ) = @_;
        push @CMDS, $cmd;
        $opt{errfunc}->($stderr) if defined $stderr;
        return $exitcode;
    };
}

# Convenience: build a VM config payload with the given tags string
sub conf_with_tags {
    my ($tags) = @_;
    my $esc = $tags;
    $esc =~ s/(["\\])/\\$1/g;
    return qq({"name":"vm","tags":"$esc"});
}

sub read_tag {
    return OpenEJovianDSS::Common::_vm_tag_force_rollback_read( {}, 100 );
}

sub debug_text { return join( "\n", map { $_->[1] } @DEBUG ) }

# --- T1: no tags key at all -> absent ---------------------------------------
{
    reset_state();
    pvesh_returns('{"name":"vm"}');
    ok( read_tag() == 0, "config without a tags key: absent" );
    ok( !!( debug_text() =~ /force-rollback tag for vmid 100: absent \(no tags\)/ ),
        "no-tags debug line names the tag as 'force-rollback'" );
}

# --- T2: the tag alone -> present -------------------------------------------
{
    reset_state();
    pvesh_returns( conf_with_tags('force-rollback') );
    ok( read_tag() == 1, "tags='force-rollback': present" );
    ok( !!( debug_text() =~ /force-rollback tag for vmid 100: present/ ),
        "present debug line names the tag as 'force-rollback'" );
}

# --- T3: the old underscore spelling must NOT be honoured -------------------
# Pins the rename: a stale 'force_rollback' tag fails safe (rollback blocks)
# rather than silently forcing a destructive rollback.
{
    reset_state();
    pvesh_returns( conf_with_tags('force_rollback') );
    ok( read_tag() == 0, "legacy tags='force_rollback': absent (renamed)" );
}

# --- T4: semicolon delimiter, no spaces -------------------------------------
{
    reset_state();
    pvesh_returns( conf_with_tags('backup;force-rollback') );
    ok( read_tag() == 1, "tags='backup;force-rollback': present" );
}

# --- T5: semicolon delimiter WITH a trailing space --------------------------
# Defensive.  Verified on PVE 9.1.11: `qm set --tags "backup; force-rollback"`
# stores "backup;force-rollback" -- pvesh never emits the space itself.  The
# per-tag trim guards a hand-edited /etc/pve/<type>/<vmid>.conf and the older
# PVE behaviour that debian/changelog records as a real bug (0.11.x entry:
# "force_rollback VM tag ignored when Proxmox stores tags with spaces after
# the delimiter").  Removing the trim must still be caught.
{
    reset_state();
    pvesh_returns( conf_with_tags('backup; force-rollback') );
    ok( read_tag() == 1, "tags='backup; force-rollback': space after ';' trimmed" );
}

# --- T6/T7: comma delimiters ------------------------------------------------
# Also defensive: PVE 9.1.11 normalises "," to ";" on write, so pvesh returns
# only ';'-delimited tags.  Common splits on /[,;]/ anyway; these pin that
# split so a future narrowing to /;/ is a deliberate, visible choice.
{
    reset_state();
    pvesh_returns( conf_with_tags('backup , force-rollback , restore') );
    ok( read_tag() == 1, "tags='backup , force-rollback , restore': present" );
}
{
    reset_state();
    pvesh_returns( conf_with_tags('a,b;c,force-rollback') );
    ok( read_tag() == 1, "mixed ',' and ';' delimiters: present" );
}

# --- T8: unrelated tags only -> absent --------------------------------------
{
    reset_state();
    pvesh_returns( conf_with_tags('backup,restore') );
    ok( read_tag() == 0, "tags='backup,restore': absent" );
    ok( !!( debug_text() =~ /absent \(tags='backup,restore'\)/ ),
        "absent debug line echoes the tags it inspected" );
}

# --- T9: no substring or prefix matching ------------------------------------
# 'eq' not '=~': neither a superstring nor a prefix may match.
{
    reset_state();
    pvesh_returns( conf_with_tags('no-force-rollback,force-rollback-now,force') );
    ok( read_tag() == 0, "superstring/prefix tags do not match: absent" );
}

# --- T10: empty tags string -> absent, no warning ---------------------------
{
    reset_state();
    pvesh_returns( conf_with_tags('') );
    ok( read_tag() == 0, "tags='': absent" );
}

# --- T11: the pvesh argv Common builds --------------------------------------
{
    reset_state();
    pvesh_returns( conf_with_tags('force-rollback') );
    read_tag();
    my $argv = join( ' ', @{ $CMDS[0] } );
    ok( $argv eq 'pvesh get /nodes/testnode/qemu/100/config'
          . ' --output-format json',
        "qemu: queries /nodes/<node>/qemu/<vmid>/config as json" );

    reset_state();
    $VIRT_TYPE = 'lxc';
    pvesh_returns( conf_with_tags('force-rollback') );
    ok( read_tag() == 1, "lxc: container config is read the same way" );
    ok( !!( join( q{ }, @{ $CMDS[0] } ) =~ m{/nodes/testnode/lxc/100/config} ),
        "lxc: virt type is threaded into the pvesh path" );
}

# --- T12: unidentifiable virt type dies -------------------------------------
{
    reset_state();
    $VIRT_TYPE = undef;
    pvesh_returns( conf_with_tags('force-rollback') );
    my $ok = eval { read_tag(); 1 };
    ok( !$ok && $@ =~ /Unable to identify virtualisation type of VM\/CT 100/,
        "undef virt type: dies before shelling out" );
    ok( !@CMDS, "undef virt type: pvesh is never invoked" );
}

# --- T13: non-zero pvesh exit dies, carrying stderr -------------------------
{
    reset_state();
    pvesh_fails( 2, 'pvesh: 500 no such VM' );
    my $ok = eval { read_tag(); 1 };
    ok( !$ok && $@ =~ /Unable to read VM\/CT 100 config/,
        "pvesh exit 2: dies rather than reporting absence" );
    ok( !!( $@ =~ /500 no such VM/ ),
        "pvesh exit 2: stderr is carried into the error" );
}

# --- T14: unparseable stdout dies -------------------------------------------
{
    reset_state();
    pvesh_returns('not json at all');
    my $ok = eval { read_tag(); 1 };
    ok( !$ok && $@ =~ /Unable to parse VM\/CT 100 config/,
        "malformed JSON: dies rather than reporting absence" );
}

# --- T15: well-formed JSON that is not an object dies -----------------------
{
    reset_state();
    pvesh_returns('[]');
    my $ok = eval { read_tag(); 1 };
    ok( !$ok && $@ =~ /Unable to parse VM\/CT 100 config/,
        "JSON array instead of object: dies rather than reporting absence" );
}

# --- T16: is_set returns a definitive answer without retrying ---------------
{
    reset_state();
    my $calls = 0;
    $PVE::Tools::RUN_COMMAND = sub {
        my ( $cmd, %opt ) = @_;
        $calls++;
        $opt{outfunc}->( conf_with_tags('force-rollback') );
        return 0;
    };
    ok( OpenEJovianDSS::Common::vm_tag_force_rollback_is_set( {}, 100 ) == 1,
        "is_set: present" );
    ok( $calls == 1, "is_set: a definitive 'present' costs exactly one read" );
    ok( !@SLEPT, "is_set: no backoff on the happy path" );
}

# --- T17: a definitive 'absent' is also not retried -------------------------
# Guards the `return $is_set unless $@` shape: a falsy-but-valid 0 must not be
# mistaken for a failure and spun on.
{
    reset_state();
    my $calls = 0;
    $PVE::Tools::RUN_COMMAND = sub {
        my ( $cmd, %opt ) = @_;
        $calls++;
        $opt{outfunc}->( conf_with_tags('backup') );
        return 0;
    };
    ok( OpenEJovianDSS::Common::vm_tag_force_rollback_is_set( {}, 100 ) == 0,
        "is_set: absent" );
    ok( $calls == 1, "is_set: a definitive 'absent' costs exactly one read" );
    ok( !@SLEPT, "is_set: falsy 0 is not retried as if it were a failure" );
}

# --- T18: transient failures are retried, then the real answer wins ---------
{
    reset_state();
    my $calls = 0;
    $PVE::Tools::RUN_COMMAND = sub {
        my ( $cmd, %opt ) = @_;
        $calls++;
        if ( $calls < 3 ) {
            $opt{errfunc}->('pvesh hiccup');
            return 2;
        }
        $opt{outfunc}->( conf_with_tags('force-rollback') );
        return 0;
    };
    ok( OpenEJovianDSS::Common::vm_tag_force_rollback_is_set( {}, 100 ) == 1,
        "is_set: two transient failures then present -> present" );
    ok( $calls == 3, "is_set: retried until a definitive answer" );
    ok( @SLEPT == 2 && !grep( { $_ != 2 } @SLEPT ),
        "is_set: backed off 2 s between the failed attempts" );
    ok( scalar( grep { $_->[0] eq 'warn' } @DEBUG ) == 2,
        "is_set: each transient failure is warned about" );
}

# --- T19: persistent failure dies after 5 attempts, never returns 'absent' --
{
    reset_state();
    my $calls = 0;
    $PVE::Tools::RUN_COMMAND = sub {
        my ( $cmd, %opt ) = @_;
        $calls++;
        $opt{errfunc}->('pvesh is down');
        return 2;
    };
    my $ok = eval { OpenEJovianDSS::Common::vm_tag_force_rollback_is_set( {}, 100 ); 1 };
    ok( !$ok, "is_set: persistent failure dies (never downgrades to absent)" );
    ok( !!( $@ =~ /Unable to read VM\/CT 100 config/ ),
        "is_set: the last error is the one propagated" );
    ok( $calls == 5, "is_set: exactly 5 attempts" );
    ok( @SLEPT == 4, "is_set: backed off between attempts, not after the last" );
}

print $failed ? "FAILED: $failed of $tests\n" : "PASS: all $tests tests\n";
exit( $failed ? 1 : 0 );
