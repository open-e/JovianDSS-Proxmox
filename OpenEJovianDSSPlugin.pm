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
use File::Temp qw(tempfile);
#use File::Sync qw(fsync sync);

use Encode qw(decode encode);

use PVE::Tools qw(run_command file_read_firstline trim dir_glob_regex dir_glob_foreach $IPV4RE $IPV6RE);
use PVE::INotify;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.9.7';

# Configuration

my $default_prefix = "jdss-";
my $default_pool = "Pool-0";
my $default_config_path = "/etc/pve/";
my $default_debug = 0;
my $default_multipath = 0;
my $default_content_size = 100;
my $default_path = "/mnt/joviandss";

my $default_jmultipathd = "/etc/multipath/conf.d/joviandssdisks";

sub api {

   my $apiver = PVE::Storage::APIVER;

   if ($apiver >= 3 and $apiver <= 10) {
      return $apiver;
   }

   return 9;
}

sub type {
    return 'joviandss';
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
        pool_name                       => { fixed    => 1 },
        config                          => { optional => 1 },
        path                            => { optional => 1 },
        debug                           => { optional => 1 },
        multipath                       => { optional => 1 },
        content                         => { optional => 1 },
        content_volume_name             => { optional => 1 },
        content_volume_size             => { optional => 1 },
    };
}

# helpers
sub safe_var_print {
    my ($varname, $variable) = @_;
    return defined $variable ? "${varname} ${variable}": "";
}

sub get_pool {
    my ($scfg) = @_;
    die "pool name required in storage.cfg" if !defined($scfg->{pool_name});
    return $scfg->{pool_name};
}

sub get_config {
    my ($scfg) = @_;

    return $scfg->{config} if (defined($scfg->{config}));

    my $pool = get_pool($scfg);
    return "/etc/pve/${default_prefix}${pool}.yaml"
}

sub get_debug {
    my ($scfg) = @_;

    return $scfg->{debug} || $default_debug;
}

sub get_content {
    my ($scfg) = @_;

    return $scfg->{content};
}

sub get_content_volume_name {
    my ($scfg) = @_;

    if ( !defined($scfg->{content_volume_name}) ) {

        my $pool = get_pool($scfg);
	my $cv = lc("proxmox-content-${default_prefix}${pool}");
        warn "Content volume name is not set up, using default value ${cv}\n";
        return $cv;
    }
    my $cvn = $scfg->{content_volume_name};
    die "Content volume name should only include lower case, numbers and . - chars" if ( not ($cvn =~ /^[a-z0-9.-]*$/) );

    return $cvn;
}

sub get_content_volume_size {
    my ($scfg) = @_;

    warn "content_volume_size property is not set up, using default $default_content_size\n" if (!defined($scfg->{content_volume_size}));
    my $size = $scfg->{content_volume_size} || $default_content_size;
    return $size;
}

sub get_content_path {
    my ($scfg) = @_;

    return $scfg->{path} if (defined($scfg->{path}));

    my $path = get_content_volume_name($scfg);
    warn "path property is not set up, using default ${path}\n";
    return $path;
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

    $timeout = 40 if !$timeout;

    my $output = sub { $msg .= "$_[0]\n" };
    my $errfunc = sub { $err .= "$_[0]\n" };
    eval {
        run_command(['/usr/local/bin/jdssc', @$cmd], outfunc => $output, errfunc => $errfunc, timeout => $timeout);
    };
    if ($@) {
        print "Error:\n";
        print "${err}";
        die "$@\n ${err}\n";
    }
    return $msg;
}

# sub joviandss_cmde {
#     my ($class, $cmd, $timeout) = @_;
# 
#     my $msg = '';
#     my $err = undef;
#     my $target;
#     my $res = ();
# 
#     $timeout = 20 if !$timeout;
# 
#     my $output = sub { $msg .= "$_[0]" };
#     my $errfunc = sub { $err .= "$_[0]" };
#     eval {
#         run_command(['/usr/local/bin/jdssc', @$cmd], outfunc => $output, errfunc => $errfunc, timeout => $timeout);
#     };
#     return ($msg, $err);
# }

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

sub volume_path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    print"Getting path of volume ${volname} ".safe_var_print("snapshot", $snapname)."\n" if get_debug($scfg);
    
    my $target = $class->get_target_name($scfg, $volname, $storeid, $snapname);

    my $tpath;

    if (multipath_enabled($scfg)) {
        $tpath = $class->get_multipath_path($scfg, $target);
    } else {
        $tpath = $class->get_target_path($scfg, $target, $storeid);
    }

    return $tpath
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    if ($vtype eq "images") {
        return $class->volume_path( $scfg, $volname, $storeid, $snapname);
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

    return "$path/$subdir" if (defined($subdir));

    return undef;
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
	$class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "rename", $newname]);

    return $newname;
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my (undef, undef, undef, undef, undef, undef, $fmt) = $class->parse_volname($volname);
    my $clone_name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);

    my $size = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "get", "-s"]);
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    print"Clone ${volname} with size ${size} to ${clone_name}".safe_var_print(" with snapshot", $snap)."\n" if get_debug($scfg);
    if ($snap){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "clone", "--size", $size, "--snapshot", $snap, "-n", $clone_name]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "clone", "--size", $size, "-n", $clone_name]);
    }
    return $clone_name;
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    my $volume_name = $name;

    $volume_name = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt) if !$volume_name;

    if ('images' ne "${fmt}") {
        print"Creating volume ${volume_name} format ${fmt}\n" if get_debug($scfg);

        my $config = get_config($scfg);
        my $pool = get_pool($scfg);
        my $extsize = $size + 1023;
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "create", "--size", "${extsize}K", "-n", $volume_name]);
    }
    return "$volume_name";
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $_format) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);
    my ($vtype, undef, undef, undef, undef, undef, $format) =
        $class->parse_volname($volname);

    if ('images' cmp "$vtype") {
        return $class->SUPER::free_image($storeid, $scfg, $volname, $isBase, $format);
    }

    print"Deleting volume ${volname} format ${format}\n" if get_debug($scfg);

    $class->deactivate_volume($storeid, $scfg, $volname, '', '');

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "delete", "-c"]);
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

    print "Stage target ${target}\n" if get_debug($scfg);

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

    print "Storage address is ${targetpath}\n" if get_debug($scfg);

    return $targetpath;
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

sub get_multipath_records {
    my ($class, $jmultipathd) = @_;
    my $res = {};

    make_path $jmultipathd, {owner=>'root', group=>'root'};
    opendir my $dir, $jmultipathd or die "Cannot open multipath directory: $!";
    my @files = readdir $dir;
    closedir $dir;

    foreach my $file (@files) {

        if ($file eq '.' or $file eq '..') {
            next;
        }

        open my $filed, '<', "${jmultipathd}/${file}";
        my $scsiid = <$filed>;
        $res->{$file} = clean_word($scsiid);
        close($filed);
    }
    return $res;
}

#sub update_bindings_file {
#    my ($class, $wwid, $bname) = @_;
#    my $filename = "/etc/multipath/bindings";
#
#    open(my $multipath_map, '-|', "multipathd show maps | grep $wwid") or die "Unable to list multipath maps: $!";
#
#    my $device_mapper_name = '';
#    my $sysfs_name = '';
#    
#    while (my $line = <$multipath_map>) {
#        chomp $line;
#        if ($line =~ /\b$wwid\b/) {
#    
#            my @parts = split(/\s+/, $line);
#            $device_mapper_name = $parts[0];
#            $sysfs_name = $parts[1]
#        }
#    }
#    make_path '/etc/multipath/conf.d/', {owner=>'root', group=>'root'};
#    my (undef, $tmppath) = tempfile('multipathXXXXX', DIR => '/tmp/', OPEN => 0);
#
#    print "Tmp file path ${tmppath}";
#
#    PVE::Tools::file_copy($filename, $tmppath);
#    open(MULTIPATH, '<', $filename);  
#    open(FH, '>', $tmppath);
#
#    my $mpvols = $class->get_multipath_records($jmultipathd);
#
#    my $startblock = "# Start of JovianDSS managed block\n";
#    my $endblock   = "# End of JovianDSS managed block";
#
#    my $printflag = 1;
#    while(<MULTIPATH>){
#
#        if (/$startblock/ ) {
#            $printflag = 0;
#        }
#
#        if ($printflag) {
#            print FH "$_";
#        }
#
#        if (/$endblock/ ) {
#            $printflag = 1;
#        }
#        if (/multipaths \{/ ) {
#            print FH $startblock;
#
#            for my $key (keys %$mpvols) {
#                my $multipathdef = "      multipath {
#            wwid $mpvols->{ $key }
#            alias ${key}
#      }\n";
#                print FH $multipathdef;
#            }
#
#            print FH $endblock;
#            print FH "\n";
#        }
#        if (/blacklist_exceptions \{/ ) {
#            print FH $startblock;
#
#            for my $key (keys %$mpvols) {
#                my $multipathdef = "      wwid $mpvols->{ $key }\n";
#                print FH $multipathdef;
#            }
#
#            print FH $endblock;
#            print FH "\n";
#        }
#    }
#    close(MULTIPATH);
#    close(FH);
#    PVE::Tools::file_copy($tmppath, $filename);
#}

sub generate_multipath_file {
    my ($class, $jmultipathd) = @_;

    my $filename = "/etc/multipath/conf.d/multipath.conf";

    make_path '/etc/multipath/conf.d/', {owner=>'root', group=>'root'};
    my (undef, $tmppath) = tempfile('multipathXXXXX', DIR => '/tmp/', OPEN => 0); 

    print "Tmp file path ${tmppath}";

    PVE::Tools::file_copy($filename, $tmppath);
    open(MULTIPATH, '<', $filename);  
    open(FH, '>', $tmppath);

    my $mpvols = $class->get_multipath_records($jmultipathd);

    my $startblock = "# Start of JovianDSS managed block\n";
    my $endblock   = "# End of JovianDSS managed block";

    my $printflag = 1;
    while(<MULTIPATH>){

        if (/$startblock/ ) {
            $printflag = 0;
        }

        if ($printflag) {
            print FH "$_";
        }

        if (/$endblock/ ) {
            $printflag = 1;
        }
        if (/multipaths \{/ ) {
            print FH $startblock;

            for my $key (keys %$mpvols) {
                my $multipathdef = "      multipath {
            wwid $mpvols->{ $key }
            alias ${key}
      }\n";
                print FH $multipathdef;
            }

            print FH $endblock;
            print FH "\n";
        }
        if (/blacklist_exceptions \{/ ) {
            print FH $startblock;

            for my $key (keys %$mpvols) {
                my $multipathdef = "      wwid $mpvols->{ $key }\n";
                print FH $multipathdef;
            }

            print FH $endblock;
            print FH "\n";
        }
    }
    close(MULTIPATH);
    close(FH);
    PVE::Tools::file_copy($tmppath, $filename);
}

sub get_device_mapper_name {
    my ($class, $wwid) = @_;
    open(my $multipath_topology, '-|', "multipath -ll $wwid") or die "Unable to list multipath topology: $!";

    my $device_mapper_name = '';
    
    while (my $line = <$multipath_topology>) {
        chomp $line;
        if ($line =~ /\b$wwid\b/) {
    
            my @parts = split(/\s+/, $line);
            $device_mapper_name = $parts[0];
        }
    }

    close $multipath_topology;

    if ($device_mapper_name =~ /^([\:\-\@\w.\/]+)$/) {
        return $1;
    }
    die "Bad device mapper name";
}

sub stage_multipath {
    my ($class, $scfg, $scsiid, $target) = @_;

    my $scsiidpath  = "/dev/disk/by-id/scsi-${scsiid}";
    my $targetpath  = "/dev/mapper/${target}";
    my $jmultipathd = $default_jmultipathd;
    my $filename    = "${jmultipathd}/${target}";

    if (-b $targetpath && -e $filename) {
        return $targetpath;
    }
    print "Staging ${target}\n" if get_debug($scfg);

    make_path $jmultipathd, {owner=>'root', group=>'root'};
    my $multipathidfd;
    # open($multipathidfd, '>', $filename) or die "Unable to create multipath record file ${filename}";
    # print $multipathidfd "${scsiid}";
    # close $multipathidfd;

    # $class->generate_multipath_file($jmultipathd);
    eval { run_command([$MULTIPATH, '-a', $scsiid]); };
    die "Unable to add scsi id ${scsiid} $@" if $@;
    eval { run_command([$SYSTEMCTL, 'restart', 'multipathd']); };
    die "Unable to restart multipath daemon $@" if $@;

    my $mpathname = $class->get_device_mapper_name($scsiid);

    eval {run_command(["dmsetup", "rename", "${mpathname}", "${target}"], errmsg => 'umount error') };
   
    #print "sed -i s/${mpathname} ${scsiid}/${target} ${scsiid}/g /etc/multipath/bindings\n" if get_debug($scfg);

    eval {run_command(["sed", "-i", "\\'s/${mpathname} ${scsiid}/${target} ${scsiid}/g\\'", "/etc/multipath/bindings"], errmsg => 'sed command error') };
    warn "Unable rename mpath device ${mpathname} to ${target} because of $@" if $@;
    
    eval { run_command([$SYSTEMCTL, 'restart', 'multipathd']); };

    my $timeout = 10;

    for (my $i = 0; $i <= $timeout; $i++) {

        if (-b $targetpath) {

            print "Staging ${target} to ${targetpath} done." if get_debug($scfg);
            return $targetpath;
        }
        sleep(1);
    }

    die "Unable to identify mapping for target ${target}, might be an issue with device mapper, multipath or udev naming scripts\n";
}

sub unstage_multipath {
    my ($class, $scfg, $storeid, $target) = @_;

    my $scsiid;

    eval { $scsiid = $class->get_scsiid($scfg, $target, $storeid); };
    if ($@) {
        warn "Unable to identify scsiid for target ${target}";
    } else {
        eval{ run_command([$MULTIPATH, '-f', ${target}]); };
        warn $@ if $@;
    }

    print "Unstage multipath for scsi id ${scsiid} target ${target}" if get_debug($scfg);
    
    eval { run_command([$SYSTEMCTL, 'restart', 'multipathd']); };
    die "Unable to restart multipath daemon $@" if $@;

    #my $filename = "${default_jmultipathd}/${target}";

    #if ( -e $filename ) {
    #    unlink $filename;
    #}

    # $class->generate_multipath_file($default_jmultipathd);

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
        my $h = shift;
        push @hosts, $h;
    });
    return @hosts;
}

sub get_scsiid {
    my ($class, $scfg, $target, $storeid) = @_;

    my $mcfg = "${default_jmultipathd}/${target}";

    #if (multipath_enabled($scfg)) {
    #    if (-e $mcfg) {
    #        open my $mcfgfile, $mcfg or die "Unable to parse existing multipath file ${mcfg}, because of $!";
    #        my $scsiid;
    #        while ( defined(my $line = <$mcfgfile>) ) {
    #            if ( $line =~ /^[a-f0-9]*$/ ) {
    #                $scsiid = $line;
    #            }
    #            close $mcfgfile;
    #            if (! defined($scsiid) ){
    #                warn "Multipath config file ${mcfg} does not contain wwid!";
    #                unlink $mcfg;
    #            }
    #        }
    #    }

    #    my $multipathpath = $class->get_multipath_path($scfg, $target);
    #    if (-e $multipathpath) {
    #        my $getscsiidcmd = ["/lib/udev/scsi_id", "-g", "-u", "-d", $multipathpath];

    #        my $scsiid;
    #        eval {run_command($getscsiidcmd, outfunc => sub {
    #            $scsiid = shift;
    #        }); };
    #        if ( defined($scsiid) ) {
    #            return $scsiid;
    #        }
    #        warn "Unable to obtaine scsi id from multipath mapping of device";
    #    }
    #}
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

        if (defined($scsiid)) {
            if ($scsiid =~ /^([\-\@\w.\/]+)$/) {
                return $1;
            }
        }
    }
    die "Unable identify scsi id for target $target";
}

sub get_target_name {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target;
    if ($snapname){
        $target = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "get", "-v", $volname, "--snapshot", $snapname]);
    } else {
        $target = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "get", "-v", $volname]);
    }

    if (defined($target)) {
        
        
        $target = clean_word($target);
        if ($target =~ /^([\:\-\@\w.\/]+)$/) {
            return $1;
        }
    }
    die "Unable to identify target name for ${volname} ".safe_var_print("snapshot", $snapname);
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
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $nodename = PVE::INotify::nodename();

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $jdssc =  $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "list", "--vmid"]);

    my $res = [];
    foreach (split(/\n/, $jdssc)) {
        my ($volname,$vm,$size) = split;

        $volname = clean_word($volname);
        $vm = clean_word($vm);
        $size = clean_word($size);

        my $volid = "$storeid:$volname";

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
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "snapshots", "create", $snap]);

}

sub volume_snapshot_needs_fsfreeze {

    return 0;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    
    die "Volume snapshot rollback is not supported\n";

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "snapshot", $snap, "rollback"]);
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    return 0;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    # return 1 if $running;

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "snapshot", $snap, "delete"]);
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $jdssc =  $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", "$volname", "snapshots", "list"]);

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
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    if ('images' cmp "$vtype") {
        return $class->SUPER::volume_size_info($scfg, $storeid, $volname, $timeout);
    }

    my $size = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "get", "-s"]);
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    return $size;
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

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

sub ensure_content_volume {
    my ($class, $storeid, $scfg, $cache) = @_; 

    my $content_path = get_content_path($scfg);
    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $content_volname = get_content_volume_name($scfg);
    my $content_volume_size = get_content_volume_size($scfg);

    my $tpath = $class->volume_path($scfg, $content_volname, $storeid);

    # Check if content volume already present in system
    my $findmntpath; 
    eval {run_command(["findmnt", $content_path, "-n", "-o", "UUID"], outfunc => sub { $findmntpath = shift; }); };

    my $tname = $class->get_target_name($scfg, $content_volname, $storeid);

    if (defined($findmntpath)) {
        my $tuuid;
        eval { run_command(['blkid', '-o', 'value', $tpath, '-s', 'UUID'], outfunc => sub { $tuuid = shift; }); };
        if ($@) {
                warn $@;
                die "Unable identify UUID of content volume.";
        }

        if ($findmntpath eq $tuuid) {
            $class->ensure_fs($scfg);
            return 1;
        }

        warn "Another volume is mounted to the content volume ${content_path} location.";
        my $cmd = ['/bin/umount', $content_path];
        eval {run_command($cmd, errmsg => 'umount error') };
        die "Unable to unmount unknown volume at content path ${content_path}" if $@;

    }

    # Get volume

    eval { $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $content_volname, "get", "-d", "-s"]); };
    if ($@) {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "create", "-d", "-s", "${content_volume_size}G", '-n', $content_volname]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $content_volname, "resize", "-d", "${content_volume_size}G"]);
    }

    $class->activate_volume_ext($storeid, $scfg, $content_volname, "", $cache, 1);

    print "Checking file system on device ${tpath}\n";
    eval { run_command(["/usr/sbin/fsck", "-n", $tpath])};
    if ($@) {
            warn $@;
            die "Unable identify file system type for content storage, if that is a first run, format ${tpath} to a file sistem of your choise.";
    }
    print "Mounting device ${tpath}\n";
    mkdir "$content_path";
    run_command(["/usr/bin/mount", $tpath, $content_path], errmsg => "Unable to mount contant storage");

    $class->ensure_fs($scfg);
}

sub ensure_fs {
    my ( $class, $scfg) = @_; 
    
    my $path = get_content_path($scfg);
    
    make_path $path, {owner=>'root', group=>'root'};
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
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    return undef if !defined($scfg->{content});

    $class->ensure_content_volume($storeid, $scfg, $cache);

    return undef;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $path = get_content_path($scfg);
    my $content_volname = get_content_volume_name($scfg);
    my $target = $class->get_target_name($scfg, $content_volname, $storeid);

    my $cmd = ['/bin/umount', $path];
    eval {run_command($cmd, errmsg => 'umount error') };
    warn "Unable to unmount ${path}" if $@;

    if (multipath_enabled($scfg)) {

        print "Removing multipath\n" if get_debug($scfg);
        $class->unstage_multipath($scfg, $storeid, $target);
    }
    print "Unstaging target\n" if get_debug($scfg);
    $class->unstage_target($scfg, $storeid, $target);

    return undef;
}

sub activate_volume_ext {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache, $directmode ) = @_;

    print "Activating volume ext ${volname} ".safe_var_print("snapshot", $snapname)."\n" if get_debug($scfg);
    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target = $class->get_target_name($scfg, $volname, $storeid, $snapname);
   
    my $createtargetcmd = ["-c", $config, "pool", $pool, "targets", "create", "-v", $volname];
    if ($snapname){
        push @$createtargetcmd, "--snapshot", $snapname;
        $class->joviandss_cmd($createtargetcmd);
    } else {
        if (defined($directmode)) {
            push @$createtargetcmd, '-d';
        }
        $class->joviandss_cmd($createtargetcmd);
    }

    print "Staging target\n" if get_debug($scfg);
    my $targetpath = $class->stage_target($scfg, $storeid, $target);

    if (multipath_enabled($scfg)) {
        my $scsiid = $class->get_scsiid($scfg, $target, $storeid);
        print "Adding multipath\n" if get_debug($scfg);
        $targetpath = $class->stage_multipath($scfg, $scsiid, $target);
    }

    for (my $i = 1; $i <= 10; $i++) {
        return 1 if -b $targetpath;
        sleep(1);
    }

    die "Unable to confirm existance of volume at path ${targetpath}\n";
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;
    
    print "Activating volume ${volname} ".safe_var_print("snapshot", $snapname)."\n" if get_debug($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return 0 if ('images' ne "$vtype");

    $class->activate_volume_ext($storeid, $scfg, $volname, $snapname, $cache);

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    print "Deactivating volume ${volname} ".safe_var_print("snapshot", $snapname)."\n" if get_debug($scfg);
    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return 0 if ('images' ne "$vtype");

    if ($snapname){
        my $starget = $class->get_target_name($scfg, $volname, $storeid, $snapname);
        $class->unstage_multipath($scfg, $storeid, $starget) if multipath_enabled($scfg);
        $class->unstage_target($scfg, $storeid, $starget);
    } else {
        my $delitablesnaps = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "delete", "-c", "-p"]);
        my @dsl = split(" ", $delitablesnaps);

        foreach (@dsl) {
            my $starget = $class->get_target_name($scfg, $volname, $storeid, $_);
            $class->unstage_multipath($scfg, $storeid, $starget) if multipath_enabled($scfg);;
            $class->unstage_target($scfg, $storeid, $starget);
        }
    }
    
    if ($snapname){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "delete", "-v", $volname, "--snapshot", $snapname]);
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "delete", "-v", $volname]);
    }
    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    $class->joviandss_cmd(["-c", $config, "pool", "${pool}", "volume", "${volname}", "resize", "{$size}K"]);

    return 1;
}

sub parse_volname {
    my ($class, $volname) = @_;

    my $iso_re;

    if (defined($PVE::Storage::iso_extension_re)) {
        $iso_re = $PVE::Storage::iso_extension_re;
    } elsif (defined($PVE::Storage::ISO_EXT_RE_0)) {
        $iso_re = $PVE::Storage::ISO_EXT_RE_0;
    } else {
        $iso_re = qr/\.(?:iso|img)/i;
    }

    my $vztmpl_re;
    if (defined($PVE::Storage::vztmpl_extension_re)) {
        $vztmpl_re = $PVE::Storage::vztmpl_extension_re;
    } elsif (defined($PVE::Storage::VZTMPL_EXT_RE_1)) {
        $vztmpl_re = $PVE::Storage::VZTMPL_EXT_RE_1;
    } else {
        $vztmpl_re = qr/\.tar\.(gz|xz|zst)/i;
    }

    if ($volname =~ m/^((base-(\d+)-\S+)\/)?((base)?(vm)?-(\d+)-\S+)$/) {
        return ('images', $4, $7, $2, $3, $5, 'raw');
    } elsif ($volname =~ m!^iso/([^/]+$iso_re)$!) {
    	return ('iso', $1);
    } elsif ($volname =~ m!^vztmpl/([^/]+$vztmpl_re)$!) {
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
