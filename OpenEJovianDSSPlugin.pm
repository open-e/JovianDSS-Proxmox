package PVE::Storage::Custom::OpenEJovianDSSPlugin;

use strict;
use warnings;
use Carp qw( confess );
use IO::File;
use JSON::XS qw( decode_json );
use Data::Dumper;
use REST::Client;
use Storable qw(lock_store lock_retrieve);

use LINBIT::Linstor;
use LINBIT::PluginHelper;

use PVE::Tools qw(run_command trim);
use PVE::INotify;
use PVE::Storage;
use PVE::Storage::Plugin;
use PVE::JSONSchema qw(get_standard_option);

use base qw(PVE::Storage::Plugin);

my $PLUGIN_VERSION = '0.0.1';

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
    return { content => [ { images => 1, rootdir => 1 }, { images => 1 } ], };
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
# check if connection is working
# and return cli object
sub linstor {
    my ($scfg) = @_;

    my @controllers = split( /,/, get_joviandss_address($scfg) );

    foreach my $controller (@controllers) {
        $controller = trim($controller);
        my $cli = REST::Client->new( { host => "http://${controller}:3370" } );
        $cli->addHeader('User-Agent', 'linstor-proxmox/' . $PLUGIN_VERSION);
        return LINBIT::Linstor->new( { cli => $cli } )
          if $cli->GET('/health')->responseCode() eq '200';
   }

    die("could not connect to any LINSTOR controller");
}

sub get_storagepool {
    my ($scfg) = @_;

    my $res_grp = get_resource_group($scfg);

    my $sp = linstor($scfg)->get_storagepool_for_resource_group($res_grp);
    die "Have resource group, but storage pool is undefined for resource group $res_grp"
      unless defined($sp);
    return $sp;
}

sub get_dev_path {
    return "/dev/drbd/by-res/$_[0]/0";
}


# Storage implementation
#
# For APIVER 2
sub map_volume {
    my ( $class, $storeid, $scfg, $volname, $snap ) = @_;

    $volname = volname_and_snap_to_snapname( $volname, $snap ) if defined($snap);

    return get_dev_path "$volname";
}

# For APIVER 2
sub unmap_volume {
    return 1;
}

sub parse_volname {
    my ( $class, $volname ) = @_;

    if ( $volname =~ m/^(vm-(\d+)-[a-z][a-z0-9\-\_\.]*[a-z0-9]+)$/ ) {
        return ( 'images', $1, $2, undef, undef, undef, 'raw' );
    }

    die "unable to parse lvm volume name '$volname'\n";
}

sub filesystem_path {
    my ( $class, $scfg, $volname, $snapname ) = @_;

    die "filesystem_path: snapshot is not implemented ($snapname)\n" if defined($snapname);

    my ( $vtype, $name, $vmid ) = $class->parse_volname($volname);

    my $path = get_dev_path "$volname";

    return wantarray ? ( $path, $vmid, $vtype ) : $path;
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

    # check if it is the controller, which always has exactly "disk-1"
    my $retname = $name;
    if ( !defined($name) ) {
        $retname = "vm-$vmid-disk-1";
    }
    return $retname if ignore_volume( $scfg, $retname );

    die "unsupported format '$fmt'" if $fmt ne 'raw';

    die "illegal name '$name' - should be 'vm-$vmid-*'\n"
      if defined($name) && $name !~ m/^vm-$vmid-/;

    my $lsc       = linstor($scfg);
    my $resources = $lsc->get_resources();

    die "volume '$name' already exists\n"
      if defined($name) && exists $resources->{$name};

    if ( !defined($name) ) {
        for ( my $i = 1 ; $i < 100 ; $i++ ) {
            my $tn = "vm-$vmid-disk-$i";
            if ( !exists( $resources->{$tn} ) ) {
                $name = $tn;
                last;
            }
        }
    }

    die "unable to allocate an image name for VM $vmid in storage '$storeid'\n"
      if !defined($name);

    eval {
        my $res_grp         = get_joviandss_address($scfg);
        my $local_node_name = get_pool($scfg);
        if ( defined($local_node_name) ) {
            print "\nNOTICE\n"
              . "  Trying to create diskful resource ($name) on ($local_node_name).\n";
        }
        $lsc->create_resource( $name, $size, $res_grp, $local_node_name );
    };
    confess $@ if $@;

    return $name;
}

sub free_image {
    my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;

   # die() does not really help in that case, the VM definition is still removed
   # so we could just return undef, still this looks a bit cleaner
    die "Not freeing contoller VM" if ignore_volume( $scfg, $volname );

    my $lsc = linstor($scfg);
    my $in_use = 1;

    foreach (0..9) {
      my $resources = $lsc->update_resources();
      $in_use = $resources->{$volname}->{in_use};
      last if (! $in_use);
      sleep(1);
    }

    warn "Resource $volname still in use after giving it some time" if ($in_use);

    # yolo, what else should we do...
    eval { $lsc->delete_resource($volname); };
    confess $@ if $@;

    return undef;
}

sub list_images {
    my ( $class, $storeid, $scfg, $vmid, $vollist, $cache ) = @_;

    my $nodename = PVE::INotify::nodename();

    my $touch = qx/touch \/tmp\/test-file/;
    #print "$class"
    print "class";
    #print "$storeid"

    #my $res = [];
    #open(PS_F, "ps -f|");
    #
    #while (<PS_F>) {
    #  ($uid,$pid,$ppid,$restOfLine) = split;
    #  print "$uid $pid $ppid\n "
    #  push @$res,
    #    {
    #      format => 'raw',
    #      volid  => 'some_id', #$volid,
    #      size   => 1024, #$size_kib * 1024,
    #      vmid   => 1, #$owner,
    #    };
    #  # do whatever I want with the variables here ...
    #}
    #
    #close(PS_F);
     
    my $res = [];
    push @$res,
      {
        format => 'raw',
        volid  => 'some_id', #$volid,
        size   => 1024, #$size_kib * 1024,
        vmid   => 1, #$owner,
      };

    return $res;
    die("running list_images");

    $cache->{"linstor:resources"} = linstor($scfg)->get_resources()
      unless $cache->{"linstor:resources"};
    $cache->{"linstor:sp"} = get_storagepool($scfg)
      unless $cache->{"linstor:sp"};

    # TODO:
    # Currently we have/expect one resource per volume per proxmox disk image,
    # we do not (yet) use or expect multi-volume resources, even thought it may
    # be useful to have all vm images in one "consistency group".

    my $resources = $cache->{"linstor:resources"};
    my $sp = $cache->{"linstor:sp"};

    return LINBIT::PluginHelper::get_images( $storeid, $vmid, $vollist,
        $resources, $nodename, $sp );
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    my $nodename = PVE::INotify::nodename();

    # they want it in bytes
    my $total = 1024;
    my $avail = 1024;
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

    return undef if ignore_volume( $scfg, $volname );

    if ($snap) {    # need to create this resource from snapshot
        my $snapname = volname_and_snap_to_snapname( $volname, $snap );
        my $new_volname = $snapname;
        eval { linstor($scfg)->restore_snapshot( $volname, $snapname, $new_volname ); };
        confess $@ if $@;
        $volname = $new_volname; # for the rest of this function switch the name
    }

    my $nodename = PVE::INotify::nodename();

    eval { linstor($scfg)->activate_resource( $volname, $nodename ); };
    confess $@ if $@;

    system ('blockdev --setrw ' . get_dev_path $volname);

    return undef;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    die "deactivate_volume: snapshot not implemented ($snapname)\n" if $snapname;

    return undef if ignore_volume( $scfg, $volname );

    my $nodename = PVE::INotify::nodename();

# deactivate_resource only removes the assignment if diskless, so this could be a single call.
# We do all this unnecessary dance to print the NOTICE.
    my $lsc = linstor($scfg);
    my $was_diskless_client =
      $lsc->resource_exists_intentionally_diskless( $volname, $nodename );

    if ($was_diskless_client) {
        print "\nNOTICE\n"
          . "  Intentionally removing diskless assignment ($volname) on ($nodename).\n"
          . "  It will be re-created when the resource is actually used on this node.\n";

        eval { $lsc->deactivate_resource( $volname, $nodename ); };
        confess $@ if $@;
    }

    return undef;
}

sub volume_resize {
    my ( $class, $scfg, $storeid, $volname, $size, $running ) = @_;

    my $size_kib = ( $size / 1024 );

    eval { linstor($scfg)->resize_resource( $volname, $size_kib ); };
    confess $@ if $@;

    # TODO: remove, temporary fix for non-synchronous LINSTOR resize
    sleep(10);

    return 1;
}

sub volume_snapshot {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $snapname = volname_and_snap_to_snapname( $volname, $snap );

    eval { linstor($scfg)->create_snapshot( $volname, $snapname ); };
    confess $@ if $@;

    return 1;
}

sub volume_snapshot_rollback {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;

    my $snapname = volname_and_snap_to_snapname( $volname, $snap );

    eval { linstor($scfg)->rollback_snapshot( $volname, $snapname ); };
    confess $@ if $@;

    return 1;
}

sub volume_snapshot_delete {
    my ( $class, $scfg, $storeid, $volname, $snap ) = @_;
    my $snapname = volname_and_snap_to_snapname( $volname, $snap );

    my $lsc = linstor($scfg);

    # on backup we created a resource from the given snapshot
    # on cleanup we as plugin only get a volume_snapshot_delete
    # so we have to do some "heuristic" to also clean up the resource we created
    if ( $snap eq 'vzdump' ) {
        eval { $lsc->delete_resource( $snapname ); };
        confess $@ if $@;
    }

    eval { $lsc->delete_snapshot( $volname, $snapname ); };
    confess $@ if $@;

    return 1;
}

sub volume_has_feature {
    my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) =
      @_;

    my $features = {
        copy     => { base    => 1, current => 1 },
        snapshot => { current => 1 },
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
