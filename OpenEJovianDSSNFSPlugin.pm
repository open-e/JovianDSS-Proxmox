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
use base qw(PVE::Storage::Plugin);

my $PLUGIN_VERSION = '0.1.0';

#    Open-E JovianDSS NFS Proxmox plugin
#
#    0.1.0 - 2025.01.09
#               Initial prototype implementation
#               NFS-based storage with JovianDSS ZFS snapshot support
#

# NFS helper functions

sub nfs_is_mounted {
    my ($server, $export, $mountpoint, $mountdata) = @_;

    $server = "[$server]" if Net::IP::ip_is_ipv6($server);
    my $source = "$server:$export";

    $mountdata = PVE::ProcFSTools::parse_proc_mounts() if !$mountdata;
    return $mountpoint if grep {
        $_->[2] =~ /^nfs/
            && $_->[0] =~ m|^\Q$source\E/?$|
            && $_->[1] eq $mountpoint
    } @$mountdata;
    return undef;
}

sub nfs_mount {
    my ($server, $export, $mountpoint, $options) = @_;

    $server = "[$server]" if Net::IP::ip_is_ipv6($server);
    my $source = "$server:$export";

    my $cmd = ['/bin/mount', '-t', 'nfs', $source, $mountpoint];
    if ($options) {
        push @$cmd, '-o', $options;
    }

    run_command($cmd, errmsg => "mount error");
}

# Helper function to parse export path
# Export format: /Pools/Pool-2/test1 or /Pools/Pool-0/Dataset-0/Subdataset
# Returns: (pool_name, dataset_name)
# Example: "/Pools/Pool-2/test1" -> ("Pool-2", "test1")
# Example: "/Pools/Pool-0/Dataset-0/Sub" -> ("Pool-0", "Dataset-0/Sub")
sub parse_export_path {
    my ( $export ) = @_;

    # Export should start with /Pools/
    unless ( $export =~ m|^/Pools/([^/]+)/(.+)$| ) {
        die "Invalid export path format. Expected /Pools/<pool>/<dataset>, got: $export\n";
    }

    my $pool_name = $1;
    my $dataset_name = $2;  # Everything after pool name: test1 or Dataset-0/Sub

    return ( $pool_name, $dataset_name );
}

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

sub check_config {
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
      if !nfs_is_mounted($server, $export, $path, $cache->{mountdata});

    return $class->SUPER::status($storeid, $scfg, $cache);
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Activate NFS storage ${storeid}\n" );

    OpenEJovianDSS::Common::store_settup( $scfg, $storeid );

    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
        if !$cache->{mountdata};

    my $path = $scfg->{path};
    my $server = $scfg->{server};
    my $export = $scfg->{export};

    if ( !nfs_is_mounted( $server, $export, $path, $cache->{mountdata} ) ) {
        $class->config_aware_base_mkdir( $scfg, $path );

        die "unable to activate storage '$storeid' - "
          . "directory '$path' does not exist\n"
            if !-d $path;

        nfs_mount( $server, $export, $path, $scfg->{options} );
    }

    $class->SUPER::activate_storage( $storeid, $scfg, $cache );
}

sub deactivate_storage {
    my ($class, $storeid, $scfg, $cache) = @_;

    OpenEJovianDSS::Common::debugmsg($scfg, "debug",
        "Deactivate NFS storage ${storeid}\n");

    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
        if !$cache->{mountdata};

    my $path = $scfg->{path};
    my $server = $scfg->{server};
    my $export = $scfg->{export};

    if (nfs_is_mounted($server, $export, $path, $cache->{mountdata})) {
        my $cmd = ['/bin/umount', $path];
        run_command($cmd, errmsg => 'umount error');
    }
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

# JovianDSS-specific functions

sub get_pool_name {
    my ( $class, $scfg ) = @_;
    my ( $pool_name, $dataset_name ) = parse_export_path( $scfg->{export} );
    return $pool_name;
}

sub get_dataset_name {
    my ( $class, $scfg ) = @_;
    my ( $pool_name, $dataset_name ) = parse_export_path( $scfg->{export} );
    return $dataset_name;
}

# Volume snapshot operations (ZFS snapshots via JovianDSS REST API)

sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $pool = $class->get_pool_name( $scfg );
    my $dataset = $class->get_dataset_name( $scfg );

    OpenEJovianDSS::Common::debugmsg( $scfg, 'debug',
        "Creating snapshot ${snap} for dataset ${dataset}\n" );

    # Use JovianDSS REST API to create ZFS snapshot on NAS volume (dataset)
    # REST API path: /pools/{pool}/nas-volumes/{dataset}/snapshots
    OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
        [ "pool", $pool, "nas_volume", $dataset, "snapshots", "create", $snap ] );
}

sub volume_snapshot_info {
    my ( $class, $scfg, $storeid, $volname ) = @_;

    my $dataset = $class->get_dataset_name( $scfg );

    return OpenEJovianDSS::Common::volume_snapshots_info(
        $scfg, $storeid, $dataset );
}

sub volume_snapshot_needs_fsfreeze {
    return 0;
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $path = $scfg->{path};
    my $pool = $class->get_pool_name( $scfg );
    my $dataset = $class->get_dataset_name( $scfg );

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Rolling back volume ${volname} to snapshot ${snap}\n" );

    # Step 1: Activate snapshot (create clone, create temp share, mount it)
    my $activation_info = OpenEJovianDSS::Common::nas_volume_activate(
        $scfg, $storeid, $pool, $dataset, $snap );

    my $mount_path = $activation_info->{mount_path};

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Snapshot ${snap} activated at ${mount_path}\n" );

    eval {
        # Step 2: Physically copy VM/container file from activated snapshot
        my ( $vtype, $name, $vmid, $basename, $basevmid, $isBase, $format ) =
            $class->parse_volname( $volname );

        # Get the relative path for the volume within the storage
        my $rel_path = $class->filesystem_path( $scfg, $volname );
        $rel_path =~ s/^\Q$path\E\/?//;  # Remove base path

        my $source_file = "${mount_path}/${rel_path}";
        my $dest_file = "${path}/${rel_path}";

        unless ( -e $source_file ) {
            die "Source file ${source_file} does not exist in "
                . "snapshot ${snap}\n";
        }

        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Copying ${source_file} to ${dest_file}\n" );

        # Use cp command to copy file, preserving attributes
        PVE::Tools::run_command( [ 'cp', '-a', $source_file, $dest_file ],
            errmsg => "rollback copy failed" );

        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "File copy completed successfully\n" );
    };
    my $err = $@;

    # Step 3: Deactivate snapshot (unmount, delete share, delete clone)
    eval {
        OpenEJovianDSS::Common::nas_volume_deactivate(
            $scfg, $storeid, $pool, $dataset, $snap );
    };
    my $deactivate_err = $@;

    if ( $deactivate_err ) {
        warn "Snapshot deactivation failed: ${deactivate_err}";
    }

    if ( $err ) {
        die "Rollback failed: ${err}\n";
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Rollback of volume ${volname} to snapshot ${snap} completed\n" );
}

sub volume_rollback_is_possible {
    my ( $class, $scfg, $storeid, $volname, $snap, $blockers ) = @_;

    my $pool = $class->get_pool_name( $scfg );
    my $dataset = $class->get_dataset_name( $scfg );

    # Check if snapshot exists via REST API
    eval {
        my $snapshots = OpenEJovianDSS::Common::volume_snapshots_info(
            $scfg, $storeid, $dataset );

        my $snap_found = 0;
        foreach my $snapshot ( @$snapshots ) {
            if ( $snapshot->{name} eq $snap ) {
                $snap_found = 1;
                last;
            }
        }

        unless ( $snap_found ) {
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                "Snapshot ${snap} not found for dataset ${dataset}\n" );
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

    return 1;
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Activate volume ${volname}"
        . ( $snapname ? " snapshot ${snapname}" : "" ) . "\n" );

    # Check that main storage (NFS share) is mounted
    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
        if !$cache->{mountdata};

    my $path = $scfg->{path};
    my $server = $scfg->{server};
    my $export = $scfg->{export};

    unless ( nfs_is_mounted( $server, $export, $path, $cache->{mountdata} ) ) {
        die "Storage '${storeid}' is not mounted. "
            . "NFS share ${server}:${export} not mounted at ${path}\n";
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Volume ${volname} activated (storage is mounted)\n" );

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache, $hints ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deactivate volume ${volname}"
        . ( $snapname ? " snapshot ${snapname}" : "" ) . "\n" );

    my $pool = $class->get_pool_name( $scfg );
    my $dataset = $class->get_dataset_name( $scfg );
    my $path = $scfg->{path};

    # Get list of all snapshots that have published clones
    my $snapshots_with_clones;
    eval {
        my $snap_output = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
            [ "pool", $pool, "nas_volume", $dataset, "snapshots", "list", "--with-clones" ] );

        # Parse snapshot names from output
        $snapshots_with_clones = [];
        for my $line ( split( /\n/, $snap_output ) ) {
            $line =~ s/^\s+|\s+$//g;
            push @$snapshots_with_clones, $line if length( $line ) > 0;
        }
    };
    if ( $@ ) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Failed to get snapshots with clones: $@\n" );
        return 1;
    }

    my $deactivated_count = 0;

    # For each snapshot with clones, check if it's mounted and deactivate
    for my $snap ( @$snapshots_with_clones ) {
        eval {
            # Get the clone name for this snapshot
            my $clone_name_output = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
                [ "pool", $pool, "nas_volume", $dataset, "snapshot", $snap,
                  "get", "--publish-name" ] );

            my $clone_name;
            for my $line ( reverse split( /\n/, $clone_name_output ) ) {
                $line =~ s/^\s+|\s+$//g;
                if ( length( $line ) > 0 ) {
                    $clone_name = $line;
                    last;
                }
            }

            if ( $clone_name ) {
                # Check if this clone is mounted
                my $mount_path = "${path}/private/snapshots/${clone_name}";

                if ( -d $mount_path ) {
                    # Check if it's actually mounted
                    my $is_mounted = 0;
                    open( my $fh, '<', '/proc/mounts' )
                        or die "Cannot read /proc/mounts: $!\n";
                    while ( my $line = <$fh> ) {
                        if ( $line =~ /\s\Q$mount_path\E\s/ ) {
                            $is_mounted = 1;
                            last;
                        }
                    }
                    close( $fh );

                    if ( $is_mounted ) {
                        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                            "Deactivating mounted snapshot ${snap}\n" );

                        OpenEJovianDSS::Common::nas_volume_deactivate(
                            $scfg, $storeid, $pool, $dataset, $snap );

                        $deactivated_count++;
                    }
                }
            }
        };
        if ( $@ ) {
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                "Error processing snapshot ${snap}: $@\n" );
        }
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deactivated ${deactivated_count} mounted snapshot clones\n" );

    return 1;
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap, $running ) = @_;

    my $pool = $class->get_pool_name( $scfg );
    my $dataset = $class->get_dataset_name( $scfg );

    OpenEJovianDSS::Common::debugmsg( $scfg, 'debug',
        "Deleting snapshot ${snap} from dataset ${dataset}\n" );

    # REST API path: /pools/{pool}/nas-volumes/{dataset}/snapshots/{snapshot}
    OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
        [ "pool", $pool, "nas_volume", $dataset, "snapshot", $snap, "delete" ] );
}

sub volume_snapshot_list {
    my ( $class, $scfg, $storeid, $volname ) = @_;

    my $pool = $class->get_pool_name( $scfg );
    my $dataset = $class->get_dataset_name( $scfg );

    # REST API path: /pools/{pool}/nas-volumes/{dataset}/snapshots
    my $jdssc = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
        [ "pool", $pool, "nas_volume", $dataset, "snapshots", "list" ] );

    my $res = [];
    foreach ( split( /\n/, $jdssc ) ) {
        my ( $sname ) = split;
        push @$res, { 'name' => "$sname" };
    }

    return $res;
}

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
            snap    => 1,
        },
        clone => {
            base    => 1,
            current => 1,
            snap    => 1,
        },
        template => {
            current => 1,
        },
        copy => {
            base    => 1,
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
