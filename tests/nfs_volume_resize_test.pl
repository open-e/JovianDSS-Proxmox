#!/usr/bin/perl

# Unit tests for the storage API v15 contract of the NFS plugin's
# volume_resize: a snapshot-targeted resize (the new $snapname parameter)
# is refused before the plugin touches any storage state, and a plain
# resize is delegated to the base file-based implementation unchanged.

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/..";

BEGIN {
    $INC{'String/Util.pm'}           = __FILE__;
    $INC{'Net/IP.pm'}                = __FILE__;
    $INC{'IO/File.pm'}               = __FILE__;
    $INC{'PVE/INotify.pm'}           = __FILE__;
    $INC{'PVE/Tools.pm'}             = __FILE__;
    $INC{'PVE/Cluster.pm'}           = __FILE__;
    $INC{'PVE/Network.pm'}           = __FILE__;
    $INC{'PVE/ProcFSTools.pm'}       = __FILE__;
    $INC{'PVE/JSONSchema.pm'}        = __FILE__;
    $INC{'PVE/Storage.pm'}           = __FILE__;
    $INC{'PVE/Storage/Plugin.pm'}    = __FILE__;
    $INC{'PVE/Storage/DirPlugin.pm'} = __FILE__;
    $INC{'JSON.pm'}                  = __FILE__;
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
    package IO::File;
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
    package PVE::Network;
    sub import { }
}
{
    package PVE::ProcFSTools;
    sub import { }
}
{
    package PVE::JSONSchema;
    sub get_standard_option { return {} }

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::get_standard_option"} = \&get_standard_option;
    }
}
{
    package PVE::Tools;
    our $IPV4RE = qr/\d+\.\d+\.\d+\.\d+/;
    our $IPV6RE = qr/[0-9a-fA-F:]+/;

    sub run_command       { die "unexpected run_command in this suite\n" }
    sub file_set_contents { }
    sub file_get_contents { '' }
    sub run_with_timeout  { my ( $t, $code, @a ) = @_; return $code->(@a) }

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::run_command"}       = \&run_command;
        *{"${caller}::file_set_contents"} = \&file_set_contents;
        *{"${caller}::file_get_contents"} = \&file_get_contents;
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
    # The base class records delegated resize calls so the tests can pin
    # that a plain resize reaches the inherited file-based implementation.
    package PVE::Storage::Plugin;
    our @RESIZE_CALLS;
    sub import { }

    sub volume_resize {
        my ( $class, @args ) = @_;
        push @RESIZE_CALLS, [@args];
        return 'base-resize-called';
    }
}
{
    package PVE::Storage::DirPlugin;
    sub import { }
}

# The plugin lives at the repo root but declares a PVE::Storage::Custom::
# package, so it is loaded by path rather than by module name.
BEGIN { require "$FindBin::Bin/../OpenEJovianDSSNFSPlugin.pm"; }

my $PLUGIN = 'PVE::Storage::Custom::OpenEJovianDSSNFSPlugin';

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
    export => '/Pools/Pool-0/data',
    server => '127.0.0.1',
};

# ---------------------------------------------------------------------------
# A snapshot-targeted resize is refused with a clear error.
# ---------------------------------------------------------------------------
{
    local @PVE::Storage::Plugin::RESIZE_CALLS = ();
    eval {
        $PLUGIN->volume_resize( $SCFG, 'jdssnfs', '100/vm-100-disk-0.raw',
            268435456, 0, 'snap1' );
    };
    like( $@, qr/resizing a snapshot is not supported/,
        'resize: snapshot target is refused' );
    ok( !@PVE::Storage::Plugin::RESIZE_CALLS,
        'resize: nothing is delegated to the base after the refusal' );
}

# ---------------------------------------------------------------------------
# The refusal is the FIRST check: it fires before any storage state is
# touched, so even a config the plugin could not act on never gets used.
# ---------------------------------------------------------------------------
{
    eval {
        $PLUGIN->volume_resize( {}, 'jdssnfs', '100/vm-100-disk-0.raw',
            268435456, 0, 'snap1' );
    };
    like( $@, qr/resizing a snapshot is not supported/,
        'resize: refusal precedes any use of the storage configuration' );
}

# ---------------------------------------------------------------------------
# An undef snapshot name is a plain resize: it is delegated to the base
# file-based implementation with the original arguments.
# ---------------------------------------------------------------------------
{
    local @PVE::Storage::Plugin::RESIZE_CALLS = ();
    my $ret = $PLUGIN->volume_resize( $SCFG, 'jdssnfs',
        '100/vm-100-disk-0.raw', 268435456, 0, undef );
    ok( scalar(@PVE::Storage::Plugin::RESIZE_CALLS) == 1,
        'resize: undef snapname is delegated to the base implementation' );
    my $args = $PVE::Storage::Plugin::RESIZE_CALLS[0] || [];
    ok(
        @$args == 5
          && $args->[2] eq '100/vm-100-disk-0.raw'
          && $args->[3] == 268435456,
        'resize: the base receives the original resize arguments'
    );
    ok( ( $ret // '' ) eq 'base-resize-called',
        'resize: the base result is passed through' );
}

print "1..$tests\n";
if ($failures) {
    print "FAILED $failures/$tests\n";
    exit 1;
}
print "PASSED $tests/$tests\n";
exit 0;
