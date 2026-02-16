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
#
#    ACKNOWLEDGMENT
#    This plugin is based on PVE::Storage::NFSPlugin by Proxmox Server
#    Solutions GmbH. We thank the Proxmox team for their excellent work.
#    https://www.proxmox.com/

package PVE::Storage::Custom::OpenEJovianDSSNFSPlugin;

use strict;
use warnings;

use IO::File;
use Net::IP;
use File::Path;

use PVE::Network;
use PVE::Tools qw(run_command);
use PVE::ProcFSTools;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use OpenEJovianDSS::Common qw(:all);
use OpenEJovianDSS::NFSCommon qw(:all);

use base qw(PVE::Storage::Plugin);

my $PLUGIN_VERSION = '0.1.0';

#    Open-E JovianDSS NFS Proxmox plugin
#
#    0.1.0 - 2025.01.09
#               Initial prototype implementation
#               NFS-based storage with JovianDSS ZFS snapshot support
#

# Configuration

sub api {
    my $supported_apiver_min = 9;
    my $supported_apiver_max = 13;

    my $api_ver = PVE::Storage::APIVER;

    if ($api_ver >= $supported_apiver_min and $api_ver <= $supported_apiver_max) {
        return $api_ver;
    }
    return $supported_apiver_max;
}

sub type {
    return 'joviandss-nfs';
}

sub plugindata {
    return {
        content => [
            {
                images => 1,
                rootdir => 1,
                vztmpl => 1,
                iso => 1,
                backup => 1,
                snippets => 1,
                import => 1,
            },
            { images => 1 },
        ],
        format => [{ raw => 1, qcow2 => 1, vmdk => 1 }, 'raw'],
        'sensitive-properties' => {
            'user_password' => 1,
        },
    };
}

sub properties {
    return {};
}

sub options {
    return {
        server             => { fixed    => 1 },
        export             => { fixed    => 1 },
        path               => { fixed    => 1 },
        'content-dirs'     => { optional => 1 },
        nodes              => { optional => 1 },
        disable            => { optional => 1 },
        'prune-backups'    => { optional => 1 },
        'max-protected-backups' => { optional => 1 },
        options            => { optional => 1 },
        content            => { optional => 1 },
        shared             => { optional => 1 },
        format             => { optional => 1 },
        mkdir              => { optional => 1 },
        'create-base-path' => { optional => 1 },
        'create-subdirs'   => { optional => 1 },
        bwlimit            => { optional => 1 },
        preallocation      => { optional => 1 },
        user_name          => { optional => 1 },
        user_password      => { optional => 1 },
        control_addresses  => { optional => 1 },
        control_port       => { optional => 1 },
        data_addresses     => { },
        ssl_cert_verify    => { optional => 1 },
        debug              => { optional => 1 },
        log_file           => { optional => 1 },
    };
}


# Editing this function should be done with care
# As it is used in other places to identify volume and snapshot location
# within file system
# Path should not create, delete, attach of detach any resources
# It returns expected path
# It does not check if actual object exists
sub path {
    my ( $class, $scfg, $volname, $storeid, $snapname ) = @_;
    OpenEJovianDSS::Common::debugmsg($scfg, 'debug', "Path start for volume ${volname} "
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . "\n");

    my $pool = OpenEJovianDSS::NFSCommon::pool_name_get( $scfg );
    my $storage_path = OpenEJovianDSS::Common::get_path($scfg);

    my $path = undef;

    # There is no need to deactivate volume
    # Because of that we skip only volume deactivation
    if ((! defined($snapname)) || ($snapname eq '')) {
        # Volume path
        # it is simple as it represents same path structure as NFS
        $path = $class->filesystem_path( $scfg, $volname, $snapname );
        return $path;
    } else {
        # Snapshot path
        #
        # Snapshot path is more complicated as each snapshot is a dedicated share
        #
        # Storage path/private/mounts/{vmid}/{volname}/{snapname}/{storage root path}

        my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

        my $mount_in_path = $class->volume_snapshot_mount_private_path( $scfg, $vtype,
                                $name, $vmid, $volname, $snapname);
        $path = "${storage_path}/${mount_in_path}";
        return $path;
    }
}

sub volume_snapshot_mount_private_path {
    my ( $class, $scfg, $vtype, $name, $vmid, $volname, $snapname ) = @_;

    my $vtype_subdirs = $class->get_vtype_subdirs();

    die "unknown vtype '$vtype'\n" if !exists($vtype_subdirs->{$vtype});

    my $subdir = $scfg->{"content-dirs"}->{$vtype} // $vtype_subdirs->{$vtype};

    my $pmvs = OpenEJovianDSS::NFSCommon::nas_private_mounts_volname_snapname($vmid, $volname, $snapname);

    my $path = "${pmvs}/${subdir}/${name}";

    return $path;
}

sub check_config {
    #TODO: review this code
    my ($class, $sectionId, $config, $create, $skipSchemaCheck) = @_;

    $config->{path} = "/mnt/pve/$sectionId" if $create && !$config->{path};

    return $class->SUPER::check_config(
        $sectionId, $config, $create, $skipSchemaCheck
    );
}

# Storage implementation

sub status {
    my ($class, $storeid, $scfg, $cache) = @_;

    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
        if !$cache->{mountdata};

    my $path = $scfg->{path};
    my $server = $scfg->{server};
    my $export = $scfg->{export};

    return undef
      if !OpenEJovianDSS::NFSCommon::path_is_nfs($scfg, $path, $export, $server );

    return $class->SUPER::status($storeid, $scfg, $cache);
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Activate NFS storage ${storeid}\n" );

    my $sharemntpath = $scfg->{path};
    my $data_address = $scfg->{server};
    my $sharepath = $scfg->{export};

    #my $timeout = 2;
    #if (!PVE::Tools::run_fork_with_timeout($timeout, sub { -d $path })) {
    #      die "unable to activate storage '$storeid' - "
    #          . "directory '$path' does not exist or is unreachable\n";
    #}
    unless ( -d $sharemntpath) {
        $class->config_aware_base_mkdir( $scfg, $sharemntpath );
        #TODO: remove this line
        #make_path $sharemntpath, { owner => 'root', group => 'root' };
    }

    if ( OpenEJovianDSS::NFSCommon::path_is_mnt( $scfg, $sharemntpath ) ) {
        if ( OpenEJovianDSS::NFSCommon::path_is_nfs( $scfg,
                $sharemntpath, $sharepath, $data_address ) ) {
            debugmsg( $scfg, "debug", "Storage ${storeid} share ${sharepath} already mounted at ${sharemntpath}" );
        } else {
            die "Unable to activate storage at path ${sharemntpath}, as other resource is mounted."
                . " Please unmount resources at path ${sharemntpath} or assign different 'path' in config.\n";
        }
    } else {
        OpenEJovianDSS::NFSCommon::mount( $scfg, $storeid,
                    $data_address, $sharepath, $sharemntpath, $scfg->{options} );
    }

    $class->SUPER::activate_storage( $storeid, $scfg, $cache );
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $sharemntpath = $scfg->{path};
    my $data_address = $scfg->{server};
    my $sharepath = $scfg->{export};

    OpenEJovianDSS::Common::debugmsg($scfg, "debug",
        "Deactivate NFS storage ${storeid} at path ${sharemntpath}\n");

    if (OpenEJovianDSS::NFSCommon::path_is_mnt( $scfg, $sharemntpath )) {
        OpenEJovianDSS::NFSCommon::umount($scfg, $storeid, $sharemntpath);

        OpenEJovianDSS::Common::debugmsg($scfg, "debug",
            "Deactivate NFS storage ${storeid} done.\n");
        return 1;
    }

    OpenEJovianDSS::Common::debugmsg($scfg, "debug",
        "Deactivate NFS storage ${storeid} at path ${sharemntpath} done nothing."
        . "As path is not a mountpoint.\n");
    return 1;
}

sub check_connection {
    my ($class, $storeid, $scfg) = @_;

    my $server = $scfg->{server};
    my $opts = $scfg->{options};

    my $cmd;

    my $is_v4 = defined($opts) && $opts =~ /vers=4.*/;
    if ($is_v4) {
        my $ip = PVE::JSONSchema::pve_verify_ip($server, 1);
        if (!defined($ip)) {
            $ip = PVE::Network::get_ip_from_hostname($server);
        }

        my $transport =
          PVE::JSONSchema::pve_verify_ipv4($ip, 1) ? 'tcp' : 'tcp6';

        $cmd = ['/usr/sbin/rpcinfo', '-T', $transport, $ip, 'nfs', '4'];
    } else {
        $cmd = ['/sbin/showmount', '--no-headers', '--exports', $server];
    }

    eval {
        run_command($cmd,
          timeout => 10, outfunc => sub { }, errfunc => sub { });
    };
    if (my $err = $@) {
        if ($is_v4) {
            my $port = 2049;
            $port = $1 if defined($opts) && $opts =~ /port=(\d+)/;

            return 0 if $port == 0;

            return PVE::Network::tcp_ping($server, $port, 2);
        }
        return 0;
    }

    return 1;
}


# Volume snapshot operations (ZFS snapshots via JovianDSS REST API)

sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $pool = OpenEJovianDSS::NFSCommon::pool_name_get( $scfg );
    my $datname = OpenEJovianDSS::NFSCommon::dataset_name_get( $scfg );

    OpenEJovianDSS::Common::debugmsg( $scfg, 'debug',
        "Creating snapshot ${snap} for dataset ${datname}\n" );

    # Use JovianDSS REST API to create ZFS snapshot on NAS volume (dataset)
    # REST API path: /pools/{pool}/nas-volumes/{dataset}/snapshots
    # Use -d flag because dataset name from export property is the exact dataset name on JovianDSS
    OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
        [ "pool", $pool, "nas_volume", "-d", $datname, "snapshots", "create", '--ignoreexists', '--proxmox-volume', ${volname}, "${snap}" ] );
}

sub volume_snapshot_info {
    my ( $class, $scfg, $storeid, $volname ) = @_;

    my $datname = OpenEJovianDSS::NFSCommon::dataset_name_get( $scfg );

    return OpenEJovianDSS::NFSCommon::snapshot_info(
        $scfg, $storeid, $datname, $volname );
}

sub volume_snapshot_needs_fsfreeze {
    return 0;
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snapname ) = @_;

    my $pool = OpenEJovianDSS::NFSCommon::pool_name_get( $scfg );
    my $datname = OpenEJovianDSS::NFSCommon::dataset_name_get( $scfg );
    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Rolling back volume ${name} volname ${volname} to snapshot ${snapname}\n" );

    my $sharepath = OpenEJovianDSS::NFSCommon::snapshot_publish($scfg, $storeid,
            $datname, $volname, $snapname );
    my $published = 1;

    # Activate snapshot and mount it
    my $snapmntpath;
    eval {
        $snapmntpath = OpenEJovianDSS::NFSCommon::snapshot_activate($scfg, $storeid,
            $pool, $datname, $vmid, $volname, $snapname, $sharepath );
    };
    my $err = $@;
    if ( $err ) {
        eval{
           OpenEJovianDSS::NFSCommon::snapshot_unpublish( $scfg, $storeid,
               $datname, $volname, $snapname );
        };
        my $errup = $@;
        if ($@) {
            die "Fail to unpublish: ${errup} after failed activation ${err}\n";
        } else {
            die "Failed to activate: $err\n";
        }
    }

    # Here we have share active and mounted

    my $vol_path = $class->path($scfg, $volname, $storeid, undef);
    my $snap_path = $class->path($scfg, $volname, $storeid, $snapname);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Snapshot ${snapname} activated at ${snap_path}\n" );

    eval {
        # Step 2: Physically copy VM/container file from activated snapshot

        unless ( -e $snap_path ) {
            die "Unable to identify volume ${volname} data within "
                . "snapshot ${snapname}\n";
        }

        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Copying ${snap_path} to ${vol_path}\n" );

        # Use cp command to copy file, preserving attributes
        PVE::Tools::run_command( [ 'cp', '--sparse=always', '-a', $snap_path, $vol_path ],
            errmsg => "rollback copy failed" );

        OpenEJovianDSS::NFSCommon::debugmsg( $scfg, "debug",
            "File copy completed successfully\n" );
    };
    my $copy_err = $@;

    eval {
        OpenEJovianDSS::NFSCommon::snapshot_deactivate( $scfg, $storeid,
                $datname, $vmid, $volname, $snapname );
    };
    my $deactivate_err = $@;

    if ($deactivate_err) {
        if ($copy_err) {
            die "Failed to umount volume ${volname} snapshot ${snapname} from ${snapmntpath} err: ${deactivate_err}"
                . "After failed volume rollback: ${copy_err}."
                . "Please conduct manual unmounting of folder ${snapmntpath}"
                . "Please conduct manual share ${sharepath} removal on the side JovianDSS storage.";
        } else {
            die "Failed to umount volume ${volname} snapshot ${snapname} from ${snapmntpath}"
                . "Please conduct manual unmounting of folder ${snapmntpath}."
                . "Please conduct manual share ${sharepath} removal on the side JovianDSS storage.";
        }
    }
    eval{
       OpenEJovianDSS::NFSCommon::snapshot_unpublish( $scfg, $storeid,
           $datname, $volname, $snapname );
    };
    my $errup = $@;
    if ($errup) {
        if ($copy_err) {
            die "Failed to remove share ${sharepath} representing volume ${volname} snapshot ${snapname}: ${errup}, "
                . "after failed restore operation: ${copy_err}. "
                . "Please conduct manual share ${sharepath} removal on the side JovianDSS storage.\n";
        } else {
            die "Failed to remove share ${sharepath} representing volume ${volname} snapshot ${snapname}: ${errup}. "
                . "Please conduct manual share ${sharepath} removal on the side JovianDSS storage.\n";
        }
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Rollback of volume ${volname} to snapshot ${snapname} done\n" );
}

sub volume_rollback_is_possible {
    my ( $class, $scfg, $storeid, $volname, $snap, $blockers ) = @_;

    my $pool = OpenEJovianDSS::NFSCommon::pool_name_get( $scfg );
    my $datname = OpenEJovianDSS::NFSCommon::dataset_name_get( $scfg );

    # Check if snapshot exists via REST API
    # TODO: have to be rewrittent to better handle many snapshots
    eval {
        my $snapshots = OpenEJovianDSS::NFSCommon::snapshot_info(
            $scfg, $storeid, $datname );

        unless ( exists $snapshots->{$snap} ) {
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                "Snapshot ${snap} not found for dataset ${datname}\n" );
            return 0;
        }
    };
    if ( $@ ) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Failed to check snapshot existence: $@\n" );
        return 0;
    }

    # For NFS file-based storage, rollback is a copy operation
    # We use clone-based approach, so no blockers for child snapshots
    # The parent class handles basic blocker checks (e.g., running VM)

    # TODO: consider checking free space
    return 1;
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Activate volume ${volname}"
        . ( $snapname ? " snapshot ${snapname}" : "" ) . "\n" );

    my $path = $scfg->{path};
    my $server = $scfg->{server};
    my $export = $scfg->{export};

    my $pool = OpenEJovianDSS::NFSCommon::pool_name_get( $scfg );
    my $datname = OpenEJovianDSS::NFSCommon::dataset_name_get( $scfg );

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    unless ( OpenEJovianDSS::NFSCommon::path_is_nfs( $scfg, $path, $export, $server ) ) {
        die "Storage '${storeid}' is not mounted. "
            . "NFS share ${server}:${export} not mounted at ${path}\n";
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Volume ${volname} activated (storage is mounted)\n" );
    # There is no need to activate volume
    # Because of that we skip only volume deactivation
    if (! defined($snapname) ) {
        return 1;
    }
    if ($snapname eq '') {
        return 1;
    }

    my $sharepath = OpenEJovianDSS::NFSCommon::snapshot_publish( $scfg, $storeid,
                        $datname, $volname, $snapname );
    eval {
        OpenEJovianDSS::NFSCommon::snapshot_activate( $scfg, $storeid,
            $pool, $datname, $vmid, $volname, $snapname, $sharepath );
    };

    my $err = $@;

    if ( $err ) {
        warn "NAS volume activation failed: $err";
        eval {
            OpenEJovianDSS::NFSCommon::snapshot_unpublish( $scfg, $storeid,
                $datname, $volname, $snapname );
        };
        my $errdeactivate = $@;

        if ( $errdeactivate ) {
            die "Failed to attach ${volname} snapshot ${snapname} error: ${err}\n"
                . "Recovery failed: ${errdeactivate}\n"
                . "Remove share ${sharepath} manually\n";
        }
    }
    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache, $hints ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deactivate volume ${volname}"
        . ( $snapname ? " snapshot ${snapname}" : "" ) . "\n" );

    my $pool = OpenEJovianDSS::NFSCommon::pool_name_get( $scfg );
    my $datname = OpenEJovianDSS::NFSCommon::dataset_name_get( $scfg );
    my $path = $scfg->{path};
    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    if ( defined($snapname) && ($snapname ne '') ) {
        if ($snapname ne '') {
            OpenEJovianDSS::NFSCommon::snapshot_deactivate( $scfg, $storeid,
                $datname, $vmid, $volname, $snapname );
            OpenEJovianDSS::NFSCommon::snapshot_unpublish( $scfg, $storeid,
                $datname, $volname, $snapname );
            return 1;
        }
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Proceed to volume ${volname} deactivation as snapname is empty");
    }

    OpenEJovianDSS::NFSCommon::all_snapshots_deactivate_unpublish(
        $scfg, $storeid, $datname, $vmid, $volname );

    return 1;
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snapname, $running ) = @_;

    my $pool = OpenEJovianDSS::NFSCommon::pool_name_get( $scfg );
    my $datname = OpenEJovianDSS::NFSCommon::dataset_name_get( $scfg );
    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    OpenEJovianDSS::Common::debugmsg( $scfg, 'debug',
        "Deleting snapshot ${snapname} of volume ${volname} from dataset ${datname}\n" );

    eval {
        OpenEJovianDSS::NFSCommon::snapshot_deactivate(
            $scfg, $storeid, $datname, $vmid, $volname, $snapname );
    };
    eval {
        OpenEJovianDSS::NFSCommon::snapshot_unpublish(
            $scfg, $storeid, $datname, $volname, $snapname );
    };

    # REST API path: /pools/{pool}/nas-volumes/{dataset}/snapshots/{snapshot}
    OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
        [ "pool", $pool, "nas_volume", "-d", $datname,
          "snapshot", $snapname, "delete", '--proxmox-volume', $volname ] );

    OpenEJovianDSS::Common::debugmsg( $scfg, 'debug',
        "Deleting snapshot ${snapname} of volume ${volname} from dataset $$datname} done.\n" );
}

# TODO: delete this code
#
#sub volume_snapshot_list {
#    my ( $class, $scfg, $storeid, $volname ) = @_;
#
#    my $pool = $class->get_pool_name( $scfg );
#    my $dataset = $class->get_dataset_name( $scfg );
#
#    # REST API path: /pools/{pool}/nas-volumes/{dataset}/snapshots
#    my $jdssc = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
#        [ "pool", $pool, "nas_volume", "-d", $dataset, "snapshots", "list" ] );
#
#    #TODO: should provide list of proxmox volume snapshots
#    #not all snapshots at once
#
#    my $res = [];
#    foreach ( split( /\n/, $jdssc ) ) {
#        my ( $sname ) = split;
#        push @$res, { 'name' => "$sname" };
#    }
#
#    return $res;
#}

# Inherit remaining functionality from parent class

sub get_volume_attribute {
    return PVE::Storage::DirPlugin::get_volume_attribute(@_);
}

sub update_volume_attribute {
    return PVE::Storage::DirPlugin::update_volume_attribute(@_);
}

sub get_import_metadata {
    return PVE::Storage::DirPlugin::get_import_metadata(@_);
}

sub volume_qemu_snapshot_method {
    return PVE::Storage::DirPlugin::volume_qemu_snapshot_method(@_);
}

sub volume_has_feature {
    my ($class, $scfg, $feature, $storeid,
        $volname, $snapname, $running, $opts) = @_;

    my $features = {
        snapshot => {
            current => 1,
            snap    => 0,
        },
        clone => {
            current => 0,
            snap    => 0,
        },
        template => {
            current => 0,
        },
        copy => {
            current => 1,
            snap    => 1,
        },
    };

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $format) =
        $class->parse_volname($volname);

    my $key = undef;
    if ($snapname) {
        $key = 'snap';
    } else {
        $key = $isBase ? 'base' : 'current';
    }

    return 1 if defined($features->{$feature}->{$key});

    return undef;
}

# Hooks for password management

sub on_add_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    if (OpenEJovianDSS::Common::get_create_base_path($scfg)) {
        my $path = OpenEJovianDSS::Common::get_path($scfg);
        if (! -d $path) {
            File::Path::make_path($path,
              { owner => 'root', group => 'root' });
            chmod 0755, $path;
        }
    }
    if (exists($sensitive{user_password})) {
        OpenEJovianDSS::Common::password_file_set_password(
            $sensitive{user_password}, $storeid);
    }
}

sub on_update_hook {
    my ($class, $storeid, $scfg, %sensitive) = @_;

    if (exists($sensitive{user_password})) {
        if (defined($sensitive{user_password})) {
            OpenEJovianDSS::Common::password_file_set_password(
                $sensitive{user_password}, $storeid);
        } else {
            OpenEJovianDSS::Common::password_file_delete($storeid);
        }
    }
    return undef;
}

sub on_update_hook_full {
    my ($class, $storeid, $scfg, $update, $delete, $sensitive) = @_;

    return $class->on_update_hook($storeid, $update, $sensitive->%*);
}

1;
