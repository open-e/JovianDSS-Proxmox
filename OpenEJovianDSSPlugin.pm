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

use File::Path qw(make_path);

use Encode qw(decode encode);

use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach $IPV4RE $IPV6RE);
use PVE::INotify;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.9.5';

# Configuration

my $default_pool = "Pool-0";
my $default_config = "/etc/pve/joviandss.cfg";
my $default_debug = 0;
my $default_multipath = 0;
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
        multipath => {
            description => "Enable multipath support",
            type => 'boolean',
            default     => $default_multipath,
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
        content_volume_name => {
            description => "Name of proxmox dedicated storage volume",
            type => 'string',
        },
        content_volume_size => {
            description => "Name of proxmox dedicated storage size",
            type => 'string',
        },
    };
}

sub options {
    return {
        pool_name           => { fixed => 1 },
        config              => { fixed => 1 },
        debug               => { optional => 1 },
        multipath           => { optional => 1 },
        path                => { optional => 1 },
        content             => { optional => 1 },
        content_volume_name => { optional => 1 },
        content_volume_size => { optional => 1 },
        share_name          => { fixed => 1 },
        share_user          => { optional => 1 },
        share_pass          => { optional => 1 },
    };
}

# helpers

sub get_pool {
    my ($scfg) = @_;
    die "pool name required in storage.cfg" if !defined($scfg->{pool_name});
    return $scfg->{pool_name};
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

sub multipath_enabled {
    my ($scfg) = @_;

    return $scfg->{multipath} || $default_multipath;
}

sub joviandss_cmd {
    my ($class, $cmd, $timeout) = @_;

    my $msg = '';
    my $err = undef;
    my $target;
    my $res = ();

    $timeout = 20 if !$timeout;

    my $output = sub { $msg .= "$_[0]\n" };
    my $errfunc = sub { $err .= "$_[0]\n" };
    eval {
        run_command(['/usr/local/bin/jdssc', @$cmd], outfunc => $output, errfunc => $errfunc, timeout => $timeout);
    };
    if ($@) {
        die $@;
    }
    return $msg;
}

sub joviandss_cmde {
    my ($class, $cmd, $timeout) = @_;

    my $msg = '';
    my $err = undef;
    my $target;
    my $res = ();

    $timeout = 20 if !$timeout;

    my $output = sub { $msg .= "$_[0]" };
    my $errfunc = sub { $err .= "$_[0]" };
    eval {
        run_command(['/usr/local/bin/jdssc', @$cmd], outfunc => $output, errfunc => $errfunc, timeout => $timeout);
    };
    return ($msg, $err);
}

my $ISCSIADM = '/usr/bin/iscsiadm';
$ISCSIADM = undef if ! -X $ISCSIADM;

my $MULTIPATH = '/usr/sbin/multipath';
$MULTIPATH = undef if ! -X $ISCSIADM;

my $SYSTEMCTL = '/usr/bin/systemctl';
$SYSTEMCTL = undef if ! -X $SYSTEMCTL;

my $DMSETUP = '/usr/sbin/dmsetup';
$DMSETUP = undef if ! -X $DMSETUP;

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

    #TODO: for each IP run discovery
    eval { iscsi_discovery($target, $portal_in); };
    warn $@ if $@;
    
    #TODO: for each target run login
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

sub get_call_stack {
    my $i = 1;
    print STDERR "Stack Trace:\n";
    while ( (my @call_details = (caller($i++))) ){
        print STDERR $call_details[1].":".$call_details[2]." in function ".$call_details[3]."\n";
    }
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    if ($vtype eq "images") {

        print"Getting path of volume ${volname} snapshot ${snapname}\n" if get_debug($scfg);
        
        my $path;
        my $target = $class->get_target_name($scfg, $volname, $storeid, $snapname);

        if (multipath_enabled($scfg)) {
            my $scsiid;
            eval { $scsiid = $class->get_scsiid($scfg, $target, $storeid); };
            warn "Volume ${volname} is not active." if $@;
            return $class->get_multipath_path($scfg, $target);
        }
        eval { $path = $class->get_target_path($scfg, $target, $storeid); };
        return $path;
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

    print"Clone ${volname} with size ${size} to ${clone_name} with snapshot ${snap}\n" if get_debug($scfg);
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

    $volume_name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt) if !$volume_name;

    print"Creating volume ${volume_name} format ${fmt}\n" if get_debug($scfg);

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "create", "-s", $size * 1024, $volume_name]);

    return "$volume_name";
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $format) = @_;

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

    print"Deleting volume ${volname} format ${format}\n" if get_debug($scfg);

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

sub stage_target {
    my ($class, $scfg, $storeid, $target) = @_;

    print "Stage target ${target}" if get_debug($scfg);

    my $targetpath = $class->get_target_path($scfg, $target, $storeid);

    if ( -b $targetpath ) {
        print "Looks like target already pressent\n" if get_debug($scfg);
        return $targetpath;
    }
    print "Get storage address\n" if get_debug($scfg);
    my @hosts = $class->get_storage_addresses($scfg, $storeid);

    foreach my $host (@hosts) {

            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '-o', 'new']); };
            warn $@ if $@;
            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--login']); };
            warn $@ if $@;
    }

    return $class->get_target_path($scfg, $target, $storeid);
}

sub unstage_target {
    my ($class, $scfg, $storeid, $target) = @_;

    print "Unstaging target ${target}\n" if get_debug($scfg); 

    my @hosts = $class->get_storage_addresses($scfg, $storeid);

    foreach my $host (@hosts) {
        eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--logout']); };
        warn $@ if $@;
        eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '-o', 'delete']); };
        warn $@ if $@;
    }
}

sub stage_multipath {
    my ($class, $scfg, $scsiid, $target) = @_;

    my $scsiidpath = "/dev/disk/by-id/scsi-${scsiid}";
    my $targetpath = "/dev/mapper/${target}";
    my $filename = "/etc/multipath/conf.d/$target";

    if (-b $targetpath && -e $filename) {
        return $targetpath;
    }
    
    my $str = "multipaths {
  multipath {
    wwid $scsiid
    alias $target
  }
}

blacklist_exceptions {
  wwid $scsiid
}";

    open(FH, '>', $filename) or die $!;

    print FH $str;

    close(FH);

    eval {run_command([$MULTIPATH, '-a', $scsiid]); };
    die "Unable to add scsi id ${scsiid} $@" if $@;
    eval {run_command([$SYSTEMCTL, 'restart', 'multipathd']); };
    die "Unable to restart multipath daemon $@" if $@;

    my $timeout = 10;

    for (my $i = 0; $i <= $timeout; $i++) {

        if (-b $targetpath) {
            #print "found mpath renamed file\n";
            #my $dir = "/dev/mapper";
            #opendir DIR,$dir;
            #my @dir = readdir(DIR);
            #close DIR;
            #foreach(@dir){
            #    if (-f $dir . "/" . $_ ){
            #        print $_,"   : file\n";
            #    }elsif(-d $dir . "/" . $_){
            #        print $_,"   : folder\n";
            #    }else{
            #        print $_,"   : other\n";
            #    }
            #}
            return $targetpath;
        }
        if (-b $scsiidpath) {
            print "Renaming ${scsiid}!\n" if get_debug($scfg);
            eval { run_command([$DMSETUP, 'rename', $scsiid , $target]); };
            die "Failed to stage target ${target} with proper name" if $@;
        }
        sleep(1);
    }

    if ( -e $targetpath ) {
        return $targetpath;
    }
    if ( -e $scsiidpath ) {
        eval { run_command([$DMSETUP, 'rename', $scsiid , $target]); };
        die "Failed to stage target ${target} with proper name" if $@;
        return $targetpath;
    }

    die "Unable to identify mapping for target ${target}, might be an issue with device mapper, multipath or udev naming scripts";
}

sub unstage_multipath {
    my ($class, $scfg, $scsiid, $target) = @_;
   
    print "Unstage multipath for scsi id ${scsiid} target ${target}" if get_debug($scfg);
    my $tcfg = "/etc/multipath/conf.d/${target}";
   
    if ( -e $tcfg ) {
        unlink $tcfg;
    }

    eval{ run_command([$MULTIPATH, '-d', $scsiid]); };
    warn $@ if $@;
    
    run_command([$SYSTEMCTL, 'restart', 'multipathd']);
}

sub get_multipath_path {
    my ($class, $scfg, $target) = @_;

    return "/dev/mapper/${target}";
}

sub get_storage_addresses {
    my ($class, $scfg, $storeid) = @_;

    my $config = get_config($scfg);

    my $gethostscmd = ["/usr/local/bin/jdssc", "-c", $config, "hosts"];

    my @hosts = ();
    run_command($gethostscmd, outfunc => sub {
        # Try to use shift
        my $h = shift;
        push @hosts, $h;
    });
    return @hosts;
}

sub get_scsiid {
    my ($class, $scfg, $target, $storeid) = @_;

    my $getscsiidcmd = ["/lib/udev/scsi_id", "-g", "-u", "-d"];
    my $iscsiid;

    my $multipathpath = $class->get_multipath_path($scfg, $target);
    my $mcfg = "/etc/multipath/conf.d/$target";

    if (-e $multipathpath) {
        my $getscsiidcmd = ["/lib/udev/scsi_id", "-g", "-u", "-d", $multipathpath];

        my $scsiid;
        eval {run_command($getscsiidcmd, outfunc => sub {
            $scsiid = shift;
        }); };
        return $scsiid;
    }

    if (-e $mcfg) {
        open my $mcfgfile, $mcfg or die "Unable to parse existing multipath file ${mcfg}, because of $!";

        while ( defined(my $line = <$mcfgfile>) ) {
            if ($line =~ m/wwid (\d+)/) {
                close $mcfgfile;
                return $1;
            }
        }
        close $mcfgfile;
        die "Multipath config file ${mcfg} does not contain wwid!";
    }

    my @hosts = $class->get_storage_addresses($scfg, $storeid);

    foreach my $host (@hosts) {
        my $targetpath = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-0";
        my $getscsiidcmd = ["/lib/udev/scsi_id", "-g", "-u", "-d", $targetpath];
        my $scsiid;
        eval {run_command($getscsiidcmd, outfunc => sub {
            $scsiid = shift;
        }); };
        if ($@) {
            warn "Unable to locate ${target} for host ${host}";
            continue;
        };
        print "Identified scsi id ${scsiid}\n" if get_debug($scfg);
        return $scsiid if defined($scsiid) ;
    }
    die "Unable identify scsi id for target $target";
}

sub get_target_name {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target;
    if ($snapname){
        $target = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--snapshot", $snapname]);
    } else {
        $target = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get"]);
    }
    print "Generated target name ${target}" if get_debug($scfg);
    return clean_word($target);
}

sub get_target_path {
    my ($class, $scfg, $target, $storeid) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my @hosts = $class->get_storage_addresses($scfg, $storeid);

    my $path;
    foreach my $host (@hosts) {
        $path = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-0";
        if ( -e $path ){
            return $path;
        }
    }
    return $path;
    #die "Unable to find active session for target ${target}";
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $nodename = PVE::INotify::nodename();

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

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

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "snapshots", "create", $snap]);

}

sub volume_snapshot_needs_fsfreeze {

    return 0;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "snapshots", $snap, "rollback"]);
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    return 1;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

    return 1 if $running;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "snapshots", $snap, "delete"]);
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

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

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

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

    my $config = get_config($scfg);
    my $pool = get_config($scfg);

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

sub ensure_content_volume {
    my ( $class, $storeid, $scfg, $cache ) = @_; 

    if (!defined($scfg->{path})){
    	return 0;
    }
    my $path = $scfg->{path};

    #$class->ensure_content_volume($storeid, $scfg, $cache) if defined($scfg->{content});
    #my $path = $scfg->{path};
    #die "path property is required for content storage\n" if !defined($scfg->{path});
    #my $path = $scfg->{path};

    #die "content_volume_name property is required for content storage\n" if !defined($scfg->{content_volume_name});
    #my $content_volume_name = $scfg->{content_volume_name};

    #die "content_volume_size property is required for content storage\n" if !defined($scfg->{content_volume_size});
    #my $content_volume_size = $scfg->{content_volume_size} * 1024 * 1024;

    # Get volume

    #my (_, $err) = $class->joviandss_cmde(["-c", $config, "pool", $pool, "volumes", $volname, "get", "-d", "-s"]);

    #if $err {
    #    # Create volume
    #    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "create", "-s", $content_volume_size * 1024, $content_volume_name]);
    #}

    #$class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $content_volume_name, "resize", $size]);

    #$class->attach_volume($scfg, $volname, $snap, $directmode, $cache);

    ## TODO: format volume

    #my $dir_path = "$path/iso";
    #mkdir $dir_path;
    #$dir_path = "$path/vztmpl";
    #mkdir $dir_path;
    #$dir_path = "$path/backup";
    #mkdir $dir_path;
    #$dir_path = "$path/rootdir";
    #mkdir $dir_path;
    #$dir_path = "$path/snippets";
    #mkdir $dir_path;
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    if (!defined($scfg->{path})){
    	return 0;
    }
 
    #$class->ensure_content_volume($storeid, $scfg, $cache) if defined($scfg->{content});
    my $path = $scfg->{path};

    make_path '/etc/multipath/conf.d/', {owner=>'root', group=>'root'};
    
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
    #my $username = $scfg->{share_user};
    #die "Path property requires share_user property\n" if !defined($scfg->{share_pass});
    
    #my $password = $scfg->{share_pass};
    #my $config = $scfg->{config};
    #my $share = $scfg->{share_name};
    #my $pool = $scfg->{pool_name};
    #my $path = $scfg->{path};

    #return 1 if (cifs_is_mounted($share, $path));

    #mkdir $path;
    #$class->joviandss_cmd(["-c", $config, "pool", $pool, "cifs",  $share, "ensure", "-u", $username, "-p", $password, "-n", $share]);

    #cifs_mount($joviandss_address, $share, $path, $username, $password);

	# Make dirs
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
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return 0 if ('images' cmp "$vtype");

    print "Activating volume ${volname}\n";
    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target = $class->get_target_name($scfg, $volname, $storeid, $snapname);
    
    if ($snapname){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname, "--snapshot", $snapname]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname]);
    }
    
    print "Staging target\n" if get_debug($scfg);
    $class->stage_target($scfg, $storeid, $target);

    if (multipath_enabled($scfg)) {
        
        my $scsiid = $class->get_scsiid($scfg, $target, $storeid);
        print "Adding multipath\n" if get_debug($scfg);
        $class->stage_multipath($scfg, $scsiid, $target);
    }

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    print "Deactivating volume ${volname}\n" if get_volume($scfg);
    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target = $class->get_target_name($scfg, $volname, $storeid, $snapname);

    if (multipath_enabled($scfg)) {
        
        my $scsiid = $class->get_scsiid($scfg, $target, $storeid);
        print "Removing multipath\n" if get_debug($scfg);
        $class->unstage_multipath($scfg, $scsiid, $target);
    }

    print "Unstaging target\n" if get_debug($scfg);
    $class->unstage_target($scfg, $storeid, $target);
    
    if ($snapname){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "delete", "--snapshot", $snapname]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "delete"]);
    }
    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

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
        replicate => { base => 1, current => 1, raw => 1},
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
