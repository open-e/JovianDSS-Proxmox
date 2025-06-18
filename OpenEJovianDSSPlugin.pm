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
use base qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.10.0-0';

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
#    0.10.0-0 - 2025.06.17
#               Storing information about activated volumes and snapshots
#               localy

# Configuration


sub api {

    my $apiver = 11;

    return $apiver;
}

sub type {
    return 'joviandss';
}

sub plugindata {
    return {
        content => [
            {
                images   => 1,
                rootdir  => 1,
                vztmpl   => 1,
                iso      => 1,
                backup   => 1,
                snippets => 1,
                none     => 1
            },
            { images => 1, rootdir => 1 }
        ],
        format => [ { raw => 1, subvol => 0 }, 'raw' ],
    };
}

sub properties {
    return {
        pool_name => {
            description => "Pool name",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_path(),
        },
        config => {
            description => "JovianDSS config address",
            type        => 'string',
        },
        debug => {
            description => "Allow debug prints",
            type        => 'boolean',
            default     => OpenEJovianDSS::Common::get_default_debug(),
        },
        multipath => {
            description => "Enable multipath support",
            type        => 'boolean',
            default     => OpenEJovianDSS::Common::get_default_multipath(),
        },
        content_volume_name => {
            description => "Name of proxmox dedicated storage volume",
            type        => 'string',
        },
        content_volume_type => {
            description =>
"Type of proxmox dedicated storage, allowed types are nfs and iscsi",
            type => 'string',
        },
        content_volume_size => {
            description => "Name of proxmox dedicated storage size",
            type        => 'string',
        },
        user_name => {
            description => "User name that will be used in REST communication",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_user_name(),
        },
        user_password => {
            description => "User password that will be used in REST communication",
            type        => 'string',
        },
        target_prefix => {
            description => "Prefix of iSCSI target 'iqn.2025-04.iscsi:'",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_target_prefix,
        },
        ssl_cert_verify => {
            description => "Enforce certificate verification for REST over SSL/TLS",
            type        => 'boolean',
        },
        control_addresses => {
            description => "Coma separated list of ip addresses, that will be used to send control REST requests to JovianDSS storage",
            type        => 'string',
        },
        control_port => {
            description => "Port number that will be used to send REST request, single for all addresses",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_control_port(),
        },
        data_addresses => {
            description => "Coma separated list of ip addresses, that will be used to transfer storage data(iSCSI data)",
            type        => 'string',
        },
        data_port => {
            description => "Port number that will be used to transfer storage data(iSCSI data)",
            type        => 'string',
            default     => OpenEJovianDSS::Common::get_default_data_port(),
        },
        block_size => {
            description => 'Block size for newly created volumes, allowed values are: '.
                           '4K 8K 16K 32K 64K 128K 256K 512K 1M',
            type        => 'string',
        },
        thin_provisioning => {
            description => 'Create new volumes as thin',
            type        => 'boolean',
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
        pool_name           => { fixed    => 1 },
        config              => { optional => 1 },
        path                => { optional => 1 },
        debug               => { optional => 1 },
        multipath           => { optional => 1 },
        content             => { optional => 1 },
        content_volume_name => { optional => 1 },
        content_volume_type => { optional => 1 },
        content_volume_size => { optional => 1 },
        shared              => { optional => 1 },
        disable             => { optional => 1 },
        target_prefix       => { optional => 1 },
        ssl_cert_verify     => { optional => 1 },
        user_name           => { optional => 1 },
        user_password       => { optional => 1 },
        control_addresses   => { optional => 1 },
        control_port        => { optional => 1 },
        data_addresses      => { optional => 1 },
        data_port           => { optional => 1 },
        block_size          => { optional => 1 },
        thin_provisioning   => { optional => 1 },
        log_file            => { optional => 1 },
        'create-subdirs'    => { optional => 1 },
        'create-base-path'  => { optional => 1 },
        'content-dirs'      => { optional => 1 },
    };
}

my $ISCSIADM = '/usr/bin/iscsiadm';
$ISCSIADM = undef if !-X $ISCSIADM;

my $MULTIPATH = '/usr/sbin/multipath';
$MULTIPATH = undef if !-X $MULTIPATH;

my $SYSTEMCTL = '/usr/bin/systemctl';
$SYSTEMCTL = undef if !-X $SYSTEMCTL;



#sub check_iscsi_support {
#    my $noerr = shift;
#
#    if ( !$ISCSIADM ) {
#        my $msg = "no iscsi support - please install open-iscsi";
#        if ($noerr) {
#            warn "warning: $msg\n";
#            return 0;
#        }
#
#        die "error: $msg\n";
#    }
#
#    return 1;
#}


#sub iscsi_test_portal {
#    my ($portal) = @_;
#
#    my ( $server, $port ) = PVE::Tools::parse_host_and_port($portal);
#    return 0 if !$server;
#    return PVE::Network::tcp_ping( $server, $port || 3260, 2 );
#}

#sub iscsi_login {
#    my ( $target, $portal_in ) = @_;
#
#    check_iscsi_support();
#
#    #TODO: for each IP run discovery
#    eval { iscsi_discovery( $target, $portal_in ); };
#    warn $@ if $@;
#
#    #TODO: for each target run login
#    run_command(
#        [
#            $ISCSIADM,  '--mode',       'node',  '-p',
#            $portal_in, '--targetname', $target, '--login'
#        ],
#        outfunc => sub { }
#    );
#}
#
#sub iscsi_logout {
#    my ( $target, $portal ) = @_;
#
#    check_iscsi_support();
#
#    run_command(
#        [ $ISCSIADM, '--mode', 'node', '--targetname', $target, '--logout' ],
#        outfunc => sub { } );
#}

sub block_device_path {
    my ( $class, $scfg, $volname, $storeid, $snapname, $content_volume_flag ) =
      @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Getting path of volume ${volname} " . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname ) . "\n");

    my $target = $class->get_target_name( $scfg, $volname, $snapname,
        $content_volume_flag );

    my $tpath;

    if ( OpenEJovianDSS::Common::get_multipath($scfg) ) {
        $tpath = $class->get_multipath_path( $scfg, $target );
    }
    else {
        $tpath = $class->get_target_path( $scfg, $target, $storeid );
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Block device path is ${tpath} of volume ${volname} " . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname ) . "\n");

    return $tpath;
}

sub path {
    my ( $class, $scfg, $volname, $storeid, $snapname ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $path;

    if ( $vtype eq "images" ) {
        my $til = OpenEJovianDSS::Common::lun_record_local_get_info_list( $scfg, $storeid, $volname, $snapname );

        if ( @$til == 1) {
            my ($targetname, $lunid, $lunrecpath, $lr) = $til->[0];
             return OpenEJovianDSS::Common::block_device_path_from_lun_rec( $scfg, $storeid, $targetname, $lunid, $lr );
        }

        unless (@$til) {
            my $bdpl = OpenEJovianDSS::Common::volume_activate( $scfg, $storeid, $vmid, $volname, $snapname, undef );

            unless( defined($bdpl) ) {
                die "Unable to identify block device related to ${volname}" .
                        OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname ) .
                        "\n";
            }
            return $bdpl[0];
        }
        die "Resource ${volname}" .
                OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname ) .
                " have multiple records \n";

    }
    else {
        $path = $class->filesystem_path( $scfg, $volname, $snapname );
    }

    return $path;
}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my ($source_vtype,
        $source_volume_name,
        $source_vmid,
        $source_basename,
        $source_basedvmid,
        $source_isBase,
        $source_format) = $class->parse_volname($source_volname);

    $target_volname = $class->find_free_diskname($storeid, $scfg, $target_vmid, $source_format) if (! defined($target_volname));

    my $til = OpenEJovianDSS::Common::lun_record_local_get_info_list( $scfg, $storeid, $source_volname, undef );

    if ( @$til == 1) {

        ($targetname, $lunid, $lunrecpath, $lr) = $til->[0];
        OpenEJovianDSS::Common::lun_record_local_create(
                $scfg,    $storeid,
                $targetname, $lunid, $target_volname, undef,
                $lr->{scsiid}, $lr->{size},
                $lr->{multipath}, $lr->{shared},
                @{ $lr->{hosts} }
        )

        eval {
            OpenEJovianDSS::Common::joviandss_cmd(
                $scfg,
                [
                    "pool", $pool,
                    "volume", $source_volname,
                    "rename", $target_volname
                ]
            );
        }
        my $err = $@;

        if ($err) {
            eval {
                OpenEJovianDSS::Common::lun_record_local_delete( $scfg, $storeid, $targetname, $lunid, $target_volname, undef );
                die "Unable to rename volume ${volname} because of ${err}\n";
            }
        }
        OpenEJovianDSS::Common::lun_record_local_delete( $scfg, $storeid, $targetname, $lunid, $source_volname, undef );
        return;

    unless (@$til) {
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                "pool", $pool,
                "volume", $source_volname,
                "rename", $target_volname
            ]
        );
    }
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;

    my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase ) =
      $class->parse_volname($volname);

    die "create_base is not possible with base image\n" if $isBase;

    $class->deactivate_volume( $storeid, $scfg, $volname, undef, undef );

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my $newnameprefix = join '', 'base-', $vmid, '-disk-';

    my $newname = OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool",     $pool,
            "volumes",
            "getfreename", "--prefix", $newnameprefix
        ]
    );
    chomp($newname);
    $newname =~ s/[^[:ascii:]]//;

    $class->rename_volume( $scfg, $storeid, $source_volname, $volname, $vmid, $target_volname );

    return $newname;
}

sub clone_image {
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my ( undef, undef, undef, undef, undef, undef, $fmt ) =
      $class->parse_volname($volname);
    my $clone_name = $class->find_free_diskname( $storeid, $scfg, $vmid, $fmt );

    my $size = OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool", $pool,
            "volume", $volname,
            "get", "-s"
        ] );
    $size = OpenEJovianDSS::Common::clean_word($size);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Clone ${volname} with size ${size} to ${clone_name}" . OpenEJovianDSS::Common::safe_var_print( " with snapshot", $snap ) . "\n");
    if ($snap) {
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                "pool",  $pool,
                "volume", $volname,
                "clone", "--size", $size, "--snapshot", $snap, "-n",
                $clone_name
            ]
        );
    }
    else {
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                "pool",  $pool,
                "volume", $volname,
                "clone", "--size", $size, "-n", $clone_name
            ]
        );
    }
    return $clone_name;
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    my $volume_name = $name;

    $volume_name = $class->find_free_diskname( $storeid, $scfg, $vmid, $fmt )
      if !$volume_name;

    if ( 'images' ne "${fmt}" ) {

        my $pool   = OpenEJovianDSS::Common::get_pool($scfg);
        my $extsize = $size * 1024;
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Creating volume ${volume_name} format ${fmt} requested size ${size}\n"
        );

        my $create_vol_cmd = [
            "pool", $pool,
            "volumes", 
            "create", "--size", "${extsize}", "-n", $volume_name
        ];

        my $block_size = OpenEJovianDSS::Common::get_block_size($scfg);
        my $thin_provisioning = OpenEJovianDSS::Common::get_thin_provisioning($scfg);

        if (defined($thin_provisioning)) {
            push @$create_vol_cmd, '--thin-provisioning', $thin_provisioning;
        }

        if (defined($block_size)) {
            push @$create_vol_cmd, '--block-size', $block_size;
        }

        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            $create_vol_cmd
        );

        if (OpenEJovianDSS::Common::get_shared($scfg)) {
            my $tgname = OpenEJovianDSS::Common::get_vm_target_group_name($scfg, $vmid);
            OpenEJovianDSS::Common::activate_volume_shared( $scfg, $storeid, $tgname, $volname );
        }
    }
    return "$volume_name";
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $_format ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);
    my ( $vtype, undef, $vmid, undef, undef, undef, $format ) =
      $class->parse_volname($volname);

    if ( 'images' cmp "$vtype" ) {
        return $class->SUPER::free_image( $storeid, $scfg, $volname, $isBase,
            $format );
    }
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deleting volume ${volname} format ${format}\n"
    );

    my $prefix = OpenEJovianDSS::Common::get_target_prefix($scfg);

    # Volume deletion will result in deletetion of all its snapshots
    # Therefore we have to detach all volume snapshots that is expected to be
    # removed along side with volume
    my $delitablesnaps = OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool", $pool,
            "volume", $volname,
            "delete", "-c", "-p", '--target-prefix', $prefix
        ]
    );
    my @dsl = split( " ", $delitablesnaps );

    foreach my $snap (@dsl) {
        OpenEJovianDSS::Common::volume_deactivate ( $scfg, $storeid, $vmid, $volname, $snap, undef );

    }

    OpenEJovianDSS::Common::volume_deactivate ( $scfg, $storeid, $vmid, $volname, undef, undef );

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool", $pool,
            "volume", $volname,
            "delete", "-c", '--target-prefix', $prefix
        ] );
    return undef;
}

#sub unstage_target {
#    my ( $class, $scfg, $storeid, $target ) = @_;
#
#    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unstaging target ${target}\n");
#    my @hosts = $class->get_iscsi_addresses( $scfg, $storeid, 1 );
#
#    foreach my $host (@hosts) {
#        my $tpath = $class->get_target_path( $scfg, $target, $storeid );
#
#        if ( defined($tpath) && -e $tpath ) {
#
# # Driver should not commit any write operation including sync before unmounting
# # Because that myght lead to data corruption in case of active migration
# # Also we do not do volume unmounting
#
#            eval {
#                run_command(
#                    [
#                        $ISCSIADM, '--mode',       'node',  '-p',
#                        $host,     '--targetname', $target, '--logout'
#                    ],
#                    outfunc => sub { }
#                );
#            };
#            warn $@ if $@;
#            eval {
#                run_command(
#                    [
#                        $ISCSIADM, '--mode',       'node',  '-p',
#                        $host,     '--targetname', $target, '-o',
#                        'delete'
#                    ],
#                    outfunc => sub { }
#                );
#            };
#            warn $@ if $@;
#        }
#    }
#}



#sub stage_multipath {
#    my ( $class, $scfg, $scsiid, $target ) = @_;
#
#    my $targetpath = $class->get_multipath_path( $scfg, $target );
#
#    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Staging ${target}\n");
#
#    eval {
#        run_command( [ $MULTIPATH, '-a', $scsiid ], outfunc => sub { } );
#    };
#    die "Unable to add the SCSI ID ${scsiid} $@\n" if $@;
#
#    #eval { run_command([$SYSTEMCTL, 'restart', 'multipathd']); };
#    eval {
#        run_command( [$MULTIPATH], outfunc => sub { } );
#    };
#    die "Unable to call multipath: $@\n" if $@;
#
#    my $mpathname = $class->get_device_mapper_name( $scfg, $scsiid );
#    unless ( defined($mpathname) ) {
#        die
#"Unable to identify the multipath name for scsiid ${scsiid} with target ${target}\n";
#    }
#    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Device mapper name ${mpathname}\n");
#
#    if ( defined($targetpath) && -e $targetpath ) {
#        my ( $tm, $mm );
#        eval {
#            run_command(
#                [ "readlink", "-f", $targetpath ],
#                outfunc => sub {
#                    $tm = shift;
#                }
#            );
#        };
#        eval {
#            run_command(
#                [ "readlink", "-f", "/dev/mapper/${mpathname}" ],
#                outfunc => sub {
#                    $mm = shift;
#                }
#            );
#        };
#
#        if ( $tm eq $mm ) {
#            return;
#        }
#        else {
#            unlink $targetpath;
#        }
#    }
#
#    eval {
#        run_command(
#            [ "ln", "/dev/mapper/${mpathname}", "/dev/mapper/${target}" ],
#            outfunc => sub { } );
#    };
#    die "Unable to create link: $@\n" if $@;
#    return 0;
#}

#sub unstage_multipath {
#    my ( $class, $scfg, $storeid, $target ) = @_;
#
#    my $scsiid;
#
#    # Multipath Block Device Link Path
#    # Link to actual block device representing multipath interface
#    my $mbdlpath = $class->get_multipath_path( $scfg, $target, 1 );
#    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unstage multipath for target ${target}\n");
#
#    # Remove link to multipath file
#    if ( defined $mbdlpath && -e $mbdlpath ) {
#
#        if ( unlink $mbdlpath ) {
#            OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Removed ${mbdlpath} link\n");
#        }
#        else {
#            warn "Unable to remove ${mbdlpath} link$!\n";
#        }
#    }
#
## Driver should not commit any write operation including sync before unmounting
## Because that myght lead to data corruption in case of active migration
## Also we do not do any unmnounting to volume as that might cause unexpected writes
#
#    eval { $scsiid = $class->get_scsiid( $scfg, $target, $storeid ); };
#    if ($@) {
#        die "Unable to identify the SCSI ID for target ${target}";
#    }
#
#    unless ( defined($scsiid) ) {
#        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unable to identify multipath resource ${target}\n");
#        return;
#    }
#
#    eval {
#        run_command( [ $MULTIPATH, '-f', ${scsiid} ], outfunc => sub { } );
#    };
#    if ($@) {
#        warn
#"Unable to remove the multipath mapping for target ${target} because of $@\n"
#          if $@;
#        my $mapper_name = $class->get_device_mapper_name( $scfg, $target );
#        if ( defined($mapper_name) ) {
#            eval {
#                run_command(
#                    [
#                        $DMSETUP, "remove", "-f",
#                        $class->get_device_mapper_name( $scfg, $target )
#                    ],
#                    outfunc => sub { }
#                );
#            };
#            die
#"Unable to remove the multipath mapping for target ${target} with dmsetup: $@\n"
#              if $@;
#        }
#        else {
#            warn "Unable to identify multipath mapper name for ${target}\n";
#        }
#    }
#
#    eval {
#        run_command( [$MULTIPATH], outfunc => sub { } );
#    };
#    die "Unable to restart the multipath daemon $@\n" if $@;
#}

sub get_expected_multipath_path {
    my ( $class, $scfg, $target ) = @_;

    if ( defined $target && length $target ) {

        my $mpath = "/dev/mapper/${target}";

        return $mpath;
    }
    return undef;
}

sub get_iscsi_addresses {
    my ( $class, $scfg, $storeid, $port ) = @_;

    # TODO: check this place for errors
    my $getaddressesscmd = [ 'hosts', '--iscsi' ];

    if ( defined($port) && $port ) {
        push @$getaddressesscmd, '--port';
    }
    my $out = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $getaddressesscmd );
    my @hosts = ();
    foreach ( split( /\n/, $out ) ) {
            push @hosts, split;
    }
    return @hosts;
}

sub get_nfs_addresses {
    my ( $class, $scfg, $storeid ) = @_;

    my $gethostscmd = [ "hosts", '--nfs' ];

    my @hosts = ();
    my $out = OpenEJovianDSS::Common::joviandss_cmd($scfg, $gethostscmd);
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
                die "Unable to get the iSCSI ID for ${targetpath} because of $@\n";
            }
        }
        else {
            next;
        }

        if ( defined($scsiid) ) {
            if ( $scsiid =~ /^([\-\@\w.\/]+)$/ ) {
                OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Identified scsi id ${1}\n");
                return $1;
            }
        }
    }
    return undef;
}

sub get_target_name {
    my ( $class, $scfg, $volname, $snapname, $content_volume_flag ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);
    my $prefix = OpenEJovianDSS::Common::get_target_prefix($scfg);

    my $get_target_cmd =
      [ 
          "pool", $pool,
          "targets",
          "get", '--target-prefix', $prefix, "-v", $volname
      ];
    if ($snapname) {
        push @$get_target_cmd, "--snapshot", $snapname;
    }
    else {
        if ( defined($content_volume_flag) && $content_volume_flag != 0 ) {
            push @$get_target_cmd, '-d';
        }
    }

    my $target = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $get_target_cmd, 80, 3 );

    if ( defined($target) ) {
        $target = OpenEJovianDSS::Common::clean_word($target);
        if ( $target =~ /^([\:\-\@\w.\/]+)$/ ) {
            return $1;
        }
    }
    die "Unable to identify the target name for ${volname} "
      . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname );
}

sub get_target_path {
    my ( $class, $scfg, $target, $storeid, $expected ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my @hosts = $class->get_iscsi_addresses( $scfg, $storeid, 1 );

    my $path;
    foreach my $host (@hosts) {
        $path = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-0";
        if ( defined $expected && $expected != 0 ) {
            return $path;
        }
        if ( -e $path ) {
            return $path;
        }
    }
    return undef;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    #TODO: rename jdssc variable
    my $jdssc = OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool", $pool,
            "volumes",
            "list", "--vmid"
        ] );

    my $res = [];
    foreach ( split( /\n/, $jdssc ) ) {
        my ( $volname, $vm, $size ) = split;

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
          };
    }

    return $res;
}

sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool",      $pool,
            "volume", $volname,
            "snapshots",
            "create", $snap
        ]
    );

}
# Returns a hash with the snapshot names as keys and the following data:
# id        - Unique id to distinguish different snapshots even if the have the same name.
# timestamp - Creation time of the snapshot (seconds since epoch).
# Returns an empty hash if the volume does not exist.
sub volume_snapshot_info {
    my ($class, $scfg, $storeid, $volname) = @_;

    return OpenEJovianDSS::Common::joviandss_volume_snapshot_info($scfg, $storeid, $volname);
}

sub volume_snapshot_needs_fsfreeze {

    return 0;
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool",     $pool,
            "volume", $volname,
            "snapshot", $snap,
            "rollback", "do"
        ]
    );
}


sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap, $blockers) = @_;

    return OpenEJovianDSS::Common::joviandss_volume_rollback_is_possible($scfg, $storeid, $volname, $snap, $blockers);
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my $starget = OpenEJovianDSS::Common::get_active_target_name(
        scfg     => $scfg,
        volname  => $volname,
        snapname => $snap
    );
    unless ( defined($starget) ) {
        $starget = $class->get_target_name( $scfg, $volname, $snap );
    }
    $class->unstage_multipath( $scfg, $storeid, $starget )
      if OpenEJovianDSS::Common::get_multipath($scfg);

    $class->unstage_target( $scfg, $storeid, $starget );

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool", $pool,
            "volume", $volname,
            "snapshot", $snap,
            "delete", '--target-prefix', $prefix
        ]
    );
}

sub volume_snapshot_list {
    my ( $class, $scfg, $storeid, $volname ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my $jdssc = OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool", $pool,
            "volume", $volname,
            "snapshots",
            "list"
        ]
    );

    my $res = [];
    foreach ( split( /\n/, $jdssc ) ) {
        my ($sname) = split;
        push @$res, { 'name' => '$sname' };
    }

    return $res;
}

sub volume_size_info {
    my ( $class, $scfg, $storeid, $volname, $timeout ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    if ( 'images' cmp "$vtype" ) {
        return $class->SUPER::volume_size_info( $scfg, $storeid, $volname,
            $timeout );
    }

    my $size = OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool", $pool,
            "volume", $volname,
            "get", "-s" 
        ] );
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    return $size;
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my $jdssc =
      OpenEJovianDSS::Common::joviandss_cmd( 
          $scfg,
          [
              "pool", $pool,
              "get"
          ] );
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

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my $content_volume_name = OpenEJovianDSS::Common::get_content_volume_name($scfg);
    my $content_volume_size = OpenEJovianDSS::Common::get_content_volume_size($scfg);

    my $content_volume_size_current = undef;

    unless ( -d "$content_path" ) {
        mkdir "$content_path";
    }

    eval {
        $content_volume_size_current = OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                'pool', $pool,
                'share', $content_volume_name,
                'get', '-d',    '-s',   '-G'
            ]
        );
    };

    if ( ! defined($content_volume_size_current)) {
        # If we are not able to identify size of content volume
        # most likely it does not exists
        # there fore we have to create it
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Creating content volume with size ${content_volume_size}\n");
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                'pool', $pool,
                'shares',
                'create', '-d', '-q', "${content_volume_size}G", '-n', $content_volume_name
            ]
        );
    } elsif (defined($content_volume_size_current) &&
             $content_volume_size_current =~ /^\d+$/ &&
             $content_volume_size_current > 0 ) {

        # TODO: check for volume size on the level of OS
        # If volume needs resize do it with jdssc
        die "Unable to identify content volume ${content_volume_name} size\n"
          unless defined($content_volume_size);
        $content_volume_size_current = OpenEJovianDSS::Common::clean_word($content_volume_size_current);
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Current content volume size ${content_volume_size_current}, config value ${content_volume_size}\n");
        if ( $content_volume_size > $content_volume_size_current ) {
            OpenEJovianDSS::Common::joviandss_cmd(
                $scfg,
                [
                    "pool", $pool,
                    "share", $content_volume_name,
                    "resize", "-d", "${content_volume_size}G"
                ]
            );
        }
    } else {
        OpenEJovianDSS::Common::debugmsg( $scfg, "warning", "Unable to process current size of content volume <${content_volume_size_current}>, please make sure that JovianDSS is accessible over network\n");
        die "Unable to process current size of content volume <${content_volume_size_current}>, please make sure that JovianDSS is accessible over network\n";
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
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Code for find mnt ${not_found_code}\n");
        $class->ensure_fs($scfg);

        if ( $not_found_code eq 0 ) {
            return 0;
        }
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Content storage found not to be mounted, mounting.\n");

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
                "/usr/bin/mount",    "-t",
                "nfs",               "-o",
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
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Code for find mnt ${not_found_code}\n");

        $class->ensure_fs($scfg);

        if ( $not_found_code eq 0 ) {
            return 0;
        }
    }

    die "Unable to mount content storage\n";
}

sub ensure_content_volume {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $content_path = OpenEJovianDSS::Common::get_content_path($scfg);

    unless ( defined($content_path) ) {
        return undef;
    }

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    my $content_volname     = OpenEJovianDSS::Common::get_content_volume_name($scfg);
    my $content_volume_size = OpenEJovianDSS::Common::get_content_volume_size($scfg);

    # First we get expected path of block device representing content volume
    # Block Device Path
    my $til = OpenEJovianDSS::Common::lun_record_local_get_info_list( $scfg, $storeid, $source_volname, undef );

    if ( @$til == 1) {

        ($targetname, $lunid, $lunrecpath, $lr) = $til->[0];
    }
    #
    my $block_devs = OpenEJovianDSS::Common::volume_activate( $scfg, $storeid, undef, $volname, undef, 1);
    #
    # my $bdpath =
    #  $class->block_device_path( $scfg, $content_volname, $storeid, undef, 1 );

    # Acquire name of block device that is mounted to content volume folder
    my $findmntpath;
    eval {
        run_command(
            [ "findmnt", $content_path, "-n", "-o", "UUID" ],
            outfunc => sub { $findmntpath = shift; }
        );
    };

    my $tname = $class->get_target_name( $scfg, $content_volname, undef, 1 );

    # if there is a block device mounted to content volume folder
    if ( defined($findmntpath) ) {
        my $tuuid = undef;

        # We need to check that volume mounted to content volume folder is the one
        # specified in config. This volume might change if user decide to change content volumes
        # of if user decide to enable multipath or disable it
        # We want to be sure that volume representing multipath block device is mounted if multipath is enabled
        # If that is not a proper device we better unmount and do remounting
        foreach my $bdpath (@$block_devs) {
            eval {
                run_command( [ 'blkid', '-o', 'value', $bdpath, '-s', 'UUID' ],
                    outfunc => sub { $tuuid = shift; } );
            };
            if ($@) {
                $class->deactivate_storage( $storeid, $scfg, $cache );
                last;
            }
            if ( defined($tuuid) ) {
                last;
            }
        }

        if ( $findmntpath eq $tuuid ) {
            return 1;
        }
        $class->deactivate_storage( $storeid, $scfg, $cache );
    }

    my $create_vol_cmd = [
        "pool", $pool,
        "volumes",
        "create", "-d", "-s", "${content_volume_size}G", '-n', $content_volname
    ];

    my $block_size = OpenEJovianDSS::Common::get_block_size($scfg);
    my $thin_provisioning = OpenEJovianDSS::Common::get_thin_provisioning($scfg);

    if (defined($thin_provisioning)) {
        push @$create_vol_cmd, '--thin-provisioning', $thin_provisioning;
    }

    if (defined($block_size)) {
        push @$create_vol_cmd, '--block-size', $block_size;
    }

    # TODO: check for volume size on the level of OS
    # If volume needs resize do it with jdssc
    my $content_volume_size_current;
    eval {
        $content_volume_size_current = OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            [
                "pool", $pool,
                "volume", $content_volname, "get",  "-d", "-G"
            ]
        );
    };
    if ( ! defined($content_volume_size_current)) {
        OpenEJovianDSS::Common::joviandss_cmd(
            $scfg,
            $create_vol_cmd
        );
    } elsif (defined($content_volume_size_current) &&
             $content_volume_size_current =~ /^\d+$/ &&
             $content_volume_size_current > 0 ) {
        # TODO: check for volume size on the level of OS
        # If volume needs resize do it with jdssc
        $content_volume_size_current = OpenEJovianDSS::Common::clean_word($content_volume_size_current);
        if ( $content_volume_size > $content_volume_size_current ) {
            OpenEJovianDSS::Common::joviandss_cmd(
                $scfg,
                [
                    "pool", $pool,
                    "volume", $content_volname,
                    "resize", "-d", "${content_volume_size}G"
                ]
            );
        }
    } else {
        OpenEJovianDSS::Common::debugmsg( $scfg, "warning", "Unable to process current size of content volume size <${content_volume_size_current}>, please make sure that JovianDSS is accessible over network\n");
        die "Unable to process current size of content volume size <${content_volume_size_current}>, please make sure that JovianDSS is accessible over network\n";
    }

    $class->_activate_volume( $storeid, $scfg, $content_volname, "", $cache,
        1, undef);

    eval {
        run_command( [ "/usr/sbin/fsck", "-n", $bdpath ], outfunc => sub { } );
    };
    if ($@) {
        die
"Unable to identify file system type for content storage, if this is the first run, format ${bdpath} to the file system of your choice.\n";
    }
    if ( $content_volume_size > $content_volume_size_current ) {
        eval {
            run_command( [ "/usr/sbin/resize2fs", $bdpath ],
                outfunc => sub { } );
        };
        if ($@) {
            warn "Unable to resize content storage file system $@\n";
        }
    }
    mkdir "$content_path";

    my $already_mounted = 0;
    my $mount_error     = undef;
    my $errfunc         = sub {
        my $line = shift;
        if ( $line =~ /already mounted on/ ) {
            $already_mounted = 1;
        }
        $mount_error .= "$line\n";
    };
    run_command(
        [ "/usr/bin/mount", $bdpath, $content_path ],
        outfunc => sub { },
        errfunc => $errfunc,
        timeout => 10,
        noerr   => 1
    );
    if ( $mount_error && !$already_mounted ) {
        $class->deactivate_storage( $storeid, $scfg, $cache );
        die $mount_error;
    }
    $class->ensure_fs($scfg);
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
            "Activate storage ${storeid}\n");

    return undef if !defined( $scfg->{content} );

    my @content_types = ( 'iso', 'backup', 'vztmpl', 'snippets' );

    my $enabled_content = OpenEJovianDSS::Common::get_content($scfg);

    my $content_volume_needed = 0;
    foreach my $content_type (@content_types) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Checking content type $content_type\n");
        if ( exists $enabled_content->{$content_type} ) {
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Set content volume flag\n");
            $content_volume_needed = 1;
            last;
        }
    }

    if ($content_volume_needed) {
        my $cvt = OpenEJovianDSS::Common::get_content_volume_type($scfg);
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Content volume type ${cvt}\n");

        if ( $cvt eq "nfs" ) {
            $class->ensure_content_volume_nfs( $storeid, $scfg, $cache );
        }
        else {
            $class->ensure_content_volume( $storeid, $scfg, $cache );
        }
    }
    return undef;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Deactivating storage ${storeid}\n");

    my $path = OpenEJovianDSS::Common::get_content_path($scfg);
    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my $content_volname = OpenEJovianDSS::Common::get_content_volume_name($scfg);
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

    return unless defined($content_volname);

    $target = OpenEJovianDSS::Common::get_active_target_name(
        scfg    => $scfg,
        volname => $content_volname,
        content => 1
    );
    unless ( defined($target) ) {
        $target = $class->get_target_name( $scfg, $content_volname, undef, 1 );
    }

    if ( OpenEJovianDSS::Common::get_multipath($scfg) ) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Removing multipath\n");
        $class->unstage_multipath( $scfg, $storeid, $target );
    }
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unstaging target\n");
    $class->unstage_target( $scfg, $storeid, $target );

    return undef;
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Activate volume ${volname}"
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . " start" );

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    return 0 if ( 'images' ne "$vtype" );

    OpenEJovianDSS::Common::volume_activate( $scfg, $storeid, $vmid, $volname, $snapname, undef);

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

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    return 0 if ( 'images' ne "$vtype" );

    OpenEJovianDSS::Common::volume_deactivate( $scfg, $storeid, $vmid, $volname, $snapname, undef );

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Deactivate volume "
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . "done" );

    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Resize volume ${volname} to size ${size}" );

    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg,
        [
            "pool",   "${pool}",
            "volume", "${volname}",
            "resize", "${size}"
        ]
    );
    OpenEJovianDSS::Common::volume_update( $scfg, $storeid, $volname, $size );

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
        snapshot   => {
            base    => 1,
            current => 1,
            snap => 1
        },
        clone      => {
            base    => 1,
            current => 1,
            snap => 1,
            images => 1
        },
        template   => {
            current => 1
        },
        copy       => {
            base    => 1,
            current => 1,
            snap => 1
        },
        sparseinit => {
            base    => {
                raw => 1
            },
            current => {
                raw => 1
            }
        },
        rename     => {
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

1;
