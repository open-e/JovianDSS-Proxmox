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

package PVE::Storage::Custom::OpenEJovianDSSPlugin;

use strict;
use warnings;
use Carp qw( confess );
use IO::File;
use Data::Dumper;
use Storable qw(lock_store lock_retrieve);

use File::Path qw(make_path);
use File::Temp qw(tempfile);

use Encode qw(decode encode);

use PVE::Tools qw(run_command);
use PVE::Tools qw($IPV4RE);
use PVE::Tools qw($IPV6RE);

use PVE::INotify;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.9.8-5';

#    Open-E JovianDSS Proxmox plugin
#
#    0.9.8-5 - 2024.09.30
#              Add rollback to the latest volume snapshot
#              Introduce share option that substitutes proxmox code modification
#              Fix migration failure
#              Extend REST API error handling
#              Fix volume provisioning bug
#              Fix Pool selection bug
#              Prevent possible iscis target name collision

# Configuration

my $default_prefix = "jdss-";
my $default_pool = "Pool-0";
my $default_config_path = "/etc/pve/";
my $default_debug = 0;
my $default_multipath = 0;
my $default_content_size = 100;
my $default_path = "/mnt/joviandss";


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
        content_volume_type => {
            description => "Type of proxmox dedicated storage, allowed types are nfs and iscsi",
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
        content_volume_type             => { optional => 1 },
        content_volume_size             => { optional => 1 },
        shared                          => { optional => 1 },
        disable                         => { optional => 1 },
    };
}

sub print_dir {
    my ($class, $scfg, $dir) = @_;

    unless (get_debug($scfg)) {
        return;
    }
    open(my $test_data, '-|', "ls -all ${dir}") or die "Unable to list dir: $!\n";

    while (my $line = <$test_data>) {
            print "${line}";
    }
}

# helpers
sub safe_var_print {
    my ($varname, $variable) = @_;
    return defined ($variable) ? "${varname} ${variable}": "";
}

sub get_pool {
    my ($scfg) = @_;

    die "pool name required in storage.cfg \n" if !defined($scfg->{pool_name});
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
        die "content_volume_name property is not set\n";
    }
    my $cvn = $scfg->{content_volume_name};
    die "Content volume name should only include lower case letters, numbers and . - characters\n" if ( not ($cvn =~ /^[a-z0-9.-]*$/) );

    return $cvn;
}

sub get_content_volume_type {
    my ($scfg) = @_;
    if ( defined($scfg->{content_volume_type}) ) {
            if ($scfg->{content_volume_type} eq 'nfs') {
                return 'nfs';
            }
            if ($scfg->{content_volume_type} eq 'iscsi') {
                return 'iscsi';
            }
            die "Uncnown type of content storage requered\n";
    }
    return  'iscsi';
}

sub get_content_volume_size {
    my ($scfg) = @_;

    if get_debug($scfg);
        print "content_volume_size property is not set up, using default $default_content_size\n" if (!defined($scfg->{content_volume_size}));
    }
    my $size = $scfg->{content_volume_size} || $default_content_size;
    return $size;
}

sub get_content_path {
    my ($scfg) = @_;


    if (defined($scfg->{path})) {
        return $scfg->{path}
    } else {
        return undef;
    }
    #my $path = get_content_volume_name($scfg);
    #warn "path property is not set up, using default ${path}\n";
    #return $path;
}

sub multipath_enabled {
    my ($scfg) = @_;
    return $scfg->{multipath} || $default_multipath;
}

sub joviandss_cmd {
    my ($class, $cmd, $timeout, $retries) = @_;

    my $msg = '';
    my $err = undef;
    my $target;
    my $res = ();
    my $retry_count = 0;

    $timeout = 40 if !$timeout;
    $retries = 0 if !$retries;

    while ($retry_count <= $retries ) {
        my $output = sub { $msg .= "$_[0]\n" };
        my $errfunc = sub { $err .= "$_[0]\n" };
        eval {
            run_command(['/usr/local/bin/jdssc', @$cmd], outfunc => $output, errfunc => $errfunc, timeout => $timeout);
        };
        if (my $rerr = $@) {
            if ($rerr =~ /got timeout/) {
                $retry_count++;
                sleep int(rand($timeout + 1));
                next;
            }
            die "$@\n";
        }
        if ($err) {
            print "Error:\n";
            print "${err}";
            die $err;
        }
        return $msg;
    }
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
    run_command([$ISCSIADM, '--mode', 'node', '-p', $portal_in, '--targetname',  $target, '--login'], outfunc => sub {});
}

sub iscsi_logout {
    my ($target, $portal) = @_;

    check_iscsi_support();

    run_command([$ISCSIADM, '--mode', 'node', '--targetname', $target, '--logout'], outfunc => sub {});
}

sub iscsi_session {
    my ($cache, $target) = @_;
    $cache->{iscsi_sessions} = iscsi_session_list() if !$cache->{iscsi_sessions};
    return $cache->{iscsi_sessions}->{$target};
}

sub block_device_path {
    my ($class, $scfg, $volname, $storeid, $snapname, $content_volume_flag) = @_;

    print"Getting path of volume ${volname} ".safe_var_print("snapshot", $snapname)."\n" if get_debug($scfg);

    my $target = $class->get_target_name($scfg, $volname, $snapname, $content_volume_flag);

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
        return $class->block_device_path( $scfg, $volname, $storeid, $snapname);
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

    die "The storage definition has no path\n" if !$path;

    my $subdir = $vtype_subdirs->{$vtype};

    return "$path/$subdir" if (defined($subdir));

    return undef;
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) =
        $class->parse_volname($volname);

    die "create_base is not possible with base image\n" if $isBase;

    $class->deactivate_volume($storeid, $scfg, $volname, undef, undef);

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

    $class->deactivate_volume($storeid, $scfg, $volname, undef, undef);

    # Volume deletion will result in deletetion of all its snapshots
    # Therefore we have to detach all volume snapshots that is expected to be
    # removed along side with volume
    my $delitablesnaps = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "delete", "-c", "-p"]);
    my @dsl = split(" ", $delitablesnaps);

    foreach my $snap (@dsl) {
        my $starget = $class->get_active_target_name(scfg => $scfg,
                                                     volname => $volname,
                                                     snapname => $snap);
        unless (defined($starget)) {
            $starget = $class->get_target_name($scfg, $volname, $snap);
        }
        $class->unstage_multipath($scfg, $storeid, $starget) if multipath_enabled($scfg);;

        $class->unstage_target($scfg, $storeid, $starget);
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "delete", "-v", $volname, "--snapshot", $snap]);
    }
     $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "delete", "-v", $volname]);

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

    if ( -e $targetpath ) {
        print "Looks like target already pressent\n" if get_debug($scfg);

        $class->print_dir($scfg, $targetpath);
        return $targetpath;
    }

    print "Get storage address\n" if get_debug($scfg);
    my @hosts = $class->get_storage_addresses($scfg, $storeid);

    foreach my $host (@hosts) {

            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '-o', 'new'], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--op', 'update', '-n', 'node.startup', '-v', 'automatic'], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--login'], outfunc => sub {}); };
            warn $@ if $@;
    }

    $targetpath = $class->get_target_path($scfg, $target, $storeid);

    print "Storage address is ${targetpath}\n" if get_debug($scfg);

    return $targetpath;
}

sub unstage_target {
    my ($class, $scfg, $storeid, $target) = @_;

    print "Unstaging target ${target}\n" if get_debug($scfg); 
    my @hosts = $class->get_storage_addresses($scfg, $storeid);

    foreach my $host (@hosts) {
        my $tpath = $class->get_target_path($scfg, $target, $storeid);

        if (-e $tpath) {
            eval { run_command(['sync', '-f', $tpath], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command(['sync', $tpath], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command(['umount', $tpath], outfunc => sub {}); };
            warn $@ if $@;

            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--logout'], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '-o', 'delete'], outfunc => sub {}); };
            warn $@ if $@;
        }
    }
}

sub get_device_mapper_name {
    my ($class, $scfg, $wwid) = @_;

    print "Starget getting device mapper name ${wwid}\n" if get_debug($scfg); 
    open(my $multipath_topology, '-|', "multipath -ll $wwid") or die "Unable to list multipath topology: $!\n";

    print "Cleaning output for ${wwid}\n" if get_debug($scfg); 

    my $device_mapper_name;

    while (my $line = <$multipath_topology>) {
        chomp $line;
        print "line ${line}\n" if get_debug($scfg); 
        if ($line =~ /\b$wwid\b/) {
            my @parts = split(/\s+/, $line);
            $device_mapper_name = $parts[0];
        }
    }
    unless ($device_mapper_name) {
        return undef;
        #die "Unable to identify mapper name\n";
    }
    print "mapper name ${device_mapper_name}\n" if get_debug($scfg); 

    close $multipath_topology;

    if ($device_mapper_name =~ /^([\:\-\@\w.\/]+)$/) {

        print "Mapper name for ${wwid} is ${1}\n" if get_debug($scfg); 
        return $1;
    }
    return undef;
}


sub add_multipath_binding {
    my ($class, $scsiid, $target) = @_;

    $class->remove_multipath_binding($scsiid, $target);
    my $binding = "${target} ${scsiid}";

    open my $bfile, '>>', "/etc/multipath/bindings" or die "Unable to add ${target} to binding file $!";
    print $bfile $binding;
    close $bfile
}

sub remove_multipath_binding {
    my ($class, $scsiid, $target) = @_;

    eval {run_command(["sed", "-i", "/${scsiid}/Id", "/etc/multipath/bindings"], outfunc => sub {}, errmsg => 'sed command error') };
    die "Unable to remove the SCSI ID from the binding file ${scsiid} because of $@\n" if $@;

    eval {run_command(["sed", "-i", "/${target}/Id", "/etc/multipath/bindings"], outfunc => sub {}, errmsg => 'sed command error') };
    die "Unable to remove the target from the binding file ${target} because of $@\n" if $@;
}

sub stage_multipath {
    my ($class, $scfg, $scsiid, $target) = @_;

    my $targetpath  = $class->get_multipath_path($scfg, $target);

    print "Staging ${target}\n" if get_debug($scfg);

    eval { run_command([$MULTIPATH, '-a', $scsiid], outfunc => sub {}); };
    die "Unable to add the SCSI ID ${scsiid} $@\n" if $@;
    #eval { run_command([$SYSTEMCTL, 'restart', 'multipathd']); };
    eval { run_command([$MULTIPATH], outfunc => sub {}); };
    die "Unable to call multipath: $@\n" if $@;

    my $mpathname = $class->get_device_mapper_name($scfg, $scsiid);
    unless (defined($mpathname)){
        die "Unable to identify the multipath name for ${mpathname}\n";
    }
    print "Device mapper name ${mpathname}\n" if get_debug($scfg);

    if ( defined($targetpath) && -e $targetpath ){
        my ($tm, $mm);
        eval {run_command(["readlink", "-f", $targetpath], outfunc => sub {
            $tm = shift;
        }); };
        eval {run_command(["readlink", "-f", "/dev/mapper/${mpathname}"], outfunc => sub {
            $mm = shift;
        }); };

        if ($tm eq $mm) {
            return ;
        } else {
            unlink $targetpath;
        }
    }

    eval { run_command(["ln", "/dev/mapper/${mpathname}", "/dev/mapper/${target}"], outfunc => sub {}); };
    die "Unable to create link: $@\n" if $@;
    return;
}

sub unstage_multipath {
    my ($class, $scfg, $storeid, $target) = @_;

    my $scsiid;

    # Multipath Block Device Link Path
    # Link to actual block device representing multipath interface
    my $mbdlpath = $class->get_multipath_path($scfg, $target);
    print "Unstage multipath for target ${target}\n" if get_debug($scfg);

    if ( defined $mbdlpath && -e $mbdlpath ) {

        if (unlink $mbdlpath) {
            print "Removed $mbdlpath} link\n" if get_debug($scfg);
        } else {
            warn "Unable to remove $mbdlpath} link$!\n";
        }
    }

    eval { $scsiid = $class->get_scsiid($scfg, $target, $storeid); };
    if ($@) {
        die "Unable to identify the SCSI ID for target ${target}";
    }

    unless (defined($scsiid)) {
        print "Unable to identify multipath resource ${target}\n" if get_debug($scfg);
        return ;
    };

    # Multipath Block Device Mapper Name
    my $mbdmname = $class->get_device_mapper_name($scfg, $scsiid);
    if (defined($mbdmname)) {
        # Multipath Block Device Mapper Path
        my $mbdmpath = "/dev/mapper/${mbdmname}";
        # If Multipath Block Device Mapper representation exists
        # We synch cache
        if ( -e $mbdmpath ) {
            eval { run_command(['sync', '-f', $mbdmpath], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command(['sync', $mbdmpath], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command(['umount', $mbdmpath], outfunc => sub {}); };
            warn $@ if $@;
        }
    }
    eval{ run_command([$MULTIPATH, '-f', ${scsiid}], outfunc => sub {}); };
    if ($@) {
        warn "Unable to remove the multipath mapping for target ${target} because of $@\n" if $@;
        my $mapper_name = $class->get_device_mapper_name($scfg, $target);
        if (defined($mapper_name)) {
            eval{ run_command([$DMSETUP, "remove", "-f", $class->get_device_mapper_name($scfg, $target)], outfunc => sub {}); };
            die "Unable to remove the multipath mapping for target ${target} with dmsetup: $@\n" if $@;
        } else {
            warn "Unable to identify multipath mapper name for ${target}\n";
        }
    }

    eval { run_command([$MULTIPATH], outfunc => sub {}); };
    die "Unable to restart the multipath daemon $@\n" if $@;
}

sub get_multipath_path {
    my ($class, $scfg, $target) = @_;

    if (defined $target && length $target) {

        my $mpath = "/dev/mapper/${target}";

        if (-b $mpath) {
            return $mpath;
        }
    }
    return undef;
}

sub get_storage_addresses {
    my ($class, $scfg, $storeid) = @_;

    my $config = get_config($scfg);

    my $gethostscmd = ['/usr/local/bin/jdssc', '-c', $config, 'hosts', '--iscsi'];

    my @hosts = ();
    run_command($gethostscmd, outfunc => sub {
        my $h = shift;
        print "Storage iscsi address ${h}\n" if get_debug($scfg);

        push @hosts, $h;
    });
    return @hosts;
}

sub get_host_addresses {
    my ($class, $scfg, $storeid) = @_;

    my $config = get_config($scfg);

    my $gethostscmd = ["/usr/local/bin/jdssc", "-c", $config, "hosts"];

    my @hosts = ();
    run_command($gethostscmd, outfunc => sub {
        my $h = shift;
        print "Storage address ${h}\n" if get_debug($scfg);

        push @hosts, $h;
    });
    return @hosts;
}

sub get_scsiid {
    my ($class, $scfg, $target, $storeid) = @_;

    my @hosts = $class->get_storage_addresses($scfg, $storeid);

    foreach my $host (@hosts) {
        my $targetpath = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-0";
        my $getscsiidcmd = ["/lib/udev/scsi_id", "-g", "-u", "-d", $targetpath];
        my $scsiid;

        if (-e $targetpath) {
            eval {run_command($getscsiidcmd, outfunc => sub { $scsiid = shift; }); };

            if ($@) {
                die "Unable to get the iSCSI ID for ${targetpath} because of $@\n";
            };
        } else {
            next;
        };

        if (defined($scsiid)) {
            if ($scsiid =~ /^([\-\@\w.\/]+)$/) {
                print "Identified scsi id ${1}\n" if get_debug($scfg);
                return $1;
            }
        }
    }
    return undef;
}

sub get_active_target_name {

    my ($class, %args) = @_;

    my $scfg = $args{scfg};
    my $volname = $args{volname};
    my $snapname = $args{snapname};
    my $content = $args{content};

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);


    my $gettargetcmd = ["-c", $config, "pool", $pool, "targets", "get", "-v", $volname, "--current"];
    if ($snapname){
        push @$gettargetcmd, "--snapshot", $snapname;
    }
    if ($content) {
        push @$gettargetcmd, '-d';
    }

    my $target;
    $target = $class->joviandss_cmd($gettargetcmd);

    if (defined($target)) {
        $target = clean_word($target);
        if ($target =~ /^([\:\-\@\w.\/]+)$/) {
            print "Active target name for volume ${volname} is $1\n" if get_debug($scfg);
            return $1;
        }
    }
    return undef;
}

sub get_target_name {
    my ($class, $scfg, $volname, $snapname, $content_volume_flag) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $get_target_cmd = ["-c", $config, "pool", $pool, "targets", "get", "-v", $volname];
    if ($snapname){
        push @$get_target_cmd, "--snapshot", $snapname;
    } else {
        if (defined($content_volume_flag)) {
            push @$get_target_cmd, '-d';
        }
    }

    my $target = $class->joviandss_cmd($get_target_cmd, 80, 3);

    if (defined($target)) {
        $target = clean_word($target);
        if ($target =~ /^([\:\-\@\w.\/]+)$/) {
            return $1;
        }
    }
    die "Unable to identify the target name for ${volname} ".safe_var_print("snapshot", $snapname);
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

    my $jdssc = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "list", "--vmid"]);

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

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "snapshot", $snap, "rollback", "do"]);
}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $res = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $volname, "snapshot", $snap, "rollback", "check"]);
    if ( length($res) > 1) {
        die "Unable to rollback ". $volname . " to snapshot " . $snap . " because the resources(s) " . $res . " will be lost in the process. Please remove the dependent resources before continuing.\n"
    }

    return 0;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $starget = $class->get_active_target_name(scfg => $scfg,
                                                 volname => $volname,
                                                 snapname => $snap);
    unless (defined($starget)) {
        $starget = $class->get_target_name($scfg, $volname, $snap);
    }
    $class->unstage_multipath($scfg, $storeid, $starget) if multipath_enabled($scfg);;

    $class->unstage_target($scfg, $storeid, $starget);

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

sub ensure_content_volume_nfs {
    my ($class, $storeid, $scfg, $cache) = @_;

    my $content_path = get_content_path($scfg);

    unless (defined($content_path) ) {
        return undef;
    }

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $content_volume_name = get_content_volume_name($scfg);
    my $content_volume_size = get_content_volume_size($scfg);

    my $content_volume_size_current;

    unless ( -d "$content_path") {
        mkdir "$content_path";
    }

    eval { $content_volume_size_current = $class->joviandss_cmd(['-c', $config, 'pool', $pool, 'share', $content_volume_name, 'get', '-d', '-s', '-G']); };

    if ($@) {
        eval { $class->joviandss_cmd(['-c', $config, 'pool', $pool, 'shares', 'create', '-d', '-q', "${content_volume_size}G", '-n', $content_volume_name]); };
        if ($@) {
            my $err_msg = $@;
            $class->deactivate_storage($storeid, $scfg, $cache);
            die "Unable to create content volume ${content_volume_name} because of ${err_msg}\n";
        }
    } else {
        # TODO: check for volume size on the level of OS
        # If volume needs resize do it with jdssc

        $content_volume_size_current = clean_word($content_volume_size_current);
        print "Current content volume size ${content_volume_size_current}, config value ${content_volume_size}\n" if get_debug($scfg);
        if ($content_volume_size > $content_volume_size_current) {
            $class->joviandss_cmd(["-c", $config, "pool", $pool, "share", $content_volume_name, "resize", "-d", "${content_volume_size}G"]);
        }
    }

    my @hosts = $class->get_host_addresses($scfg, $storeid);

    foreach my $host (@hosts) {
        my $not_found_code = 1;
        my $nfs_path = "${host}:/Pools/${pool}/${content_volume_name}";
        my $cmd = ['/usr/bin/findmnt', '-t', 'nfs', '-S', $nfs_path, '-M', $content_path];
        eval { $not_found_code = run_command($cmd, outfunc => sub {}) };
        print "Code for find mnt ${not_found_code}\n" if get_debug($scfg);
        $class->ensure_fs($scfg);

        if ($not_found_code eq 0) {
            return 0;
        }
    }

    print "Content storage found not to be mounted, mounting.\n" if get_debug($scfg);

    my $not_mounted = 1;
    eval { $not_mounted = run_command(["findmnt", $content_path], outfunc => sub {})};

    if ($not_mounted == 0) {
        $class->deactivate_storage($storeid, $scfg, $cache);
    }

    foreach my $host (@hosts) {
        my $not_found_code = 1;
        my $nfs_path = "${host}:/Pools/${pool}/${content_volume_name}";
        run_command(["/usr/bin/mount", $nfs_path, $content_path], outfunc => sub {}, timeout => 10, noerr => 1 );

        my $cmd = ['/usr/bin/findmnt', '-t', 'nfs', '-S', $nfs_path, '-M', $content_path];
        eval { $not_found_code = run_command($cmd, outfunc => sub {}) };
        print "Code for find mnt ${not_found_code}\n" if get_debug($scfg);
        $class->ensure_fs($scfg);

        if ($not_found_code eq 0) {
            return 0;
        }
    }

    die "Unable to mount content storage\n";
}

sub ensure_content_volume {
    my ($class, $storeid, $scfg, $cache) = @_; 

    my $content_path = get_content_path($scfg);

    unless (defined($content_path) ) {
        return undef;
    }

    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $content_volname = get_content_volume_name($scfg);
    my $content_volume_size = get_content_volume_size($scfg);

    # First we get expected path of block device representing content volume
    # Block Device Path
    my $bdpath = $class->block_device_path($scfg, $content_volname, $storeid, undef, 1);

    # Acquire name of block device that is mounted to content volume folder
    my $findmntpath;
    eval {run_command(["findmnt", $content_path, "-n", "-o", "UUID"], outfunc => sub { $findmntpath = shift; }); };

    my $tname = $class->get_target_name($scfg, $content_volname, undef, 1);

    # if there is a block device mounted to content volume folder
    if (defined($findmntpath)) {
        my $tuuid;
        # We need to check that volume mounted to content volume folder is the one
        # specified in config. This volume might change if user decide to change content volumes
        # of if user decide to enable multipath or disable it
        # We want to be sure that volume representing multipath block device is mounted if multipath is enabled
        # If that is not a proper device we better unmount and do remounting
        eval { run_command(['blkid', '-o', 'value', $bdpath, '-s', 'UUID'], outfunc => sub { $tuuid = shift; }); };
        if ($@) {
            $class->deactivate_storage($storeid, $scfg, $cache);
        }

        if ($findmntpath eq $tuuid) {
            #$class->ensure_fs($scfg);
            return 1;
        }
        $class->deactivate_storage($storeid, $scfg, $cache);
    }

    # TODO: check for volume size on the level of OS
    # If volume needs resize do it with jdssc
    my $content_volume_size_current;
    eval { $content_volume_size_current = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $content_volname, "get", "-d", "-G"]); };
    if ($@) {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", "create", "-d", "-s", "${content_volume_size}G", '-n', $content_volname]);
    } else {
        # TODO: check for volume size on the level of OS
        # If volume needs resize do it with jdssc
        $content_volume_size_current = clean_word($content_volume_size_current);
        print "Current content volume size ${content_volume_size_current}, config value ${content_volume_size}\n";
        if ($content_volume_size > $content_volume_size_current) {
            $class->joviandss_cmd(["-c", $config, "pool", $pool, "volume", $content_volname, "resize", "-d", "${content_volume_size}G"]);
        }
    }

    $class->activate_volume_ext($storeid, $scfg, $content_volname, "", $cache, 1);

    print "Checking file system on device ${bdpath}\n";
    eval { run_command(["/usr/sbin/fsck", "-n", $bdpath], outfunc => sub {}) };
    if ($@) {
            die "Unable to identify file system type for content storage, if this is the first run, format ${bdpath} to the file system of your choice.\n";
    }
    if ($content_volume_size > $content_volume_size_current) {
        eval { run_command(["/usr/sbin/resize2fs", $bdpath], outfunc => sub {})};
        if ($@) {
            warn "Unable to resize content storage file system $@\n";
        }
    }
    print "Mounting device ${bdpath} to ${content_path}\n";
    mkdir "$content_path";

    my $already_mounted = 0;
    my $mount_error = undef;
    my $errfunc = sub {
        my $line = shift;
        if ($line =~ /already mounted on/) {
            $already_mounted = 1;
        };
        $mount_error .= "$line\n";
    };
    run_command(["/usr/bin/mount", $bdpath, $content_path], outfunc => sub {}, errfunc => $errfunc, timeout => 10, noerr => 1 );
    if ($mount_error && !$already_mounted) {
        $class->deactivate_storage($storeid, $scfg, $cache);
        die $mount_error;
    }
    $class->ensure_fs($scfg);
}

sub ensure_fs {
    my ( $class, $scfg) = @_; 

    my $path = get_content_path($scfg);

    if ( defined($path) ) {
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
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    print "Activate storage ${storeid}\n" if get_debug($scfg);

    return undef if !defined($scfg->{content});

    my @content_types = ('iso', 'backup', 'vztmpl', 'snippets');

    my $enabled_content = get_content($scfg);

    my $content_volume_needed = 0;
    foreach my $content_type (@content_types) {
        print "Checking content type $content_type\n" if get_debug($scfg);
        if (exists $enabled_content->{$content_type}) {
            print "Set content volume flag\n" if get_debug($scfg);
            $content_volume_needed = 1;
            last;
        }
    }

    if ($content_volume_needed) {
        my $cvt = get_content_volume_type($scfg);
        print "Content volume type ${cvt}\n" if get_debug($scfg);

        if ($cvt eq "nfs") {
            $class->ensure_content_volume_nfs($storeid, $scfg, $cache);
        } else {
            $class->ensure_content_volume($storeid, $scfg, $cache);
        }
    }
    return undef;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    print "Deactivating storage ${storeid}\n" if get_debug($scfg);

    my $path = get_content_path($scfg);
    my $pool = get_pool($scfg);

    my $content_volname = get_content_volume_name($scfg);
    my $target;

    # TODO: consider removing multipath and iscsi target on the basis of mount point
    if ( defined($path) ) {
        my $cmd = ['/bin/umount', $path];
        eval {run_command($cmd, errmsg => 'umount error', outfunc => sub {}) };

        if (get_debug($scfg)) {
            warn "Unable to unmount ${path}" if $@;
        }
    }

    return unless defined($content_volname);

    $target = $class->get_active_target_name(scfg => $scfg,
                                             volname => $content_volname,
                                             content => 1);
    unless (defined($target)) {
        $target = $class->get_target_name($scfg, $content_volname, undef, 1);
    }

    if (multipath_enabled($scfg)) {
        print "Removing multipath\n" if get_debug($scfg);
        $class->unstage_multipath($scfg, $storeid, $target);
    }
    print "Unstaging target\n" if get_debug($scfg);
    $class->unstage_target($scfg, $storeid, $target);

    return undef;
}

sub activate_volume_ext {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache, $content_volume_flag) = @_;

    print "Activating volume ext ${volname} ".safe_var_print("snapshot", $snapname)."\n" if get_debug($scfg);
    my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target = $class->get_target_name($scfg, $volname, $snapname, $content_volume_flag);

    my $targetpath = $class->get_target_path($scfg, $target, $storeid);

    my $create_target_cmd = ["-c", $config, "pool", $pool, "targets", "create", "-v", $volname];
    if ($snapname){
        push @$create_target_cmd, "--snapshot", $snapname;
    } else {
        if (defined($content_volume_flag)) {
            push @$create_target_cmd, '-d';
        }
    }

    $class->joviandss_cmd($create_target_cmd, 80, 3);

    print "Staging target\n" if get_debug($scfg);
    $class->stage_target($scfg, $storeid, $target);

    for (my $i = 1; $i <= 10; $i++) {
        last if (-e $targetpath);
        sleep(1);
    }

    unless (-e $targetpath) {
        die "Unable to confirm existance of volume at path ${targetpath}\n";
    }

    if (multipath_enabled($scfg)) {
        my $scsiid = $class->get_scsiid($scfg, $target, $storeid);
        print "Adding multipath\n" if get_debug($scfg);
        if (defined($scsiid)) {
            $class->stage_multipath($scfg, $scsiid, $target);
        } else {
            die "Unable to get scsi id for multipath device ${target}\n";
        }
    }
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

    my $target = $class->get_active_target_name(scfg => $scfg,
                                                volname => $volname,
                                                snapname => $snapname);
    unless (defined($target)) {
        $target = $class->get_target_name($scfg, $volname, $snapname);
    }

    $class->unstage_multipath($scfg, $storeid, $target) if multipath_enabled($scfg);
    $class->unstage_target($scfg, $storeid, $target);

    my $delete_target_cmd = ["-c", $config, "pool", $pool, "targets", "delete", "-v", $volname];
    if ($snapname){
        push @$delete_target_cmd, "--snapshot", $snapname;
    }

    $class->joviandss_cmd($delete_target_cmd, 80, 3);

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

sub get_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute) = @_;
    return undef;
}

sub update_volume_attribute {
    my ($class, $scfg, $storeid, $volname, $attribute, $value) = @_;
    return undef;
}

1;
