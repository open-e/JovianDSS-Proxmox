#!/usr/bin/perl

# Unit tests for the NFS plugin's configuration update hooks:
#   classic on_update_hook — storage-only, two channels (pre-v11 inline
#       update values and sensitive parameters), user_password can be
#       changed but never cleared;
#   on_update_hook_full (storage API v13) — refuse-then-apply: the
#       set+delete conflict pre-check and every refusal run before any
#       password-file write.
# Structure mirrors the iSCSI plugin's check/apply architecture.

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
    package PVE::Storage::Plugin;
    sub import { }
}
{
    package PVE::Storage::DirPlugin;
    sub import { }
}

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
# Doubles: the password-file writer records instead of touching disk; the
# never-clear refusal stays the real pure-die function so its message is
# pinned; debug logging is silenced.
# ---------------------------------------------------------------------------

my @SET_CALLS;

{
    no warnings 'redefine';
    *OpenEJovianDSS::Common::password_file_set_password = sub {
        my ( $storage_type, $storeid, $password ) = @_;
        push @SET_CALLS,
          { type => $storage_type, storeid => $storeid, value => $password };
        return;
    };
    *OpenEJovianDSS::Common::debugmsg = sub { };
}

my $STOREID = 'jdssnfs';
my $SCFG    = {
    export  => '/Pools/Pool-0/data',
    server  => '127.0.0.1',
    path    => '/mnt/pve/jdssnfs',
    user_name => 'admin',
};

sub reset_state { @SET_CALLS = (); }

# ---------------------------------------------------------------------------
# Classic hook, update channel: pre-v11 hosts deliver user_password inline
# in the update options — the hook must store it.
# ---------------------------------------------------------------------------
{
    reset_state();
    my $inline_update = { user_password => 'inlinepw1' };
    $PLUGIN->on_update_hook( $STOREID, $inline_update );
    is( scalar(@SET_CALLS), 1, 'classic: inline user_password is stored' );
    is( $SET_CALLS[0]{value}, 'inlinepw1',
        'classic: the inline value reaches the password file writer' );
    is( $SET_CALLS[0]{type}, $PLUGIN->type(),
        'classic: the writer is keyed by the plugin storage type' );
    # The hook stores the credential but deliberately leaves $opts_update
    # untouched - the plugin does not rewrite the caller's update options.
    is( $inline_update->{user_password}, 'inlinepw1',
        'classic: the update options are left as the caller passed them' );
}

# ---------------------------------------------------------------------------
# Classic hook, sensitive channel: set stores, undef refuses with the
# canonical never-clear message.
# ---------------------------------------------------------------------------
{
    reset_state();
    $PLUGIN->on_update_hook( $STOREID, {}, user_password => 'sensipw2' );
    is( scalar(@SET_CALLS), 1, 'classic: sensitive user_password is stored' );
    is( $SET_CALLS[0]{value}, 'sensipw2',
        'classic: the sensitive value reaches the password file writer' );
}
{
    reset_state();
    eval { $PLUGIN->on_update_hook( $STOREID, {}, user_password => undef ); };
    like( $@, qr/user_password cannot be cleared/,
        'classic: clearing user_password is refused with the canonical message' );
    is( scalar(@SET_CALLS), 0, 'classic: the refusal writes nothing' );
}

# ---------------------------------------------------------------------------
# Full hook: a plain update without any delete list must be tolerated —
# real PVE passes undef when pvesm set has no --delete.
# ---------------------------------------------------------------------------
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, { content => 'images' },
            undef, {} );
    };
    is( $@, '', 'full: undef delete list is tolerated' );
    is( scalar(@SET_CALLS), 0, 'full: a non-sensitive update writes nothing' );
}

# ---------------------------------------------------------------------------
# Full hook: a sensitive user_password update is applied after the checks.
# ---------------------------------------------------------------------------
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, {}, [],
            { user_password => 'fullpw3' } );
    };
    is( $@, '', 'full: sensitive password update is accepted' );
    is( scalar(@SET_CALLS), 1, 'full: the update reaches the writer once' );
    is( $SET_CALLS[0]{value}, 'fullpw3', 'full: the new value is stored' );
}

# ---------------------------------------------------------------------------
# Full hook: set+delete of one property in one request is refused — both
# for plain and for sensitive properties (PVE itself resolves the sensitive
# combination to a set; the plugin is deliberately stricter).
# ---------------------------------------------------------------------------
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, { content => 'images' },
            ['content'], {} );
    };
    like( $@, qr/property 'content' is both updated and deleted/,
        'full: plain set+delete conflict is refused' );
}
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, {},
            ['user_password'], { user_password => 'newpw4' } );
    };
    like( $@, qr/property 'user_password' is both updated and deleted/,
        'full: sensitive set+delete conflict is refused' );
    is( scalar(@SET_CALLS), 0, 'full: the refused conflict writes nothing' );
}

# ---------------------------------------------------------------------------
# Full hook: deleting user_password is refused by the sensitive check (the
# deletion arrives as an undefined sensitive value plus a delete entry).
# ---------------------------------------------------------------------------
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, {},
            ['user_password'], { user_password => undef } );
    };
    like( $@, qr/user_password is required and should not be removed/,
        'full: deleting user_password is refused' );
    is( scalar(@SET_CALLS), 0, 'full: the refused deletion writes nothing' );
}

# ---------------------------------------------------------------------------
# Full hook: deleting user_name is refused by the delete check.
# ---------------------------------------------------------------------------
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, {}, ['user_name'], {} );
    };
    like( $@, qr/Both user_name and user_password is required/,
        'full: deleting user_name is refused' );
}

# ---------------------------------------------------------------------------
# Full hook: every refusal is decided before any write — a mixed update
# carrying a valid new password next to a refused deletion must leave the
# password file untouched.
# ---------------------------------------------------------------------------
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, {}, ['user_name'],
            { user_password => 'newpw5' } );
    };
    like( $@, qr/Both user_name and user_password is required/,
        'full: the mixed update is refused at the delete check' );
    is( scalar(@SET_CALLS), 0,
        'full: the valid password half of a refused update is not written' );
}

# ---------------------------------------------------------------------------
# Full hook: deleting an unrelated optional property alone passes and
# writes nothing.
# ---------------------------------------------------------------------------
{
    reset_state();
    eval {
        $PLUGIN->on_update_hook_full( $STOREID, $SCFG, {}, ['options'], {} );
    };
    is( $@, '', 'full: deleting an unrelated optional property is accepted' );
    is( scalar(@SET_CALLS), 0, 'full: it writes nothing' );
}

# ---------------------------------------------------------------------------
# alloc_image refuses every non-raw format before touching the filesystem.
# PVE core does not enforce plugindata's format list at allocation time
# (Issue 8), so this guard is the only thing standing between a
# 'pvesm alloc --format qcow2' and a real qcow2 file on the share.
# ---------------------------------------------------------------------------
{
    my $scfg = { type => 'joviandss-nfs', server => '127.0.0.1',
                 export => '/Pools/Pool-0/data', path => '/mnt/pve/teststore',
                 user_name => 'admin' };
    for my $fmt (qw(qcow2 vmdk subvol)) {
        eval { $PLUGIN->alloc_image( 'teststore', $scfg, 990001, $fmt, undef, 1048576 ) };
        like( $@, qr/unsupported format '\Q$fmt\E'.*only supports raw/,
            "alloc_image refuses format '$fmt' with the raw-only message" );
    }
}

print "1..$tests\n";
if ($failures) {
    print "FAILED $failures/$tests\n";
    exit 1;
}
print "PASSED $tests/$tests\n";
exit 0;
