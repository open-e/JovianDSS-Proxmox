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

my $PLUGIN_VERSION = '0.7.4';

# Configuration

my $default_joviandss_address = "192.168.0.100";
my $default_pool = "Pool-0";
my $default_config = "/etc/pve/joviandss.cfg";
my $default_debug = 0;

sub api {

   my $apiver = PVE::Storage::APIVER;

   if ($apiver >= 3 and $apiver <= 9) {
      return $apiver;
   }

   return 6;
}

sub type {
    return 'open-e';
}

sub plugindata {
    return {
    content => [ { images => 1, rootdir => 1, vztmpl => 0, iso => 0, backup => 0, snippets => 0, none => 1 },
             { images => 1,  rootdir => 1 }],
    # TODO: check subvol and add to supported formats
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
    };
}

sub options {
    return {
        joviandss_address  => { optional => 1 },
        pool_name        => { optional => 1 },
        config        => { fixed => 1 },
        debug       => { optional => 1},
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

sub joviandss_cmd {
    my ($class, $cmd, $outfunc) = @_;

    my $msg = '';
    my $func;
    if (defined($outfunc)) {
	$func = sub {
	    my $part = &$outfunc(@_);
	    $msg .= $part if defined($part);
	};
    } else {
	$func = sub { $msg .= "$_[0]\n" };
    }
    run_command(['/usr/local/bin/jdssc', @$cmd], errmsg => 'joviandss error', outfunc => $func);

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

#sub filesystem_path {
#    my ($class, $scfg, $volname, $snapname) = @_;
#
#    #die "get filesystem path $volname | $snapname";
#
#    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
#
#    my $config = $scfg->{config};
#
#    my $pool = $scfg->{pool_name};
#
#    open my $jcli, '-|' or
#        exec "jdssc", "-p", "-c", $config, "pool", $pool, "targets", $volname, "get", "--host", "--lun" or
#        die "jdssc failed: $!\n";
#
#    my $path = "";
#
#    while (<$jcli>) {
#      my ($target, $host, $lun) = split;
#      $path =  "iscsi://$host/$target/$lun";
#    }
#    close $jcli;
#
#    return wantarray ? ($path, $vmid, $vtype) : $path;
#}

sub path {
    my ($class, $scfg, $volname, $storeid, $snapname) = @_;
    
    #die "get path $volname | $storeid | $snapname";

    #die "direct access to snapshots not implemented"
	#if defined($snapname);

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

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

#TODO: implement this for iso and backups
sub get_subdir {
    my ($class, $scfg, $vtype) = @_;

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
    #TODO: implement cloning from snapshot
    #die "Cloning from snapshot is not supported yet" if $snap;
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
    my ( $class, $storeid, $scfg, $volname, $isBase ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    #print"Abort volume removal";
    #return undef;
    #remove associated target before removing volume
    #$class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "delete"]);
    $class->deactivate_volume($storeid, $scfg, $volname, '', '');
 
    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "delete", "-c"]);
    return undef;
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

    open my $jdssc, '-|' or
        exec "/usr/local/bin/jdssc", "-p", "-c", $config, "pool", $pool, "volumes", "list", "--vmid" or
        die "jdssc failed: $!\n";
 
    my $res = [];

    while (<$jdssc>) {
        my ($volname,$vm,$size) = split;
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
    close $jdssc;

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
    my ($class, $scfg, $storeid, $volname, $snap) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "snapshots", $snap, "delete"]);
}

sub volume_snapshot_list {
    my ($class, $scfg, $storeid, $volname) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};


    open my $jcli, '-|' or 
        exec "/usr/local/bin/jdssc", "-p", "-c", $config, "pool", $pool, "volume", "$volname", "snapshot", "list" or
        die "jdssc failed: $!\n";

    my $res = [];
 
    while (<$jcli>) {
      my ($sname) = split;
      #print "$uid $pid $ppid\n "
      push @$res, { 'name' => '$sname'};
    }
    #die "volume snapshot list: snapshot not implemented ($snapname)\n" if $snapname;
    return $res
}

sub volume_size_info {
    my ($class, $scfg, $storeid, $volname, $timeout) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    my $size = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "get", "-s"]);
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    return $size;
}

sub status {
    my ( $class, $storeid, $scfg, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};

    open my $jcli, '-|' or 
        exec "/usr/local/bin/jdssc", "-p", "-c", $config, "pool", $pool, "get" or
        die "jdssc failed: $!\n";

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
    
    #my $i = 1;
    #while ( (my @call_details = (caller($i++))) ){
    #    print STDERR $call_details[1].":".$call_details[2]." in function ".$call_details[3]."\n";
    #}
    #foreach my $hash (@$res) {
    #    print "$hash->{'volid'}\n";
    #}

    my $target_info = "";

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

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);

    if ($snap){
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname, "--snapshot", $snap]); 
    } else {
        $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname]); 
    }

    iscsi_login($target, $host);

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};
    
    my $target_info = "";

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
    }
               #
    #if ($volname =~ m/^((\S+):(base)?(vm)?-(\d+)-(\S+))?((base)?(vm)?-(\d+)-(\S+))$/) {
	#return ('images', $2, $1, undef, undef, undef, 'raw');
    #}

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
    my ( $class, $scfg, $feature, $storeid, $volname, $snapname, $running ) =
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
