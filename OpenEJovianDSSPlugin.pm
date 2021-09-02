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


sub get_storagepool {
    my ($scfg) = @_;

    my $res_grp = get_resource_group($scfg);

    my $sp = linstor($scfg)->get_storagepool_for_resource_group($res_grp);
    die "Have resource group, but storage pool is undefined for resource group $res_grp"
      unless defined($sp);
    return $sp;
}

#sub get_dev_path {
#    return "/dev/drbd/by-res/$_[0]/0";
#}


# Storage implementation
#
# For APIVER 2
#sub map_volume {
#    my ( $class, $storeid, $scfg, $volname, $snap ) = @_;
#
#    $volname = volname_and_snap_to_snapname( $volname, $snap ) if defined($snap);
#
#    return get_dev_path "$volname";
#}
#
## For APIVER 2
#sub unmap_volume {
#    return 1;
#}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    
    die "get path $volname | $storeid | $snapname";

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
    }
    close $jcli;

    return ($path, $vmid, $vtype);
}

sub get_subdir {
    my ($class, $scfg, $vtype) = @_;

    return undef;
}

sub create_base {
    my ( $class, $storeid, $scfg, $volname ) = @_;

    die "can't create base images in drbd storage\n";
}

sub clone_image {
    my ( $class, $scfg, $storeid, $volname, $vmid, $snap ) = @_;

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

    #open(LIST_VOLUMES, "jcli -p -c $config pool $pool volume delete $volname|");
    
    open my $jcli, '-|' or 
        exec "jcli", "-p", "-c", $config, "pool", $pool, "volumes", $volname, "delete" or
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
    my $nodename = PVE::INotify::nodename();

    # they want it in bytes
    my $total = 1024;
    my $avail = 1024*1024*1024;
    return ( $total, $avail, $total - $avail, 1 );
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

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    
    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", "create", $volname or
        die "jcli failed: $!\n";
 
    close $jcli;

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    
    open my $jcli, '-|' or
        exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", $volname, "delete" or
        die "jcli failed: $!\n";
    
    close $jcli;
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
	return ('images', $2, $1, undef, undef, undef, 'raw');
    }

    die "unable to parse joviandss volume name '$volname'\n";
}

sub volume_has_feature {
    my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) =
      @_;

    my $features = {
	    snapshot => { current => { raw => 1, qcow2 => 1}, snap => { raw => 1, qcow => 1} },
	    clone => { base => { qcow2 => 1, raw => 1, vmdk => 1} },
	    template => { current => 1},
	    copy => { base => 1, current => 1},
	    sparseinit => { base => {qcow2 => 1, raw => 1, vmdk => 1},
			current => {qcow2 => 1, raw => 1, vmdk => 1} },
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
