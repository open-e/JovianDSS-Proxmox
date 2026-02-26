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
use File::Basename;
use File::Path qw(make_path);
use File::Spec;

use Net::IP;

use JSON qw(decode_json);
#use PVE::SafeSyslog;

use PVE::Tools qw(run_command file_get_contents file_set_contents);

use OpenEJovianDSS::Common qw(cmd_log_output) ;


our @EXPORT_OK = qw(

    dataset_name_get
    pool_name_get

    snapshot_info

    path_is_nfs

    snapshot_activate
    snapshot_deactivate
    snapshot_publish
    snapshot_unpublish
    snapshot_deactivate_unpublish
    all_snapshots_deactivate_unpublish

    mount
    umount
    path_is_mnt
    parse_export_path
    nas_private_mounts_volname_snapname

    get_password_file_name
    get_user_password
    password_file_set_password
    password_file_delete

    nas_sname
    nas_vmid_from_sname
    nas_snapid_from_sname
);

our %EXPORT_TAGS = ( all => [@EXPORT_OK], );


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

sub nas_sname {
    my ($snapname, $vmid) = @_;

    # Replace chars not allowed in JovianDSS names (only [-\w] are allowed)
    (my $safe_snap = $snapname) =~ s/[^-\w]/_/g;
    return "sv_${vmid}_${safe_snap}";
}

sub nas_vmid_from_sname {
    my ($sname) = @_;

    return undef unless $sname =~ /^sv_(\d+)_/;
    return $1;
}

sub nas_snapid_from_sname {
    my ($sname) = @_;

    return undef unless $sname =~ /^sv_\d+_(.+)$/s;
    return $1;
}

# Extract vmid from a Proxmox disk volume name (e.g. "vm-102-disk-0" -> "102")
sub _vmid_from_volname {
    my ($volname) = @_;

    return undef unless $volname =~ /^(?:vm|subvol|base)-(\d+)-/;
    return $1;
}

sub snapshot_info {
    my ( $scfg, $storeid, $dataset, $volname ) = @_;

    my $vmid = _vmid_from_volname($volname);
    my $pool = pool_name_get( $scfg );

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
        # Only include sv_<vmid>_<snapname> entries belonging to this volume
        if ( defined($vmid) ) {
            my $snap_vmid = nas_vmid_from_sname($line);
            next unless defined($snap_vmid) && $snap_vmid eq $vmid;
        }
        my $snap_name = nas_snapid_from_sname($line);
        next unless defined($snap_name);
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "NAS volume ${dataset} volume ${volname} has snapshot ${snap_name}\n" );
        $snapshots->{$snap_name} = {
            name => $snap_name,
        };
    }

    return $snapshots;
}

# NAS volume activation for NFS snapshot rollback
# Creates clone, temporary share, and mounts it for file copying
sub snapshot_activate {
    my ( $scfg, $storeid, $pool, $dataset, $vmid, $volname, $snapname, $sharepath ) = @_;

    # TODO: Make sure that clone is mounted as READONLY

    my $server = $scfg->{server};

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Activating dataset ${dataset} volume ${volname} snapshot ${snapname}\n" );

    my $path = OpenEJovianDSS::Common::get_path( $scfg );
    my $pmvs = nas_private_mounts_volname_snapname($vmid, $volname, $snapname);

    my $snapmntpath = OpenEJovianDSS::Common::safe_word("${path}/${pmvs}", 'snapshot mount path') ;

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

    if (defined($optionscfg) && $optionscfg ne '') {
        $optstr .= OpenEJovianDSS::Common::safe_word(",${optionscfg}", 'Options property');
    }

    push @$nfs_mount_cmd, '-o', $optstr;
    my $shareippath = OpenEJovianDSS::Common::safe_word("${server}:${sharepath}", "Share ip with NFS path" );
    push @$nfs_mount_cmd, $shareippath, $snapmntpath;

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
            OpenEJovianDSS::Common::get_path($scfg),
            nas_private_mounts_volname_snapname($vmid, $volname, $snapname)
        );
    return 1 if ( !-d $snapshot_dir);
    if ( path_is_mnt( $scfg, $snapshot_dir ) ){
        umount ( $scfg, $storeid, $snapshot_dir );
    }
    return 1;
}


sub path_is_empty {
    my ($scfg, $path) = @_;

    if ( ! -d $path) {
        if (-e $path) {
            die "Check failed, ${path} should be a directory or empty\n";
        }
        return 1;
    }
    opendir(my $dh, $path) or die "Cannot open directory '$path': $!";

    while (my $entry = readdir($dh)) {
        next if $entry eq '.' or $entry eq '..';
        closedir($dh);
        return 0;  # Not empty
    }

    closedir($dh);
    return 1;      # Empty
}

sub snapshot_deactivate_unpublish {
    my ( $scfg, $storeid, $datname, $vmid, $volname, $snapname ) = @_;

    my $dir = File::Spec->catdir(
            OpenEJovianDSS::Common::get_path($scfg),
            nas_private_mounts_volname_snapname($vmid, $volname, $snapname)
        );
    my $snapshot_dir = OpenEJovianDSS::Common::safe_word($dir, "Snapshot dir");
    my $no_error = 0;
    my $err;
    for my $attempt ( 1 .. 10) {
        eval {

            if ( -d $snapshot_dir) {
                OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                    "Deactivating volume ${volname} snapshot entry ${snapname} with path ${snapshot_dir}" );
                snapshot_deactivate( $scfg, $storeid, $datname, $vmid, $volname, $snapname );
            }
            snapshot_unpublish( $scfg, $storeid, $datname, $volname, $snapname );
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                    "Unpublishing ${volname} snapshot entry ${snapname} done" );

            if (! path_is_mnt($scfg, $snapshot_dir) && path_is_empty($scfg, $snapshot_dir)) {
                OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                    "Removing ${snapshot_dir}" );
                rmdir($snapshot_dir);
            }
        };
        $err = $@;
        if ($err) {
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                "Deactivating volume ${volname} snapshot entry ${snapname} with path ${snapshot_dir} failed attempt ${attempt}: ${err}\n" );
            sleep 1;
        } else {
            $no_error = 1;
            last;
        }
    }
    if ($no_error == 1) {
        return 1;
    }
    die "Failed to detach deactivate snapshot: ${err}\n";
}

# NAS volume deactivation for NFS snapshot rollback cleanup
# Unmounts share and unpublishes snapshot (deletes share and clone)
sub all_snapshots_deactivate_unpublish {
    my ( $scfg, $storeid, $datname, $vmid, $volname ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Deactivating all snapshots for NAS dataset ${datname} volume ${volname}\n" );

    my $pmv = nas_private_mounts_volname($vmid, $volname);

    my $volume_dir = OpenEJovianDSS::Common::get_path($scfg) . "/$pmv";

    if ( path_is_empty($scfg, $volume_dir ) ) {
        rmdir($volume_dir);
        return 1;
    }

    my @entries;
    if ( -d $volume_dir && opendir(my $dh, $volume_dir) ) {
        @entries = readdir($dh);
        closedir($dh);
    } else {
        die "Unable to open volume ${volname} snapshots dir ${volume_dir}\n";
    }
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Entries to deactivate: " . join(" ", @entries) );

    my $no_error = 1;
    my $last_error = undef;
    for my $entry (@entries) {
        next if $entry eq '.' || $entry eq '..';

        my $snapname = $entry;
        my $snapshot_dir = File::Spec->catdir($volume_dir, $snapname);

        $snapshot_dir = OpenEJovianDSS::Common::safe_word($snapshot_dir, "Snapshot directory");

        eval {
            snapshot_deactivate_unpublish( $scfg, $storeid, $datname, $vmid, $volname, $snapname );
        };
        if ($@) {
            $last_error = $@;
            $no_error = 0;
        }
    };

    if ( $no_error ) {
        if( path_is_empty($scfg, $volume_dir)) {
            rmdir($volume_dir);
        }
        return 1;
    }
    die "Failure during snapshot mountpoint detachment for ${volname} because of: ${last_error}\n";
}


sub path_is_mnt {
    my ( $scfg,  $path) = @_;

    my $path_safe = OpenEJovianDSS::Common::safe_word($path, 'Mounting path');

    return 0 if ( ! -d $path_safe );

    my $findmnt_cmd;
    my $rc = 1;

    $findmnt_cmd = [ '/usr/bin/findmnt', '-M', $path_safe ];
    eval {
        $rc = run_command(
            $findmnt_cmd,
            outfunc => sub { },
            errfunc => sub {
                cmd_log_output($scfg, 'error', $findmnt_cmd, shift);
            },
            noerr   => 1,
            timeout => 10,
        );
    };

    if ( $rc == 0 ) {
        return 1;
    }
    my $err;

    my $mountpoint_cmd = ['/usr/bin/mountpoint', $path_safe];

    return 0 if ( ! -d $path_safe );

    eval {
        $rc = run_command(
            $mountpoint_cmd,
            outfunc => sub {},
            errfunc => sub {
                cmd_log_output($scfg, 'error', $mountpoint_cmd, shift);
            },
            noerr   => 1,
            timeout => 10,
        );
    };
    $err = $@;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Path is mnt check cmd " . join(' ', @$mountpoint_cmd) . " code ${rc} err ${err}" );

    if ($rc == 0) {
        # is a mountpoint
        return 1;
    } elsif ($rc == 32){
        # is not a mountpoint
        return 0;
    }
    die "Failure during mount point check of ${path_safe}: ${err}\n";
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

    my $cmd = [ '/usr/bin/findmnt',
                '-J',
                '-M',
                OpenEJovianDSS::Common::safe_word($snapmntpath, 'snapshot mounting path'),
                '-o',
                'TARGET,SOURCE,FSTYPE'
            ];
    my $rc = run_command(
        $cmd,
        outfunc => sub { $json_out .= "$_[0]\n"; },
        errfunc => sub {
            cmd_log_output($scfg, 'error', $cmd, shift);
        },
        noerr   => 1,
        timeout => 10,
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
    my $source_dirty = "$data_address:$sharepath";

    my $source = OpenEJovianDSS::Common::safe_word($source_dirty, 'Source address') ;

    my $cmd = ['/bin/mount', '-t', 'nfs'];

    if ($options) {
        push @$cmd, '-o',OpenEJovianDSS::Common::safe_word($options, "mounting options");
    }
    push @$cmd, $source;
    push @$cmd, OpenEJovianDSS::Common::safe_word($sharemntpath, 'Share storage path');

    run_command($cmd, errmsg => "mount error");
}

sub umount {
    my ( $scfg, $storeid, $mntdirty ) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Umounting snapshotdir ${mntdirty}" );

    my $mntclean;
    if ( $mntdirty =~ /^([\:\-\@\w.\/]+)$/ ) {
        $mntclean = $1;
    } else {
        die "Forbidden symbols in snapshot dir path ${mntdirty}\n";
    }

    return if ( ! -d $mntclean );

    my $is_mnt = path_is_mnt( $scfg,  $mntclean);

    if ($is_mnt) {
        # is a mountpoint
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Unmounting ${mntclean}\n" );
    } else {
        # is not a mountpoint
        rmdir($mntclean);
        return;
    }

    for (my $i = 0; $i < 3; $i++) {
        my $cmd = [ '/bin/umount', $mntclean ];
        my $exitcode;
        eval {
            $exitcode = run_command(
                $cmd,
                outfunc => sub {
                    cmd_log_output($scfg, 'debug', $cmd, shift);
                },
                errfunc => sub {
                    cmd_log_output($scfg, 'error', $cmd, shift);
                },
                noerr   => 1,
                timeout => 30
            );
        };

        my $umount_err = $@;
        if ($umount_err) {
            OpenEJovianDSS::Common::debugmsg( $scfg, "error",
                "Unmounting has error: ${umount_err}\n" );
        }

        $is_mnt = path_is_mnt( $scfg,  $mntclean);

        if ($is_mnt) {
            # is a mountpoint
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                "Re-try umounting ${mntclean}\n" );
        } else {
            # is not a mountpoint
            rmdir($mntclean);
            return;
        }
    }
    my $cmd = [ '/bin/umount', '-l', $mntclean ];

    eval {
        my $exitcode = run_command(
            $cmd,
            outfunc => sub {},
            errfunc => sub {
                cmd_log_output($scfg, 'error', $cmd, shift);
            },
            noerr   => 1,
            timeout => 30
        );
    };

    my $umount_err = $@;
    if ($umount_err) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "error",
            "Unmounting of ${mntclean} failed: ${umount_err}\n" );
        warn "Unmounting of ${mntclean} failed: ${umount_err}";
    }

    $is_mnt = path_is_mnt( $scfg,  $mntclean);

    if ( ! $is_mnt) {
        # is not a mountpoint
        rmdir($mntclean);
        return;
    }

    die "Unable to unmount ${mntclean}\n";
}

sub snapshot_publish {
    my ( $scfg, $storeid, $datname, $volname, $snapname ) = @_;

    my $pool = pool_name_get( $scfg );
    my $vmid = _vmid_from_volname($volname);
    my $internal_snap = nas_sname($snapname, $vmid);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Publishing snapshot ${snapname} (${internal_snap}) for volume ${volname} from dataset ${datname}\n" );

    my $cmd_output = joviandss_cmd( $scfg, $storeid,
        [ "pool", $pool,
          "nas_volume", "-d", $datname,
          "snapshot", $internal_snap,
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
        return $1;
    }
    die "Share name representing "
        . "dataset ${datname} "
        . "volume ${volname} "
        . "snapshot ${snapname} "
        . "contains forbidden symbols: ${sharepath}\n";
}


sub snapshot_unpublish {
    my ( $scfg, $storeid, $datname, $volname, $snapname ) = @_;

    my $pool = pool_name_get( $scfg );
    my $vmid = _vmid_from_volname($volname);
    my $internal_snap = nas_sname($snapname, $vmid);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
        "Unpublishing snapshot ${snapname} (${internal_snap}) for dataset ${datname} of volume ${volname}\n" );
    $pool = OpenEJovianDSS::Common::safe_word($pool, 'Pool name');
    $datname = OpenEJovianDSS::Common::safe_word($datname, 'Dataset name');
    $internal_snap = OpenEJovianDSS::Common::safe_word($internal_snap, 'Snapshot name');
    joviandss_cmd(
        $scfg, $storeid,
        [ 'pool', $pool,
          'nas_volume', '-d', $datname,
          'snapshot', $internal_snap,
          'unpublish' ],
      120,
      10
    );
    return 1;
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

# Password management — NFS-specific path: joviandss-nfs/<storeid>.pw

my $NFS_PASSWORD_DIR = '/etc/pve/priv/storage/joviandss-nfs';

sub get_password_file_name {
    my ($storeid) = @_;
    return "${NFS_PASSWORD_DIR}/${storeid}.pw";
}

sub get_user_password {
    my ($storeid) = @_;

    my $pwfile = get_password_file_name($storeid);
    return undef if ! -f $pwfile;

    my $content = file_get_contents($pwfile);
    my $config = {};
    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || $line eq '';
        if ($line =~ /^(\S+)\s+(.+)$/) {
            $config->{$1} = $2;
        }
    }
    return $config->{user_password};
}

sub password_file_set_password {
    my ($password, $storeid) = @_;

    my $pwfile = get_password_file_name($storeid);
    if (! -d $NFS_PASSWORD_DIR) {
        File::Path::make_path($NFS_PASSWORD_DIR, { mode => 0700 });
    }
    file_set_contents($pwfile, "user_password $password\n", 0600, 1);
}

sub password_file_delete {
    my ($storeid) = @_;
    my $pwfile = get_password_file_name($storeid);
    unlink $pwfile;
}

sub joviandss_cmd {
    my ( $scfg, $storeid, $cmd, $timeout, $retries, $force_debug_level ) = @_;
    my $password = get_user_password($storeid);
    return OpenEJovianDSS::Common::joviandss_cmd(
        $scfg, $storeid, $cmd, $timeout, $retries, $force_debug_level, $password);
}

1;
