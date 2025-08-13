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
use base                   qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.10.4-0';

#    Open-E JovianDSS Proxmox plugin
#
#    0.9.8-5 - 2024.09.30
#               Add rollback to the latest volume snapshot
#               Introduce share option that substitutes proxmox code modification
#               Fix migration failure
#               Extend REST API error handling
#               Fix volume provisioning bug
#               Fix Pool selection bug
#               Prevent possible iscis target name collision
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
#               Fix data coruption during migration
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

# Configuration

sub api {

    my $apiver = 12;

    return $apiver;
}

sub type {
    return 'joviandss';
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
            'user_password' => 1,
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
              'Maximun number of luns assigned to single iSCSI target',
            type    => 'int',
            default => OpenEJovianDSS::Common::get_luns_per_target(),
        },
        ssl_cert_verify => {
            description =>
              "Enforce certificate verification for REST over SSL/TLS",
            type => 'boolean',
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
        },
        debug => {
            description => "Allow debug prints",
            type        => 'boolean',
            default     => OpenEJovianDSS::Common::get_default_debug(),
        },
        log_file => {
            description => "Log file path",
            type        => 'string',
            default     => '/var/log/joviandss.log',
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
        ssl_cert_verify    => { optional => 1 },
        user_name          => { fixed    => 1 },
        user_password      => { optional => 1 },
        control_addresses  => { fixed    => 1 },
        control_port       => { optional => 1 },
        data_addresses     => { optional => 1 },
        data_port          => { optional => 1 },
        block_size         => { optional => 1 },
        thin_provisioning  => { optional => 1 },
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

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $path = undef;

    if ( $vtype eq "images" ) {
        my $til = OpenEJovianDSS::Common::lun_record_local_get_info_list( $scfg,
            $storeid, $volname, $snapname );

        unless (@$til) {
            eval {
                OpenEJovianDSS::Common::debugmsg($scfg, 'debug', "None lun records found for volume ${volname}, "
                      . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
                      . "\n");

                my $bdpl = OpenEJovianDSS::Common::volume_activate($scfg, $storeid,
                    $vmid, $volname, $snapname, undef );

                unless ( defined($bdpl) ) {
                    die "Unable to identify block device related to ${volname}"
                      . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
                      . "\n";
                }
                my $pathval = ${$bdpl}[0];
                $pathval =~ m{^([\:\w\-/\.]+)$}
                  or die "Invalid source path '$pathval'";
                $path = $pathval;
            };

            if ($@) {
                my $error = $@;
                # Handle specific "volume does not exist" error
                my $clean_error = $error;
                $clean_error =~ s/\s+$//;
                if ($clean_error =~ /^JDSS resource volume .+ DNE\.$/) {
                    debugmsg($scfg, "debug", "Volume $volname does not exist: ${clean_error}");
                    return wantarray ? ( undef, $vmid, $vtype ) : undef;
                }
                debugmsg($scfg, "error", "Volume activation error: ${error}");
                die $error;  # Re-throw other errors
            }

            if (defined($path)) {
                return wantarray ? ( $path, $vmid, $vtype ) : $path;
            }
        }

        if ( @$til == 1 ) {
            my ( $targetname, $lunid, $lunrecpath, $lr ) = @{ $til->[0] };
            my $pathval;
            OpenEJovianDSS::Common::debugmsg($scfg, 'debug', "One lun record found for volume ${volname}, "
                  . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
                  . "\n");
            eval {
                $pathval =
                  OpenEJovianDSS::Common::block_device_path_from_lun_rec( $scfg,
                    $storeid, $targetname, $lunid, $lr );
                $pathval =~ m{^([\:\w\-/\.]+)$}
                  or die "Invalid source path '$pathval'";
            };

# TODO: reevaluate this section
# If we are not able to identify block device for existing lun record
# something is off, there fore we deactivate volume and activate it again
# We have to check that activate/deactivate transaction will not lead to unexpected
# side effect, like deactivation of volume snapshot should not lead to volume deactivation
            if ($@) {
                OpenEJovianDSS::Common::debugmsg($scfg, 'debug', "Path unable to identify device for volume ${volname}, "
                  . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
                  . " $@\n");
                OpenEJovianDSS::Common::volume_deactivate( $scfg, $storeid,
                    $vmid, $volname, $snapname, undef );
                my $bdpl =
                  OpenEJovianDSS::Common::volume_activate( $scfg, $storeid,
                    $vmid, $volname, $snapname, undef );

                unless ( defined($bdpl) ) {
                    die "Unable to identify block device related to ${volname}"
                      . OpenEJovianDSS::Common::safe_var_print( "snapshot",
                        $snapname )
                      . "\n";
                }
                $pathval = ${$bdpl}[0];
                $pathval =~ m{^([\:\w\-/\.]+)$}
                  or die "Invalid source path '$pathval'";
            }
            return wantarray ? ( $pathval, $vmid, $vtype ) : $pathval;
        }

        # Check if we actually have multiple records or if this is a different error
        if (@$til == 0) {
            # This means volume activation must have failed in the unless block
            die "Resource ${volname}"
              . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
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
            OpenEJovianDSS::Common::debugmsg($scfg, 'warning', "Failed to identify correct record for ${volname}"
              . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
              . "\nFound records:\n${records_info}"
            );
            sleep(3);
            die "Resource ${volname}"
              . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
              . " have multiple records:\n${records_info}";
        } else {
            # This should never happen (we already handled @$til == 1 case above)
            die "Unexpected error in LUN record handling for ${volname}"
              . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
              . "\n";
        }

    }
    else {
        $path = $class->filesystem_path( $scfg, $volname, $snapname );
    }

    return $path;
}

sub rename_volume {
    my ( $class, $scfg, $storeid, $original_volname, $new_vmid, $new_volname )
      = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my (
        $original_vtype,    $original_volume_name, $original_vmid,
        $original_basename, $original_basedvmid,   $original_isBase,
        $original_format
    ) = $class->parse_volname($original_volname);

    $new_volname =
      $class->find_free_diskname( $storeid, $scfg, $new_vmid, $original_format )
      if ( !defined($new_volname) );

    OpenEJovianDSS::Common::volume_deactivate( $scfg, $storeid,
        $original_vmid, $original_volname, undef, undef );
    OpenEJovianDSS::Common::volume_unpublish( $scfg, $storeid,
        $original_vmid, $original_volname, undef, undef );

    OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", $pool, "volume", $original_volname, "rename", $new_volname ]
    );

    my $newname = "${storeid}:${new_volname}";
    return $newname;
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;

    my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) =
      $class->parse_volname($volname);

    die "create_base is not possible with base image\n" if $isBase;

    $class->deactivate_volume( $storeid, $scfg, $volname, undef, undef );

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my $newnameprefix = join '', 'base-', $vmid, '-disk-';

    my $newname = OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", $pool, "volumes", "getfreename", "--prefix", $newnameprefix ]
    );
    chomp($newname);
    $newname =~ s/[^[:ascii:]]//;

    $class->rename_volume( $scfg, $storeid, $volname, $vmid, $newname );

    return $newname;
}

sub clone_image {
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my ( undef, undef, undef, undef, undef, undef, $fmt ) =
      $class->parse_volname($volname);
    my $clone_name = $class->find_free_diskname( $storeid, $scfg, $vmid, $fmt );

    my $size = OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", $pool, "volume", $volname, "get", "-s" ] );
    $size = OpenEJovianDSS::Common::clean_word($size);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Clone ${volname} with size ${size} to ${clone_name}"
          . OpenEJovianDSS::Common::safe_var_print( " with snapshot", $snap )
          . "\n" );
    if ($snap) {
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                "pool",  $pool,    "volume", $volname,
                "clone", "--size", $size,    "--snapshot",
                $snap,   "-n",     $clone_name
            ]
        );
    }
    else {
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                "pool",  $pool,    "volume", $volname,
                "clone", "--size", $size,    "-n",
                $clone_name
            ]
        );
    }
    return $clone_name;
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    my $volume_name = $name;

    unless ( defined($volume_name) ) {
        $volume_name =
          $class->find_free_diskname( $storeid, $scfg, $vmid, $fmt );
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Searching for free volume name for vm ${vmid} format ${fmt}" );
    }

    if ( 'images' ne "${fmt}" ) {

        my $pool    = OpenEJovianDSS::Common::get_pool($scfg);
        my $extsize = $size * 1024;
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
"Creating volume ${volume_name} format ${fmt} requested size ${size}"
        );

        my $create_vol_cmd = [
            "pool",   $pool,        "volumes", "create",
            "--size", "${extsize}", "-n",      $volume_name
        ];

        my $block_size = OpenEJovianDSS::Common::get_block_size($scfg);
        my $thin_provisioning =
          OpenEJovianDSS::Common::get_thin_provisioning($scfg);

        if ( defined($thin_provisioning) ) {
            push @$create_vol_cmd, '--thin-provisioning', $thin_provisioning;
        }

        if ( defined($block_size) ) {
            push @$create_vol_cmd, '--block-size', $block_size;
        }

        OpenEJovianDSS::Common::joviandss_cmd( $scfg, $create_vol_cmd );
    }
    return OpenEJovianDSS::Common::clean_word($volume_name);
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $_format ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);
    my ( $vtype, undef, $vmid, undef, undef, undef, $format ) =
      $class->parse_volname($volname);

    if ( 'images' cmp "$vtype" ) {
        return $class->SUPER::free_image( $storeid, $scfg, $volname, $isBase,
            $format );
    }
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deleting volume ${volname} format ${format}\n" );

    my $tgname =
      OpenEJovianDSS::Common::get_vm_target_group_name( $scfg, $vmid );
    my $prefix = OpenEJovianDSS::Common::get_target_prefix($scfg);

    # Volume deletion will result in deletetion of all its snapshots
    # Therefore we have to detach all volume snapshots that is expected to be
    # removed along side with volume

    OpenEJovianDSS::Common::volume_deactivate( $scfg, $storeid, $vmid,
        $volname, undef, undef );

    # Deactivation does not unpublish volumes, only snapshots
    OpenEJovianDSS::Common::volume_unpublish( $scfg, $storeid, $vmid, $volname,
        undef, undef );

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool",   $pool, "volume",          $volname,
            "delete", "-c",  '--target-prefix', $prefix,
            '--target-group-name', $tgname
        ]
    );
    return undef;
}

sub get_nfs_addresses {
    my ( $class, $scfg, $storeid ) = @_;

    my $gethostscmd = [ "hosts", '--nfs' ];

    my @hosts = ();
    my $out   = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $gethostscmd );
    foreach ( split( /\n/, $out ) ) {
        push @hosts, OpenEJovianDSS::Common::clean_word(split);
    }
    return @hosts;
}

sub get_scsiid {
    my ( $class, $scfg, $target, $storeid ) = @_;

    my @hosts = $class->get_iscsi_addresses( $scfg, $storeid, 1 );

    foreach my $host (@hosts) {
        my $targetpath = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-0";
        my $getscsiidcmd =
          [ "/lib/udev/scsi_id", "-g", "-u", "-d", $targetpath ];
        my $scsiid;

        if ( -e $targetpath ) {
            eval {
                run_command( $getscsiidcmd,
                    outfunc => sub { $scsiid = shift; } );
            };

            if ($@) {
                die
"Unable to get the iSCSI ID for ${targetpath} because of $@\n";
            }
        }
        else {
            next;
        }

        if ( defined($scsiid) ) {
            if ( $scsiid =~ /^([\-\@\w.\/]+)$/ ) {
                OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                    "Identified scsi id ${1}\n" );
                return $1;
            }
        }
    }
    return undef;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    #TODO: rename jdssc variable
    my $jdssc = OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", $pool, "volumes", "list", "--vmid" ] );

    my $res = [];
    foreach ( split( /\n/, $jdssc ) ) {
        my ( $volname, $vm, $size, $ctime ) = split;

        $volname = OpenEJovianDSS::Common::clean_word($volname);
        $vm      = OpenEJovianDSS::Common::clean_word($vm);
        $size    = OpenEJovianDSS::Common::clean_word($size);

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

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", $pool, "volume", $volname, "snapshots", "create", $snap ] );

}

# Returns a hash with the snapshot names as keys and the following data:
# id        - Unique id to distinguish different snapshots even if the have the same name.
# timestamp - Creation time of the snapshot (seconds since epoch).
# Returns an empty hash if the volume does not exist.
sub volume_snapshot_info {
    my ( $class, $scfg, $storeid, $volname ) = @_;

    return OpenEJovianDSS::Common::volume_snapshots_info( $scfg,
        $storeid, $volname );
}

sub volume_snapshot_needs_fsfreeze {

    return 0;
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool",     $pool, "volume",   $volname,
            "snapshot", $snap, "rollback", "do"
        ]
    );
}

sub volume_rollback_is_possible {
    my ( $class, $scfg, $storeid, $volname, $snap, $blockers ) = @_;

    return OpenEJovianDSS::Common::volume_rollback_check( $scfg,
        $storeid, $volname, $snap, $blockers );
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);
    my $prefix = OpenEJovianDSS::Common::get_target_prefix($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $tgname =
      OpenEJovianDSS::Common::get_vm_target_group_name( $scfg, $vmid );

    OpenEJovianDSS::Common::volume_deactivate( $scfg, $storeid, $vmid,
        $volname, $snap, undef );

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool",     $pool,
            "volume",   $volname,
            "snapshot", $snap,
            "delete",   '--target-prefix',
            $prefix,    '--target-group-name',
            $tgname
        ]
    );
}

sub volume_snapshot_list {
    my ( $class, $scfg, $storeid, $volname ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my $jdssc = OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", $pool, "volume", $volname, "snapshots", "list" ] );

    my $res = [];
    foreach ( split( /\n/, $jdssc ) ) {
        my ($sname) = split;
        push @$res, { 'name' => '$sname' };
    }

    return $res;
}

sub volume_size_info {
    my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    if ( 'images' cmp "$vtype" ) {
        return $class->SUPER::volume_size_info( $scfg, $storeid, $volname,
            $timeout );
    }

    my $size = OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", $pool, "volume", $volname, "get", "-s" ] );
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    return $size;
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my $jdssc =
      OpenEJovianDSS::Common::joviandss_cmd( $scfg, [ "pool", $pool, "get" ],
        10, 0, 'info' );
    my $gb = 1024 * 1024 * 1024;
    my ( $total, $avail, $used ) = split( " ", $jdssc );

    return ( $total * $gb, $avail * $gb, $used * $gb, 1 );
}

sub disk_for_target {
    my ( $class, $storeid, $scfg, $target ) = @_;
    return undef;
}

sub ensure_content_volume_nfs {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $content_path = OpenEJovianDSS::Common::get_content_path($scfg);

    unless ( defined($content_path) ) {
        return undef;
    }

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my $content_volume_name =
      OpenEJovianDSS::Common::get_content_volume_name($scfg);
    my $content_volume_size =
      OpenEJovianDSS::Common::get_content_volume_size($scfg);

    my $content_volume_size_current = undef;

    unless ( -d "$content_path" ) {
        mkdir "$content_path";
    }

    eval {
        $content_volume_size_current = OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                'pool', $pool, 'share', $content_volume_name,
                'get',  '-d',  '-s',    '-G'
            ]
        );
    };

    if ( !defined($content_volume_size_current) ) {

        # If we are not able to identify size of content volume
        # most likely it does not exists
        # there fore we have to create it
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Creating content volume with size ${content_volume_size}\n" );
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                'pool',   $pool, 'shares',
                'create', '-d',  '-q', "${content_volume_size}G", '-n',
                $content_volume_name
            ]
        );
    }
    elsif (defined($content_volume_size_current)
        && $content_volume_size_current =~ /^\d+$/
        && $content_volume_size_current > 0 )
    {

        # TODO: check for volume size on the level of OS
        # If volume needs resize do it with jdssc
        die "Unable to identify content volume ${content_volume_name} size\n"
          unless defined($content_volume_size);
        $content_volume_size_current =
          OpenEJovianDSS::Common::clean_word($content_volume_size_current);
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
"Current content volume size ${content_volume_size_current}, config value ${content_volume_size}\n"
        );
        if ( $content_volume_size > $content_volume_size_current ) {
            OpenEJovianDSS::Common::joviandss_cmd(
                $scfg,
                [
                    "pool",   $pool, "share", $content_volume_name,
                    "resize", "-d",  "${content_volume_size}G"
                ]
            );
        }
    }
    else {
        OpenEJovianDSS::Common::debugmsg( $scfg, "warning",
"Unable to process current size of content volume <${content_volume_size_current}>, please make sure that JovianDSS is accessible over network\n"
        );
        die
"Unable to process current size of content volume <${content_volume_size_current}>, please make sure that JovianDSS is accessible over network\n";
    }

    my @hosts = $class->get_nfs_addresses( $scfg, $storeid );

    foreach my $host (@hosts) {
        my $not_found_code = 1;
        my $nfs_path       = "${host}:/Pools/${pool}/${content_volume_name}";
        my $cmd            = [
            '/usr/bin/findmnt', '-t', 'nfs', '-S',
            $nfs_path,          '-M', $content_path
        ];
        eval {
            $not_found_code = run_command( $cmd, outfunc => sub { } );
        };
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Code for find mnt ${not_found_code}\n" );
        $class->ensure_fs($scfg);

        if ( $not_found_code eq 0 ) {
            return 0;
        }
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Content storage found not to be mounted, mounting.\n" );

    my $not_mounted = 1;
    eval {
        $not_mounted =
          run_command( [ "findmnt", $content_path ], outfunc => sub { } );
    };

    if ( $not_mounted == 0 ) {
        $class->deactivate_storage( $storeid, $scfg, $cache );
    }

    foreach my $host (@hosts) {
        my $not_found_code = 1;
        my $nfs_path       = "${host}:/Pools/${pool}/${content_volume_name}";
        run_command(
            [
                "/usr/bin/mount",         "-t",
                "nfs",                    "-o",
                "vers=3,nconnect=4,sync", $nfs_path,
                $content_path
            ],
            outfunc => sub { },
            timeout => 10,
            noerr   => 1
        );

        my $cmd = [
            '/usr/bin/findmnt', '-t', 'nfs', '-S',
            $nfs_path,          '-M', $content_path
        ];
        eval {
            $not_found_code = run_command( $cmd, outfunc => sub { } );
        };
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Code for find mnt ${not_found_code}\n" );

        $class->ensure_fs($scfg);

        if ( $not_found_code eq 0 ) {
            return 0;
        }
    }

    die "Unable to mount content storage\n";
}

sub ensure_fs {
    my ( $class, $scfg ) = @_;

    my $path = OpenEJovianDSS::Common::get_content_path($scfg);

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
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Activate storage ${storeid}\n" );

    OpenEJovianDSS::Common::store_settup( $scfg, $storeid );

    return undef if !defined( $scfg->{content} );

    my @content_types = ( 'iso', 'backup', 'vztmpl', 'snippets' );

    my $enabled_content = OpenEJovianDSS::Common::get_content($scfg);

    my $content_volume_needed = 0;
    foreach my $content_type (@content_types) {
        if ( exists $enabled_content->{$content_type} ) {
            $content_volume_needed = 1;
            last;
        }
    }

    if ($content_volume_needed) {
        my $cvt = OpenEJovianDSS::Common::get_content_volume_type($scfg);

        if ( $cvt eq "nfs" ) {
            $class->ensure_content_volume_nfs( $storeid, $scfg, $cache );
        }

        #else {
        #    $class->ensure_content_volume( $storeid, $scfg, $cache );
        #}
    }
    return 1;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deactivating storage ${storeid}\n" );

    my $path = OpenEJovianDSS::Common::get_content_path($scfg);
    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my $content_volname =
      OpenEJovianDSS::Common::get_content_volume_name($scfg);
    my $target;

# TODO: consider removing multipath and iscsi target on the basis of mount point
    if ( defined($path) ) {
        my $cmd = [ '/bin/umount', $path ];
        eval {
            run_command( $cmd, errmsg => 'umount error', outfunc => sub { } );
        };

        if ( OpenEJovianDSS::Common::get_debug($scfg) ) {
            warn "Unable to unmount ${path}" if $@;
        }
    }
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Activate volume ${volname}"
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . " start" );

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    return 0 if ( 'images' ne "$vtype" );

    my $til =
      OpenEJovianDSS::Common::lun_record_local_get_info_list( $scfg, $storeid,
        $volname, $snapname );

    unless (@$til) {
        OpenEJovianDSS::Common::volume_activate( $scfg, $storeid, $vmid,
            $volname, $snapname, undef );
    }
    else {
# If volume was resized on other node we have to make sure that current size is accurate
        my $current_size =
          OpenEJovianDSS::Common::volume_get_size( $scfg, $storeid, $volname );
        if ( @$til == 1 ) {
            my ( $targetname, $lunid, $lunrecpath, $lr ) = @{ $til->[0] };
            if ( $current_size > $lr->{size} ) {
                OpenEJovianDSS::Common::volume_update_size( $scfg, $storeid,
                    $vmid, $volname, $current_size );
            }
        }
        else {
            die "Unable to identify lun record.\n";
        }
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Activate volume ${volname}"
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . " done" );

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Deactivate volume "
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . "start" );
    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);
    my $prefix = OpenEJovianDSS::Common::get_target_prefix($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $tgname =
      OpenEJovianDSS::Common::get_vm_target_group_name( $scfg, $vmid );

    return 0 if ( 'images' ne "$vtype" );

    OpenEJovianDSS::Common::volume_deactivate( $scfg, $storeid, $vmid,
        $volname, $snapname, undef );

    # Unpublish if that is a state of VM
    if ( $volname =~ m!^vm-(\d+)-state-(.+)$! ) {
        OpenEJovianDSS::Common::volume_unpublish( $scfg, $storeid,
            $vmid, $volname, $snapname, undef );
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Deactivate volume "
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . "done" );

    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Resize volume ${volname} to size ${size}" );

    OpenEJovianDSS::Common::joviandss_cmd( $scfg,
        [ "pool", "${pool}", "volume", "${volname}", "resize", "${size}" ] );

    my $til =
      OpenEJovianDSS::Common::lun_record_local_get_info_list( $scfg, $storeid,
        $volname, undef );
    if ( @$til == 1 ) {
        my ( $targetname, $lunid, $lunrecpath, $lunrecord ) = @{ $til->[0] };
        OpenEJovianDSS::Common::lun_record_update_device( $scfg, $storeid,
            $targetname, $lunid, $lunrecpath, $lunrecord, $size );
    }

    return 1;
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

    my ($path) = $class->path($scfg, $volname, $storeid, $options->{'snapshot-name'});
    my $blockdev = { driver => 'host_device', filename => $path };
    return $blockdev;
}

sub volume_qemu_snapshot_method {
    my ($class, $storeid, $scfg, $volname) = @_;

    return 'storage';
}

# Password file management
sub joviandss_password_file_name {
    my ($scfg, $storeid) = @_;
    return "/etc/pve/priv/storage/joviandss/${storeid}.pw";
}

sub joviandss_set_password {
    my ($password, $storeid) = @_;
    my $pwfile = joviandss_password_file_name(undef, $storeid);

    # Create directory with full path
    my $dir = "/etc/pve/priv/storage/joviandss";
    if (! -d $dir) {
        File::Path::make_path($dir, { mode => 0700 });
    }

    PVE::Tools::file_set_contents($pwfile, "user_password $password\n", 0600, 1);
}

sub joviandss_get_password {
    my ($scfg, $storeid) = @_;
    my $pwfile = joviandss_password_file_name($scfg, $storeid);

    return undef if ! -f $pwfile;

    # Read entire file and parse key-value pairs
    my $content = PVE::Tools::file_get_contents($pwfile);
    my $config = {};

    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;  # trim whitespace
        next if $line =~ /^#/ || $line eq '';  # skip comments and empty lines

        if ($line =~ /^(\S+)\s+(.+)$/) {
            $config->{$1} = $2;
        }
    }

    return $config->{user_password};
}

sub joviandss_delete_password {
    my ($storeid) = @_;
    my $pwfile = joviandss_password_file_name(undef, $storeid);
    unlink $pwfile;
}

# Storage hooks for sensitive properties
sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    return if !exists($sensitive{user_password});
    joviandss_set_password($sensitive{user_password}, $storeid);
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;
    return if !exists($sensitive{user_password});
    if (defined($sensitive{user_password})) {
        joviandss_set_password($sensitive{user_password}, $storeid);
    } else {
        joviandss_delete_password($storeid);
    }
}

1;
