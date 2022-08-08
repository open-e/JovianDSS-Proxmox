#    Copyright (c) 2022 Open-E, Inc.
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
use Carp qw( confess );
use IO::File;
use JSON::XS qw( decode_json );
use Data::Dumper;
use Storable qw(lock_store lock_retrieve);
use UUID "uuid";

use Encode qw(decode encode);

use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach $IPV4RE $IPV6RE);
use PVE::INotify;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.9.4';

# Configuration

my $default_joviandss_address = "192.168.0.100";
my $default_pool = "Pool-0";
my $default_config = "/etc/pve/joviandss.cfg";
my $default_debug = 0;
my $default_path = "/mnt/joviandss";

sub api {

   my $apiver = PVE::Storage::APIVER;

   if ($apiver >= 3 and $apiver <= 10) {
      return $apiver;
   }

   return 9;
}

sub type {
    return 'open-e';
}

sub plugindata {
    return {
    content => [ { images => 1, rootdir => 1, vztmpl => 1, iso => 1, backup => 1, snippets => 1, none => 1 },
             { images => 1,  rootdir => 1 }],
    format => [ { raw => 1, subvol => 0 } , 'raw' ],
    };
}

sub properties {
    return {
        joviandss_address => {
            description => "The fqdn or ip of the Open-E JovianDSS storage (',' separated list allowed)",
            type        => 'string',
            default     => $default_joviandss_address,
        },
        pool_name => {
            description => "Pool name",
            type        => 'string',
            default     => $default_pool,
        },
        config => {
            description => "JovianDSS config address",
            type        => 'string',
            default     => $default_config,
        },
        debug => {
            description => "Allow debug prints",
            type => 'boolean',
            default     => $default_debug,
        },
        share_name => {
            description => "Name of proxmox dedicated storage share",
            type => 'string',
        },
        share_user => {
            description => "User name proxmox dedicated storage",
            type => 'string',
        },
        share_pass => {
            description => "Password for proxmox dedicated storage",
            type => 'string',
        },
    };
}

sub options {
    return {
        joviandss_address  => { fixed => 1 },
        pool_name          => { fixed => 1 },
        config             => { fixed => 1 },
        debug              => { optional => 1 },
        path               => { optional => 1 },
        content            => { optional => 1 },
        share_name         => { fixed => 1 },
        share_user         => { optional => 1 },
        share_pass         => { optional => 1 },
    };
}

# helpers

sub get_pool {
    my ($scfg) = @_;

    return $scfg->{pool_name} || $default_pool;
}

sub get_joviandss_address {
    my ($scfg) = @_;

    return $scfg->{joviandss_address} || $default_joviandss_address;
}

sub get_config {
    my ($scfg) = @_;

    return $scfg->{config} || $default_config;
}

sub get_debug {
    my ($scfg) = @_;

    return $scfg->{debug} || $default_debug;
}

sub get_path {
    my ($scfg) = @_;

    return $scfg->{path} || $default_path;
}

sub joviandss_cmd {
    my ($class, $cmd, $timeout) = @_;

    my $msg = '';
    my $err = undef;
    my $target;
    my $res = ();

    $timeout = 10 if !$timeout;

    my $output = sub { $msg .= "$_[0]\n" };
    my $errfunc = sub { $err .= "$_[0]\n" };
    eval {
	    run_command(['/usr/local/bin/jdssc', @$cmd], outfunc => $output, errfunc => $errfunc, timeout => $timeout);
    };
    if ($@) {
	    die $err;
    }
    return $msg;
}

my $ISCSIADM = '/usr/bin/iscsiadm';
$ISCSIADM = undef if ! -X $ISCSIADM;

sub check_iscsi_support {
    my $noerr = shift;

    if (!$ISCSIADM) {
	my $msg = "no iscsi support - please install open-iscsi";
	if ($noerr) {
	    warn "warning: $msg\n";
	    return 0;
	}

	die "error: $msg\n";
    }

    return 1;
}

sub iscsi_session_list {

    check_iscsi_support ();

    my $cmd = [$ISCSIADM, '--mode', 'session'];

    my $res = {};

    eval {
	run_command($cmd, errmsg => 'iscsi session scan failed', outfunc => sub {
	    my $line = shift;

	    if ($line =~ m/^tcp:\s+\[(\S+)\]\s+\S+\s+(\S+)(\s+\S+)?\s*$/) {
		my ($session, $target) = ($1, $2);
		# there can be several sessions per target (multipath)
		push @{$res->{$target}}, $session;
	    }
	});
    };
    if (my $err = $@) {
	die $err if $err !~ m/: No active sessions.$/i;
    }

    return $res;
}

sub device_id_from_path {
    my ($path) = @_;

    my $msg = '';

    my $func = sub { $msg .= "$_[0]\n" };

    my $cmd = [];
    push @$cmd, "udevadm", "info", "-q", "symlink", $path;

    run_command($cmd, errmsg => 'joviandss error', outfunc => $func);

    my @devs = split(" ", $msg);

    my $devid = "";
    foreach (@devs) {
        $devid = "/dev/$_";
        last if index($_, "disk/by-id") == 0;
    }
    return $devid;
}

sub iscsi_discovery {
    my ($target, $portal) = @_;

    check_iscsi_support ();

    my $res = {};
    return $res if !iscsi_test_portal($portal); # fixme: raise exception here?

    my $cmd = [$ISCSIADM, '--mode', 'discovery', '--type', 'sendtargets', '--portal', $portal];
    run_command($cmd, outfunc => sub {
	my $line = shift;

	if ($line =~ m/^((?:$IPV4RE|\[$IPV6RE\]):\d+)\,\S+\s+(\S+)\s*$/) {
	    my $portal = $1;
	    my $target = $2;
	    # one target can have more than one portal (multipath).
	    push @{$res->{$target}}, $portal;
	}
    });

    return $res;
}

sub iscsi_test_portal {
    my ($portal) = @_;

    my ($server, $port) = PVE::Tools::parse_host_and_port($portal);
    return 0 if !$server;
    return PVE::Network::tcp_ping($server, $port || 3260, 2);
}

sub iscsi_login {
    my ($target, $portal_in) = @_;

    check_iscsi_support();

    eval { iscsi_discovery($target, $portal_in); };
    warn $@ if $@;

    run_command([$ISCSIADM, '--mode', 'node', '-p', $portal_in, '--targetname',  $target, '--login']);
}

sub iscsi_logout {
    my ($target, $portal) = @_;

    check_iscsi_support();

    run_command([$ISCSIADM, '--mode', 'node', '--targetname', $target, '--logout']);
}

sub iscsi_session {
    my ($cache, $target) = @_;
    $cache->{iscsi_sessions} = iscsi_session_list() if !$cache->{iscsi_sessions};
    return $cache->{iscsi_sessions}->{$target};
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    if ($vtype eq "images") {
        print"Getting path of volume ${volname} snapshot ${snapname}\n" if $scfg->{debug};

        my $dpath = "";

        if ($snapname){
            $dpath = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--path", "--snapshot", $snapname]);
        } else {
            $dpath = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--path"]);
        }

        chomp($dpath);
        $dpath =~ s/[^[:ascii:]]//;
        my $path = "/dev/disk/by-path/${dpath}";

        return ($path, $vmid, $vtype);
    }

    return $class->filesystem_path($scfg, $volname, $snapname);
}

my $vtype_subdirs = {
    images => 'images',
    iso => 'iso',
    vztmpl => 'vztmpl',
    backup => 'backup',
    rootdir => 'rootdir',
    snippets => 'snippets',
};

sub get_subdir {
    my ($class, $scfg, $vtype) = @_;

    my $path = $scfg->{path};

    die "storage definition has no path\n" if !$path;

    my $subdir = $vtype_subdirs->{$vtype};

    return "$path/$subdir" if defined($subdir);

    return undef;
    #die "unknown vtype '$vtype'\n" if !defined($subdir);

    #return "$path/$subdir";
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);

    die "create_base not possible with base image\n" if $isBase;

    $class->deactivate_volume($storeid, $scfg, $volname, '', '');

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my $newnameprefix = join '', 'base-', $vmid, '-disk-';

	my $newname = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "getfreename", "--prefix", $newnameprefix]);
    chomp($newname);
    $newname =~ s/[^[:ascii:]]//;
	$class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "rename", $newname]);

    return $newname;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my (undef, undef, undef, undef, undef, undef, $fmt) = $class->parse_volname($volname);
    my $clone_name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);

    my $size = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "get", "-s"]);
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    print"Clone ${volname} with size ${size} to ${clone_name} with snapshot ${snap}\n" if $scfg->{debug};
    if ($snap){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "clone", "-s", $size, "--snapshot", $snap, $clone_name]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "clone", "-s", $size, $clone_name]);
    }
    return $clone_name;
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    my $volume_name = $name;

    $volume_name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt)
        if !$volume_name;

    print"Allocating image ${volume_name} format ${fmt}\n" if $scfg->{debug};
    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "create", "-s", $size * 1024, $volume_name]);

    return "$volume_name";
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    $class->deactivate_volume($storeid, $scfg, $volname, '', '');

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "delete", "-c"]);
    return undef;
}

sub clean_word {
    my ($word) = @_;

    chomp($word);
    $word =~ s/[^[:ascii:]]//;

    return $word;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $nodename = PVE::INotify::nodename();

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    if ($scfg->{debug}) {
        print"list images ${storeid}\n" if $storeid;
        print"scfg ${scfg}\n" if $scfg;
        print"vmid ${vmid}" if $vmid;
        print"vollist ${vollist}" if $vollist;
        print"cache ${cache}" if $cache;
    }

    my $jdssc =  $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "list", "--vmid"]);

    my $res = [];
    foreach (split(/\n/, $jdssc)) {
        my ($volname,$vm,$size) = split;

        $volname = clean_word($volname);
        $vm = clean_word($vm);
        $size = clean_word($size);

        my $volid = "joviandss:$volname";

        if ($vollist) {
            my $found = grep { $_ eq $volid } @$vollist;
            next if !$found;
        } else {
            next if defined ($vmid) && ($vm ne $vmid);
        }

        push @$res, {
            format => 'raw',
            volid  => $volid,
            size   => $size,
            vmid   => $vm,
        };
    }

    return $res;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "snapshots", "create", $snap]);

}

sub volume_snapshot_needs_fsfreeze {

    return 0;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "snapshots", $snap, "rollback"]);
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    return 1 if $running;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "snapshots", $snap, "delete"]);
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my $jdssc =  $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "$volname", "snapshots", "list"]);

    my $res = [];
    foreach (split(/\n/, $jdssc)) {
      my ($sname) = split;
      push @$res, { 'name' => '$sname'};
    }

    return $res
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    if ('images' cmp "$vtype") {
        return $class->SUPER::volume_size_info($scfg, $storeid, $volname, $timeout);
    }

    my $size = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "get", "-s"]);
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    return $size;
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my $jdssc =  $class->joviandss_cmd(["-c", $config, "pool", $pool, "get"]);

    my $gb = 1024*1024*1024;
    my ($total, $avail, $used) = split(" ", $jdssc);

    return ($total * $gb, $avail * $gb, $used * $gb, 1 );
}

sub disk_for_target{
    my ( $class, $storeid, $scfg, $target ) = @_;
	return undef
}

sub storage_mounted {
    my ($path, $disk) = @_;

    my $mounts = PVE::ProcFSTools::parse_proc_mounts();
    for my $mp (@$mounts) {
    my ($dev, $dir, $fs) = $mp->@*;

    	next if $dir !~ m!^$mounts(?:/|$)!;
    	next if $dev ne $disk;
    	return 1;
    }
    return 0;
}

sub cifs_is_mounted {
    my ($share, $mountpoint) = @_;

    #$server = "[$server]" if Net::IP::ip_is_ipv6($server);
    #my $source = "//${server}/$share";
    my $mountdata = PVE::ProcFSTools::parse_proc_mounts();

    return $mountpoint if grep {
    $_->[2] =~ /^cifs/ &&
	$_->[0] =~ /$share/ &&
	#$_->[0] =~ m|^\Q$source\E/?$| &&
    $_->[1] eq $mountpoint
    } @$mountdata;
    return undef;
}

sub cifs_mount {
    my ($server, $share, $mountpoint, $username, $password, $smbver) = @_;

    $server = "[$server]" if Net::IP::ip_is_ipv6($server);
    my $source = "//${server}/$share";

    my $cmd = ['/bin/mount', '-t', 'cifs', $source, $mountpoint];
    push @$cmd, '-o', 'soft';
    push @$cmd, '-o', "username=$username", '-o', "password=$password";
    push @$cmd, '-o', "domain=workgroup";
    push @$cmd, '-o', defined($smbver) ? "vers=$smbver" : "vers=3.0";

    run_command($cmd, errmsg => "mount error");
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    if (!defined($scfg->{path})){
    	return 0;
    }

    die "Path property requires share_user property\n" if !defined($scfg->{share_user});
    my $username = $scfg->{share_user};
    die "Path property requires share_user property\n" if !defined($scfg->{share_pass});
    my $password = $scfg->{share_pass};

    my $config = $scfg->{config};
    my $share = $scfg->{share_name};
    my $pool = $scfg->{pool_name};
    my $path = $scfg->{path};
    my $joviandss_address = $scfg->{joviandss_address};

    return 1 if (cifs_is_mounted($share, $path));

	mkdir $path;
    $class->joviandss_cmd(["-c", $config, "pool", $pool, "cifs",  $share, "ensure", "-u", $username, "-p", $password, "-n", $share]);

    cifs_mount($joviandss_address, $share, $path, $username, $password);

	# Make dirs

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
    return undef;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    $cache->{mountdata} = PVE::ProcFSTools::parse_proc_mounts()
    if !$cache->{mountdata};

    my $path = $scfg->{path};
    my $server = $scfg->{server};
    my $share = $scfg->{share};

    return 1 if (cifs_is_mounted($share, $path));

    my $cmd = ['/bin/umount', $path];
    run_command($cmd, errmsg => 'umount error');

    return undef;
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snap, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my $target_info = "";

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return 0 if ('images' cmp "$vtype");

    if ($snap){
        $target_info = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--host", "--snapshot", $snap]);
    } else {
        $target_info = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--host"]);
    }

    my @tmp = split(" ", $target_info, 2);

    my $host = $tmp[1];
    chomp($host);
    $host =~ s/[^[:ascii:]]//;

    my $target = $tmp[0];
    chomp($target);
    $target =~ s/[^[:ascii:]]//;

    my $session = iscsi_session($cache, $target);
    if (defined ($session)) {
        print"Nothing to do, exiting" if $scfg->{debug};
        return 1;
    }

    if ($snap){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname, "--snapshot", $snap]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname]);
    }

    iscsi_login($target, $host);

    return 0;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my $target_info = "";

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    return 0 if ('images' cmp "$vtype");

    if ($snapname){
        $target_info = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--host", "--snapshot", $snapname]);
    } else {
        $target_info = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--host"]);
    }

    my @tmp = split(" ", $target_info, 2);
    my $host = $tmp[1];
    my $target = $tmp[0];

    eval{ iscsi_logout($target, $host)};
    warn $@ if $@;
    $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "delete"]);

    if ($snapname){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "delete", "--snapshot", $snapname]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "delete"]);
    }
    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "resize", $size]);

    return 1;
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^((base-(\d+)-\S+)\/)?((base)?(vm)?-(\d+)-\S+)$/) {
        return ('images', $4, $7, $2, $3, $5, 'raw');
    } elsif ($volname =~ m!^iso/([^/]+$PVE::Storage::iso_extension_re)$!) {
    	return ('iso', $1);
    } elsif ($volname =~ m!^vztmpl/([^/]+$PVE::Storage::vztmpl_extension_re)$!) {
    	return ('vztmpl', $1);
    } elsif ($volname =~ m!^rootdir/(\d+)$!) {
    	return ('rootdir', $1, $1);
    } elsif ($volname =~ m!^backup/([^/]+(?:\.(?:tgz|(?:(?:tar|vma)(?:\.(?:${\COMPRESSOR_RE}))?))))$!) {
    	my $fn = $1;
    	if ($fn =~ m/^vzdump-(openvz|lxc|qemu)-(\d+)-.+/) {
    	    return ('backup', $fn, $2);
    	}
    	return ('backup', $fn);
    }

    die "unable to parse joviandss volume name '$volname'\n";
}

sub storage_can_replicate {
    my ($class, $scfg, $storeid, $format) = @_;

    return 1 if $format eq 'raw';
    # TODO: additional testing of subvolumes is required
    #return 1 if $format eq 'raw' || $format eq 'subvol';

    return 0;
}

sub volume_has_feature {
    my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running, $opts) =
      @_;

    my $features = {
        snapshot => { base => 1, current => 1, snap => 1 },
        clone => { base => 1, current => 1, snap => 1, images => 1},
        template => { current => 1 },
        copy => { base => 1, current => 1, snap => 1},
        sparseinit => { base => { raw => 1 }, current => { raw => 1} },
        replicate => { base => 1, current => 1},
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

1;
# vim: set et sw=4 :
