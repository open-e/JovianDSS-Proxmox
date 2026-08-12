#!/usr/bin/perl

# Unit tests for OpenEJovianDSS::Common::volume_snapshots_info — the data
# source behind the plugin's volume_snapshot_info API method (replication
# contract: per-snapshot id + epoch timestamp, best-effort virtual-size,
# and an empty hash when the volume does not exist).

use strict;
use warnings;

use FindBin;

# ---------------------------------------------------------------------------
# Stubbed environment: Common.pm must load without a PVE installation.
# ---------------------------------------------------------------------------
BEGIN {
    $INC{'String/Util.pm'} = __FILE__;
    $INC{'PVE/INotify.pm'} = __FILE__;
    $INC{'PVE/Tools.pm'}   = __FILE__;
    $INC{'JSON.pm'}        = __FILE__;
}
{
    # Imported but unused on the paths under test.
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
    sub run_command       { die "unexpected run_command in this suite\n" }
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

require "$FindBin::Bin/../OpenEJovianDSS/Common.pm";

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

my ( $tests, $failures ) = ( 0, 0 );

sub ok {
    my ( $cond, $desc ) = @_;
    $tests++;
    if ($cond) {
        print "ok $tests - $desc\n";
        return 1;
    }
    $failures++;
    print "NOT OK $tests - $desc\n";
    return 0;
}

sub is {
    my ( $got, $expected, $desc ) = @_;
    my $eq =
        ( defined $got && defined $expected ) ? $got eq $expected
      : ( !defined $got && !defined $expected ) ? 1
      :                                           0;
    if ( !ok( $eq, $desc ) ) {
        print "    got:      " . ( $got      // '(undef)' ) . "\n";
        print "    expected: " . ( $expected // '(undef)' ) . "\n";
    }
}

sub like {
    my ( $got, $re, $desc ) = @_;
    if ( !ok( scalar( ( $got // '' ) =~ $re ), $desc ) ) {
        print "    got:   '" . ( $got // '(undef)' ) . "'\n";
        print "    match: $re\n";
    }
}

# ---------------------------------------------------------------------------
# Doubles: jdssc round-trips answer from a scripted response; debug logging
# is silenced (no log file in the stub context).
# ---------------------------------------------------------------------------

my @CMDS;
my $CMD_OUTPUT = '';
my $CMD_ERROR;

{
    no warnings 'redefine';
    *OpenEJovianDSS::Common::joviandss_cmd = sub {
        my ( $ctx, $cmd ) = @_;
        push @CMDS, $cmd;
        die $CMD_ERROR if defined $CMD_ERROR;
        return $CMD_OUTPUT;
    };
    *OpenEJovianDSS::Common::debugmsg = sub { };
}

my $CTX = { scfg => { pool_name => 'Pool-0' }, storeid => 'jdss' };

sub reset_state {
    @CMDS       = ();
    $CMD_OUTPUT = '';
    $CMD_ERROR  = undef;
}

# ---------------------------------------------------------------------------
# The jdssc query must ask for every field the parser consumes.
# ---------------------------------------------------------------------------
{
    reset_state();
    OpenEJovianDSS::Common::volume_snapshots_info( $CTX, 'vm-100-disk-0' );
    my $cmd = join ' ', @{ $CMDS[0] };
    is( $cmd,
        'pool Pool-0 volume vm-100-disk-0 snapshots list --guid --creation --volsize',
        'query: snapshots list requests guid, creation and volsize' );
}

# ---------------------------------------------------------------------------
# Full line: id, epoch timestamp and virtual-size are extracted.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT =
        "pvesnap 15370701587392113066 1753900000 1073741824\n"
      . "backup 111 1753900100 2147483648\n";
    my $info =
      OpenEJovianDSS::Common::volume_snapshots_info( $CTX, 'vm-100-disk-0' );

    is( scalar( keys %$info ), 2, 'parse: every line becomes a snapshot' );
    is( $info->{pvesnap}{id},
        '15370701587392113066', 'parse: guid becomes the id' );
    is( $info->{pvesnap}{timestamp},
        '1753900000', 'parse: creation becomes the timestamp' );
    is( $info->{pvesnap}{'virtual-size'},
        '1073741824', 'parse: volsize becomes virtual-size' );
    is( $info->{backup}{'virtual-size'},
        '2147483648', 'parse: second snapshot carries its own sizes' );
}

# ---------------------------------------------------------------------------
# virtual-size is best effort: the '-' placeholder must not surface.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT = "pvesnap 15370701587392113066 1753900000 -\n";
    my $info =
      OpenEJovianDSS::Common::volume_snapshots_info( $CTX, 'vm-100-disk-0' );

    is( $info->{pvesnap}{id},
        '15370701587392113066', 'placeholder: id still parsed' );
    ok( !exists $info->{pvesnap}{'virtual-size'},
        'placeholder: no virtual-size key when the appliance lacks it' );
}

# ---------------------------------------------------------------------------
# No snapshots: empty hash.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT = '';
    my $info =
      OpenEJovianDSS::Common::volume_snapshots_info( $CTX, 'vm-100-disk-0' );
    is( scalar( keys %$info ), 0, 'empty: no snapshots yields an empty hash' );
}

# ---------------------------------------------------------------------------
# Missing volume: the documented contract is an empty hash, not an error.
# joviandss_cmd dies with jdssc's stderr, which carries the canonical
# "JDSS resource ... does not exist." message.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_ERROR = "JDSS resource v_vm-100-disk-0 does not exist.\n\n";
    my $info = eval {
        OpenEJovianDSS::Common::volume_snapshots_info( $CTX, 'vm-100-disk-0' );
    };
    is( $@, '', 'missing volume: no error escapes' );
    ok( ref($info) eq 'HASH' && !%$info,
        'missing volume: an empty hash is returned' );
}

# ---------------------------------------------------------------------------
# Any other jdssc failure must propagate untouched.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_ERROR = "Failed to list snapshots vm-100-disk-0.\n";
    eval {
        OpenEJovianDSS::Common::volume_snapshots_info( $CTX, 'vm-100-disk-0' );
    };
    like( $@, qr/Failed to list snapshots/,
        'other errors: the original error is rethrown' );
}

print "1..$tests\n";
if ($failures) {
    print "FAILED $failures/$tests\n";
    exit 1;
}
print "PASSED $tests/$tests\n";
exit 0;
