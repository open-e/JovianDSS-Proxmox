#    Copyright (c) 2024 Open-E, Inc.
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

package OpenEJovianDSS::NFSCommon;

use strict;


use warnings;
use Exporter 'import';
use Carp qw( confess longmess );
use Cwd qw( );
use Data::Dumper;
use File::Basename;
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use String::Util;

use Fcntl qw(:DEFAULT O_WRONLY O_APPEND O_CREAT O_SYNC);
use IO::Handle;

use JSON qw(decode_json from_json to_json);
#use PVE::SafeSyslog;

use Time::HiRes qw(gettimeofday);

use PVE::INotify;
use PVE::Tools qw(run_command);

our @EXPORT_OK = qw(

  nas_volume_snapshots_info

  nas_volume_snapshot_activate
  nas_volume_snapshot_deactivate

);

sub nas_volume_snapshot_mount_in_path {
    my ( $volname, $snapname ) = @_;

    my $vtype_subdirs = get_vtype_subdirs();

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);
    die "storage definition has no path\n" if !$path;
    die "unknown vtype '$vtype'\n" if !exists($vtype_subdirs->{$vtype});

    my $subdir = $scfg->{"content-dirs"}->{$vtype} // $vtype_subdirs->{$vtype};

    $mount_in_path = "private/mounts/${vmid}/${volname}/${snapname}/${subdir}/${name}";

    return $mount_in_path;
}

sub nas_volume_snapshots_info {
    my ( $scfg, $storeid, $dataset, $volname ) = @_;

    my $pool = get_pool($scfg);

    # Use -d flag because dataset name from export property is the exact dataset name on JovianDSS
    my $output = joviandss_cmd(
        $scfg,
        $storeid,
        [
            'pool', $pool, 'nas_volume', '-d', $dataset,
            'snapshots', 'list'
        ]
    );

    my $snapshots = {};
    my @lines = split( /\n/, $output );
    for my $line (@lines) {
        $line =~ s/^\s+|\s+$//g;
        next unless length($line) > 0;
        debugmsg( $scfg, "debug",
            "NAS volume ${dataset} has snapshot ${line}\n" );
        $snapshots->{$line} = {
            name => $line,
        };
    }

    return $snapshots;
}

# NAS volume activation for NFS snapshot rollback
# Creates clone, temporary share, and mounts it for file copying
sub nas_volume_snapshot_activate {
    my ( $scfg, $storeid, $pool, $dataset, $volname, $snapname ) = @_;

    # TODO: Make sure that clone is mounted as READONLY
    my $published = 0;
    my $share_mounted = 0;

    my $clone_name;
    my $mount_path;
    my $server = $scfg->{server};

    debugmsg( $scfg, "debug",
        "Activating dataset ${dataset} volume ${volname} snapshot ${snapname}\n" );

    eval {
        # Step 1: Publish snapshot (creates clone with proper naming and NFS share)
        debugmsg( $scfg, "debug",
            "Publishing snapshot ${snapname} for proxmox volume ${volname} from dataset ${dataset}\n" );

        my $cmd_output = joviandss_cmd( $scfg, $storeid,
            [ "pool", $pool,
              "nas_volume", "-d", $dataset,
              "snapshot", '--proxmox-volume', ${volname} , $snapname,
              "publish" ] );

        # Parse clone name from output (last non-empty line)
        my @lines = split( /\n/, $cmd_output );
        for my $line ( reverse @lines ) {
            $line =~ s/^\s+|\s+$//g;  # trim whitespace
            if ( length( $line ) > 0 ) {
                $clone_name = $line;
                last;
            }
        }

        unless ( $clone_name ) {
            die "Failed to get clone name from publish command output\n";
        }

        debugmsg( $scfg, "debug",
            "Snapshot published as clone ${clone_name}\n" );

        $published = 1;

        # Step 2: Mount the snapshot clone to storage private area
        # Mount point: {storage_path}/private/snapshots/{clone_name}
        my $path = get_path( $scfg );
        my $snapshots_dir = "${path}/private/snapshots";

        # Create snapshots directory if it doesn't exist
        make_path( $snapshots_dir )
            unless -d $snapshots_dir;

        $mount_path = "${snapshots_dir}/${clone_name}";

        debugmsg( $scfg, "debug",
            "Creating mount point ${mount_path}\n" );

        # Create mount directory
        make_path( $mount_path );

        # Mount the NFS share
        # Format: server:/Pools/Pool-0/clone_name
        my $nfs_export = "/Pools/${pool}/${clone_name}";

        debugmsg( $scfg, "debug",
            "Mounting ${server}:${nfs_export} to ${mount_path}\n" );

        my $mount_cmd = [ '/bin/mount', '-o', 'ro', '-t', 'nfs',
                         "${server}:${nfs_export}", $mount_path ];

        PVE::Tools::run_command( $mount_cmd,
            errmsg => "Failed to mount NFS share for snapshot clone" );

        $share_mounted = 1;

    };
    my $err = $@;

    if ( $err ) {
        warn "NAS volume activation failed: $err";

        # Cleanup in reverse order
        if ( $share_mounted ) {
            eval {
                debugmsg( $scfg, "debug",
                    "Unmounting ${mount_path}\n" );
                PVE::Tools::run_command( [ '/bin/umount', $mount_path ],
                    errmsg => "Failed to unmount share" );
            };
            warn "Unmount failed during cleanup: $@" if $@;

            # Remove mount directory (should be empty after unmount)
            eval {
                rmdir( $mount_path ) if -d $mount_path;
            };
        }

        if ( $published ) {
            eval {
                debugmsg( $scfg, "debug",
                    "Unpublishing snapshot\n" );
                joviandss_cmd( $scfg, $storeid,
                    [ "pool", $pool,
                      "nas_volume", "-d", $dataset,
                      "snapshot", $snapname,
                      "unpublish" ] );
            };
            warn "Unpublish failed during cleanup: $@" if $@;
        }

        die $err;
    }

    unless ( defined( $mount_path ) && -d $mount_path ) {
        die "Unable to provide mount path for NAS volume "
            . "${pool}/${dataset} snapshot ${snapname} after activation\n";
    }

    debugmsg( $scfg, "debug",
        "NAS volume snapshot activated at ${mount_path}\n" );

    return {
        mount_path  => $mount_path,
        clone_name  => $clone_name,
    };
}

# NAS volume deactivation for NFS snapshot rollback cleanup
# Unmounts share and unpublishes snapshot (deletes share and clone)
sub nas_volume_deactivate {
    my ( $scfg, $storeid, $pool, $dataset, $volname, $snapname ) = @_;

    debugmsg( $scfg, "debug",
        "Deactivating NAS dataset ${dataset} volume ${volname} snapshot ${snapname}\n" );

    my $clone_name;

    my $cleanup_errors = 0;

    # Step 1: Get the publish clone name to construct mount path
    # TODO: so the goal here is to go with share path
    # acquire share path and if it is a snapshot unmount it
    # if it is a snapsho remove dedicated share
    my $share_path;
    eval {
        my $cmd_output = joviandss_cmd( $scfg, $storeid,
            [ "pool", $pool,
              "nas_volume", "-d", $dataset,
              "snapshot", '--proxmox-volume', $volname, $snapname,
              "get", "--publish-name" ] );

        # Parse clone name from output (last non-empty line)
        my @lines = split( /\n/, $cmd_output );
        for my $line ( reverse @lines ) {
            $line =~ s/^\s+|\s+$//g;  # trim whitespace
            if ( length( $line ) > 0 ) {
                $clone_name = $line;
                last;
            }
        }
    };
    if ( $@ ) {
        warn "Failed to get clone name: $@";
        $cleanup_errors++;
    }

    # Step 2: Unmount the snapshot clone
    my $mount_path;
    if ( $clone_name ) {
        my $path = get_path( $scfg );
        $mount_path = "${path}/private/snapshots/${clone_name}";
    }
    if ( defined( $mount_path ) && -d $mount_path ) {
        eval {
            debugmsg( $scfg, "debug",
                "Unmounting ${mount_path}\n" );

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
                PVE::Tools::run_command( [ '/bin/umount', $mount_path ],
                    errmsg => "Failed to unmount ${mount_path}" );
            }

            # Remove mount directory (should be empty after unmount)
            rmdir( $mount_path ) if -d $mount_path;
        };
        if ( $@ ) {
            warn "Failed to unmount: $@";
            $cleanup_errors++;
        }
    }

    # Step 3: Unpublish snapshot (deletes NFS share and clone)
    eval {
        debugmsg( $scfg, "debug",
            "Unpublishing snapshot ${snapname}\n" );
        joviandss_cmd( $scfg, $storeid,
            [ "pool", $pool,
              "nas_volume", "-d", $dataset,
              "snapshot", $snapname,
              "unpublish" ] );
    };
    if ( $@ ) {
        warn "Failed to unpublish snapshot: $@";
        $cleanup_errors++;
    }

    if ( $cleanup_errors > 0 ) {
        warn "NAS volume deactivation completed with ${cleanup_errors} errors\n";
    } else {
        debugmsg( $scfg, "debug",
            "NAS volume snapshot deactivated successfully\n" );
    }

    return 1;
}


1;
