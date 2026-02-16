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

    dataset_name_get
    pool_name_get

    snapshot_info

    volume_snapshot_mount_private_path
    path_is_nfs

    snapshot_activate
    snapshot_deactivate

);

our %EXPORT_TAGS = ( all => [@EXPORT_OK], );

sub volume_snapshot_mount_private_path {
    my ( $scfg, $vtype, $name, $vmid, $volname, $snapname ) = @_;

    my $vtype_subdirs = get_vtype_subdirs();

    die "unknown vtype '$vtype'\n" if !exists($vtype_subdirs->{$vtype});

    my $subdir = $scfg->{"content-dirs"}->{$vtype} // $vtype_subdirs->{$vtype};

    my $pmvs = nas_private_mounts_volname_snapname($vmid, $volname, $snapname);

    my $path = "${pmvs}/${subdir}/${name}";

    return $path;
}

sub nas_private_mounts_volname {
    my ($vmid, $volname ) = @_;

    my $pmv = "private/mounts/${vmid}/${volname}";

    return $pmv;
}

sub nas_private_mounts_volname_snapname {
    my ($vmid, $volname, $snapname ) = @_;

    my $pmv = nas_private_mounts_volname($vmid, $volname );

    my $pmvs = "${pmv}/${snapname}";

    return $pmvs;
}

sub snapshot_info {
    my ( $scfg, $storeid, $dataset, $volname ) = @_;

    my $pool = pool_name_get( $scfg );

    # Use -d flag because dataset name from export property is the exact dataset name on JovianDSS
    # TODO: consider improving this function as with huge number of snapshots
    # philtering should be done inside jdssc tool
    my $output = OpenEJovianDSS::Common::joviandss_cmd(
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
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "NAS volume ${dataset} has snapshot ${line}\n" );
        $snapshots->{$line} = {
            name => $line,
        };
    }

    return $snapshots;
}

# NAS volume activation for NFS snapshot rollback
# Creates clone, temporary share, and mounts it for file copying
sub snapshot_activate {
    my ( $scfg, $storeid, $pool, $dataset, $vmid, $volname, $snapname, $sharepath ) = @_;

    # TODO: Make sure that clone is mounted as READONLY
    my $published = 0;
    my $share_mounted = 0;

    my $clone_name;
    my $mount_path;
    my $server = $scfg->{server};

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Activating dataset ${dataset} volume ${volname} snapshot ${snapname}\n" );

    my $snapmntpath;

    my $path = get_path( $scfg );
    my $pmvs = nas_private_mounts_volname_snapname($vmid, $volname, $snapname);

    $snapmntpath = "${path}/${pmvs}";

    # Create snapshots directory if it doesn't exist

    if (-d $snapmntpath) {
        if ( path_is_mnt( $scfg, $snapmntpath ) ){
            if ( path_is_nfs( $scfg,  $snapmntpath, $sharepath, $server ) ) {
                return $snapmntpath;
            } else {
                umount( $scfg, $storeid, $snapmntpath );
            }
        }
    } else {
        make_path( $snapmntpath );
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Mounting ${server}:${sharepath} to ${snapmntpath}\n" );

    my $nfs_mount_cmd = [ '/bin/mount', '-t', 'nfs'];

    my $optionscfg = OpenEJovianDSS::Common::get_options($scfg);
    my $optstr = 'ro';
    $optstr .= ",$optionscfg" if defined($optionscfg) && $optionscfg ne '';
    push @$nfs_mount_cmd, '-o', $optstr;
    push @$nfs_mount_cmd, "${server}:${sharepath}", $snapmntpath;

    run_command( $nfs_mount_cmd,
                outfunc => sub {},
                errfunc => sub { cmd_log_output($scfg, 'error', $nfs_mount_cmd, shift); }
            );
    return $snapmntpath;
}

# NAS volume deactivation for NFS snapshot rollback cleanup
# Unmounts share and unpublishes snapshot (deletes share and clone)
sub snapshot_deactivate {
    my ( $scfg, $storeid, $dataset, $vmid, $volname, $snapname ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deactivating NAS dataset ${dataset} volume ${volname} snapshot ${snapname}\n" );

    my $snapshot_dir = File::Spec->catdir(
            get_path($scfg),
            nas_private_mounts_volname_snapname($vmid, $volname, $snapname)
        );

    umount ( $scfg, $storeid, $snapshot_dir );

    return 1;
}

# NAS volume deactivation for NFS snapshot rollback cleanup
# Unmounts share and unpublishes snapshot (deletes share and clone)
sub all_snapshots_deactivate_unpublish {
    my ( $scfg, $storeid, $datname, $vmid, $volname ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deactivating all snapshots for NAS dataset ${datname} volume ${volname}\n" );

    my $pmv = nas_private_mounts_volname($vmid, $volname);

    my $volume_dir = get_path($scfg) . "/$pmv";

    my %datasets_to_unpublish;

    my @entries;
    if ( -d $volume_dir && opendir(my $dh, $volume_dir) ) {
        @entries = readdir($dh);
        closedir($dh);
    }
    for my $entry (@entries) {
        next if $entry eq '.' || $entry eq '..';

        my $snapname = $entry;
        my $snapshot_dir = File::Spec->catdir($volume_dir, $snapname);

        next if !-d $snapshot_dir;

        umount ( $scfg, $storeid, $snapshot_dir );

        snapshot_unpublish( $scfg, $storeid, $datname, $volname, $snapname );

    };

    return 1;
}


sub path_is_mnt {
    my ( $scfg,  $mntpath) = @_;

    my $dir_is_mounted = [ '/usr/bin/findmnt', '-M', $mntpath ];
    my $json_out = '';
    my $rc = run_command(
        $dir_is_mounted,
        outfunc => sub { $json_out .= "$_[0]\n"; },
        errfunc => sub {
            cmd_log_output($scfg, 'error', $dir_is_mounted, shift);
        },
        noerr   => 1,
    );

    if ( $rc == 0 ) {
        return 1;
    }
    return 0;
}

sub address_normalize {
      my ($addr) = @_;
      return undef if !defined $addr;

      # If host is bracketed IPv6, remove [ and ].
      if ($addr =~ /^\[(.+)\]$/) {
          return $1;
      }

      return $addr;
};

sub path_is_nfs {
    my ( $scfg,  $snapmntpath, $sharepath, $shareip ) = @_;
    # sharepath and shareip are optional
    # they will be checked if they are not undef
    # sharepath is a path of form <pool name>/<share name>

    # TODO: consider extending this function with check for IP
    # and share name
    my $json_out = '';

    my $cmd = [ '/usr/bin/findmnt', '-J', '-M', $snapmntpath, '-o', 'TARGET,SOURCE,FSTYPE' ];

    my $rc = run_command(
        $cmd,
        outfunc => sub { $json_out .= "$_[0]\n"; },
        errfunc => sub {
            cmd_log_output($scfg, 'error', $cmd, shift);
        },
        noerr   => 1,
    );

    if ( $rc != 0 || $json_out eq '') {
        return 0;
    }

    my $j = eval { decode_json($json_out) };

    return 0 if ( $@ || ref($j) ne 'HASH' || ref($j->{filesystems}) ne 'ARRAY' );
    return 0 if ( !@{ $j->{filesystems} } );
    my $fs = $j->{filesystems}[0];
    return 0 if ( !defined($fs->{fstype}) || $fs->{fstype} !~ /^nfs/ );

    if ( defined( $sharepath ) || defined( $shareip ) ) {
        my ($mntip, $mntpath);

        if ($fs->{source} =~ /^\[([^\]]+)\]:(\/.*)$/) {
            # Bracketed IPv6: [2001:db8::1]:/export
            ($mntip, $mntpath) = ($1, $2);
        } elsif ($fs->{source} =~ /^(.+):(\/.*)$/) {
            # Hostname, IPv4, or unbracketed IPv6 ending before :/path
            ($mntip, $mntpath) = ($1, $2);
        } else {
            return 0;
        }

        if (defined( $shareip)) {
            my $actual_ip   = address_normalize($mntip);
            my $expected_ip = address_normalize($shareip);

            return 0 if !defined $actual_ip;
            return 0 if !defined $expected_ip;
            return 0 if $actual_ip ne $expected_ip;
        }

        if (defined($sharepath) ) {
            return 0 if($sharepath ne $mntpath);
        }
    }
    return 1;
}

sub mount {
    my ( $scfg, $storeid, $data_address, $sharepath, $sharemntpath, $options) = @_;

    $data_address = "[$data_address]" if Net::IP::ip_is_ipv6($data_address);
    my $source = "$data_address:$sharepath";

    my $cmd = ['/bin/mount', '-t', 'nfs', $source, $sharemntpath];
    if ($options) {
        push @$cmd, '-o', $options;
    }

    run_command($cmd, errmsg => "mount error");
}

sub umount {
    my ( $scfg, $storeid, $snapshot_dir ) = @_;

    my $snapshot_dir_is_mounted = [ '/usr/bin/findmnt', '-M', $snapshot_dir ];

    my $rc = run_command(
        $snapshot_dir_is_mounted,
        outfunc => sub {},
        errfunc => sub {
            cmd_log_output($scfg, 'error', $snapshot_dir_is_mounted, shift);
        },
        noerr   => 1,
    );

    if ($rc != 0) {
        warn "No share mounted to ${snapshot_dir}\n";
        OpenEJovianDSS::Common::debugmsg( $scfg, "warn", "No share mounted to ${snapshot_dir}" );
        rmdir($snapshot_dir);
        return ;
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Unmounting ${snapshot_dir}\n" );

    for (my $i = 0; $i < 3; $i++) {
        my $cmd = [ '/bin/umount', $snapshot_dir ];
        my $exitcode = run_command(
            $cmd,
            outfunc => sub {},
            errfunc => sub {
                cmd_log_output($scfg, 'error', $cmd, shift);
            },
            noerr   => 1
        );
        if ( $exitcode == 0 ) {
            rmdir($snapshot_dir);
            return ;
        }
    }
    my $cmd = [ '/bin/umount', $snapshot_dir ];

    my $exitcode = run_command(
        $cmd,
        outfunc => sub {},
        errfunc => sub {
            cmd_log_output($scfg, 'error', $cmd, shift);
        },
        noerr   => 1
    );

    $rc = run_command(
        $snapshot_dir_is_mounted,
        outfunc => sub {},
        errfunc => sub {
            cmd_log_output($scfg, 'error', $snapshot_dir_is_mounted, shift);
        },
        noerr   => 1,
    );

    if ($rc != 0) {
        rmdir($snapshot_dir);
        return ;
    }

    die "Unable to unmount ${snapshot_dir}\n";
}

sub snapshot_publish {
    my ( $scfg, $storeid, $datname, $volname, $snapname ) = @_;

    my $pool = pool_name_get( $scfg );
    # Step 1: Publish snapshot (creates clone with proper naming and NFS share)
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Publishing snapshot ${snapname} for proxmox volume ${volname} from dataset ${datname}\n" );

    my $cmd_output = OpenEJovianDSS::Common::joviandss_cmd( $scfg, $storeid,
        [ "pool", $pool,
          "nas_volume", "-d", $datname,
          "snapshot", '--proxmox-volume', ${volname} , $snapname,
          "publish" ] );

   my $sharepath;
    # Parse clone name from output (last non-empty line)
    my @lines = split( /\n/, $cmd_output );
    for my $line ( reverse @lines ) {
        $line =~ s/^\s+|\s+$//g;  # trim whitespace
        if ( length( $line ) > 0 ) {
            $sharepath = OpenEJovianDSS::Common::clean_word( $line );
            last;
        }
    }

    if ( $sharepath =~ /^([\:\-\@\w.\/]+)$/ ) {
        return $sharepath;
    }
    die "Share name representing "
        . "dataset ${datname} "
        . "volume ${volname} "
        . "snapshot ${snapname} "
        . "contains forbidden symbols: ${sharepath}\n";
};


sub snapshot_unpublish {
    my ( $scfg, $storeid, $datname, $volname, $snapname ) = @_;

    my $pool = pool_name_get( $scfg );

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Unpublishing snapshot ${snapname} for dataset ${datname} of volume ${volname}\n" );
    OpenEJovianDSS::Common::joviandss_cmd(
        $scfg, $storeid,
        [ 'pool', $pool,
          'nas_volume', '-d', $datname,
          'snapshot', '--proxmox-volume', $volname, $snapname,
          'unpublish' ]
    );
    return 1;
};


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

sub pool_name_get {
    my ( $scfg ) = @_;
    my ( $pool_name, $dataset_name ) = parse_export_path( $scfg->{export} );
    return $pool_name;
}

sub dataset_name_get {
    my ( $scfg ) = @_;
    my ( $pool_name, $dataset_name ) = parse_export_path( $scfg->{export} );
    return $dataset_name;
}

1;
