#    Copyright (c) 2025 Open-E, Inc.
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

package PVE::Storage::Custom::OpenEJovianDSSPlugin;

use strict;
use warnings;

use Data::Dumper;

#use Encode   qw(decode encode);
#use Storable qw(lock_store lock_retrieve);

use File::Path qw(make_path);

#use File::Temp qw(tempfile);
use File::Basename;

use Time::HiRes qw(gettimeofday);

use PVE::Tools qw(run_command);
use PVE::Tools qw($IPV4RE);
use PVE::Tools qw($IPV6RE);

#use PVE::INotify;
#TODO: comment/uncomment to enable criticue operation
use PVE::Storage;
use PVE::Storage::Plugin;

#use PVE::SafeSyslog;

use OpenEJovianDSS::Common qw(:all);
use OpenEJovianDSS::Lock;
use base                   qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.11.5';

#    Open-E JovianDSS Proxmox plugin
#
#    0.9.8-5 - 2024.09.30
#               Add rollback to the latest volume snapshot
#               Introduce share option that substitutes proxmox code modification
#               Fix migration failure
#               Extend REST API error handling
#               Fix volume provisioning bug
#               Fix Pool selection bug
#               Prevent possible iscsi target name collision
#
#    0.9.9.0 - 2024.11.15
#               Add NFS base context volume
#               Fix volume resize problem
#               Fix incorrect volume allocation size
#               Fix volume migration problem
#
#    0.9.9.1 - 2024.12.13
#               Provide dynamic target name prefix generation
#               Enforce VIP addresses for iscsi targets
#               Fix volume resize for running machine
#
#    0.9.9.2 - 2024.12.17
#               Add logging to jdssc debug file
#               Fix data corruption during migration
#
#    0.9.10-8 - 2025.04.02
#               Make plugin configurable solely by from storage.cfg
#               Provide code style improvement
#
#    0.10.0-0 - 2025.06.17
#               Storing information about activated volumes and snapshots
#               localy
#               Support proxmox API v11
#               Major code rework
#
#    0.10.2-0 - 2025.08.08
#               Fix sparce lun numbering for iscsi
#
#    0.10.3-0 - 2025.08.12
#               Fix misleading "multiple records" error during VM snapshot creation
#               Fix deletion of non-existing volumes
#               Improve error message formatting for LUN record conflicts
#
#    0.10.4-0 - 2025.08.13
#               Add sensitive-properties support for user_password
#               Update API version to 12 for Proxmox VE 9.x support
#
#    0.10.5-0 - 2025.08.14
#               Enable thin provisioning by default
#               Improve iSCSI session management and error handling
#               Add comprehensive thin/thick provisioning test scenarios
#               Update documentation with Proxmox backup limitations
#               Fix redundant iSCSI login attempts and error messages

# Configuration

sub api {
    my $supported_apiver_min = 9;
    my $supported_apiver_max = 14;

    my $api_ver = PVE::Storage::APIVER;

    if ($api_ver >= $supported_apiver_min and $api_ver <= $supported_apiver_max) {
        return $api_ver;
    }
    return $supported_apiver_max;
}

sub type {
    return OpenEJovianDSS::Common::PLUGIN_TYPE_JOVIANDSS;
}

sub plugindata {
    return {
        content => [
            {
                images  => 1,
                rootdir => 1,
                none    => 1
            },
            { images => 1, rootdir => 1 }
        ],
        format => [ { raw => 1, subvol => 0 }, 'raw' ],
        'sensitive-properties' => {
            'user_password'      => 1,
            'chap_user_password' => 1,
        },
    };
}

sub properties {
    return {
        pool_name => {
            description => "Pool name",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_pool(),
        },
        config => {
            description => "JovianDSS config address",
            type        => 'string',
        },
        multipath => {
            description => "Enable multipath support",
            type        => 'boolean',
            default     => OpenEJovianDSS::Common::get_default_multipath(),
        },
        user_name => {
            description => "User name that will be used in REST communication",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_user_name(),
        },
        user_password => {
            description =>
              "User password that will be used in REST communication",
            type => 'string',
        },
        target_prefix => {
            description => "Prefix of iSCSI target 'iqn.2025-04.iscsi:'",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_target_prefix(),
        },
        luns_per_target => {
            description =>
              'Maximum number of luns assigned to single iSCSI target',
            type    => 'int',
            default => OpenEJovianDSS::Common::get_default_luns_per_target(),
        },
        jdssc_timeout => {
            description =>
              'Default execution timeout in seconds for jdssc calls; the plugin '
              . 'kills the process at timeout + 1 (bounded by the cluster-lock clamp)',
            type    => 'integer',
            minimum => 10,
            default => OpenEJovianDSS::Common::get_default_jdssc_timeout(),
        },
        %{ OpenEJovianDSS::Common::lock_properties() },
        ssl_cert_verify => {
            description =>
              "Enforce certificate verification for REST over SSL/TLS",
            type => 'boolean',
        },
        delete_timeout => {
            description =>
              "Timeout in seconds for volume delete operations (default 600). "
              . "Increase this if the JovianDSS pool has many snapshots and "
              . "volume deletion takes longer than the default.",
            type    => 'int',
            default => 600,
        },
        control_addresses => {
            description =>
"Coma separated list of ip addresses, that will be used to send control REST requests to JovianDSS storage",
            type => 'string',
        },
        control_port => {
            description =>
"Port number that will be used to send REST request, single for all addresses",
            type    => 'int',
            default => OpenEJovianDSS::Common::get_default_control_port(),
        },
        data_addresses => {
            description =>
"Coma separated list of ip addresses, that will be used to transfer storage data(iSCSI data)",
            type => 'string',
        },
        data_port => {
            description =>
"Port number that will be used to transfer storage data(iSCSI data)",
            type    => 'int',
            default => OpenEJovianDSS::Common::get_default_data_port(),
        },
        block_size => {
            description =>
              'Block size for newly created volumes, allowed values are: '
              . '4K 8K 16K 32K 64K 128K 256K 512K 1M',
            type    => 'string',
            default => '16K'
        },
        thin_provisioning => {
            description => 'Create new volumes as thin',
            type        => 'boolean',
            default     => 1,
        },
        chap_enabled => {
            description => 'Enable CHAP authentication for iSCSI targets',
            type        => 'boolean',
            default     => 0,
        },
        chap_user_name => {
            description => 'CHAP initiator username presented to iSCSI targets',
            type        => 'string',
        },
        chap_user_password => {
            description => 'CHAP initiator password for iSCSI authentication',
            type        => 'string',
        },
        cluster_prefix => {
            description =>
              "Volume name prefix for cluster isolation. "
              . "When set, only volumes whose names start with this prefix "
              . "are visible to this storage instance. Allows multiple "
              . "Proxmox clusters to share the same JovianDSS pool without "
              . "seeing each other's volumes. "
              . "Only letters and digits allowed (e.g. 'pveA', 'cluster01').",
            type    => 'string',
            pattern => '[a-zA-Z][a-zA-Z0-9]*',
        },
        debug => {
            description => "Allow debug prints",
            type        => 'boolean',
            default     => OpenEJovianDSS::Common::get_default_debug(),
        },
        log_file => {
            description => "Log file path",
            type        => 'string',
            default     => '/var/log/joviandss/joviandss.log',
        },
    };
}

sub options {
    return {
        pool_name          => { fixed    => 1 },
        config             => { optional => 1 },
        path               => { optional => 1 },
        debug              => { optional => 1 },
        multipath          => { optional => 1 },
        content            => { optional => 1 },
        shared             => { optional => 1 },
        disable            => { optional => 1 },
        target_prefix      => { optional => 1 },
        luns_per_target    => { optional => 1 },
        jdssc_timeout                 => { optional => 1 },
        jdssc_general_lock_type            => { optional => 1 },
        jdssc_general_lock_path            => { optional => 1 },
        jdssc_general_lock_acquire_timeout => { optional => 1 },
        jdssc_general_lock_hold_timeout    => { optional => 1 },
        jdssc_info_lock_type               => { optional => 1 },
        jdssc_info_lock_path               => { optional => 1 },
        jdssc_info_lock_acquire_timeout    => { optional => 1 },
        jdssc_info_lock_hold_timeout       => { optional => 1 },
        multipath_lock_type                => { optional => 1 },
        multipath_lock_path                => { optional => 1 },
        multipath_lock_acquire_timeout     => { optional => 1 },
        multipath_lock_hold_timeout        => { optional => 1 },
        ssl_cert_verify    => { optional => 1 },
        delete_timeout     => { optional => 1 },
        user_name          => { },
        user_password      => { optional => 1 },
        control_addresses  => { optional => 1 },
        control_port       => { optional => 1 },
        data_addresses     => { },
        data_port          => { optional => 1 },
        block_size         => { optional => 1 },
        thin_provisioning  => { optional => 1 },
        chap_enabled       => { optional => 1 },
        chap_user_name     => { optional => 1 },
        chap_user_password => { optional => 1 },
        cluster_prefix     => { optional => 1, fixed => 1 },
        log_file           => { optional => 1 },
        'create-subdirs'   => { optional => 1 },
        'create-base-path' => { optional => 1 },
        'content-dirs'     => { optional => 1 },
    };
}

my $ISCSIADM = '/usr/bin/iscsiadm';
$ISCSIADM = undef if !-X $ISCSIADM;

my $SYSTEMCTL = '/usr/bin/systemctl';
$SYSTEMCTL = undef if !-X $SYSTEMCTL;

sub path {
    my ( $class, $scfg, $volname, $storeid, $snapname ) = @_;
    # Thin entry point for PVE core: create the per-operation ctx once, delegate,
    # then map _path()'s fixed [$path, $vmid, $vtype] shape onto PVE's wantarray
    # contract here, at the top level. Internal callers must use _path() with the
    # ctx of the volume's own storage so the ctx is built exactly once and threaded
    # down.
    my ( $path, $vmid, $vtype ) =
      @{ _path( $class, new_ctx( $scfg, $storeid ), $volname, $snapname ) };
    return wantarray ? ( $path, $vmid, $vtype ) : $path;
}

# _path always returns a fixed-shape arrayref [$path, $vmid, $vtype] and never
# branches on wantarray (internal helper convention — context handling lives only
# in the top-level path()). $path is undef when the volume does not exist.
sub _path {
    my ( $class, $ctx, $volname, $snapname ) = @_;
    my $scfg = $ctx->{scfg};
    debugmsg($ctx, 'debug', "Path start for volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . "\n");

    my $pool = get_pool($ctx);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);
    my $volname_clustered = volume_name_clustered( $ctx, $volname );

    my $path = undef;

    if ( $vtype eq "images" ) {
        my $til = lun_record_local_get_info_list( $ctx, $volname_clustered, $snapname );

        unless (@$til) {
            eval {
                debugmsg($ctx, 'debug', "None lun records found for volume ${volname}, "
                      . safe_var_print( "snapshot", $snapname )
                      . "\n");

                my $pathval = block_device_path_from_rest( $ctx, $volname_clustered, $snapname );

                $pathval =~ m{^([\:\w\-/\.]+)$}
                  or die "Invalid source path '$pathval'";
                $path = $pathval;
            };

            if ($@) {
                my $error = $@;
                # Handle specific "volume does not exist" error
                my $clean_error = $error;
                $clean_error =~ s/\s+$//;
                if ($clean_error =~ /^JDSS resource .+ does not exist\.$/) {
                    debugmsg($ctx, "debug", "Volume $volname does not exist: ${clean_error}");
                    return [ undef, $vmid, $vtype ];
                }
                debugmsg($ctx, "error",
                    "Unable to identify expected block device path for volume "
                    . safe_var_print( "snapshot", $snapname )
                    . "activation error: ${error}");
                die $error;  # Re-throw other errors
            }

            if (defined($path)) {
                debugmsg($ctx, 'debug', "Path after activation of volume ${volname} "
                      . safe_var_print( "snapshot", $snapname )
                      . "${path}\n");
                return [ $path, $vmid, $vtype ];
            }
        }

        if ( @$til == 1 ) {
            my ( $targetname, $lunid, $lunrecpath, $lr ) = @{ $til->[0] };
            my $pathval;
            debugmsg($ctx, 'debug', "One lun record found for volume ${volname}, "
                  . safe_var_print( "snapshot", $snapname )
                  . "\n");
            eval {
                $pathval =
                  block_device_path_from_lun_rec( $ctx,
                    $targetname, $lunid, $lr );
                $pathval =~ m{^([\:\w\-/\.]+)$}
                  or die "Invalid source path '$pathval'";
            };

# TODO: reevaluate this section
# If we are not able to identify block device for existing lun record
# something is off, there fore we deactivate volume and activate it again
# We have to check that activate/deactivate transaction will not lead to unexpected
# side effect, like deactivation of volume snapshot should not lead to volume deactivation
            if ($@) {
                debugmsg($ctx, 'debug', "Path unable to identify device for volume ${volname}, "
                  . safe_var_print( "snapshot", $snapname )
                  . " $@\n");
                volume_deactivate( $ctx,
                    $vmid, $volname_clustered, $snapname, undef );
                my $bdpl =
                  volume_activate( $ctx,
                    $vmid, $volname_clustered, $snapname, undef );

                unless ( defined($bdpl) ) {
                    die "Unable to identify block device related to ${volname} "
                      . safe_var_print( "snapshot",
                        $snapname )
                      . "\n";
                }
                $pathval = ${$bdpl}[0];
                $pathval =~ m{^([\:\w\-/\.]+)$}
                  or die "Invalid source path '$pathval'";
            }
            debugmsg($ctx, 'debug', "Path from lun record ${volname}, "
                  . safe_var_print( "snapshot", $snapname )
                  . "${pathval}\n");

            return [ $pathval, $vmid, $vtype ];
        }

        # Check if we actually have multiple records or if this is a different error
        if (@$til == 0) {
            # This means volume activation must have failed in the unless block
            die "Resource ${volname} "
              . safe_var_print( "snapshot", $snapname )
              . " activation failed - no LUN records found and unable to create new record\n";
        } elsif (@$til > 1) {
            # Actually multiple records found
            my $records_info = "";
            for my $i (0 .. $#{$til}) {
                my ($targetname, $lunid, $lunrecpath, $lr) = @{$til->[$i]};
                my $vol = $lr->{volname} // 'undef';
                my $snap = defined($lr->{snapname}) ? $lr->{snapname} : 'undef';
                $records_info .= "Record $i: volume=$vol snapshot=$snap target=$targetname lun=$lunid\n";
            }
            debugmsg($ctx, 'warn', "Failed to identify correct record for ${volname} "
              . safe_var_print( "snapshot", $snapname )
              . "\nFound records:\n${records_info}"
            );
            die "Resource ${volname} "
              . safe_var_print( "snapshot", $snapname )
              . " have multiple records:\n${records_info}";
        } else {
            # This should never happen (we already handled @$til == 1 case above)
            die "Unexpected error in LUN record handling for ${volname} "
              . safe_var_print( "snapshot", $snapname )
              . "\n";
        }

    }
    else {
        # filesystem_path is wantarray-aware; capture its full triple in list
        # context and box it into the fixed shape.
        my ( $fs_path, $fs_vmid, $fs_vtype ) =
          $class->filesystem_path( $scfg, $volname, $snapname );
        return [ $fs_path, $fs_vmid, $fs_vtype ];
    }
}

sub rename_volume {
    my ( $class, $scfg, $storeid, $original_volname, $new_vmid, $new_volname ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _rename_volume_lock( $class, $ctx, $original_volname, $new_vmid, $new_volname );
}

sub _rename_volume_lock {
    my ( $class, $ctx, $original_volname, $new_vmid, $new_volname ) = @_;
    my $storeid = $ctx->{storeid};
    my $scfg    = $ctx->{scfg};

    my ( undef, undef, $src_vmid ) = eval { $class->parse_volname($original_volname) };

    my $code = sub {
        _rename_volume( $class, $ctx, $original_volname, $new_vmid, $new_volname )
    };

    my $res;
    if ( !defined($src_vmid) || !defined($new_vmid) ) {
        # Cannot determine one or both VMIDs: serialise at storage level.
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef, $code,
        );
    } elsif ( $src_vmid == $new_vmid ) {
        # Rename within the same VM: one lock is sufficient.
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $new_vmid, undef, $code,
        );
    } elsif ( $src_vmid < $new_vmid ) {
        # Acquire lower vmid first.
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $src_vmid, undef,
            sub {
                my $r = OpenEJovianDSS::Lock::with_lock(
                    $ctx, 'vm', $new_vmid, undef, $code,
                );
                die $@ if $@;
                return $r;
            },
        );
    } else {
        # Acquire lower vmid first (new_vmid is lower here).
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $new_vmid, undef,
            sub {
                my $r = OpenEJovianDSS::Lock::with_lock(
                    $ctx, 'vm', $src_vmid, undef, $code,
                );
                die $@ if $@;
                return $r;
            },
        );
    }
    die $@ if $@;
    return $res;
}

sub _rename_volume {
    my ( $class, $ctx, $original_volname, $new_vmid, $new_volname )
      = @_;
    my $scfg    = $ctx->{scfg};
    my $storeid = $ctx->{storeid};

    my $pool = get_pool($ctx);

    my (
        $original_vtype,    $original_volume_name, $original_vmid,
        $original_basename, $original_basedvmid,   $original_isBase,
        $original_format
    ) = $class->parse_volname($original_volname);

    my $new_volname_clustered;

    if ( defined($new_volname) ) {
        $new_volname_clustered = volume_name_clustered( $ctx, $new_volname );
    } else {
        my $cluster_prefix = OpenEJovianDSS::Common::get_cluster_prefix($ctx);
        $new_volname_clustered = _find_free_diskname( $class, $ctx, $new_vmid, $original_format,
                                                      undef, $cluster_prefix );
    }

    my $original_volname_clustered = volume_name_clustered( $ctx, $original_volname );

    volume_deactivate( $ctx,
        $original_vmid, $original_volname_clustered, undef, undef );

    volume_unpublish( $ctx,
        $original_vmid, $original_volname_clustered, undef, undef );

    my $jscsiid = joviandss_cmd(
            $ctx,
            [
                "pool",   $pool,
                "volume", $original_volname_clustered,
                "get", "-i"
            ],
            118, 5
        );

    $jscsiid = OpenEJovianDSS::Common::clean_word($jscsiid);
    $jscsiid = OpenEJovianDSS::Common::safe_word($jscsiid);
    #TODO: Lock file have to be updated here
    joviandss_cmd( $ctx,
            [ "pool", $pool,
              "volume", $original_volname_clustered,
              "rename", $new_volname_clustered, "--idempotent-scsi-id", $jscsiid ],
            118, 3);

    my $newname = join ':', $storeid , OpenEJovianDSS::Common::volume_name_unclustered( $ctx, $new_volname_clustered );
    return $newname;
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _create_base_lock( $class, $ctx, $volname );
}

sub _create_base_lock {
    my ( $class, $ctx, $volname ) = @_;

    my ( undef, undef, $vmid ) = eval { $class->parse_volname($volname) };
    my $res;
    if ( defined $vmid ) {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub { _create_base( $class, $ctx, $volname ) },
        );
    } else {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef,
            sub { _create_base( $class, $ctx, $volname ) },
        );
    }
    die $@ if $@;
    return $res;
}

sub _create_base {
    my ( $class, $ctx, $volname ) = @_;
    my $scfg    = $ctx->{scfg};
    my $storeid = $ctx->{storeid};

    my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) =
      $class->parse_volname($volname);

    die "create_base is not possible with base image\n" if $isBase;

    # Call _deactivate_volume directly to avoid re-acquiring the per-VM lock
    # (pmxcfs mkdir is not re-entrant; the lock is already held here).
    _deactivate_volume( $class, $ctx, $volname, undef, undef );

    my $pool = get_pool($ctx);

    my $newnameprefix = join '', 'base-', $vmid, '-disk-';

    my $max_retries = 10;
    my $newname;
    for my $attempt ( 1 .. $max_retries ) {

        my $getfreename_cmd =
            [ "pool", $pool, "volumes", "getfreename", "--prefix", $newnameprefix ];
        my $cluster_prefix = OpenEJovianDSS::Common::get_cluster_prefix($ctx);

        if ( defined($cluster_prefix) ) {
            push @$getfreename_cmd, '--cluster-prefix', $cluster_prefix;
        }

        $newname = joviandss_cmd( $ctx,
            $getfreename_cmd,
            118, 5
        );
        $newname = clean_word($newname);
        $newname = OpenEJovianDSS::Common::safe_word($newname); 
        my $err;
        eval {
            # Call _rename_volume directly for the same reason.
            _rename_volume( $class, $ctx, $volname, $vmid, $newname );
        };
        $err = $@;
        last unless $err;
        if ( $err =~ /already exists/i && $attempt < $max_retries ) {
            my $delay = 1 + rand(3);
            debugmsg( $ctx, "warn",
                "create_base: volume ${newname} already exists "
              . "(JovianDSS stale list under load), "
              . sprintf( "retrying in %.1fs (attempt %d/%d)\n",
                         $delay, $attempt, $max_retries - 1 ) );
            select( undef, undef, undef, $delay );
            next;
        }
        die $err;
    }

    return $newname;
}

sub clone_image {
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _clone_image_lock( $class, $ctx, $volname, $vmid, $snap );
}

sub _clone_image_lock {
    my ( $class, $ctx, $volname, $vmid, $snap ) = @_;

    my ( undef, undef, $src_vmid ) = eval { $class->parse_volname($volname) };

    my $code = sub {
        _clone_image( $class, $ctx, $volname, $vmid, $snap )
    };

    my $res;
    if ( !defined($src_vmid) || $src_vmid == $vmid ) {
        # Source vmid unknown or same as destination: single lock is sufficient.
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef, $code,
        );
    } elsif ( $src_vmid < $vmid ) {
        # Acquire lower vmid first to prevent deadlock.
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $src_vmid, undef,
            sub {
                my $r = OpenEJovianDSS::Lock::with_lock(
                    $ctx, 'vm', $vmid, undef, $code,
                );
                die $@ if $@;
                return $r;
            },
        );
    } else {
        # Acquire lower vmid first (vmid is lower here).
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub {
                my $r = OpenEJovianDSS::Lock::with_lock(
                    $ctx, 'vm', $src_vmid, undef, $code,
                );
                die $@ if $@;
                return $r;
            },
        );
    }
    die $@ if $@;
    return $res;
}

sub _clone_image {
    my ( $class, $ctx, $volname, $vmid, $snap ) = @_;
    my $scfg    = $ctx->{scfg};
    my $storeid = $ctx->{storeid};

    my $pool = get_pool($ctx);

    my ( undef, undef, undef, undef, undef, undef, $fmt ) =
      $class->parse_volname($volname);

    my $cluster_prefix = OpenEJovianDSS::Common::get_cluster_prefix($ctx);
    my $clone_name_clustered = _find_free_diskname( $class, $ctx, $vmid, $fmt, undef, $cluster_prefix );


    my $volname_clustered = volume_name_clustered( $ctx, $volname );
    my $size = joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $volname_clustered, "get", "-s" ], 118, 3 );

    $size = clean_word($size);

    my $max_retries = 10;
    for my $attempt ( 1 .. $max_retries ) {
        if ( $attempt > 1 ) {
            $clone_name_clustered = _find_free_diskname( $class, $ctx, $vmid, $fmt, undef, $cluster_prefix);
            debugmsg( $ctx, "warn",
                "clone_image retry ${attempt}/${max_retries}: retrying with new candidate name ${clone_name_clustered}\n" );
        }

        debugmsg( $ctx, "debug",
                "Clone ${volname_clustered} with size ${size} to ${clone_name_clustered} "
              . safe_var_print( " with snapshot", $snap )
              . "\n" );

        my $err;
        eval {
            if ($snap) {
                joviandss_cmd(
                    $ctx,
                    [
                        "pool",  $pool,    "volume", $volname_clustered,
                        "clone", "--size", $size,    "--snapshot",
                        $snap,   "-n",     $clone_name_clustered
                    ],
                    118, 3
                );
            }
            else {
                joviandss_cmd(
                    $ctx,
                    [
                        "pool",  $pool,    "volume", $volname_clustered,
                        "clone", "--size", $size,    "-n",
                        $clone_name_clustered
                    ],
                    118, 3
                );
            }
        };
        $err = $@;
        unless ($err) {
            eval {
                my $tgname = get_vm_target_group_name($ctx, $vmid);
                OpenEJovianDSS::Common::volume_publish($ctx, $tgname, $clone_name_clustered, undef, undef);
            };
            last;
        }
        if ( $err =~ /already exists/i && $attempt < $max_retries ) {
            my $delay = 1 + rand(3);
            debugmsg( $ctx, "warn",
                "clone_image: volume ${clone_name_clustered} already exists "
              . "(JovianDSS stale list under load), "
              . sprintf( "retrying in %.1fs (attempt %d/%d)\n",
                         $delay, $attempt, $max_retries - 1 ) );
            select( undef, undef, undef, $delay );
            next;
        }
        die $err;
    }
    return  OpenEJovianDSS::Common::volume_name_unclustered( $ctx, $clone_name_clustered );
}

sub find_free_diskname {
    my ($class, $storeid, $scfg, $vmid, $fmt, $add_fmt_suffix, $cluster_prefix) = @_;
    # Thin entry point for PVE core: create the per-operation ctx once and
    # delegate. Internal callers must use _find_free_diskname() with the ctx of
    # the volume's own storage so the ctx is built exactly once and threaded down.
    return _find_free_diskname( $class, new_ctx( $scfg, $storeid ),
        $vmid, $fmt, $add_fmt_suffix, $cluster_prefix );
}

sub _find_free_diskname {
    my ($class, $ctx, $vmid, $fmt, $add_fmt_suffix, $cluster_prefix) = @_;

    my $pool = get_pool($ctx);

    $fmt //= '';
    my $prefix = ($fmt eq 'subvol') ? 'subvol-' : 'vm-';
    my $suffix = $add_fmt_suffix ? ".$fmt" : '';

    # TODO: implement suffix support needed for qcow
    my $newnameprefix = join '', $prefix, $vmid, '-disk-';
    if (defined($cluster_prefix)) {
        $newnameprefix = join '_', $cluster_prefix, $newnameprefix;
    }
    my $newname = joviandss_cmd( $ctx,
        [ "pool", $pool, "volumes", "getfreename",
            '--prefix', $newnameprefix, '--suffix', $suffix ],
        118,
        5
    );

    $newname = OpenEJovianDSS::Common::clean_word($newname);
    $newname = OpenEJovianDSS::Common::safe_word($newname);
    return $newname;
}


sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _alloc_image_lock( $class, $ctx, $vmid, $fmt, $name, $size );
}

sub _alloc_image_lock {
    my ( $class, $ctx, $vmid, $fmt, $name, $size ) = @_;

    my $res = OpenEJovianDSS::Lock::with_lock(
        $ctx, 'vm', $vmid, undef,
        sub { _alloc_image( $class, $ctx, $vmid, $fmt, $name, $size ) },
    );
    die $@ if $@;
    return $res;
}

sub _alloc_image {
    my ( $class, $ctx, $vmid, $fmt, $name, $size ) = @_;
    my $scfg    = $ctx->{scfg};
    my $storeid = $ctx->{storeid};

    my $volume_name = $name;
    my $volume_name_clustered;

    my $cluster_prefix = OpenEJovianDSS::Common::get_cluster_prefix($ctx);

    if ( defined($volume_name) ) {
        $volume_name_clustered = volume_name_clustered( $ctx, $volume_name );
    } else {
        $volume_name_clustered =
            _find_free_diskname( $class, $ctx, $vmid, $fmt, undef, $cluster_prefix );
        debugmsg( $ctx, "debug",
            "Searching for free volume name for vm ${vmid} format ${fmt}" );
    }

    if ( 'images' ne "${fmt}" ) {

        my $pool    = get_pool($ctx);
        my $size_assigned = $size * 1024;
        my $block_size = get_block_size($ctx);
        my $block_size_bytes = get_block_size_bytes($ctx);

        # JovianDSS allocates volumes with block sized chunks
        # Volume size is rounded down to the block size
        if ($size_assigned % $block_size_bytes != 0) {
            $size_assigned = ( int($size_assigned / $block_size_bytes) * $block_size_bytes ) + $block_size_bytes;
        }

        my $thin_provisioning =
          get_thin_provisioning($ctx);

        my $max_retries = 5;
        for my $attempt ( 1 .. $max_retries ) {

            # On retry (name was auto-selected), re-query for a free name so we
            # skip any volume that appeared in JovianDSS since the last check.
            if ( $attempt > 1 && !defined($volume_name) ) {
                $volume_name_clustered =
                    _find_free_diskname( $class, $ctx, $vmid, $fmt, undef, $cluster_prefix );
                debugmsg( $ctx, "warn",
                    "alloc_image retry ${attempt}/${max_retries}: "
                  . "retrying with new candidate name ${volume_name_clustered}\n" );
            }

            debugmsg( $ctx, "debug",
"Creating volume ${volume_name_clustered} format ${fmt} requested size ${size_assigned}"
            );

            #my $volume_name_clustered = volume_name_clustered( $ctx, $volume_name );
            my $create_vol_cmd = [
                "pool",   $pool,    "volumes", "create",
                "--size", "${size_assigned}", "-n", $volume_name_clustered
            ];

            if ( defined($thin_provisioning) ) {
                push @$create_vol_cmd, '--thin-provisioning', $thin_provisioning;
            }

            if ( defined($block_size) ) {
                push @$create_vol_cmd, '--block-size', $block_size;
            }

            my $err;
            eval {
                joviandss_cmd(
                    $ctx, $create_vol_cmd, 118, 3 );
            };
            $err = $@;

            unless ($err) {
                eval {
                    my $tgname = get_vm_target_group_name($ctx, $vmid);
                    OpenEJovianDSS::Common::volume_publish($ctx, $tgname, $volume_name_clustered, undef, undef);
                };
                last;
            }

            # Only retry "already exists" when the name was auto-selected.
            # A caller-specified name must not be silently changed.
            if ( !defined($name) && $err =~ /already exists/i
                && $attempt < $max_retries )
            {
                my $delay = 1 + rand(3);
                debugmsg( $ctx, "warn",
                    "alloc_image: volume ${volume_name_clustered} already exists "
                  . "(JovianDSS stale list under load), "
                  . sprintf( "retrying in %.1fs (attempt %d/%d)\n",
                        $delay, $attempt, $max_retries - 1 ) );
                select( undef, undef, undef, $delay );
                next;
            }
            die $err;
        }
    }
    return clean_word(OpenEJovianDSS::Common::volume_name_unclustered($ctx, $volume_name_clustered));
}

# cluster_lock_storage — strict no-op pass-through.
#
# Locking is handled inside each plugin method via _method_lock wrappers that
# call Lock::lock_vm directly.  cluster_lock_storage must NOT acquire any lock
# here because the pmxcfs mkdir primitive is not re-entrant: if this function
# acquired a lock and the plugin method it calls also tried to acquire the same
# lock, the inner mkdir would block forever (deadlock).
sub cluster_lock_storage {
    my ($class, $storeid, $shared, $timeout, $func, @param) = @_;
    return $func->(@param);
}


sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $_format ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _free_image_lock( $class, $ctx, $volname, $isBase, $_format );
}

sub _free_image_lock {
    my ( $class, $ctx, $volname, $isBase, $_format ) = @_;

    my ( undef, undef, $vmid ) = eval { $class->parse_volname($volname) };
    my $res;
    if ( defined $vmid ) {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub { _free_image( $class, $ctx, $volname, $isBase, $_format ) },
        );
    } else {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef,
            sub { _free_image( $class, $ctx, $volname, $isBase, $_format ) },
        );
    }
    die $@ if $@;
    return $res;
}

sub _free_image {
    my ( $class, $ctx, $volname, $isBase, $_format ) = @_;
    my $scfg    = $ctx->{scfg};
    my $storeid = $ctx->{storeid};

    my $pool = get_pool($ctx);
    my ( $vtype, undef, $vmid, undef, undef, undef, $format ) =
      $class->parse_volname($volname);

    debugmsg( $ctx, "debug",
        "Deleting volume ${volname} format ${format} start" );

    if ( 'images' cmp "$vtype" ) {
        return $class->SUPER::free_image( $storeid, $scfg, $volname, $isBase,
            $format );
    }

    my $tgname =
      get_vm_target_group_name( $ctx, $vmid );
    my $prefix = get_target_prefix($ctx);
    my $volname_clustered = volume_name_clustered( $ctx, $volname );

    # Volume deletion will result in deletetion of all its snapshots
    # Therefore we have to detach all volume snapshots that is expected to be
    # removed along side with volume

    volume_deactivate( $ctx, $vmid,
        $volname_clustered, undef, undef );

    # volume_unpublish is intentionally skipped here.  The final
    # "volume delete -c" already handles iSCSI target detachment via
    # _detach_volume() with the --target-group-name filter.  Running
    # volume_unpublish first would (a) duplicate REST calls and
    # (b) delete the target before _detach_volume sees it, forcing an
    # expensive full-pool target scan (~7 s) instead of a single
    # filtered lookup (~0.3 s).  Total free_image time drops from
    # ~22 s to ~9 s, keeping it under the 10 s CFS lock timeout.

    joviandss_cmd(
        $ctx,
        [
            "pool",   $pool, "volume",          $volname_clustered,
            "delete", "-c",  '--target-prefix', $prefix,
            '--target-group-name', $tgname
        ],
        get_delete_timeout($ctx),
        5
    );

    debugmsg( $ctx, "debug",
        "Deleting volume ${volname} format ${format} done" );
    return undef;
}

sub get_nfs_addresses {
    my ( $class, $scfg, $storeid ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my $gethostscmd = [ "hosts", '--nfs' ];

    my @hosts = ();
    my $out   = joviandss_cmd( $ctx, $gethostscmd );
    foreach ( split( /\n/, $out ) ) {
        push @hosts, clean_word(split);
    }
    return @hosts;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my $pool = get_pool($ctx);

    #TODO: rename jdssc variable
    my $list_cmd = [ "pool", $pool, "volumes", "list", "--vmid" ];
    my $cluster_prefix =  OpenEJovianDSS::Common::get_cluster_prefix($ctx);

    if (defined($cluster_prefix)) {
        push @$list_cmd, '--cluster-prefix', $cluster_prefix;
    }
    my $jdssc = joviandss_cmd( $ctx, $list_cmd, 118, 5, undef, 'jdssc_info' );

    my $res = [];
    foreach ( split( /\n/, $jdssc ) ) {
        my ( $raw_volname, $vm, $size, $ctime ) = split;

        my $volname = volume_name_unclustered( $ctx, clean_word($raw_volname) );
        next unless defined($volname);

        $vm   = clean_word($vm);
        $size = clean_word($size);

        my $volid = "$storeid:$volname";

        if ($vollist) {
            my $found = grep { $_ eq $volid } @$vollist;
            next if !$found;
        }
        else {
            next if defined($vmid) && ( $vm ne $vmid );
        }

        push @$res,
          {
            format => 'raw',
            volid  => $volid,
            size   => $size,
            vmid   => $vm,
            ctime  => $ctime,
          };
    }

    return $res;
}

sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my $pool = get_pool($ctx);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    # TODO: make snapshot creation idempotent
    # This will require adding --idempotent flag for jdss cmd
    my $volname_clustered = volume_name_clustered( $ctx, $volname );
    joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $volname_clustered, "snapshots", "create", $snap ], 118 );
}

# Returns a hash with the snapshot names as keys and the following data:
# id        - Unique id to distinguish different snapshots even if the have the same name.
# timestamp - Creation time of the snapshot (seconds since epoch).
# Returns an empty hash if the volume does not exist.
sub volume_snapshot_info {
    my ( $class, $scfg, $storeid, $volname ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my $volname_clustered = volume_name_clustered( $ctx, $volname );
    return volume_snapshots_info( $ctx, $volname_clustered );
}

sub volume_snapshot_needs_fsfreeze {

    return 0;
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _volume_snapshot_rollback_lock( $class, $ctx, $volname, $snap );
}

sub _volume_snapshot_rollback_lock {
    my ( $class, $ctx, $volname, $snap ) = @_;

    my ( undef, undef, $vmid ) = eval { $class->parse_volname($volname) };
    my $res;
    if ( defined $vmid ) {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub { _volume_snapshot_rollback( $class, $ctx, $volname, $snap ) },
        );
    } else {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef,
            sub { _volume_snapshot_rollback( $class, $ctx, $volname, $snap ) },
        );
    }
    die $@ if $@;
    return $res;
}

sub _volume_snapshot_rollback {
    my ( $class, $ctx, $volname, $snap ) = @_;

    my $pool = get_pool($ctx);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    print "Rollback: starting rollback of ${volname} to snapshot ${snap}\n";
    debugmsg( $ctx, "debug",
            "Volume ${volname} "
          . safe_var_print( "snapshot", $snap )
          . " rollback start" );

    # Determine virtualisation type from config file presence — instant file
    # check, no pvesh call needed.  Used only for remove_vm_snapshot_config
    # when blocker snapshots are cleaned up from the Proxmox config.
    my $virt_type =
        -f "/etc/pve/qemu-server/${vmid}.conf" ? 'qemu' :
        -f "/etc/pve/lxc/${vmid}.conf"         ? 'lxc'  : undef;

    # Always use --force-snapshots: volume_rollback_is_possible already
    # verified this rollback is safe.  For VMs without the force_rollback tag,
    # no blockers exist at this point so --force-snapshots is a no-op.
    # For force_rollback VMs the JovianDSS REST API atomically deletes all
    # newer snapshot blockers before restoring the volume.
    # Deleted blocker names are returned as "snap:<name>" tokens; we call
    # remove_vm_snapshot_config for each — it is idempotent, so calling it for
    # unmanaged snapshots is harmless.
    my $volname_clustered = volume_name_clustered( $ctx, $volname );
    my $deleted_raw = joviandss_cmd(
        $ctx,
        [
            'pool',     $pool, 'volume',   $volname_clustered,
            'snapshot', $snap, 'rollback', 'do',
            '--force-snapshots',
        ],
        118,
        5
    );

    foreach my $line ( split /\n/, $deleted_raw ) {
        foreach my $token ( split /\s+/, $line ) {
            next unless $token =~ /^snap:(.+)$/;
            my $deleted = $1;
            debugmsg( $ctx, "debug",
                "Rollback: jdssc deleted blocking snapshot '${deleted}'\n" );
            if ( defined $virt_type ) {
                remove_vm_snapshot_config(
                    $ctx, $vmid, $virt_type, $deleted);
            }
        }
    }

    print "Rollback: ${volname} to snapshot ${snap} complete\n";
    debugmsg( $ctx, "debug",
            "Volume ${volname} "
          . safe_var_print( "snapshot", $snap )
          . " rollback done" );

}

sub volume_rollback_is_possible {
    my ( $class, $scfg, $storeid, $volname, $snap, $blockers ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $managed_by_ha = ha_state_is_defined($ctx, $vmid);
    if ($managed_by_ha) {
        my $hastate = ha_state_get($ctx, $vmid);

        if (($hastate ne 'ignored')) {
            my $resource_type = ha_type_get($ctx, $vmid);
            print "vmid ${vmid}: HA check failed — managed by HA (state: ${hastate})\n";
            my $msg =
            "Rollback blocked: ${resource_type}:${vmid} is controlled by High Availability (state: ${hastate}).\n"
            . "Rollback requires temporary manual control to prevent HA from restarting or moving the resource.\n"
            . "Disable HA management before retrying:\n"
            . "Web UI: Datacenter -> HA -> Resources -> set state to ignored\n"
            . "CLI: ha-manager set ${resource_type}:${vmid} --state ignored\n";
            die $msg;
        }
    }

    # Compute force_rollback once here so volume_rollback_check does not need
    # to spawn its own pvesh subprocess for the same information.
    my $force_rollback = vm_tag_force_rollback_is_set(
        $ctx, $vmid);

    my $volname_clustered = volume_name_clustered( $ctx, $volname );
    my $ok = volume_rollback_check(
        $ctx, $vmid, $volname_clustered, $snap, $blockers,
        $force_rollback);

    return $ok;
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _volume_snapshot_delete_lock( $class, $ctx, $volname, $snap, $running );
}

sub _volume_snapshot_delete_lock {
    my ( $class, $ctx, $volname, $snap, $running ) = @_;

    my ( undef, undef, $vmid ) = eval { $class->parse_volname($volname) };
    my $res;
    if ( defined $vmid ) {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub { _volume_snapshot_delete( $class, $ctx, $volname, $snap, $running ) },
        );
    } else {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef,
            sub { _volume_snapshot_delete( $class, $ctx, $volname, $snap, $running ) },
        );
    }
    die $@ if $@;
    return $res;
}

sub _volume_snapshot_delete {
    my ( $class, $ctx, $volname, $snap, $running ) = @_;

    my $pool   = get_pool($ctx);
    my $prefix = get_target_prefix($ctx);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $tgname =
      get_vm_target_group_name( $ctx, $vmid );

    my $volname_clustered = volume_name_clustered( $ctx, $volname );

    volume_deactivate( $ctx, $vmid,
        $volname_clustered, $snap, undef );

    joviandss_cmd(
        $ctx,
        [
            "pool",     $pool,
            "volume",   $volname_clustered,
            "snapshot", $snap,
            "delete",   '--target-prefix',
            $prefix,    '--target-group-name',
            $tgname
        ],
        118,
        5
    );
}

sub volume_snapshot_list {
    my ( $class, $scfg, $storeid, $volname ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my $pool = get_pool($ctx);

    my $volname_clustered = volume_name_clustered( $ctx, $volname );
    my $jdssc = joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $volname_clustered, "snapshots", "list" ], 118, 5 );

    my $res = [];
    foreach ( split( /\n/, $jdssc ) ) {
        my ($sname) = split;
        push @$res, { 'name' => "$sname" };
    }

    return $res;
}

sub volume_size_info {
    my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my $pool = get_pool($ctx);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);


    if ( 'images' cmp "$vtype" ) {
        return $class->SUPER::volume_size_info( $scfg, $storeid, $volname,
            $timeout );
    }

    my $volname_clustered = volume_name_clustered( $ctx, $volname );
    my $size = joviandss_cmd( $ctx,
        [ "pool", $pool, "volume", $volname_clustered, "get", "-s" ], 118, 3,
        undef, 'jdssc_info' );

    return clean_word($size);
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    my $pool = get_pool($ctx);
    my $gb = 1024 * 1024 * 1024;

    for my $attempt (1 .. 3) {
        my $stats = eval {
            joviandss_cmd( $ctx, [ "pool", $pool, "get" ], 118, 3, undef, 'jdssc_info' );
        };
        if ($@) {
            debugmsg( $ctx, 'warn', "Storage status check failed (attempt ${attempt}): $@" );
            next;
        }

        my ( $pool_name, $pool_id, $total, $avail, $used ) = split( " ", $stats );
        unless ( defined($total) && defined($avail) && defined($used) ) {
            debugmsg( $ctx, 'warn', "Unexpected pool info output (attempt ${attempt}): ${stats}\n" );
            next;
        }

        return ( $total * $gb, $avail * $gb, $used * $gb, 1 );
    }

    die "Unable to get storage status for pool ${pool} after 3 attempts\n";
}

sub get_identity {
    my ($class, $scfg, $storeid) = @_;

    my $ctx = new_ctx($scfg, $storeid);

    my $pool = get_pool($ctx);

    for my $attempt (1 .. 3) {
        my $stats = eval {
            joviandss_cmd( $ctx, [ "pool", $pool, "get" ], 118, 3, undef, 'jdssc_info' );
        };
        if ($@) {
            debugmsg( $ctx, 'warn', "Storage identity check failed (attempt ${attempt}): $@" );
            next;
        }

        my ( $pool_name, $pool_id, $total, $avail, $used ) = split( " ", $stats );
        unless ( defined($total) && defined($avail) && defined($used) ) {
            debugmsg( $ctx, 'warn', "Unexpected pool info output (attempt ${attempt}): ${stats}\n" );
            next;
        }
        return "${pool_name}-${pool_id}";
    }

    die "Unable to get storage identity for pool ${pool} after 3 attempts\n";
}

sub disk_for_target {
    my ( $class, $storeid, $scfg, $target ) = @_;
    return undef;
}

sub ensure_fs {
    my ( $class, $scfg ) = @_;

    my $ctx  = new_ctx( $scfg, undef );
    my $path = OpenEJovianDSS::Common::get_content_path($ctx);

    if ( defined($path) ) {
        make_path $path, { owner => 'root', group => 'root' };
        my $dir_path = "$path/iso";
        mkdir $dir_path;
        $dir_path = "$path/vztmpl";
        mkdir $dir_path;
        $dir_path = "$path/backup";
        mkdir $dir_path;
        $dir_path = "$path/rootdir";
        mkdir $dir_path;
        $dir_path = "$path/snippets";
        mkdir $dir_path;
        $dir_path = "$path/template";
        mkdir $dir_path;
        $dir_path = "$path/template/cache";
        mkdir $dir_path;
    }
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    debugmsg( $ctx, "debug",
        "Activate storage ${storeid}\n" );

    store_setup( $ctx );

    return undef if !defined( $ctx->{scfg}{content} );

    my %supported_content = (
                images  => 1,
                rootdir => 1
            );

    my $enabled_content = get_content($ctx);

    my $content_volume_needed = 0;

    foreach my $enabled_content_type (keys %{$enabled_content}) {
        unless ( exists $supported_content{$enabled_content_type} ) {
            die "Content type ${enabled_content_type} is not supported\n";
        }
    }

    if ( get_create_base_path($ctx) ) {
        my $path = get_path($ctx);
        if (! -d $path) {
            File::Path::make_path($path, { owner => 'root', group => 'root' } );
            chmod 0755, $path;
        }
    }

    return 1;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    debugmsg( $ctx, "debug",
        "Deactivating storage ${storeid}\n" );

    return 1;
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _activate_volume_lock( $class, $ctx, $volname, $snapname, $cache );
}

sub _activate_volume_lock {
    my ( $class, $ctx, $volname, $snapname, $cache ) = @_;

    my ( undef, undef, $vmid ) = eval { $class->parse_volname($volname) };
    my $res;
    if ( defined $vmid ) {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub { _activate_volume( $class, $ctx, $volname, $snapname, $cache ) },
        );
    } else {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef,
            sub { _activate_volume( $class, $ctx, $volname, $snapname, $cache ) },
        );
    }
    die $@ if $@;
    return $res;
}

sub _activate_volume {
    my ( $class, $ctx, $volname, $snapname, $cache ) = @_;

    debugmsg( $ctx, "debug",
            "Activate volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . " start" );

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);
    my $volname_clustered = volume_name_clustered( $ctx, $volname );

    return 0 if ( 'images' ne "$vtype" );

    my $til =
      lun_record_local_get_info_list( $ctx,
        $volname_clustered, $snapname );

    unless (@$til) {
        volume_activate( $ctx, $vmid,
            $volname_clustered, $snapname, undef );
    }
    else {
# If volume was resized on other node we have to make sure that current size is accurate
        my ( $targetname, $lunid, $lunrecpath, $lr ) = @{ $til->[0] };

        my $pathval;
        eval {
            $pathval =
              block_device_path_from_lun_rec( $ctx,
                $targetname, $lunid, $lr );
            $pathval =~ m{^([\:\w\-/\.]+)$}
              or die "Invalid source path '$pathval'";
        };

        unless (-b $pathval) {
            debugmsg( $ctx, "debug",
                    "Block device with given path ${pathval} for volume ${volname} "
                  . safe_var_print( "snapshot", $snapname )
                  . " not found. Re-activating." );
            volume_deactivate( $ctx,
                $vmid, $volname_clustered, $snapname, undef );
            volume_activate( $ctx,
                $vmid, $volname_clustered, $snapname, undef );
        }

        my $current_size =
          volume_get_size( $ctx, $volname_clustered );
        if ( @$til == 1 ) {
            my ( $targetname, $lunid, $lunrecpath, $lr ) = @{ $til->[0] };
            if ( $current_size > $lr->{size} ) {
                volume_update_size( $ctx,
                    $vmid, $volname_clustered, $current_size );
            }
        }
        else {
            die "Unable to identify lun record.\n";
        }
    }

    debugmsg( $ctx, "debug",
            "Activate volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . " done" );
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache, $hints ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _deactivate_volume_lock( $class, $ctx, $volname, $snapname, $cache, $hints );
}

sub _deactivate_volume_lock {
    my ( $class, $ctx, $volname, $snapname, $cache, $hints ) = @_;

    my ( undef, undef, $vmid ) = eval { $class->parse_volname($volname) };
    my $res;
    if ( defined $vmid ) {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub { _deactivate_volume( $class, $ctx, $volname, $snapname, $cache, $hints ) },
        );
    } else {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef,
            sub { _deactivate_volume( $class, $ctx, $volname, $snapname, $cache, $hints ) },
        );
    }
    die $@ if $@;
    return $res;
}

sub _deactivate_volume {
    my ( $class, $ctx, $volname, $snapname, $cache, $hints ) = @_;

    debugmsg( $ctx, "debug",
            "Deactivate volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . " start" );
    my $pool   = get_pool($ctx);
    my $prefix = get_target_prefix($ctx);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);
    my $volname_clustered = volume_name_clustered( $ctx, $volname );

    my $tgname =
      get_vm_target_group_name( $ctx, $vmid );

    return 0 if ( 'images' ne "$vtype" );

    my $had_lun_record = undef;
    if ( $volname =~ m!^vm-(\d+)-state-(.+)$! ) {
        my $lunrecs = lun_record_local_get_info_list( $ctx, $volname_clustered, $snapname );
        $had_lun_record = scalar(@$lunrecs) > 0;
    }
    volume_deactivate( $ctx, $vmid,
        $volname_clustered, $snapname, undef );

    # Unpublish VM state volumes only when no other initiator holds an active session
    if ( $had_lun_record ) {
        volume_unpublish($ctx, $vmid, $volname_clustered, $snapname, undef);
    }

    debugmsg( $ctx, "debug",
            "Deactivate volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . " done" );

    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    return _volume_resize_lock( $class, $ctx, $volname, $size, $running );
}

sub _volume_resize_lock {
    my ( $class, $ctx, $volname, $size, $running ) = @_;

    my ( undef, undef, $vmid ) = eval { $class->parse_volname($volname) };
    my $res;
    if ( defined $vmid ) {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'vm', $vmid, undef,
            sub { _volume_resize( $class, $ctx, $volname, $size, $running ) },
        );
    } else {
        $res = OpenEJovianDSS::Lock::with_lock(
            $ctx, 'storage', undef, undef,
            sub { _volume_resize( $class, $ctx, $volname, $size, $running ) },
        );
    }
    die $@ if $@;
    return $res;
}

sub _volume_resize {
    my ( $class, $ctx, $volname, $size, $running ) = @_;

    my $pool = get_pool($ctx);
    my $resizeok = 0;
    debugmsg( $ctx, "debug",
        "Resize volume ${volname} to size ${size}" );

    # Sanitize everything that enters the command line (house rule: argv
    # values pass safe_word / a strict untaint at the trust boundary).
    my $volname_clustered = OpenEJovianDSS::Common::safe_word(
        volume_name_clustered( $ctx, $volname ), 'volume name' );

    if ( $size =~ /^(\d+)$/ ) {
        $size = $1;    # untainted, strictly numeric
    }
    else {
        die "Volume resize size must be a positive integer, got '${size}'\n";
    }

    eval {
        joviandss_cmd( $ctx,
            [ "pool", "${pool}", "volume", $volname_clustered, "resize", "${size}" ], 118, 3 );
    };
    my $rerr = $@;
    if ($rerr && $rerr !~ /got timeout/ ) {
        die $rerr;
    }
    my $retry_count = 0;

    while ( $retry_count <= 10 ) {

        if ( !$rerr ) {
            # Previous attempt (pre-loop or in-loop) completed cleanly.
            $resizeok = 1;
            last;
        }

        debugmsg( $ctx, "debug",
            "Resize volume ${volname} attempt error: ${rerr}" );

        if ( OpenEJovianDSS::Lock::lock_error_fatal($rerr) ) {
            # Hold-cap death: the locks protecting this operation can no
            # longer be trusted - never absorbed into a retry (the same
            # rethrow every comparable wrapper performs first).
            die $rerr;
        }

        if ( $rerr =~ /got timeout/ ) {
            sleep( 10 );
        }

        # The whole recovery step runs inside one eval (review F-19): a
        # transient failure of the size probe is recorded and retried like
        # any resize failure, instead of aborting the recovery the loop
        # exists to perform. $resizeok is set INSIDE the eval but the loop
        # exit happens OUTSIDE it - 'last' from within an eval block is an
        # "Exiting eval via last" trap.
        local $@;
        eval {
            my $cursize = OpenEJovianDSS::Common::volume_get_size( $ctx, $volname_clustered );
            $cursize = OpenEJovianDSS::Common::clean_word($cursize);

            if ( int($cursize) >= int($size) ) {
                $resizeok = 1;
            }
            else {
                joviandss_cmd( $ctx,
                    [ "pool", "${pool}", "volume", "${volname_clustered}", "resize", "${size}" ], 118, 3);
            }
            1;
        };
        $rerr = $@;

        if ( $resizeok ) {
            last;
        }
        $retry_count++;
    }

    if ($resizeok) {
        my $til = lun_record_local_get_info_list( $ctx, $volname_clustered, undef );
        if ( @$til == 1 ) {
            my ( $targetname, $lunid, $lunrecpath, $lunrecord ) = @{ $til->[0] };
            lun_record_update_device( $ctx,
                $targetname, $lunid, $lunrecpath, $lunrecord, $size );
        }
        return 1;
    }
    die $rerr;
}

sub parse_volname {
    my ( $class, $volname ) = @_;

    my $iso_re;

    if ( defined($PVE::Storage::iso_extension_re) ) {
        $iso_re = $PVE::Storage::iso_extension_re;
    }
    elsif ( defined($PVE::Storage::ISO_EXT_RE_0) ) {
        $iso_re = $PVE::Storage::ISO_EXT_RE_0;
    }
    else {
        $iso_re = qr/\.(?:iso|img)/i;
    }

    my $vztmpl_re;
    if ( defined($PVE::Storage::vztmpl_extension_re) ) {
        $vztmpl_re = $PVE::Storage::vztmpl_extension_re;
    }
    elsif ( defined($PVE::Storage::VZTMPL_EXT_RE_1) ) {
        $vztmpl_re = $PVE::Storage::VZTMPL_EXT_RE_1;
    }
    else {
        $vztmpl_re = qr/\.tar\.(gz|xz|zst)/i;
    }

    if ( $volname =~ m/^((base-(\d+)-\S+)\/)?((base)?(vm)?-(\d+)-\S+)$/ ) {
        return ( 'images', $4, $7, $2, $3, $5, 'raw' );
    }
    elsif ( $volname =~ m!^iso/([^/]+$iso_re)$! ) {
        return ( 'iso', $1 );
    }
    elsif ( $volname =~ m!^vztmpl/([^/]+$vztmpl_re)$! ) {
        return ( 'vztmpl', $1 );
    }
    elsif ( $volname =~ m!^rootdir/(\d+)$! ) {
        return ( 'rootdir', $1, $1 );
    }
    elsif ( $volname =~
m!^backup/([^/]+(?:\.(?:tgz|(?:(?:tar|vma)(?:\.(?:${\COMPRESSOR_RE}))?))))$!
      )
    {
        my $fn = $1;
        if ( $fn =~ m/^vzdump-(openvz|lxc|qemu)-(\d+)-.+/ ) {
            return ( 'backup', $fn, $2 );
        }
        return ( 'backup', $fn );
    }

    die "unable to parse joviandss volume name '$volname'\n";
}

sub storage_can_replicate {
    my ( $class, $scfg, $storeid, $format ) = @_;

    return 0;
}

sub volume_has_feature {
    my (
        $class,   $scfg,     $feature, $storeid,
        $volname, $snapname, $running, $opts
    ) = @_;

    my $features = {
        snapshot => {
            base    => 1,
            current => 1,
            snap    => 1
        },
        clone => {
            base    => 1,
            current => 1,
            snap    => 1,
            images  => 1
        },
        template => {
            current => 1
        },
        copy => {
            base    => 1,
            current => 1,
            snap    => 1
        },
        sparseinit => {
            base => {
                raw => 1
            },
            current => {
                raw => 1
            }
        },
        rename => {
            current => {
                raw => 1
            },
        }
    };

    my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) =
      $class->parse_volname($volname);

    my $key = undef;
    if ($snapname) {
        $key = 'snap';
    }
    else {
        $key = $isBase ? 'base' : 'current';
    }
    return 1 if $features->{$feature}->{$key};

    return undef;
}

sub get_volume_attribute {
    my ( $class, $scfg, $storeid, $volname, $attribute ) = @_;
    return undef;
}

sub update_volume_attribute {
    my ( $class, $scfg, $storeid, $volname, $attribute, $value ) = @_;
    return undef;
}

sub qemu_blockdev_options {
    my ($class, $scfg, $storeid, $volname, $machine_version, $options) = @_;

    my $ctx      = new_ctx($scfg, $storeid);
    my $snapname = $options->{'snapshot-name'};

    # _path returns a fixed [$path, $vmid, $vtype] arrayref; only the
    # block-device path is needed here.
    my ( $path, $vmid, $vtype ) = @{ _path( $class, $ctx, $volname, $snapname ) };

    my $blockdev = { driver => 'host_device', filename => $path };
    return $blockdev;
}

sub volume_qemu_snapshot_method {
    my ($class, $storeid, $scfg, $volname) = @_;

    return 'storage';
}

sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    my $ctx = new_ctx($scfg, $storeid);

    if ( get_create_base_path($ctx) ) {
        my $path = get_path($ctx);
        if (! -d $path) {
            File::Path::make_path($path, { owner => 'root', group => 'root' } );
            chmod 0755, $path;
        }
    }
    if (exists($sensitive{user_password})) {
        if (defined($sensitive{user_password})) {
            OpenEJovianDSS::Common::password_file_set_password($ctx, $sensitive{user_password});
        }
    }
    if (exists($sensitive{chap_user_password})) {
        if (defined($sensitive{chap_user_password})) {
            OpenEJovianDSS::Common::password_file_set_chap_password($ctx, $sensitive{chap_user_password});
        }
    }
    if (OpenEJovianDSS::Common::get_chap_enabled($ctx)) {
        die "chap_user_name is required when chap_enabled is set\n"
            unless defined $scfg->{chap_user_name} && length($scfg->{chap_user_name});
        die "chap_user_password is required when chap_enabled is set\n"
            unless defined OpenEJovianDSS::Common::get_chap_user_password($ctx);
    }
    # undef is the correct return value here (same as PVE's base Plugin.pm default).
    # Config.pm only sets $res->{config} = $returned_config if $returned_config,
    # so undef means the 'config' key is simply omitted from the API response —
    # it never becomes JSON null. Only plugins that generate server-side properties
    # (e.g. PBS encryption-key) return a hashref here.
    return undef;
}

sub on_delete_hook {
    my ($class, $storeid, $scfg) = @_;
    my $ctx = new_ctx($scfg, $storeid);
    OpenEJovianDSS::Common::password_file_delete($ctx);
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %param) = @_;

    my $ctx = new_ctx($scfg, $storeid);
    if ( exists($param{user_password}) ) {
        if (defined($param{user_password})) {
            OpenEJovianDSS::Common::password_file_set_password($ctx, $param{user_password});
        } else {
            OpenEJovianDSS::Common::password_file_delete_user_password($ctx);
        }
    }
    if (exists($param{chap_user_password})) {
        if (defined($param{chap_user_password})) {
            OpenEJovianDSS::Common::password_file_set_chap_password($ctx, $param{chap_user_password});
        } else {
            OpenEJovianDSS::Common::password_file_delete_chap_password($ctx);
        }
    }
    if (OpenEJovianDSS::Common::get_chap_enabled($ctx)) {
        die "chap_user_name is required when chap_enabled is set\n"
            unless defined $scfg->{chap_user_name} && length($scfg->{chap_user_name});
        die "chap_user_password is required when chap_enabled is set\n"
            unless defined OpenEJovianDSS::Common::get_chap_user_password($ctx);
    }
    return undef;
}

1;
