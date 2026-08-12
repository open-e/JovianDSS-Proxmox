#!/usr/bin/perl

# Unit tests for OpenEJovianDSS::NFSCommon::snapshots_info — the data source
# behind the NFS plugin's volume_snapshot_info API method (contract:
# per-snapshot id — the volname-prefixed guid — plus epoch timestamp,
# entries keyed by the decoded snapshot name, snapshots of other vmids
# filtered out).

use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/..";

# ---------------------------------------------------------------------------
# Stubbed environment: NFSCommon.pm (and the Common.pm it pulls in) must load
# without a PVE installation or Net::IP.
# ---------------------------------------------------------------------------
BEGIN {
    $INC{'String/Util.pm'} = __FILE__;
    $INC{'PVE/INotify.pm'} = __FILE__;
    $INC{'PVE/Tools.pm'}   = __FILE__;
    $INC{'JSON.pm'}        = __FILE__;
    $INC{'Net/IP.pm'}      = __FILE__;
}
{
    # Imported but unused on the paths under test.
    package String::Util;
    sub import { }
}
{
    package Net::IP;
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
    sub file_get_contents { '' }

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::run_command"}       = \&run_command;
        *{"${caller}::file_set_contents"} = \&file_set_contents;
        *{"${caller}::file_get_contents"} = \&file_get_contents;
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

require OpenEJovianDSS::NFSCommon;

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

# ---------------------------------------------------------------------------
# Doubles: jdssc round-trips answer from a scripted response; debug logging
# is silenced (no log file in the stub context).
# ---------------------------------------------------------------------------

my @CMDS;
my $CMD_OUTPUT = '';

{
    no warnings 'redefine';
    *OpenEJovianDSS::Common::joviandss_cmd = sub {
        my ( $ctx, $cmd ) = @_;
        push @CMDS, $cmd;
        return $CMD_OUTPUT;
    };
    *OpenEJovianDSS::Common::debugmsg = sub { };
}

my $CTX = {
    scfg    => { export => '/Pools/Pool-0/data' },
    storeid => 'jdssnfs',
};

sub reset_state {
    @CMDS       = ();
    $CMD_OUTPUT = '';
}

# ---------------------------------------------------------------------------
# The jdssc query must ask for every field the parser consumes.
# ---------------------------------------------------------------------------
{
    reset_state();
    OpenEJovianDSS::NFSCommon::snapshots_info( $CTX, 'data', 'vm-102-disk-0' );
    my $cmd = join ' ', @{ $CMDS[0] };
    is( $cmd,
        'pool Pool-0 nas_volume -d data snapshots list --guid --creation',
        'query: snapshots list requests guid and creation' );
}

# ---------------------------------------------------------------------------
# Full line: id and epoch timestamp are extracted, the internal
# {vmid}_{snapname} name is decoded, only this volume's vmid is listed.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT =
        "102_pvesnap 3093503392097038293 1753900000\n"
      . "102_backup 4093503392097038294 1753900100\n"
      . "205_other 5093503392097038295 1753900200\n";
    my $info =
      OpenEJovianDSS::NFSCommon::snapshots_info( $CTX, 'data', 'vm-102-disk-0' );

    is( scalar( keys %$info ), 2, 'parse: only this vmid\'s snapshots listed' );
    is( $info->{pvesnap}{id},
        'vm-102-disk-0-3093503392097038293',
        'parse: id is the volname-prefixed guid' );
    is( $info->{pvesnap}{timestamp},
        '1753900000', 'parse: creation becomes the timestamp' );
    is( $info->{pvesnap}{name}, 'pvesnap', 'parse: internal name is decoded' );
    is( $info->{backup}{id},
        'vm-102-disk-0-4093503392097038294',
        'parse: second snapshot carries its own id' );
    ok( !exists $info->{other},
        'parse: snapshot of another vmid is filtered out' );
}

# ---------------------------------------------------------------------------
# id and timestamp are best effort: the '-' placeholders must not surface.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT = "102_pvesnap - -\n";
    my $info =
      OpenEJovianDSS::NFSCommon::snapshots_info( $CTX, 'data', 'vm-102-disk-0' );

    is( $info->{pvesnap}{name}, 'pvesnap', 'placeholder: snapshot still listed' );
    ok( !exists $info->{pvesnap}{id},
        'placeholder: no id key when the appliance lacks a guid' );
    ok( !exists $info->{pvesnap}{timestamp},
        'placeholder: no timestamp key when the appliance lacks a creation' );
}

# ---------------------------------------------------------------------------
# A name-only line (older jdssc without the flags) is still listed.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT = "102_pvesnap\n";
    my $info =
      OpenEJovianDSS::NFSCommon::snapshots_info( $CTX, 'data', 'vm-102-disk-0' );

    is( $info->{pvesnap}{name}, 'pvesnap', 'legacy: name-only line is listed' );
    ok( !exists $info->{pvesnap}{id} && !exists $info->{pvesnap}{timestamp},
        'legacy: no id or timestamp is invented' );
}

# ---------------------------------------------------------------------------
# A snapshot name without the {vmid}_ prefix is not a plugin snapshot.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT = "plainsnap 6093503392097038296 1753900300\n";
    my $info =
      OpenEJovianDSS::NFSCommon::snapshots_info( $CTX, 'data', 'vm-102-disk-0' );

    is( scalar( keys %$info ), 0, 'foreign: non-plugin snapshot is skipped' );
}

# ---------------------------------------------------------------------------
# A volume name without a vmid disables the vmid filter.
# ---------------------------------------------------------------------------
{
    reset_state();
    $CMD_OUTPUT =
        "102_pvesnap 3093503392097038293 1753900000\n"
      . "205_other 5093503392097038295 1753900200\n";
    my $info =
      OpenEJovianDSS::NFSCommon::snapshots_info( $CTX, 'data', 'groupdir' );

    is( scalar( keys %$info ), 2, 'no vmid: every plugin snapshot is listed' );
    is( $info->{other}{id},
        'groupdir-5093503392097038295',
        'no vmid: foreign entry keeps its id' );
}

print "1..$tests\n";
if ($failures) {
    print "FAILED $failures/$tests\n";
    exit 1;
}
print "PASSED $tests/$tests\n";
exit 0;
