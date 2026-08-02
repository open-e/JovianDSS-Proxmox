#!/usr/bin/perl

# Unit tests for the storage API v11-v14 surface of the plugin:
#
#   v11 — sensitive properties: the plugindata declaration, the
#         on_add/on_update/on_delete hooks routing user_password and
#         chap_user_password into the restricted password file (key-value
#         format, 0600 file in a 0700 directory), the change-but-never-
#         clear rule for user_password and the chap cross-validation.
#   v12 — qemu_blockdev_options (host_device + activated path, snapshot
#         pass-through), volume_qemu_snapshot_method ('storage'), the
#         raw-only format declaration behind get_formats, and the
#         deliberate absence of rename_snapshot.
#   v13 — activation and deactivation tolerate the hints parameter; the
#         absence of on_update_hook_full is pinned (its deletion
#         blind spot is Issue 7 in docs/issues/ISSUES.md).
#   v14 — get_identity: pool-name-plus-pool-id identity, retry on
#         transient failures, clear error when the appliance answer stays
#         unusable.
#
# The end-to-end halves live in
# pve-testing/testcases/iscsi-plugin/api-compatibility/v11 through v14.

use strict;
use warnings;

use File::Temp ();
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

    sub run_command { return $RUN_COMMAND->(@_) }

    # Real file operations: the password machinery is under test, so the
    # stubs must honor content and permissions on actual files (redirected
    # into a temp directory by the get_plugin_password_dir override below).
    sub file_set_contents {
        my ( $file, $data, $perm ) = @_;
        open( my $fh, '>', $file ) or die "file_set_contents $file: $!\n";
        print {$fh} $data;
        close $fh;
        chmod( $perm // 0644, $file ) or die "chmod $file: $!\n";
        return;
    }

    sub file_get_contents {
        my ($file) = @_;
        open( my $fh, '<', $file ) or die "file_get_contents $file: $!\n";
        local $/;
        my $data = <$fh>;
        close $fh;
        return $data;
    }

    sub run_with_timeout { my ( $t, $code, @a ) = @_; return $code->(@a) }

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
    if ( !ok( ( $got // '' ) =~ $re, $desc ) ) {
        print "    got:   '" . ( $got // '(undef)' ) . "'\n";
        print "    match: $re\n";
    }
}

sub slurp {
    my ($file) = @_;
    open( my $fh, '<', $file ) or return undef;
    local $/;
    my $data = <$fh>;
    close $fh;
    return $data;
}

# ---------------------------------------------------------------------------
# Password directory redirected into a temp tree; the plugin's own
# make_path creates the final component, so its mode is honestly testable.
# ---------------------------------------------------------------------------

my $TMPDIR = File::Temp->newdir();
my $PWDIR  = "$TMPDIR/joviandss";
{
    no warnings 'redefine';
    *OpenEJovianDSS::Common::get_plugin_password_dir = sub { return $PWDIR };
}

my $STOREID = 'apitest';
my $PWFILE  = "$PWDIR/$STOREID.pw";
my $SCFG    = {
    pool_name          => 'Pool-0',
    user_name          => 'admin',
    control_addresses  => '127.0.0.1',
    'create-base-path' => 0,
};

# ---------------------------------------------------------------------------
# v11: plugindata declarations
# ---------------------------------------------------------------------------
{
    my $pd = $PLUGIN->plugindata;
    my $sp = $pd->{'sensitive-properties'};
    ok( ref($sp) eq 'HASH'
          && $sp->{user_password}
          && $sp->{chap_user_password}
          && keys(%$sp) == 2,
        'v11: plugindata declares user_password and chap_user_password sensitive' );
    ok( !exists $pd->{features},
        'v11: plugindata claims no features (not a backup provider)' );
}

# ---------------------------------------------------------------------------
# v11: on_add_hook stores the password securely
# ---------------------------------------------------------------------------
{
    $PLUGIN->on_add_hook( $STOREID, $SCFG, user_password => 's3cr3t1' );
    ok( -f $PWFILE, 'add: password file created' );
    is( slurp($PWFILE), "user_password s3cr3t1\n",
        'add: file carries the property in key-value form' );
    is( sprintf( "%04o", ( stat($PWFILE) )[2] & 07777 ),
        '0600', 'add: password file mode is 0600' );
    is( sprintf( "%04o", ( stat($PWDIR) )[2] & 07777 ),
        '0700', 'add: password directory mode is 0700' );

    my $ctx = OpenEJovianDSS::Common::new_ctx( $SCFG, $STOREID );
    is( OpenEJovianDSS::Common::get_user_password($ctx),
        's3cr3t1', 'add: the stored password is what the plugin reads back' );
}

# ---------------------------------------------------------------------------
# v11: a storage must not come into existence without a stored password
# ---------------------------------------------------------------------------
{
    unlink $PWFILE;
    eval { $PLUGIN->on_add_hook( 'otherstore', $SCFG ) };
    like( $@, qr/user password is not\s+stored/,
        'add: refused when no password is supplied or stored' );

    # restore the working state for the following sections
    $PLUGIN->on_add_hook( $STOREID, $SCFG, user_password => 's3cr3t1' );
}

# ---------------------------------------------------------------------------
# v11: on_update_hook replaces but never clears user_password
# ---------------------------------------------------------------------------
{
    $PLUGIN->on_update_hook( $STOREID, $SCFG, user_password => 'n3wpass' );
    is( slurp($PWFILE), "user_password n3wpass\n",
        'update: new password replaces the stored value' );

    eval { $PLUGIN->on_update_hook( $STOREID, $SCFG, user_password => undef ) };
    like( $@, qr/cannot be cleared/,
        'update: clearing user_password is refused' );
    is( slurp($PWFILE), "user_password n3wpass\n",
        'update: the stored value survives the refused clearing' );
}

# ---------------------------------------------------------------------------
# v11: chap_user_password shares the file and can be individually removed
# ---------------------------------------------------------------------------
{
    $PLUGIN->on_update_hook( $STOREID, $SCFG, chap_user_password => 'chappw' );
    is( slurp($PWFILE), "chap_user_password chappw\nuser_password n3wpass\n",
        'chap: both properties stored in one sorted key-value file' );

    $PLUGIN->on_update_hook( $STOREID, $SCFG, chap_user_password => undef );
    is( slurp($PWFILE), "user_password n3wpass\n",
        'chap: chap password removed individually, user_password kept' );
}

# ---------------------------------------------------------------------------
# v11: chap_enabled cross-validation
# ---------------------------------------------------------------------------
{
    my $chap_scfg = { %$SCFG, chap_enabled => 1 };
    eval { $PLUGIN->on_update_hook( $STOREID, $chap_scfg ) };
    like( $@, qr/chap_user_name is required/,
        'chap: enabling chap without a chap user name is refused' );
}

# ---------------------------------------------------------------------------
# v11: on_delete_hook removes the whole file
# ---------------------------------------------------------------------------
{
    $PLUGIN->on_delete_hook( $STOREID, $SCFG );
    ok( !-f $PWFILE, 'delete: password file removed with the storage' );
}

# ---------------------------------------------------------------------------
# v12: declared API version covers the v11/v12 contracts
# ---------------------------------------------------------------------------
{
    is( $PLUGIN->api, 15, 'v12: api() answers the stubbed APIVER 15' );
}

# ---------------------------------------------------------------------------
# v12: volume_qemu_snapshot_method declares transparent storage snapshots
# ---------------------------------------------------------------------------
{
    is( $PLUGIN->volume_qemu_snapshot_method( $STOREID, $SCFG, 'vm-100-disk-0' ),
        'storage',
        'v12: running-VM snapshots are declared storage-handled' );
}

# ---------------------------------------------------------------------------
# v12: qemu_blockdev_options returns host_device with the activated path
# ---------------------------------------------------------------------------
{
    my @path_calls;
    no strict 'refs';
    no warnings 'redefine';
    local *{"${PLUGIN}::_path"} = sub {
        my ( $class, $ctx, $volname, $snapname ) = @_;
        push @path_calls, { volname => $volname, snapname => $snapname };
        return [ '/dev/mapper/testdev', 990001, 'images' ];
    };

    my $bd = $PLUGIN->qemu_blockdev_options( $SCFG, $STOREID,
        'vm-990001-disk-0', '9.2', {} );
    ok( ref($bd) eq 'HASH'
          && $bd->{driver} eq 'host_device'
          && $bd->{filename} eq '/dev/mapper/testdev'
          && keys(%$bd) == 2,
        'v12: blockdev options are host_device plus the device path' );
    is( $path_calls[0]{snapname}, undef,
        'v12: no snapshot name resolves the live volume path' );

    $PLUGIN->qemu_blockdev_options( $SCFG, $STOREID, 'vm-990001-disk-0',
        '9.2', { 'snapshot-name' => 'snap1' } );
    is( $path_calls[1]{snapname}, 'snap1',
        'v12: the snapshot-name option is passed through to path resolution' );
}

# ---------------------------------------------------------------------------
# v12: format declaration behind get_formats — raw only, raw default
# ---------------------------------------------------------------------------
{
    my $fmt = $PLUGIN->plugindata->{format};
    ok( ref($fmt) eq 'ARRAY'
          && $fmt->[0]{raw}
          && !$fmt->[0]{subvol}
          && $fmt->[1] eq 'raw',
        'v12: raw is the only enabled format and the default' );
}

# ---------------------------------------------------------------------------
# v12: the declared format is enforced at allocation time — PVE does not
# check the storage's format list itself (Issue 8).
# ---------------------------------------------------------------------------
{
    no strict 'refs';
    no warnings 'redefine';

    my $allocated = 0;
    local *{"${PLUGIN}::_alloc_image_lock"} = sub { $allocated++; return 'vm-100-disk-0' };

    eval {
        $PLUGIN->alloc_image( $STOREID, $SCFG, 100, 'qcow2',
            'vm-100-disk-0.qcow2', 131072 );
    };
    like( $@, qr/unsupported format 'qcow2'/,
        'v12: allocation with an unsupported format is refused' );
    is( $allocated, 0,
        'v12: the refused allocation never reaches the storage' );

    eval { $PLUGIN->alloc_image( $STOREID, $SCFG, 100, 'raw', 'vm-100-disk-0', 131072 ) };
    is( $@, '', 'v12: raw allocation passes the format guard' );
    is( $allocated, 1, 'v12: the raw allocation proceeds to the storage' );

    eval { $PLUGIN->alloc_image( $STOREID, $SCFG, 100, undef, 'vm-100-disk-0', 131072 ) };
    is( $@, '', 'v12: an unspecified format defaults through the guard' );
}

# ---------------------------------------------------------------------------
# v12: rename_snapshot is deliberately absent — the 'storage' snapshot
# method never triggers it (only 'mixed' flows do).
# ---------------------------------------------------------------------------
{
    ok( !$PLUGIN->can('rename_snapshot'),
        'v12: rename_snapshot not implemented, per the storage method' );
}

# ---------------------------------------------------------------------------
# v13: activation and deactivation tolerate the hints parameter — the
# plugin ignores hints, which the contract explicitly allows.
# ---------------------------------------------------------------------------
{
    no strict 'refs';
    no warnings 'redefine';

    my $hints = { 'plugin-may-deactivate-volume' => 1 };

    my @act;
    local *{"${PLUGIN}::_activate_volume_lock"} = sub {
        my ( $class, $ctx, $volname, $snapname, $cache ) = @_;
        push @act, { volname => $volname };
        return 1;
    };
    eval {
        $PLUGIN->activate_volume( $STOREID, $SCFG, 'vm-100-disk-0',
            undef, {}, $hints );
    };
    is( $@, '', 'v13: activate_volume accepts a defined hints hashref' );
    is( scalar(@act), 1, 'v13: activation proceeds with hints present' );

    my @deact;
    local *{"${PLUGIN}::_deactivate_volume_lock"} = sub {
        my ( $class, $ctx, $volname, $snapname, $cache, $h ) = @_;
        push @deact, { hints => $h };
        return 1;
    };
    eval {
        $PLUGIN->deactivate_volume( $STOREID, $SCFG, 'vm-100-disk-0',
            undef, {}, $hints );
    };
    is( $@, '', 'v13: deactivate_volume accepts a hints hashref' );
    is( $deact[0]{hints}, $hints,
        'v13: deactivation threads the hints reference through' );
}

# ---------------------------------------------------------------------------
# v13: on_update_hook_full is not implemented — pinned deliberately. Its
# absence means property DELETIONS stay invisible to the update hook (a
# deleted chap_user_name bypasses the chap validation, Issue 7); when the
# hook gets implemented this pin must flip.
# ---------------------------------------------------------------------------
{
    ok( !$PLUGIN->can('on_update_hook_full'),
        'v13: on_update_hook_full not implemented (deletion gap: Issue 7)' );
}

# ---------------------------------------------------------------------------
# v14: get_identity answers the pool identity from the appliance
# ---------------------------------------------------------------------------
{
    no strict 'refs';
    no warnings 'redefine';

    my ( @cmds, @responses );
    local *{"${PLUGIN}::joviandss_cmd"} = sub {
        my ( $ctx, $cmd ) = @_;
        push @cmds, join( ' ', @$cmd );
        my $r = shift @responses;
        die $r->{die} if ref($r) && $r->{die};
        return $r;
    };
    local *{"${PLUGIN}::debugmsg"} = sub { };

    @responses =
      ("Pool-0 8138266952553772026 107374182400 53687091200 53687091200\n");
    is( $PLUGIN->get_identity( $SCFG, $STOREID ),
        'Pool-0-8138266952553772026',
        'v14: identity is the pool name plus the appliance pool id' );
    is( $cmds[0], 'pool Pool-0 get',
        'v14: identity is sourced from the pool get query' );

    @cmds      = ();
    @responses = (
        { die => "transient REST failure\n" },
        { die => "transient REST failure\n" },
        "Pool-0 42 1 1 0\n",
    );
    is( $PLUGIN->get_identity( $SCFG, $STOREID ),
        'Pool-0-42',
        'v14: transient failures are retried up to three attempts' );

    @responses = ( "garbage\n", "garbage\n", "garbage\n" );
    eval { $PLUGIN->get_identity( $SCFG, $STOREID ) };
    like( $@, qr/Unable to get storage identity/,
        'v14: persistently unusable answers end in a clear error' );
}

print "1..$tests\n";
if ($failures) {
    print "FAILED $failures/$tests\n";
    exit 1;
}
print "PASSED $tests/$tests\n";
exit 0;
