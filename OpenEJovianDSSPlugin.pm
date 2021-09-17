package PVE::Storage::Custom::OpenEJovianDSSPlugin;

use strict;
use warnings;
use Carp qw( confess );
use IO::File;
use JSON::XS qw( decode_json );
use Data::Dumper;
use REST::Client;
use Storable qw(lock_store lock_retrieve);
use UUID "uuid";

use Encode qw(decode encode);

use PVE::Tools qw(run_command trim);
use PVE::INotify;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

my $PLUGIN_VERSION = '0.4.1';

# Configuration

my $default_joviandss_address = "192.168.0.100";
my $default_pool = "Pool-0";
my $default_config = "/etc/pve/joviandss.cfg";

sub api {
   # PVE 5: APIVER 2
   # PVE 6: APIVER 3
   # PVE 6: APIVER 4 e6f4eed43581de9b9706cc2263c9631ea2abfc1a / volume_has_feature
   # PVE 6: APIVER 5 a97d3ee49f21a61d3df10d196140c95dde45ec27 / allow rename
   # PVE 6: APIVER 6 8f26b3910d7e5149bfa495c3df9c44242af989d5 / prune_backups (fine, we don't support that content type)
   # PVE 6: APIVER 7 2c036838ed1747dabee1d2c79621c7d398d24c50 / volume_snapshot_needs_fsfreeze (guess we are fine, upstream only implemented it for RDBPlugin; we are not that different to let's say LVM in this regard)
   # PVE 6: APIVER 8 343ca2570c3972f0fa1086b020bc9ab731f27b11 / prune_backups (fine again, see APIVER 6)
   #
   # we support all (not all features), we just have to be careful what we return
   # as for example PVE5 would not like a APIVER 3

   my $apiver = PVE::Storage::APIVER;

   if ($apiver >= 2 and $apiver <= 8) {
      return $apiver;
   }

   return 3;
}

# we have to name it drbd, there is a hardcoded 'drbd' in Plugin.pm
sub type {
    return 'open-e';
}

sub plugindata {
    return {
	content => [ {images => 1}, { images => 1 }],
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
    };
}

sub options {
    return {
        joviandss_address  => { optional => 1 },
        pool_name        => { optional => 1 },
        config        => { optional => 1 },
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

sub filesystem_path {
    my ($class, $scfg, $volname, $snapname) = @_;

    #die "get filesystem path $volname | $snapname";

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", $volname, "get", "--host", "--lun" or
        die "jcli failed: $!\n";
 
    my $path = "";

    while (<$jcli>) {
      my ($target, $host, $lun) = split;
      $path =  "iscsi://$host/$target/$lun";
    }
    close $jcli;

    return wantarray ? ($path, $vmid, $vtype) : $path;
}
sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    
    #die "get path $volname | $storeid | $snapname";

    die "direct access to snapshots not implemented"
	if defined($snapname);

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    
    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", $volname, "get", "--host", "--lun" or
        die "jcli failed: $!\n";
 
    my $path = "";

    while (<$jcli>) {
      my ($target, $host, $lun) = split;
        $path =  "iscsi://$host/$target/$lun";
        last;
    }
    close $jcli;
    #$path = decode('UTF-8', $path);
    #print $path;
    #print "Get path";
    #print "iscsi://172.16.0.220/iqn.2020-04.com.open-e.cinder:vm-101-cdb52cd73a1345dd890207fe64075d88/0";
    #die "error $path"
    #if $path ne "iscsi://172.16.0.220/iqn.2020-04.com.open-e.cinder:vm-101-cdb52cd73a1345dd890207fe64075d88/0";
    #        iscsi://172.16.0.220/iqn.2020-04.com.open-e.cinder:vm-101-cdb52cd73a1345dd890207fe64075d88/0
    #$path = "iscsi://172.16.0.220/iqn.2020-04.com.open-e.cinder:vm-101-cdb52cd73a1345dd890207fe64075d88/0";

    return ($path, $vmid, $vtype);
}

sub get_subdir {
    my ($class, $scfg, $vtype) = @_;

    return undef;
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;

    die "can't create base images in Open-E JovianDSS storage\n";
}

sub clone_image {
    my ($class, $scfg, $storeid, $volname, $vmid, $snap) = @_;

    die "$class, $scfg, $storeid, $volname, $vmid, $snap ";

    die "can't clone images in drbd storage\n";
}

sub alloc_image {
    my ( $class, $storeid, $scfg, $vmid, $fmt, $name, $size ) = @_;

    my $volume_name;

    if ( !defined($name) ) {
        my $uuid = uuid();
        $uuid =~ tr/-//d;
        $volume_name = "vm-$vmid-$uuid";
    } else {
        $volume_name = "vm-$vmid-$name";
    }

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    open my $jcli, '-|' or 
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes", "create", "-s", $size * 1024, $volume_name or
        die "jcli failed: $!\n";
    close $jcli;

    return "$volume_name";
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    #remove associated target before removing volume
    open my $jclidelete, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", $volname, "delete"; 
 
    open my $jcli, '-|' or 
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes", $volname, "delete", "-c" or
        die "jcli failed: $!\n";
    close $jcli;
    return undef;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $nodename = PVE::INotify::nodename();

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes", "list", "--vmid" or
        die "jcli failed: $!\n";
 
    my $res = [];


    while (<$jcli>) {
      my ($volname,$vmid,$size) = split;
      #print "$uid $pid $ppid\n "
      my $volid = "joviandss:$volname";
      #die $volid;
      push @$res, {
          format => 'raw',
          volid  => $volid,
          size   => $size,
          vmid   => $vmid,
        };
    }
    close $jcli;
   
    # TODO: delete this comment section
    # its purpouse is to store means of debuging
    #my $i = 1;
    #while ( (my @call_details = (caller($i++))) ){
    #    print STDERR $call_details[1].":".$call_details[2]." in function ".$call_details[3]."\n";
    #}
    #foreach my $hash (@$res) {
    #    print "$hash->{'volid'}\n";
    #}
    return $res;
}

sub volume_snapshot {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    
    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    
    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes", $volname, "snapshots", "create", $snap or
        die "jcli failed: $!\n";
 
    close $jcli;

}

sub volume_snapshot_rollback {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;
    
    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes", $volname, "snapshots", $snap, "rollback" or
        die "jcli failed: $!\n";
 
    close $jcli;
}

sub volume_snapshot_delete {
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes", $volname, "snapshots", $snap, "delete" or
        die "jcli failed: $!\n";
 
    close $jcli;
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    open my $jcli, '-|' or 
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volume", "$volname", "snapshot", "list" or
        die "jcli failed: $!\n";

    my $res = [];
 
    while (<$jcli>) {
      my ($sname) = split;
      #print "$uid $pid $ppid\n "
      push @$res, { 'name' => '$sname'};
    }
    #die "volume snapshot list: snapshot not implemented ($snapname)\n" if $snapname;
    return $res
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    open my $jcli, '-|' or 
        exec "jcli", "-p", "-c", $config, "pool", $pool, "get" or
        die "jcli failed: $!\n";

    my $total = "";
    my $used = "";
    my $avail = "";
    my $gb = 1024*1024*1024;
    while (<$jcli>) {
      ($total, $avail, $used) = split;
    }
    return ($total * $gb, $avail * $gb, $used * $gb, 1 );
}

sub activate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    return undef;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    return undef;
}

sub activate_volume {
    my ( $class, $storeid, $scfg, $volname, $snap, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};
    print "Activate volume $volname";
    
    #my $i = 1;
    #while ( (my @call_details = (caller($i++))) ){
    #    print STDERR $call_details[1].":".$call_details[2]." in function ".$call_details[3]."\n";
    #}
    #foreach my $hash (@$res) {
    #    print "$hash->{'volid'}\n";
    #}

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", "create", $volname or
        die "jcli failed: $!\n";
 
    close $jcli;
    #die "Volume activate call with arguments $volname, $snap, $cache";

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};
    print "Deactivate volume $volname";

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    
    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", $volname, "delete" or
        die "jcli failed: $!\n";
    
    close $jcli;
    #die "Volume deactivate call with arguments $volname, $snapname, $cache";
    #die "Activating volume $volname";
    return 1;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    #my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes",
                $volname, "resize", $size or
        die "jcli failed: $!\n";
 
    close $jcli;

    return 1;
}

sub parse_volname {
    my ($class, $volname) = @_;

    if ($volname =~ m/^((\S+):vm-(\d+)-(\S+))?(vm-(\d+)-(\S+))$/) {
	return ('images', $2, $1, undef, undef, 'current', 'raw');
    }

    die "unable to parse joviandss volume name '$volname'\n";
}

sub volume_has_feature {
    my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) =
      @_;

    my $features = {
	    snapshot => { base => 1, current => 1, snap => 1 },
	    clone => { base => 1, current => 1, snap => 1, images => 1},
	    template => { current => 1 },
	    copy => { snap => 1 },
	    #copy => { base => 1, current => 1, snap => 1},
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

# Export a volume into a file handle as a stream of desired format.
sub volume_export {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots) = @_;

    die "Volume export call with arguments $fh, $volname, $format, $snapshot, $base_snapshot, $with_snapshots";

#    if ($scfg->{path} && !defined($snapshot) && !defined($base_snapshot)) {
#	my $file = $class->path($scfg, $volname, $storeid)
#	    or goto unsupported;
#	my ($size, $file_format) = file_size_info($file);
#
#	if ($format eq 'raw+size') {
#	    goto unsupported if $with_snapshots || $file_format eq 'subvol';
#	    write_common_header($fh, $size);
#	    if ($file_format eq 'raw') {
#		run_command(['dd', "if=$file", "bs=4k"], output => '>&'.fileno($fh));
#	    } else {
#		run_command(['qemu-img', 'convert', '-f', $file_format, '-O', 'raw', $file, '/dev/stdout'],
#		            output => '>&'.fileno($fh));
#	    }
#	    return;
#	} elsif ($format =~ /^(qcow2|vmdk)\+size$/) {
#	    my $data_format = $1;
#	    goto unsupported if !$with_snapshots || $file_format ne $data_format;
#	    write_common_header($fh, $size);
#	    run_command(['dd', "if=$file", "bs=4k"], output => '>&'.fileno($fh));
#	    return;
#	} elsif ($format eq 'tar+size') {
#	    goto unsupported if $file_format ne 'subvol';
#	    write_common_header($fh, $size);
#	    run_command(['tar', @COMMON_TAR_FLAGS, '-cf', '-', '-C', $file, '.'],
#	                output => '>&'.fileno($fh));
#	    return;
#	}
#    }
# unsupported:
#    die "volume export format $format not available for $class";
}

sub volume_export_formats {
    my ($class, $scfg, $storeid, $volname, $snapshot, $base_snapshot, $with_snapshots) = @_;
    if ($scfg->{path} && !defined($snapshot) && !defined($base_snapshot)) {
	my $file = $class->path($scfg, $volname, $storeid)
	    or return;
	my ($size, $format) = file_size_info($file);

	if ($with_snapshots) {
	    return ($format.'+size') if ($format eq 'qcow2' || $format eq 'vmdk');
	    return ();
	}
	return ('tar+size') if $format eq 'subvol';
	return ('raw+size');
    }
    return ();
}

# Import data from a stream, creating a new or replacing or adding to an existing volume.
sub volume_import {
    my ($class, $scfg, $storeid, $fh, $volname, $format, $base_snapshot, $with_snapshots, $allow_rename) = @_;

    die "volume import format '$format' not available for $class\n";
	#if $format !~ /^(raw|tar|qcow2|vmdk)\+size$/;
    #my $data_format = $1;

    #die "format $format cannot be imported without snapshots\n"
	#if !$with_snapshots && ($data_format eq 'qcow2' || $data_format eq 'vmdk');
    #die "format $format cannot be imported with snapshots\n"
	#if $with_snapshots && ($data_format eq 'raw' || $data_format eq 'tar');

    #my ($vtype, $name, $vmid, $basename, $basevmid, $isBase, $file_format) =
	#$class->parse_volname($volname);

    ## XXX: Should we bother with conversion routines at this level? This won't
    ## happen without manual CLI usage, so for now we just error out...
    #die "cannot import format $format into a file of format $file_format\n"
	#if $data_format ne $file_format && !($data_format eq 'tar' && $file_format eq 'subvol');

    ## Check for an existing file first since interrupting alloc_image doesn't
    ## free it.
    #my $file = $class->path($scfg, $volname, $storeid);
    #if (-e $file) {
	#die "file '$file' already exists\n" if !$allow_rename;
	#warn "file '$file' already exists - importing with a different name\n";
	#$name = undef;
    #}

    #my ($size) = read_common_header($fh);
    #$size = int($size/1024);

    #eval {
	#my $allocname = $class->alloc_image($storeid, $scfg, $vmid, $file_format, $name, $size);
	#my $oldname = $volname;
	#$volname = $allocname;
	#if (defined($name) && $allocname ne $oldname) {
	#    die "internal error: unexpected allocated name: '$allocname' != '$oldname'\n";
	#}
	#my $file = $class->path($scfg, $volname, $storeid)
	#    or die "internal error: failed to get path to newly allocated volume $volname\n";
	#if ($data_format eq 'raw' || $data_format eq 'qcow2' || $data_format eq 'vmdk') {
	#    run_command(['dd', "of=$file", 'conv=sparse', 'bs=64k'],
	#                input => '<&'.fileno($fh));
	#} elsif ($data_format eq 'tar') {
	#    run_command(['tar', @COMMON_TAR_FLAGS, '-C', $file, '-xf', '-'],
	#                input => '<&'.fileno($fh));
	#} else {
	#    die "volume import format '$format' not available for $class";
	#}
    #};
    #if (my $err = $@) {
	#eval { $class->free_image($storeid, $scfg, $volname, 0, $file_format) };
	#warn $@ if $@;
	#die $err;
    #}

    return "$storeid:$volname";
}

sub volume_import_formats {
    my ($class, $scfg, $storeid, $volname, $base_snapshot, $with_snapshots) = @_;
    if ($scfg->{path} && !defined($base_snapshot)) {
	my $format = ($class->parse_volname($volname))[6];
	if ($with_snapshots) {
	    return ($format.'+size') if ($format eq 'qcow2' || $format eq 'vmdk');
	    return ();
	}
	return ('tar+size') if $format eq 'subvol';
	return ('raw+size');
    }
    return ();
}
1;
# vim: set et sw=4 :
