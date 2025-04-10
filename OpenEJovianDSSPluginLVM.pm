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

package PVE::Storage::Custom::OpenEJovianDSSPluginLVM;

use strict;
use warnings;
use Carp qw( confess );

use Encode qw(decode encode);
use Storable qw(lock_store lock_retrieve);

use File::Path qw(make_path);
use File::Temp qw(tempfile);
use File::Basename;
use JSON qw(decode_json);

use IO::File;

use Time::HiRes qw(gettimeofday);

use PVE::Tools qw(run_command trim);
use PVE::Tools qw($IPV4RE);
use PVE::Tools qw($IPV6RE);

use PVE::INotify;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::SafeSyslog;

use OpenEJovianDSS::Common qw(:all);

use base qw(PVE::Storage::Plugin);

use constant COMPRESSOR_RE => 'gz|lzo|zst';

my $PLUGIN_VERSION = '0.9.10-9';

#    Open-E JovianDSS Proxmox-LVM plugin
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
#    0.9.9.1 - 2024.12.13
#               Provide dynamic target name prefix generation
#               Enforce VIP addresses for iscsi targets
#               Fix volume resize for running machine
#    0.9.9.2 - 2024.12.17
#               Add logging to jdssc debug file
#               Fix data coruption during migration
#    0.9.9.3 - 2025.01.18
#               Add LVM based plugin
#    0.9.10-0 - 2025.03.25
#               Unify config options for jdssc and proxmox plugin


my $LVM_RESERVATION = 4 * 1024 * 1024;

sub api {

   my $apiver = PVE::Storage::APIVER;

   if ($apiver >= 3 and $apiver <= 10) {
      return $apiver;
   }

   return 10;
}

sub type {
    return 'joviandss-lvm';
}

sub plugindata {
    return {
    content => [ { images => 1, rootdir => 1 }, { images => 1,  rootdir => 1 }],
    format => [ { raw => 1, subvol => 0 } , 'raw' ],
    };
}

sub properties {
    return {};
}

sub options {
    return {
        pool_name                       => { fixed    => 1 },
        config                          => { optional => 1 },
        path                            => { optional => 1 },
        debug                           => { optional => 1 },
        multipath                       => { optional => 1 },
        content                         => { optional => 1 },
        shared                          => { optional => 1 },
        disable                         => { optional => 1 },
        target_prefix                   => { optional => 1 },
        ssl_cert_verify                 => { optional => 1 },
        user_name                       => { optional => 1 },
        user_password                   => { optional => 1 },
        control_addresses               => { optional => 1 },
        control_port                    => { optional => 1 },
        data_addresses                  => { optional => 1 },
        data_port                       => { optional => 1 },
        block_size                      => { optional => 1 },
        thin_provisioning               => { optional => 1 },
        log_file                        => { optional => 1 },
    };
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

#sub iscsi_login {
#    my ($target, $portal_in) = @_;
#
#    check_iscsi_support();
#
#    #TODO: for each IP run discovery
#    eval { iscsi_discovery($target, $portal_in); };
#    warn $@ if $@;
#
#    #TODO: for each target run login
#    run_command([$ISCSIADM, '--mode', 'node', '-p', $portal_in, '--targetname',  $target, '--login'], outfunc => sub {});
#}

#sub iscsi_logout {
#    my ($target, $portal) = @_;
#
#    check_iscsi_support();
#
#    run_command([$ISCSIADM, '--mode', 'node', '--targetname', $target, '--logout'], outfunc => sub {});
#}

sub iscsi_session {
    my ($cache, $target) = @_;
    $cache->{iscsi_sessions} = iscsi_session_list() if !$cache->{iscsi_sessions};
    return $cache->{iscsi_sessions}->{$target};
}

sub get_multipath_device_name {
    my ($device_path) = @_;

    my $cmd = [
        'lsblk',
        '-J',
        '-o', 'NAME,SIZE,FSTYPE,UUID,LABEL,MOUNTPOINT,SERIAL,VENDOR,ZONED,HCTL,KNAME,TYPE,TRAN',
        $device_path
    ];

    my $json_out = '';
    my $outfunc = sub { $json_out .= "$_[0]\n" };

    run_command($cmd, errmsg => "Getting multipath device for ${device_path} failed", outfunc => $outfunc);

    my $data = decode_json($json_out);

    my @mpath_names;
    for my $dev (@{ $data->{blockdevices} }) {
        if (exists $dev->{children} && ref($dev->{children}) eq 'ARRAY') {
            for my $child (@{ $dev->{children} }) {
                if (defined $child->{type} && $child->{type} eq 'mpath') {
                    push @mpath_names, $child->{name};
                }
            }
        }
    }

    # Return the proper result based on the number of multipath devices found.
    if (@mpath_names == 1) {
        return $mpath_names[0];
    } elsif (@mpath_names == 0) {
        return undef;
    } else {
        die "More than one multipath device found: " . join(", ", @mpath_names);
    }
}

sub block_device_path {
    my ($class, $scfg, $volname, $storeid, $snapname, $content_volume_flag) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Getting path of volume ${volname} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)."\n");

    my $target = $class->get_active_target_name(scfg => $scfg,
                                                volname => $volname,
                                                snapname => $snapname,
                                                content=>$content_volume_flag);

    if (!defined($target)){
        return undef;
    }

    my $tpath = $class->get_target_path($scfg, $target, $storeid);

    if (!defined($tpath)) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Target path for ${volname} not found\n");

        return undef;
    }
    my $bdpath;
    eval {run_command(["readlink", "-f", $tpath], outfunc => sub { $bdpath = shift; }); };

    $bdpath = OpenEJovianDSS::Common::clean_word($bdpath);
    my $block_device_name = basename($bdpath);
    unless ($block_device_name =~ /^[a-z0-9]+$/) {
        die "Invalide block device name ${block_device_name} for iscsi target ${target}\n";
    }

    if (OpenEJovianDSS::Common::get_multipath($scfg)) {
        $tpath = $class->get_multipath_path($storeid, $scfg, $target);
    }
    if (defined($tpath)) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Block device path is ${tpath} of volume ${volname} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)."\n");
    } else {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unable to identify path for volume ${volname} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)."\n");
    }
    return $tpath;
}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $path;

    if ($vtype eq "images") {
        my $vmvgname = $class->vm_vg_name($vmid, $snapname);
        $path = "/dev/$vmvgname/$volname";
    } else {
        die "Only images are supported\n";
    }
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Volume ${volname} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)." have path ${path}");
    return $path;
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;

    my ($vtype, $name, $vmid, $basename, $basevmid, $isBase) = $class->parse_volname($volname);

    die "create_base is not possible with base image\n" if $isBase;

    my $newvolname = $name;

    $newvolname =~ s/^vm-/base-/;

    $class->rename_volume($scfg, $storeid, $volname, $vmid, $newvolname);
    return $newvolname;

}

sub rename_volume {
    my ($class, $scfg, $storeid, $source_volname, $target_vmid, $target_volname) = @_;

    my ($source_vtype,
        $source_volume_name,
        $source_vmid,
        $source_basename,
        $source_basedvmid,
        $source_isBase,
        $source_format) = $class->parse_volname($source_volname);

    if ("${source_vmid}" ne "${target_vmid}") {
        die "Pluging does not allow volume movement to other VM";
    }

    $target_volname = $class->find_free_diskname($storeid, $scfg, $source_vmid, $source_format) if !$target_volname;

    my $source_vmdiskname = $class->vm_disk_name($source_vmid, 0);

    my $device = $class->block_device_path($scfg, $source_vmdiskname, $storeid, undef, 0);

    my $vols =  $class->vm_disk_list_volumes($scfg, $device);

    foreach my $vol (@$vols){
        if ($vol->{lvname} eq $target_volname) {
            die "Volume with name ${target_volname} already exists\n";
        }
    }

    my $source_vmvgname = $class->vm_vg_name($source_vmid);

    run_command(
        ['/sbin/lvrename', '--devices', $device, $source_vmvgname, $source_volname, $target_volname],
        errmsg => "Unable to rename '${source_volname}' to '${target_volname}' on vg '${source_vmvgname}'\n",
    );
    return "${storeid}:${target_volname}";
}

sub _clone_image_routine {
    my ($class, $scfg, $storeid, $source_volname, $clone_vmid, $snap) = @_;
    my $pool = $scfg->{pool_name};

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Start cloning volume ${source_volname} to ${clone_vmid} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snap));
    my ($source_vtype,
        $source_volume_name,
        $source_vmid,
        $source_basename,
        $source_basevmid,
        $source_isBase,
        $source_format) = $class->parse_volname($source_volname);

    my $clonevmdiskname = $class->vm_disk_name($clone_vmid, 0);
    my $sourcevmdiskname = $class->vm_disk_name($source_vmid, 0);

    my $clonevmvgname = $class->vm_vg_name($clone_vmid, undef);

    my $vmdiskexists = $class->vm_disk_exists($scfg, $clone_vmid, 0);

    my $info = undef;
    my $clonedevice = undef;

    if ($vmdiskexists == 0) {
        if ($snap){
            OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $sourcevmdiskname, "clone", "--snapshot", $snap, "-n", $clonevmdiskname]);
        } else {
            OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $sourcevmdiskname, "clone", "-n", $clonevmdiskname]);
        }
        $clonedevice = OpenEJovianDSS::Common::vm_disk_connect($storeid, $scfg, $clonevmdiskname, undef, undef);

        $info = vm_disk_lvm_info($clonedevice);

        my $cmd = ['/sbin/vgimportclone', '--basevgname', $clonevmvgname, '--devices', $clonedevice, '--nolocking', '-y', $info->{pvname}];
        run_command($cmd, errmsg => "Failed to import lvm clone of volume ${source_volname} from ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snap), outfunc => sub {});
    } else {
        $clonedevice = $class->vm_disk_connect($storeid, $scfg, $clonevmdiskname, undef, undef);
        $info = vm_disk_vg_info($clonedevice, $clonevmvgname);
    }

    die "Unable to locate device for cloned volume ${clonevmdiskname}\n" if !defined($clonedevice);
    # TODO: consider cases when disk is not base
    # will later deactivation lead to failure?
    # $sourcedevice = $class->vm_disk_connect($storeid, $scfg, $clonevmdiskname, $snap, undef);

    my $volume_suffix;
    if ($source_volname =~ /^(?:base|vm)-\d+-(.+)$/) {
        $volume_suffix = $1;
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "For '$source_volname', extracted part: $volume_suffix\n");
    } else {
        die "Unable to generate clone name from ${source_volname}\n";
    }
    my $clone_volname = "vm-${clone_vmid}-".$volume_suffix;
    my $renamecmd = ['lvrename', '--devices', $clonedevice, $clonevmvgname, $source_volname, $clone_volname];
    run_command($renamecmd, errmsg => "Rename volume ${source_volname} to ${clone_volname} error");

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Cloning of volume ${source_volname} to ${clone_vmid} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snap)." done\n");
    return $clone_volname;
}

sub clone_image {
    my ($class, $scfg, $storeid, $source_volname, $clone_vmid, $snap) = @_;

    #my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Start cloning volume ${source_volname} to ${clone_vmid} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snap));
    my ($source_vtype,
        $source_volume_name,
        $source_vmid,
        $source_basename,
        $source_basevmid,
        $source_isBase,
        $source_format) = $class->parse_volname($source_volname);

    my $clonevmdiskname = $class->vm_disk_name($clone_vmid, 0);
    my $sourcevmdiskname = $class->vm_disk_name($source_vmid, 0);

    my $clone_volname = undef;
    #$clonevolname = $class->cluster_lock_storage($storeid, $scfg->{shared}, undef, sub {
    eval { $clone_volname = $class->_clone_image_routine($scfg, $storeid, $source_volname, $clone_vmid, $snap); };

    if (!defined($clone_volname)) {
        $class->vm_disk_disconnect_all($storeid, $scfg, $clonevmdiskname, undef);
        $class->vm_disk_remove($storeid, $scfg, $clonevmdiskname, undef);
        die "Fail to clone volume ${source_volname}\n";
    }
    return $clone_volname;

    # TODO: consider cases when disk is not base
    # will later deactivation lead to failure?
}

my $ignore_no_medium_warnings = sub {
    my $line = shift;
    # ignore those, most of the time they're from (virtual) IPMI/iKVM devices
    # and just spam the log..
    if ($line !~ /open failed: No medium found/) {
        print STDERR "$line\n";
    }
};

sub clear_first_sector {
    my ($dev) = shift;

    if (my $fh = IO::File->new($dev, "w")) {
        my $buf = 0 x 512;
        syswrite $fh, $buf;
        $fh->close();
    }
}

sub vm_disk_vg_info {
    my ($device, $vgname) = @_;

    my $info = vm_disk_lvm_info($device);

    if (!defined($info)) {
        return undef;
    }
    if ($info->{vgname}) {
        return $info if $info->{vgname} eq $vgname; # already created
        die "device ${device} expected to be used by ${vgname} but actually it is used by '$info->{vgname}'\n";
    }
    die "Unable to confirm volume group name for device ${device}'\n";
}

sub vm_disk_lvm_update {
    my ($class, $storeid, $scfg, $vmdiskname, $device, $vmdisksize) = @_;

    $class->update_block_device($storeid, $scfg, $vmdiskname, undef);

    my $info = vm_disk_lvm_info($device);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "VM disk ${vmdiskname} pv $info->{pvname} update to size ${vmdisksize}\n");

    my $cmd = ['pvresize', '-y', '--devices', $device, '--setphysicalvolumesize', "${vmdisksize}b",  $info->{pvname}];
    run_command($cmd, outfunc => sub {});
}

sub vm_disk_lvm_info {
    my ($device) = @_;

    die "no device specified\n" if !$device;

    my $has_label = 0;

    my $cmd = ['/usr/bin/file', '-L', '-s', $device];
    run_command($cmd, outfunc => sub {
        my $line = shift;
        $has_label = 1 if $line =~ m/LVM2/;
    });

    return undef if !$has_label;

    $cmd = ['/sbin/pvs', '--separator', ':', '--noheadings', '--units', 'b',
            '--unbuffered', '--nosuffix', '--options',
            'pv_name,vg_name,pv_size,vg_size,vg_free,pv_uuid', '--devices', $device];

    my $pvinfo;
    run_command($cmd, outfunc => sub {
        my $line = shift;

        $line = trim($line);

        my ($pvname, $vgname, $pvsize, $vgsize, $vgfree, $uuid) = split(':', $line);

        die "found multiple pvs entries for device '$device'\n" if $pvinfo;

    $pvinfo = {
        pvname => $pvname,
        vgname => $vgname,
        pvsize => int($pvsize),
        vgsize => int($vgsize),
        vgfree => int($vgfree),
        uuid => $uuid,
    };
    });

    return $pvinfo;
}

sub vm_disk_create_volume_group {
    my ($class, $scfg, $device, $vgname) = @_;

    my $res = vm_disk_lvm_info($device);

    if ($res->{vgname}) {
        return if $res->{vgname} eq $vgname; # already created
        die "device '$device' is already used by volume group '$res->{vgname}'\n";
    }

    clear_first_sector($device); # else pvcreate fails

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "pvcreate for device ${device}");

    my $cmd = ['/sbin/pvcreate', '--metadatasize', '250k', $device];

    run_command($cmd, errmsg => "pvcreate '$device' error");

    # Added clustered flag, have to checked later
    $cmd = ['/sbin/vgcreate', '-y', $vgname, $device];

    run_command($cmd, errmsg => "vgcreate $vgname $device error", errfunc => $ignore_no_medium_warnings, outfunc => $ignore_no_medium_warnings);
}

sub vm_disk_list_volumes {
    my ($class, $scfg, $device) = @_;

    my @lvrecords;
    my $cmd = ['lvs', '--separator', ':', '--noheadings', '--units', 'b', '--options', 'lv_name,lv_size,lv_attr,vg_name', '--nosuffix', '--devices', $device];

    my $lvsinfo;
    run_command($cmd, outfunc => sub {
        my $line = shift;

        $line = trim($line);

        my ($lvname, $lvsize, $lvattr, $vgname) = split(':', $line);

        my $volinfo = {
            lvname => $lvname,
            lvsize => int($lvsize),
            lvattr => $lvattr,
            vgname => $vgname,
        };
        push @lvrecords, $volinfo;
    });
    return \@lvrecords;
}

sub lvm_create_volume {
    my ($class, $scfg, $device, $vgname, $volname, $size) = @_;

    my $lv_cmd = ['/sbin/lvcreate', '--devices', $device, '-aly', '-Wy', '--yes', '--size', "${size}b", '--name', $volname, $vgname];
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Allocate volume ${volname} at volume group ${vgname}");
    run_command($lv_cmd, errmsg => "lvcreate '$vgname/$volname' error");
}

sub lvm_remove_volume {
    my ($class, $scfg, $device, $vgname, $volname) = @_;

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Remove lvm volume ${volname} from device ${device}");
    my $cmd = ['/sbin/lvremove', '--devices', $device, '-f', "${vgname}/${volname}"];
    my $exitcode = run_command($cmd, errmsg => "unable to remove ${volname} ", noerr=>1);
    if ($exitcode == 0) {
        return;
    }
    die "Unable to remove ${volname} from lvm\n";
}

sub vm_vg_name {
    my ($class, $vmid, $snapshot) = @_;

    my $vmvgname;
    $vmvgname = "joviandss-pve-${vmid}";
    if ($snapshot) {
        $vmvgname .= "-" . $snapshot;
    }
    return $vmvgname;
}


sub vm_disk_name {
    my ($class, $vmid, $isBase) = @_;

    my $vmdiskname;
    if ($isBase) {
        $vmdiskname = "base-${vmid}";
    } else {
        $vmdiskname = "vm-${vmid}";
    }
    return $vmdiskname;
}

sub vm_disk_exists {
    my ($class, $scfg, $vmid, $isBase) = @_;

    my $vmdiskname;

    $vmdiskname = $class->vm_disk_name($vmid, $isBase);

   #my $config = get_config($scfg);
    my $pool   = get_pool($scfg);

    my $output;

    eval { $output = OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, "get", "-G"]); };
    if (my $err = $@) {

        if ($err =~ /^JDSS resource\s+\S+\s+DNE\./) {
            return 0;
        }
        die "Unable to identify volume ${vmdiskname} status\n";
    }
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "disk exists and its size is ${output}\n");

    return 1;
}

sub vm_disk_size {
    my ($class, $scfg, $vmdiskname) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $output = OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, "get", "-s"]);

    my $size = int(OpenEJovianDSS::Common::clean_word($output) + 0);
    return $size;
}

sub vm_disk_extend_to {
    my ($class,$storeid, $scfg, $vmdiskname, $device, $newsize) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", "${pool}", "volume", "${vmdiskname}", "resize", "${newsize}"]);

    $class->vm_disk_lvm_update($storeid, $scfg, $vmdiskname, $device, $newsize);

    return ;
}

sub alloc_image_routine {
    my ($class, $storeid, $scfg, $vmid, $volname, $size_bytes, $thin_provisioning, $block_size) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $vmdiskname = $class->vm_disk_name($vmid, 0);
    my $vmvgname = $class->vm_vg_name($vmid);
    my $vmdiskexists = $class->vm_disk_exists($scfg, $vmid, 0);
    my $device;

    if ($vmdiskexists == 0) {
        # we create additional space for volume
        # In order to provide space for lvm
        # TODO: check if difference in size of zvol and pve is more then 4M
        # And provide addition resize options
        my $extsize = $size_bytes + 4 * 1024 * 1024;
        OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Creating vm disk  ${vmdiskname} of size ${extsize}\n");
        my $createvolcmd = ["pool", $pool, "volumes", "create", "--size", "${extsize}", "-n", $vmdiskname];

        if (defined($thin_provisioning)) {
            push @$createvolcmd, '--thin-provisioning', $thin_provisioning;
        }

        if (defined($block_size)) {
            push @$createvolcmd, '--block-size', $block_size;
        }

        OpenEJovianDSS::Common::joviandss_cmd($scfg, $createvolcmd);

        $device = $class->vm_disk_connect($storeid, $scfg, $vmdiskname, undef, undef);
        $class->vm_disk_create_volume_group($scfg, $device, $vmvgname);
    } else {
        $device = $class->vm_disk_connect($storeid, $scfg, $vmdiskname, undef, undef);
        my $pvsinfo = vm_disk_lvm_info($device);
        my $vginfo;
        if (defined($pvsinfo)) {
           $vginfo = vm_disk_vg_info($device, $vmvgname);
        } else {
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unable to locate proper volume group on disk ${device}, creating\n"            );
            $class->vm_disk_create_volume_group($scfg, $device, $vmvgname);
            $vginfo = vm_disk_vg_info($device, $vmvgname);
        }

        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "got VG info!\n");

        my $vmdisksize = $class->vm_disk_size($scfg, $vmdiskname);

        # check if zvol size is not different from LVM size
        # that should handle cases of failure during volume resizing
        # when lvm data was not updated properly
        if ( abs($vmdisksize - $vginfo->{vgsize}) <= 0.01 * abs($vmdisksize) ) {
            $class->vm_disk_lvm_update($storeid, $scfg, $vmdiskname, $device, $vmdisksize);
            $vginfo = vm_disk_vg_info($device, $vmvgname);
        }

        if ($vginfo->{vgfree} < $size_bytes) {
            my $newvolsize = 0;
            $newvolsize = $size_bytes - $vginfo->{vgfree} + $vmdisksize;
            $class->vm_disk_extend_to($storeid, $scfg, $vmdiskname, $device, $newvolsize);
        }
    }
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Start lvm creation!\n");
    $class->lvm_create_volume($scfg, $device, $vmvgname, $volname, $size_bytes);
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Creating lvm disk  ${volname} of size ${size_bytes} Bytes done\n");

    return
}

#sub find_free_diskname {
#    my ($class, $storeid, $scfg, $vmid, $fmt) = @_;
#}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $volname, $size ) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    unless ($size =~ m/\d$/) {
        die "Volume size should be strictly numerical, ${size} characters are not supported\n";
    }
    # size is provided in kibibytes
    my $size_bytes = $size * 1024;

    my $block_size = get_block_size($scfg);
    my $thin_provisioning = get_thin_provisioning($scfg);
    # TODO: remove unecessary print

    my $isBase;
    if ($volname) {
        my ($vtype, $volume_name, $vmid_from_volname, $basename, $basedvmid, $isBase, $format) = $class->parse_volname($volname);
        if (!defined($vmid_from_volname) || $vmid_from_volname !~ /^\d+$/) {
            die "Unable to identify vm id from volume name ${volname}\n";
        }
        if ("${vmid_from_volname}" ne "${vmid}") {
            die "VM id in volume name ${vmid_from_volname} is different from requested ${vmid}\n";
        }
    } else {
        $volname = $class->find_free_diskname($storeid, $scfg, $vmid, $fmt);
        my ($vtype, $volume_name, undef, $basename, $basedvmid, $isBase, $format) = $class->parse_volname($volname);
    }

    if ('raw' eq "${fmt}") {

        eval {
            $class->alloc_image_routine(
                        $storeid,
                        $scfg,
                        $vmid,
                        $volname,
                        $size_bytes,
                        $thin_provisioning,
                        $block_size);
        };
        if (my $err = $@) {
            # TODO:
            # uncomment image cleaning routine
            $class->free_image($storeid, $scfg, $volname, $isBase, $fmt);
            die $err;
        }

    } else {
        die "Storage does not support ${fmt} format\n";
    }
    return "$volname";
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase, $format) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, undef, $vmid, undef, undef, undef, undef) = $class->parse_volname($volname);

    my $vmvgname = $class->vm_vg_name($vmid, undef);

    if ('images' ne "$vtype") {
        return $class->SUPER::free_image($storeid, $scfg, $volname, $isBase, $format);
    }
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Deleting volume ${volname} format ${format}\n");

    my $vmdiskname = $class->vm_disk_name($vmid, 0);
    my $device = $class->block_device_path($scfg, $vmdiskname, $storeid, undef, 0);

    my $connect_flag = undef;
    # TODO: do not fail if lvm volume do not exists
    # that is important for alloc_image that uses free_image to clean resources
    # in case of volume creation failure
    if (!defined($device)) {
        $device = $class->vm_disk_connect($storeid, $scfg, $vmdiskname, undef, undef);
        $connect_flag = 1;
    }

    my $pvsinfo = vm_disk_lvm_info($device);
    if (defined($pvsinfo)) {
        if ($pvsinfo->{vgname} eq $vmvgname) {
            my $vols = $class->vm_disk_list_volumes($scfg, $device);
            foreach my $vol (@$vols) {
                if ($vol->{lvname} eq $volname) {
                    OpenEJovianDSS::Common::deactivate_volume($storeid, $scfg, $volname, undef, undef);
                    $class->lvm_remove_volume($scfg, $device, $vmvgname, $volname);
                    last;
                }
            }

            # If deleted lvm volume was the last one, we have to release joviandss zvol
            $vols = $class->vm_disk_list_volumes($scfg, $device);

            if (defined($vols)) {

                if (scalar(@$vols) == 0) {
                    $class->vm_disk_disconnect_all($storeid, $scfg, $vmdiskname, undef);
                    $class->vm_disk_remove($storeid, $scfg, $vmdiskname, undef);
                }
            }

        } else {
            my $groupfound = $pvsinfo->{vgname};
            die "VM Disk is expected to have group ${vmvgname}, group found ${groupfound}\n";
        }
    } else {
        if ($connect_flag) {
            $class->vm_disk_disconnect($storeid, $scfg, $vmdiskname, undef, undef);
        }
        die "Unable to process lvm data for disk ${volname} to remove it. ".
             "Please remove it manualy\n";
    }
    if ($connect_flag) {
        $class->vm_disk_disconnect($storeid, $scfg, $vmdiskname, undef, undef);
    }

    return undef;
}

sub stage_target {
    my ($class, $scfg, $storeid, $target) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Stage target ${target}\n");

    my $targetpath = $class->get_target_path($scfg, $target, $storeid);

    if (defined($targetpath) && -e $targetpath ) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Looks like target already pressent\n");

        return $targetpath;
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Get storage address\n");
    my @hosts = $class->get_iscsi_addresses($scfg, $storeid, 1);

    foreach my $host (@hosts) {

            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '-o', 'new'], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--op', 'update', '-n', 'node.startup', '-v', 'automatic'], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--login'], outfunc => sub {}); };
            warn $@ if $@;
    }

    $targetpath = $class->get_target_path($scfg, $target, $storeid);

    die "Unable to locate target ${target} block device location.\n" if !defined($targetpath);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Storage address is ${targetpath}\n");

    return $targetpath;
}

sub unstage_target {
    my ($class, $scfg, $storeid, $target) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unstaging target ${target}\n");
    my @hosts = $class->get_iscsi_addresses($scfg, $storeid, 1);

    foreach my $host (@hosts) {
        my $tpath = $class->get_target_path($scfg, $target, $storeid);

        if (defined($tpath) && -e $tpath) {

            # Driver should not commit any write operation including sync before unmounting
            # Because that myght lead to data corruption in case of active migration
            # Also we do not do volume unmounting

            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '--logout'], outfunc => sub {}); };
            warn $@ if $@;
            eval { run_command([$ISCSIADM, '--mode', 'node', '-p', $host, '--targetname',  $target, '-o', 'delete'], outfunc => sub {}); };
            warn $@ if $@;
        }
    }
}

sub get_device_mapper_name {
    my ($class, $scfg, $wwid) = @_;

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Starget getting device mapper name ${wwid}\n");
    open(my $multipath_topology, '-|', "multipath -ll $wwid") or die "Unable to list multipath topology: $!\n";

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Cleaning output for ${wwid}\n");

    my $device_mapper_name;

    while (my $line = <$multipath_topology>) {
        chomp $line;
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "line ${line}\n"); 
        if ($line =~ /\b$wwid\b/) {
            my @parts = split(/\s+/, $line);
            $device_mapper_name = $parts[0];
        }
    }
    unless ($device_mapper_name) {
        return undef;
    }
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "mapper name ${device_mapper_name}\n");

    close $multipath_topology;

    if ($device_mapper_name =~ /^([\:\-\@\w.\/]+)$/) {

        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Mapper name for ${wwid} is ${1}\n"); 
        return $1;
    }
    return undef;
}

sub remove_multipath_binding {
    my ($class, $scsiid, $target) = @_;

    eval {run_command(["sed", "-i", "/${scsiid}/Id", "/etc/multipath/bindings"], outfunc => sub {}, errmsg => 'sed command error') };
    die "Unable to remove the SCSI ID from the binding file ${scsiid} because of $@\n" if $@;

    eval {run_command(["sed", "-i", "/${target}/Id", "/etc/multipath/bindings"], outfunc => sub {}, errmsg => 'sed command error') };
    die "Unable to remove the target from the binding file ${target} because of $@\n" if $@;
}

sub stage_multipath {
    my ($class, $storeid, $scfg, $scsiid, $target) = @_;

    my $targetpath = $class->get_multipath_path($storeid, $scfg, $target);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Staging ${target}\n");

    eval { run_command([$MULTIPATH, '-a', $scsiid], outfunc => sub {}); };
    die "Unable to add the SCSI ID ${scsiid} $@\n" if $@;
    #eval { run_command([$SYSTEMCTL, 'restart', 'multipathd']); };
    eval { run_command([$MULTIPATH], outfunc => sub {}); };
    die "Unable to call multipath: $@\n" if $@;

    my $mpathname = $class->get_device_mapper_name($scfg, $scsiid);
    unless (defined($mpathname)){
        die "Unable to identify the multipath name for scsiid ${scsiid} with target ${target}\n";
    }
    return "/dev/mapper/${mpathname}";
}

sub unstage_multipath {
    my ($class, $scfg, $storeid, $target) = @_;

    my $scsiid;

    # Multipath Block Device Link Path
    # Link to actual block device representing multipath interface
    my $mbdlpath = $class->get_multipath_path($storeid, $scfg, $target, 1);
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unstage multipath for target ${target}\n");

    # Driver should not commit any write operation including sync before unmounting
    # Because that myght lead to data corruption in case of active migration
    # Also we do not do any unmnounting to volume as that might cause unexpected writes

    eval { $scsiid = $class->get_scsiid($scfg, $target, $storeid); };
    if ($@) {
        die "Unable to identify the SCSI ID for target ${target}";
    }

    unless (defined($scsiid)) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unable to identify multipath resource ${target}\n");
        return ;
    };

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

sub get_expected_multipath_path {
    my ($class, $scfg, $target) = @_;

    if (defined $target && length $target) {

        my $mpath = "/dev/mapper/${target}";

        return $mpath;
    }
    return undef;
}

sub get_multipath_path {
    my ($class, $storeid, $scfg, $target, $expected) = @_;

    my $tpath = $class->get_target_path($scfg, $target, $storeid);

    unless (defined($tpath)) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Unable to identify device path for target ${target}\n");
        return undef;
    }
    my $bdpath;
    eval {run_command(["readlink", "-f", $tpath], outfunc => sub { $bdpath = shift; }); };

    $bdpath = OpenEJovianDSS::Common::clean_word($bdpath);
    my $block_device_name = basename($bdpath);
    unless ($block_device_name =~ /^[a-z0-9]+$/) {
        die "Invalide block device name ${block_device_name} for iscsi target ${target}\n";
    }

    my $mpathname = get_multipath_device_name($bdpath);

    if (!defined($mpathname)) {
        return undef;
    }

    my $mpathpath = "/dev/mapper/${mpathname}";

    if (-b $mpathpath) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Multipath block device is ${mpathpath}\n");
        return $mpathpath;
    }
    return undef;
}

sub get_iscsi_addresses {
    my ($class, $scfg, $storeid, $addport) = @_;

   #my $config = get_config($scfg);

    my $da = get_data_addresses($scfg);

    my $dp = get_data_port($scfg);

    if (defined($da)){
        my @iplist = split(/\s*,\s*/, $da);
        if (defined($addport) && $addport) {
            foreach (@iplist) {
                $_ .= ":${dp}";
            }
        }
        return @iplist;
    }

    my $getaddressescmd = ['hosts', '--iscsi'];

    my $cmdout = OpenEJovianDSS::Common::joviandss_cmd($scfg, $getaddressescmd);

    if (length($cmdout) > 1) {
        my @hosts = ();

        foreach (split(/\n/, $cmdout)) {
            my ($host) = split;
            if (defined($addport) && $addport) {
                push @hosts, "${host}:${dp}";
            } else {
                push @hosts, $host;
            }
        }

        if (@hosts > 0) {
            return @hosts;
        }
    }

    my $ca = get_control_addresses($scfg);

    my @iplist = split(/\s*,\s*/, $ca);
    if (defined($addport) && $addport) {
        foreach (@iplist) {
            $_ .= ":${dp}";
        }
    }

    return @iplist;
}

sub get_scsiid {
    my ($class, $scfg, $target, $storeid) = @_;

    my @hosts = $class->get_iscsi_addresses($scfg, $storeid, 1);

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
                OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Identified scsi id ${1}\n");
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

    my $pool = get_pool($scfg);

    my $prefix = get_target_prefix($scfg);
    my $gettargetcmd = ["pool", $pool, "targets", "get", '--target-prefix', $prefix, "-v", $volname, "--current"];
    if ($snapname){
        push @$gettargetcmd, "--snapshot", $snapname;
    }
    if ($content) {
        push @$gettargetcmd, '-d';
    }

    my $target;
    $target = OpenEJovianDSS::Common::joviandss_cmd($scfg, $gettargetcmd);

    if (defined($target)) {
        $target = OpenEJovianDSS::Common::clean_word($target);
        if ($target =~ /^([\:\-\@\w.\/]+)$/) {
            OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Active target name for volume ${volname} is $1\n");
            return $1;
        }
    }
    return undef;
}

sub get_target_name {
    my ($class, $scfg, $volname, $snapname, $content_volume_flag) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $prefix = get_target_prefix($scfg);
    my $get_target_cmd = ["pool", $pool, "targets", "get", '--target-prefix', $prefix, "-v", $volname];
    if ($snapname){
        push @$get_target_cmd, "--snapshot", $snapname;
    } else {
        if (defined($content_volume_flag) && $content_volume_flag != 0) {
            push @$get_target_cmd, '-d';
        }
    }

    my $target = OpenEJovianDSS::Common::joviandss_cmd($scfg, $get_target_cmd, 80, 3);

    if (defined($target)) {
        $target = OpenEJovianDSS::Common::clean_word($target);
        if ($target =~ /^([\:\-\@\w.\/]+)$/) {
            return $1;
        }
    }
    die "Unable to identify the target name for ${volname} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)."\n";
}

sub get_target_path {
    my ($class, $scfg, $target, $storeid, $expected) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my @hosts = $class->get_iscsi_addresses($scfg, $storeid, 1);

    my $path;
    foreach my $host (@hosts) {
        $path = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-0";
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Checking path ${path}\n");
        if (defined $expected && $expected != 0) {
            return $path;
        }
        if ( -e $path ){
            return $path;
        }
    }
    return undef;
}

sub _list_images_single_vm {
    my ( $class, $storeid, $scfg, $vmid ) = @_;

    my $res = [];

    my $pool = get_pool($scfg);

    my $vmdiskname = $class->vm_disk_name($vmid, 0);
    my $device = $class->block_device_path($scfg, $vmdiskname, $storeid, undef, 0);
    if (!defined($device)) {
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Block device for ${vmdiskname} not found\n");

        my $size;
        eval {$size = OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, 'get', '-s']); };
        if ($@) {
            return $res;
        }

        $size = OpenEJovianDSS::Common::clean_word($size);

        push @$res, {
            format => 'raw',
            volid  => "${storeid}:${vmdiskname}",
            size   => "$size",
            vmid   => "$vmid",
        };
    } else {
        my $vols = $class->vm_disk_list_volumes($scfg, $device);

        foreach my $vol (@$vols) {
            my ($lvm_vtype,
                $lvm_volume_name,
                $lvm_vmid,
                $lvm_basename,
                $lvm_basedvmid,
                $lvm_isBase,
                $lvm_format) = $class->parse_volname($vol->{lvname});

            if ("$vmid" ne "$lvm_vmid") {
                OpenEJovianDSS::Common::debugmsg($scfg, "error", "VM disk ${vmid} hosts disk $vol->{lvname}\n");
                next;
            }

            my $volid = "$storeid:$vol->{lvname}";

            push @$res, {
                format => 'raw',
                volid  => "${volid}",
                size   => "$vol->{lvsize}",
                vmid   => "$vmid",
            };
        }
    }
    return $res;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    #my $nodename = PVE::INotify::nodename();

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $res = [];
    # case for single vm
    if (defined($vmid)) {
        my $vm_disks_info = $class->_list_images_single_vm($storeid, $scfg, $vmid);

        if (defined($vollist)) {
            foreach my $vol (@$vm_disks_info){
                my (undef, $volname) = split /:/, $vol->{volid}, 2;
                if ($vollist) {
                    next if ! grep { $_ eq $volname } @$vollist;
                }
                push(@$res, $vol);
            }
            return $res;
        } else {
            return $vm_disks_info;
        }
    }

    # TODO: test vol list
    # case for vollist
    if (defined($vollist)) {

        my $intermediate_list = [];

        foreach my $vol (@$vollist){
            my ($vtype,
                $volume_name,
                $vmid,
                $basename,
                $basedvmid,
                $isBase,
                $format) = $class->parse_volname($vol);

            my $vm_disks_info = $class->_list_images_single_vm($storeid, $scfg, $vmid);
            push(@$intermediate_list, @$vm_disks_info);
        }

        foreach my $vol (@$intermediate_list){
            my (undef, $volname) = split /:/, $vol->{volid}, 2;
            next if ! grep { $_ eq $volname } @$vollist;
            push(@$res, $vol);
        }
        return $res;
    }

    # case for all
    my $vmdisks = OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volumes", "list", "--vmid"]);

    foreach (split(/\n/, $vmdisks)) {
        my ($vmdiskname,$vmid,$size) = split;

        if ($vmdiskname =~ /^(?:base|vm)-(\d+)$/) {

            my $vm_disks_info = $class->_list_images_single_vm($storeid, $scfg, $1);

            push(@$res, @$vm_disks_info);
        }
    }
    return $res;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $vmdiskname = $class->vm_disk_name($vmid, 0);

    OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, "snapshots", "create", '--ignoreexists', $snap]);

}

sub volume_snapshot_needs_fsfreeze {

    return 0;
}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $vmdiskname = $class->vm_disk_name($vmid, 0);

    OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, "snapshot", $snap, "rollback", "do"]);

    $class->update_block_device($storeid, $scfg, $vmdiskname, undef);

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Rollback of zvol ${vmdiskname} to snapshot ${snap} done\n");

}

sub volume_rollback_is_possible {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $vmdiskname = $class->vm_disk_name($vmid, 0);

    my $res = OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, "snapshot", $snap, "rollback", "check"]);
    if ( length($res) > 1) {
        die "Unable to rollback ". $volname . " to snapshot " . $snap . " because the resources(s) " . $res . " will be lost in the process. Please remove the dependent resources before continuing.\n"
    }

    return 0;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap, $running) = @_;

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $starget = $class->get_active_target_name(scfg => $scfg,
                                                 volname => $volname,
                                                 snapname => $snap);
    unless (defined($starget)) {
        $starget = $class->get_target_name($scfg, $volname, $snap);
    }
    $class->unstage_multipath($scfg, $storeid, $starget) if OpenEJovianDSS::Common::get_multipath($scfg);;

    $class->unstage_target($scfg, $storeid, $starget);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $volname, "snapshot", $snap, "delete"]);
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $volume_name, $vmid, $basename, $basedvmid, $isBase, $format) = $class->parse_volname($volname);

    my $vmdiskname = $class->vm_disk_name($vmid, $isBase);

    if ('images' eq "$vtype") {
        my $device = $class->block_device_path($scfg, $vmdiskname, $storeid, undef, 0);

        unless ( defined $device) {
            $device = $class->vm_disk_iscsi_connect($storeid, $scfg, $vmdiskname, undef, undef);
        }

        my $vols = $class->vm_disk_list_volumes($scfg, $device);

        foreach my $vol (@$vols) {
            if ("${volname}" eq "$vol->{lvname}") {
                my $size = "$vol->{lvsize}";
                $size =~ s/[^[:ascii:]]//;
                return $size;
            }
        }
    }
    return undef;
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $jdssc =  OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "get"]);
    my $gb = 1024*1024*1024;
    my ($total, $avail, $used) = split(" ", $jdssc);

    return ($total * $gb, $avail * $gb, $used * $gb, 1 );
}

# TODO: run here first volume list, so that everything would be activated
sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    print "Activate storage ${storeid}\n" if get_debug($scfg);

    return undef;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    print "Deactivating storage ${storeid}\n" if get_debug($scfg);

    return undef;
}


# Activates zvol related to given vm
sub vm_disk_connect {
    my ( $class, $storeid, $scfg, $vmdiskname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Activate vm disk ${vmdiskname}\n");

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target = $class->get_target_name($scfg, $vmdiskname, $snapname, 0);

    my $prefix = get_target_prefix($scfg);
    my $create_target_cmd = ["pool", $pool, "targets", "create", '--target-prefix', $prefix, "-v", $vmdiskname];
    if ($snapname){
        push @$create_target_cmd, "--snapshot", $snapname;
    }

    OpenEJovianDSS::Common::joviandss_cmd($scfg, $create_target_cmd, 80, 3);

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Staging target ${target}");
    $class->stage_target($scfg, $storeid, $target);

    my $updateudevadm = ['udevadm', 'trigger', '-t', 'all'];
    run_command($updateudevadm, errmsg => "Failed to update udev devices after iscsi target attachment");

    my $targetpath = $class->get_target_path($scfg, $target, $storeid);

    for (my $i = 1; $i <= 10; $i++) {
        last if (-e $targetpath);
        sleep(1);
    }

    unless (-e $targetpath) {
        die "Unable to confirm existance of volume at path ${targetpath}\n";
    }

    if (OpenEJovianDSS::Common::get_multipath($scfg)) {
        my $scsiid = $class->get_scsiid($scfg, $target, $storeid);
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "Adding multipath\n");
        if (defined($scsiid)) {
            my $multipathpath = $class->stage_multipath($storeid, $scfg, $scsiid, $target);
            run_command($updateudevadm, errmsg => "Failed to update udev devices after multipath creation");
            OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Activate vm disk ${vmdiskname} done. Created multipath device ${multipathpath}\n");

            return $multipathpath;
        } else {
            die "Unable to get scsi id for multipath device ${target}\n";
        }
    }
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Activate vm disk ${vmdiskname} done. Created iSCSI device ${targetpath}\n");

    return $targetpath;
}

# Activates zvol related to given vm to the level of iscsi
# This function will be called on nodes that use volume and not using it
# Because of it, vm_disk_iscsi_connect do not removes or reasign volumes to target
# It only creates new or operates on existing one
sub vm_disk_iscsi_connect {
    my ( $class, $storeid, $scfg, $vmdiskname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Activate vm disk ${vmdiskname}\n");

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target = $class->get_active_target_name(scfg => $scfg,
                                                volname => $vmdiskname,
                                                snapname => $snapname,
                                                content=>0);

    if (!defined($target)) {
        my $prefix = get_target_prefix($scfg);
        my $create_target_cmd = ["pool", $pool, "targets", "create", '--target-prefix', $prefix, "-v", $vmdiskname];
        if ($snapname){
            push @$create_target_cmd, "--snapshot", $snapname;
        }

        OpenEJovianDSS::Common::joviandss_cmd($scfg, $create_target_cmd, 80, 3);
    }
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Staging target ${target}");
    $class->stage_target($scfg, $storeid, $target);

    my $updateudevadm = ['udevadm', 'trigger', '-t', 'all'];
    run_command($updateudevadm, errmsg => "Failed to update udev devices after iscsi target attachment");

    my $targetpath = $class->get_target_path($scfg, $target, $storeid);

    for (my $i = 1; $i <= 10; $i++) {
        last if (-e $targetpath);
        sleep(1);
    }

    unless (-e $targetpath) {
        die "Unable to confirm existance of volume at path ${targetpath}\n";
    }

    return $targetpath;
}

# Disconnect zvol or its snapshot from proxmox server
sub vm_disk_disconnect {
    my ( $class, $storeid, $scfg, $vmdiskname, $snapshot, $cache ) = @_;
    # virtual machine format is vm-id
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Disconnect vm disk ${vmdiskname}".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapshot)." start");

    my $target = $class->get_active_target_name(scfg => $scfg,
                                                volname => $vmdiskname,
                                                snapname => $snapshot);
    unless (defined($target)) {
        $target = $class->get_target_name($scfg, $vmdiskname, undef);
    }

    $class->unstage_multipath($scfg, $storeid, $target) if OpenEJovianDSS::Common::get_multipath($scfg);
    $class->unstage_target($scfg, $storeid, $target);

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Disconnect vm disk ${vmdiskname}".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapshot)." done");
}

# Disconnect zvol from proxmox server
# along side with its snapshots related to it
sub vm_disk_disconnect_all {
    my ( $class, $storeid, $scfg, $vmdiskname, $cache ) = @_;
    # virtual machine format is vm-id
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Disconnect all resources for vm disk ${vmdiskname} start");

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $target = $class->get_active_target_name(scfg => $scfg,
                                                volname => $vmdiskname,
                                                snapname => undef);
    unless (defined($target)) {
        $target = $class->get_target_name($scfg, $vmdiskname, undef);
    }

    $class->unstage_multipath($scfg, $storeid, $target) if OpenEJovianDSS::Common::get_multipath($scfg);
    $class->unstage_target($scfg, $storeid, $target);

    # In order to remove volume with its snapshots we have to list active snapshots, the one with clones
    # and deactivate them
    my $snaps = OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, "delete", "-c", "-p"]);
    my @dsl = split(" ", $snaps);

    my $prefix = get_target_prefix($scfg);

    foreach my $snap (@dsl) {
        my $starget = $class->get_active_target_name(scfg => $scfg,
                                                     volname => $vmdiskname,
                                                     snapname => $snap);
        unless (defined($starget)) {
            $starget = $class->get_target_name($scfg, $vmdiskname, $snap);
        }
        $class->unstage_multipath($scfg, $storeid, $starget) if OpenEJovianDSS::Common::get_multipath($scfg);;

        $class->unstage_target($scfg, $storeid, $starget);

        OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "targets", "delete", '--target-prefix', $prefix, "-v", $vmdiskname, "--snapshot", $snap]);
    }
    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Disconnect all resources for vm disk ${vmdiskname} done");
}

# Disconnect zvol from proxmox server
# along side with its snapshots related to it
sub vm_disk_remove {
    my ( $class, $storeid, $scfg, $vmdiskname, $cache ) = @_;

    #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my $prefix = get_target_prefix($scfg);

    OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "targets", "delete", '--target-prefix', $prefix, "-v", $vmdiskname]);

    OpenEJovianDSS::Common::joviandss_cmd($scfg, ["pool", $pool, "volume", $vmdiskname, "delete", "-c"]);

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Remove vm disk ${vmdiskname} done.");
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Activate volume ${volname} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)." start");

    my ($vtype, $volume_name, $vmid, $basename, $basevmid, $isBase, $format) = $class->parse_volname($volname);

    return 0 if ('images' ne "$vtype");

    my $vmdiskname = $class->vm_disk_name($vmid, 0);

    my $device = $class->vm_disk_connect($storeid, $scfg, $vmdiskname, $snapname, $cache);

    if (!defined($device)) {
        die "Unable to connect disk ${volname}".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)."\n";
    }
    my $vmvgname = $class->vm_vg_name($vmid, $snapname);

    if ($snapname) {
        my $info;
        eval {  $info = vm_disk_vg_info($device, $vmvgname); };

        if ($@) {
            $info = vm_disk_lvm_info($device);
            my $cmd = ['/sbin/vgimportclone', '--basevgname', $vmvgname, '--devices', $device, '--nolocking', '-y', $info->{pvname}];
            run_command($cmd, errmsg => "Failed to import lvm clone of volume ${vmdiskname} from snapshot ${snapname}", outfunc => sub {});
        }
    }

    my $pvscan = ['/sbin/pvscan'];
    run_command($pvscan, errmsg => "Failed to scan lvm persistent volumes", outfunc => sub {});

    my $vgscan = ['/sbin/vgscan'];
    run_command($pvscan, errmsg => "Failed to scan lvm volume groups", outfunc => sub {});

    my $lvm_activate_mode = 'ey';

    my $cmd = ['/sbin/lvchange', '--devices', $device, "-a$lvm_activate_mode", "${vmvgname}/${volname}"];
    run_command($cmd, errmsg => "Failed to activate lv ${vmvgname}/${volname}");

    $cmd = ['/sbin/lvchange', '--devices', $device, '--refresh', "${vmvgname}/${volname}"];
    run_command($cmd, errmsg => "Failed to refresh lv ${vmvgname}/${volname}");

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Activate volume ${volname}".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)." done");

    return 1;
}


sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Deactivate volume ${volname} ".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)."start");
    my $pool = get_pool($scfg);

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    return 0 if ('images' ne "$vtype");

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Deactivate volume ${volname}".OpenEJovianDSS::Common::safe_var_print("snapshot", $snapname)."done");


    # We do not delete target on joviandss as this will lead to race condition
    # in case of migration

    # This is a temporarely deactivation logic
    # We remove multipath device and logout of iscsi targets becaue there is no other way to guarantee
    # multipath deactivation if volume was migrated and deleted on other host

    my $activepresent = 0;
    my $notinactivepresent = 0;
    my $vmdiskname = $class->vm_disk_name($vmid, 0);
    my $vmvgname = $class->vm_vg_name($vmid, undef);

    my $device = $class->block_device_path($scfg, $vmdiskname, $storeid, undef, 0);

    my $vols =  $class->vm_disk_list_volumes($scfg, $device);

    my $cmd = ['/sbin/lvchange', '--devices', $device, '-aln', "${vmvgname}/${volname}"];
    run_command($cmd, errmsg => "can't deactivate LV '${vmvgname}/${volname}'", noerr=>1);

    foreach my $vol (@$vols){
        #TODO: recheck this construction
        if ($vol->{lvattr}){
            my $attr = $vol->{lvattr};
            my $flag = substr($attr, 4, 1);

            if ($flag ne 'i') {
                $notinactivepresent = 1;
            }
            if ($flag eq 'a') {
                $activepresent = 1;
            }
        }
    }
    if ($activepresent == 0 && $notinactivepresent == 0) {
        $class->vm_disk_disconnect_all($storeid, $scfg, $vmdiskname, undef);
    }

    return 1;
}

sub update_block_device {
    my ( $class, $storeid, $scfg, $vmdiskname, $expectedsize) = @_;

    my @update_device_try = (1..10);
    foreach(@update_device_try){

        my $target = $class->get_target_name($scfg, $vmdiskname, undef, 0);

        my $tpath = $class->get_target_path($scfg, $target, $storeid);

        my $bdpath;
        eval {run_command(["readlink", "-f", $tpath], outfunc => sub { $bdpath = shift; }); };

        $bdpath = OpenEJovianDSS::Common::clean_word($bdpath);
        my $block_device_name = basename($bdpath);
        unless ($block_device_name =~ /^[a-z0-9]+$/) {
            die "Invalide block device name ${block_device_name} for iscsi target ${target}\n";
        }
        my $rescan_file = "/sys/block/${block_device_name}/device/rescan";
        open my $fh, '>', $rescan_file or die "Cannot open $rescan_file $!";
        print $fh "1" or die "Cannot write to $rescan_file $!";
        close $fh or die "Cannot close ${rescan_file} $!";

        eval{ run_command([$ISCSIADM, '-m', 'node', '-R', '-T', ${target}], outfunc => sub {}); };

        my $updateudevadm = ['udevadm', 'trigger', '-t', 'all'];
        run_command($updateudevadm, errmsg => "Failed to update udev devices after iscsi target attachment");

        if (OpenEJovianDSS::Common::get_multipath($scfg)) {
            my $multipath_device_path = $class->get_multipath_path($storeid, $scfg, $target);
            eval{ run_command([$MULTIPATH, '-r', ${multipath_device_path}], outfunc => sub {}); };
        }

        $bdpath = $class->block_device_path($scfg, $vmdiskname, $storeid, undef);

        sleep(1);

        my $updated_size;
        run_command(['/sbin/blockdev', '--getsize64', $bdpath], outfunc => sub {
            my ($line) = @_;
            die "unexpected output from /sbin/blockdev: $line\n" if $line !~ /^(\d+)$/;
            $updated_size = int($1);
        });

        if ($expectedsize) {
            if ($updated_size eq $expectedsize) {
                last;
            }
        } else {
            last;
        }
        sleep(1);
    }

}

sub update_vm_disk {
    my ( $class, $storeid, $scfg, $vmdiskname) = @_;

    $class->update_block_device($storeid, $scfg, $vmdiskname);

}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

   #my $config = get_config($scfg);
    my $pool = get_pool($scfg);

    my ($vtype, $volume_name, $vmid, $basename, $basedvmid, $isBase, $format) = $class->parse_volname($volname);

    my $vmdiskname = $class->vm_disk_name($vmid, 0);
    my $vmvgname = $class->vm_vg_name($vmid);

    my $device = $class->vm_disk_connect($storeid, $scfg, $vmdiskname, undef, undef);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug", "VM disk ${vmdiskname} is connected to ${device}\n");

    my $vginfo = vm_disk_vg_info($device, $vmvgname);

    # get zvol size
    my $vmdisksize = $class->vm_disk_size($scfg, $vmdiskname);


    # check if zvol size is not different from LVM size
    # that should handle cases of failure during volume resizing
    # when lvm data was not updated properly
    if ( abs($vmdisksize - $vginfo->{vgsize}) <= 0.01 * abs($vmdisksize) ) {
        print("vmdisk size ${vmdisksize} vgs " . $vginfo->{vgsize} . "vgs free size " . $vginfo->{vgfree} . "\n") if get_debug($scfg);
        $class->vm_disk_lvm_update($storeid, $scfg, $vmdiskname, $device, $vmdisksize);
        $vginfo = vm_disk_vg_info($device, $vmvgname);
    }

    if ($vginfo->{vgfree} < $size) {
        my $newvolsize = 0;
        $newvolsize = $size - $vginfo->{vgfree} + $vmdisksize;
        $class->vm_disk_extend_to($storeid, $scfg, $vmdiskname, $device, $newvolsize);
        $class->vm_disk_lvm_update($storeid, $scfg, $vmdiskname, $device, $vmdisksize);
    }

    my $path = $class->path($scfg, $volname);

    my $lvextendcmd = ['/sbin/lvextend', '-L', "${size}B", $path];

    run_command($lvextendcmd, errmsg => "Unable to extend volume ${volname} to size ${size}B");

    OpenEJovianDSS::Common::debugmsg($scfg, "debug", "Resize volume ${volname} to size ${size} done");

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
