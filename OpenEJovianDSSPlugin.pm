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

   if ($apiver >= 3 and $apiver <= 9) {
      return $apiver;
   }

   return 6;
}

# we have to name it drbd, there is a hardcoded 'drbd' in Plugin.pm
sub type {
    return 'open-e';
}

sub plugindata {
    return {
	content => [ {
        images => 1,
		iso => 1,
		backup => 1,
    }, 
        { images => 1 }],
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
    run_command(['jcli', @$cmd], errmsg => 'joviandss error', outfunc => $func);

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

    #foreach (@$cmd) {
    #    print "$_\n";
    #}

    run_command($cmd, errmsg => 'joviandss error', outfunc => $func);

    my @devs = split(" ", $msg);

    my $devid = "";
    foreach (@devs) {
        $devid = "/dev/$_"; 
        last if index($_, "disk/by-id") == 0;
        print "$_\n";
    }
    #die "term $devid";
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

    #open my $jcli, '-|' or
    #    exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", $volname, "get", "--path" or
    #    die "jcli failed: $!\n";
    #my @out = qx(jcli -p -c $config pool $pool targets  $volname  get --path);
    #my $dpath = join("", @out);
    
    my $dpath = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--path"]); 
    chomp($dpath);
    $dpath =~ s/[^[:ascii:]]//;
    my $path = "/dev/disk/by-path/${dpath}";

    #my $did = device_id_from_path($path); 

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

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};
    #die "$class, $scfg, $storeid, $volname, $vmid, $snap ";
    my $volume_name;

    my $uuid = uuid();
    $uuid =~ tr/-//d;
    $volume_name = "vm-$vmid-$uuid";

    my $size = $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "get", "-s"]);
    chomp($size);
    $size =~ s/[^[:ascii:]]//;

    print"${volname} ${size} ${volume_name}\n";
    $class->joviandss_cmd(["-c", $config, "pool", $pool, "volumes", $volname, "clone", "-s", $size, $volume_name]);
    return $volume_name;
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

    #if ( !defined($size) ) {
    #    $size = 1024
    #}

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
    print"Activate storage\n";
    return undef;
}

sub deactivate_storage {
    my ( $class, $storeid, $scfg, $cache ) = @_;
    print"Deactivate storage\n";

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
    my $target_info = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--host"]);

    my @tmp = split(" ", $target_info, 2);
    
    my $host = $tmp[1];
    chomp($host);
    $host =~ s/[^[:ascii:]]//;

    my $target = $tmp[0];
    chomp($target);
    $target =~ s/[^[:ascii:]]//;

    my $session = iscsi_session($cache, $target);
    if (defined ($session)) {
        print"Nothing to do, exiting";
        return 1;
    }

    my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    
    $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname]); 
    
    iscsi_login($target, $host);
    #run_command([$ISCSIADM, "--mode", "node", "-p", $host, "-T", $target, "-o", "new"]);
    #run_command([$ISCSIADM, '--mode', 'node', '--targetname',  $target, '--login']);
    #class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", "create", $volname]); 
    #iscsiadm -m node -p 10.0.0.245 -T iqn.2020-04.com.open-e.cinder:vm-100-19cf298b9c454d84b8423d3c30da78cb --login
    #open my $jcli, '-|' or
    #    exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", "create", $volname or
    #    die "jcli failed: $!\n";
 
    #close $jcli;
    #die "Volume activate call with arguments $volname, $snap, $cache";

    return 1;
}

sub deactivate_volume {
    my ( $class, $storeid, $scfg, $volname, $snapname, $cache ) = @_;

    my $config = $scfg->{config};

    my $pool = $scfg->{pool_name};
    print "Deactivate volume $volname";
    
    my $target_info = $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "get", "--host"]);

    my @tmp = split(" ", $target_info, 2);
    my $host = $tmp[1];
    my $target = $tmp[0];
    iscsi_logout($target, $host);
    $class->joviandss_cmd(["-c", $config, "pool", $pool, "targets", $volname, "delete"]);
    
    #my ($vtype, $name, $vmid) = $class->parse_volname($volname);
    #
    #open my $jcli, '-|' or
    #    exec "jcli", "-p", "-c", $config, "pool", $pool, "targets", $volname, "delete" or
    #    die "jcli failed: $!\n";
    #
    #close $jcli;
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
	    #copy => { snap => 1 },
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
