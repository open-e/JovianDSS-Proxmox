#!/usr/bin/perl

# Unit tests for the storage API v15 contract of volume_resize: a
# snapshot-targeted resize (the new $snapname parameter) is refused before
# the plugin touches any storage state.  The end-to-end half of the same
# contract — a native qm resize of a snapshotted volume grows the live
# volume only — lives in
# pve-testing/testcases/iscsi-plugin/api-v15/qm-resize-snapshotted-volume.yaml.

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/..";

BEGIN {
    $INC{'String/Util.pm'}        = __FILE__;
    $INC{'PVE/INotify.pm'}        = __FILE__;
    $INC{'PVE/Tools.pm'}          = __FILE__;
    $INC{'PVE/Cluster.pm'}        = __FILE__;
    $INC{'PVE/Storage.pm'}        = __FILE__;
    $INC{'PVE/Storage/Plugin.pm'} = __FILE__;
    $INC{'JSON.pm'}               = __FILE__;
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
    package PVE::Cluster;
    sub import { }
}
{
    package PVE::Tools;
    our $RUN_COMMAND = sub { die "unexpected run_command in this suite\n" };
    our $IPV4RE      = qr/\d+\.\d+\.\d+\.\d+/;
    our $IPV6RE      = qr/[0-9a-fA-F:]+/;

    sub run_command       { return $RUN_COMMAND->(@_) }
    sub file_set_contents { }
    sub run_with_timeout  { my ( $t, $code, @a ) = @_; return $code->(@a) }

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::run_command"}       = \&run_command;
        *{"${caller}::file_set_contents"} = \&file_set_contents;
        ${"${caller}::IPV4RE"}            = $IPV4RE;
        ${"${caller}::IPV6RE"}            = $IPV6RE;
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
{
    package PVE::Storage;
    use constant APIVER => 15;
    use constant APIAGE => 6;
    sub import { }
}
{
    package PVE::Storage::Plugin;
    sub import { }
}

# The plugin lives at the repo root but declares a PVE::Storage::Custom::
# package, so it is loaded by path rather than by module name.
BEGIN { require "$FindBin::Bin/../OpenEJovianDSSPlugin.pm"; }

my $PLUGIN = 'PVE::Storage::Custom::OpenEJovianDSSPlugin';

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

sub like {
    my ( $got, $re, $desc ) = @_;
    if ( !ok( scalar( ( $got // '' ) =~ $re ), $desc ) ) {
        print "    got:   '" . ( $got // '(undef)' ) . "'\n";
        print "    match: $re\n";
    }
}

my $SCFG = {
    pool_name         => 'Pool-0',
    user_name         => 'admin',
    control_addresses => '127.0.0.1',
};

# ---------------------------------------------------------------------------
# A snapshot-targeted resize is refused with a clear error.
# ---------------------------------------------------------------------------
{
    eval {
        $PLUGIN->volume_resize( $SCFG, 'jdss', 'vm-100-disk-0',
            268435456, 0, 'snap1' );
    };
    like( $@, qr/resizing a snapshot is not supported/,
        'resize: snapshot target is refused' );
}

# ---------------------------------------------------------------------------
# The refusal is the FIRST check: it fires before any storage context is
# built, so even a config the plugin could not act on never gets touched.
# ---------------------------------------------------------------------------
{
    eval {
        $PLUGIN->volume_resize( {}, 'jdss', 'vm-100-disk-0',
            268435456, 0, 'snap1' );
    };
    like( $@, qr/resizing a snapshot is not supported/,
        'resize: refusal precedes any use of the storage configuration' );
}

# ---------------------------------------------------------------------------
# An empty snapshot name is not a snapshot target — the guard must trigger
# on definedness, not on truthiness (the resize proceeds past it and dies
# later on the unusable test config instead).
# ---------------------------------------------------------------------------
{
    eval {
        $PLUGIN->volume_resize( {}, 'jdss', 'vm-100-disk-0',
            268435456, 0, undef );
    };
    ok( ( $@ // '' ) !~ /resizing a snapshot is not supported/,
        'resize: undef snapname is not treated as a snapshot target' );
}

print "1..$tests\n";
if ($failures) {
    print "FAILED $failures/$tests\n";
    exit 1;
}
print "PASSED $tests/$tests\n";
exit 0;
