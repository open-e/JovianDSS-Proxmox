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

package OpenEJovianDSS::Common;

use strict;


use warnings;
use Exporter 'import';
use Carp qw( confess );
use Data::Dumper;
use File::Basename;
use File::Find qw(find);
use File::Path qw(make_path);
use String::Util;

use JSON qw(decode_json from_json to_json);
#use PVE::SafeSyslog;

use Time::HiRes qw(gettimeofday);

use PVE::Tools qw(run_command);

our @EXPORT_OK = qw(
  get_default_prefix
  get_default_pool
  get_default_config_path
  get_default_debug
  get_default_multipath
  get_default_content_size
  get_default_path
  get_default_target_prefix
  get_default_ssl_cert_verify
  get_default_control_port
  get_default_data_port
  get_default_user_name

  get_pool
  get_config
  get_debug
  get_target_prefix
  get_ssl_cert_verify
  get_control_addresses
  get_control_port
  get_data_addresses
  get_data_port
  get_user_name
  get_user_password
  get_block_size
  get_thin_provisioning
  get_log_file
  get_content
  get_content_volume_name
  get_content_volume_type
  get_content_volume_size
  get_content_path
  get_multipath
  clean_word
  get_log_level
  get_debug

  safe_var_print
  debugmsg
  joviandss_cmd
  joviandss_volume_snapshot_info
  joviandss_volume_rollback_is_possible

  get_iscsi_addresses
  get_target_path
  get_active_target_name
  get_vm_target_group_name
  get_content_target_group_name

  volume_get_size

  volume_publish
  volume_unpublish

  volume_activate
  volume_deactivate

  store_settup
);

our %EXPORT_TAGS = ( all => [@EXPORT_OK], );

my $PLUGIN_LOCAL_STATE_DIR = '/etc/joviandss/state';
my $PLUGIN_GLOBAL_STATE_DIR = '/etc/pve/priv/joviandss/state';


my $ISCSIADM = '/usr/bin/iscsiadm';
$ISCSIADM = undef if !-X $ISCSIADM;

my $MULTIPATH = '/usr/sbin/multipath';
$MULTIPATH = undef if !-X $MULTIPATH;

my $DMSETUP = '/usr/sbin/dmsetup';
$DMSETUP = undef if !-X $DMSETUP;

my $default_prefix          = "jdss-";
my $default_pool            = "Pool-0";
my $default_config_path     = "/etc/pve/";
my $default_debug           = 0;
my $default_multipath       = 0;
my $default_shared          = 0;
my $default_content_size    = 100;
my $default_path            = "/mnt/joviandss";
my $default_target_prefix   = "iqn.2025-04.proxmox.joviandss.iscsi:";
my $default_ssl_cert_verify = 1;
my $default_control_port    = '82';
my $default_data_port       = '3260';
my $default_user_name       = 'admin';

sub get_default_prefix          { return $default_prefix }
sub get_default_pool            { return $default_pool }
sub get_default_config_path     { return $default_config_path }
sub get_default_debug           { return $default_debug }
sub get_default_multipath       { return $default_multipath }
sub get_default_content_size    { return $default_content_size }
sub get_default_path            { return $default_path }
sub get_default_target_prefix   { return $default_target_prefix }
sub get_default_ssl_cert_verify { return $default_ssl_cert_verify }
sub get_default_control_port    { return $default_control_port }
sub get_default_data_port       { return $default_data_port }
sub get_default_user_name       { return $default_user_name }

sub get_pool {
    my ($scfg) = @_;

    die "pool name required in storage.cfg \n"
      if !defined( $scfg->{'pool_name'} );
    return $scfg->{'pool_name'};
}

sub get_config {
    my ($scfg) = @_;

    return $scfg->{config} if ( defined( $scfg->{config} ) );

    return undef;
}

sub get_debug {
    my ($scfg) = @_;

    if ( defined( $scfg->{debug} ) && $scfg->{debug} ) {
        return 1;
    }
    return undef;
}

sub get_log_level {
    my ($scfg) = @_;

    if ( defined( $scfg->{debug} ) && $scfg->{debug} ) {
        return map_log_level_to_number("DEBUG");
    }
    return map_log_level_to_number("INFO");
}

sub get_target_prefix {
    my ($scfg) = @_;
    my $prefix = $scfg->{target_prefix} || $default_target_prefix;

    $prefix =~ s/:$//;
    return $prefix;
}

sub get_ssl_cert_verify {
    my ($scfg) = @_;

    return $scfg->{ssl_cert_verify};
}

sub get_control_addresses {
    my ($scfg) = @_;
    if ( defined( $scfg->{control_addresses} ) ) {
        if ( length( $scfg->{control_addresses} ) > 4 ) {
            return $scfg->{control_addresses};
        }
    }
    return undef;
}

sub get_control_port {
    my ($scfg) = @_;
    return $scfg->{control_port} || $default_control_port;
}

sub get_data_addresses {
    my ($scfg) = @_;

    if ( defined( $scfg->{data_addresses} ) ) {
        return $scfg->{data_addresses};
    }
    return undef;
}

sub get_data_port {
    my ($scfg) = @_;

    if ( defined( $scfg->{data_port} ) ) {
        return $scfg->{data_port};
    }
    return '3260';
}

sub get_user_name {
    my ($scfg) = @_;
    return $scfg->{user_name} || $default_user_name;
}

sub get_user_password {
    my ($scfg) = @_;
    return $scfg->{user_password};
}

sub get_block_size {
    my ($scfg) = @_;
    return $scfg->{block_size};
}

sub get_thin_provisioning {
    my ($scfg) = @_;
    if ( defined( $scfg->{thin_provisioning} ) ) {
        if ( $scfg->{thin_provisioning} ) {
            return 'y';
        }
    }
    return 'n';
}

sub get_log_file {
    my ($scfg) = @_;
    return $scfg->{log_file};
}

sub get_content {
    my ($scfg) = @_;
    return $scfg->{content};
}

sub get_content_volume_name {
    my ($scfg) = @_;

    if ( !defined( $scfg->{content_volume_name} ) ) {
        die "content_volume_name property is not set\n";
    }
    my $cvn = $scfg->{content_volume_name};
    die
"Content volume name should only include lower case letters, numbers and . - characters\n"
      if ( not( $cvn =~ /^[a-z0-9.-]*$/ ) );

    return $cvn;
}

sub get_content_volume_type {
    my ($scfg) = @_;
    if ( defined( $scfg->{content_volume_type} ) ) {
        if ( $scfg->{content_volume_type} eq 'nfs' ) {
            return 'nfs';
        }
        if ( $scfg->{content_volume_type} eq 'iscsi' ) {
            return 'iscsi';
        }
        die "Uncnown type of content storage requered\n";
    }
    return 'iscsi';
}

sub get_content_volume_size {
    my ($scfg) = @_;

    if ( get_debug($scfg) ) {
        print
"content_volume_size property is not set up, using default $default_content_size\n"
          if ( !defined( $scfg->{content_volume_size} ) );
    }
    my $size = $scfg->{content_volume_size} || $default_content_size;
    return $size;
}

sub get_content_path {
    my ($scfg) = @_;

    if ( defined( $scfg->{path} ) ) {
        return $scfg->{path};
    }
    else {
        return undef;
    }
}

sub get_multipath {
    my ($scfg) = @_;
    return $scfg->{multipath} || $default_multipath;
}

sub get_shared {
    my ($scfg) = @_;
    return $scfg->{shared} || $default_shared;
}

sub clean_word {
    my ($word) = @_;

    chomp($word);
    $word =~ s/[^[:ascii:]]//;

    return $word;
}

my $log_file_path = undef;

sub map_log_level_to_number {
    my ($level) = @_;
    my $upper = uc($level);

    my %levels = (
        FATAL => 1,
        ERROR => 2,
        WARN  => 3,
        INFO  => 4,
        DEBUG => 5,
        TRACE => 6,
    );

    return exists $levels{$upper} ? $levels{$upper} : $levels{TRACE};
}

sub debugmsg {
    my ( $scfg, $dlevel, $msg ) = @_;

    chomp $msg;

    return if !$msg;

    my $msg_level = map_log_level_to_number($dlevel);

    my $config_level = get_log_level($scfg);
    if ( $config_level >= $msg_level ) {

        $log_file_path = get_log_file($scfg);
        if ( !defined($log_file_path) ) {
            $log_file_path =
              clean_word( joviandss_cmd( $scfg, [ 'cfg', '--getlogfile' ] ) );
        }

        my ( $seconds, $microseconds ) = gettimeofday();

        my $milliseconds = int( $microseconds / 1000 );

        my ( $sec, $min, $hour, $day, $month, $year ) = localtime($seconds);
        $year  += 1900;
        $month += 1;
        my $line =
          sprintf( "%04d-%02d-%02d %02d:%02d:%02d.%03d - plugin - %s - %s",
            $year, $month,        $day,        $hour, $min,
            $sec,  $milliseconds, uc($dlevel), $msg );

        open( my $fh, '>>', $log_file_path )
          or die "Could not open file '$log_file_path' $!";

        # TODO: do not remove this line
        print $fh "$line\n";

        close($fh);
    }
}

sub safe_var_print {
    my ( $varname, $variable ) = @_;
    return defined($variable) ? "${varname} ${variable}" : "";
}

sub joviandss_cmd {
    my ( $scfg, $cmd, $timeout, $retries ) = @_;

    my $msg = '';
    my $err = undef;
    my $target;
    my $retry_count = 0;

    $timeout = 40 if !$timeout;
    $retries = 0  if !$retries;
    my $connection_options = [];

    my $ssl_cert_verify = get_ssl_cert_verify($scfg);
    if ( defined($ssl_cert_verify) ) {
        push @$connection_options, '--ssl-cert-verify', $ssl_cert_verify;
    }

    my $control_addresses = get_control_addresses($scfg);
    if ( defined($control_addresses) ) {
        push @$connection_options, '--control-addresses',
          "${control_addresses}";
    }

    my $control_port = get_control_port($scfg);
    if ( defined($control_port) ) {
        push @$connection_options, '--control-port', $control_port;
    }

    my $data_addresses = get_data_addresses($scfg);
    if ( defined($data_addresses) ) {
        push @$connection_options, '--data-addresses', $data_addresses;
    }

    my $data_port = get_data_port($scfg);
    if ( defined($data_port) ) {
        push @$connection_options, '--data-port', $data_port;
    }

    my $user_name = get_user_name($scfg);
    if ( defined($user_name) ) {
        push @$connection_options, '--user-name', $user_name;
    }

    my $user_password = get_user_password($scfg);
    if ( defined($user_password) ) {
        push @$connection_options, '--user-password', $user_password;
    }

    my $log_file = get_log_file($scfg);
    if ( defined($log_file) ) {
        push @$connection_options, '--logfile', $log_file;
    }

    my $config_file = get_config($scfg);
    if ( defined($config_file) ) {
        push @$connection_options, '-c', $config_file;
    }

    while ( $retry_count <= $retries ) {
        my $output   = sub { $msg .= "$_[0]\n" };
        my $errfunc  = sub { $err .= "$_[0]\n" };
        my $exitcode = 0;
        eval {
            $exitcode = run_command(
                [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ],
                outfunc => $output,
                errfunc => $errfunc,
                timeout => $timeout,
                noerr   => 1
            );
        };
        my $rerr = $@;

        if ( $exitcode == 0 ) {
            return $msg;
        }

        if ( $rerr =~ /got timeout/ ) {
            $retry_count++;
            sleep int( rand( $timeout + 1 ) );
            next;
        }

        if ($err) {
            die "${err}\n";
        }
        die "$rerr\n";
    }

    die "Unhadled state during running JovianDSS command\n";
}

# Returns a hash with the snapshot names as keys and the following data:
# id        - Unique id to distinguish different snapshots even if the have the same name.
# timestamp - Creation time of the snapshot (seconds since epoch).
# Returns an empty hash if the volume does not exist.
sub volume_snapshot_info {
    my ( $scfg, $storeid, $volname ) = @_;

    my $pool = get_pool($scfg);

    my $output = joviandss_cmd(
        $scfg,
        [
            'pool',      $pool,  'volume', $volname,
            'snapshots', 'list', '--guid', '--creation'
        ]
    );

    my $snapshots = {};
    my @lines     = split( /\n/, $output );
    for my $line (@lines) {
        my ( $name, $guid, $creation ) = split( /\s+/, $line );
        my ($sname) = split;
        debugmsg( $scfg, "debug",
"Volume ${volname} has snapshot ${name} with id ${guid} made at ${creation}\n"
        );
        $snapshots->{$name} = {
            id        => $guid,
            timestamp => $creation,
        };
    }

    return $snapshots;
}

sub volume_rollback_is_possible {
    my ( $scfg, $storeid, $volname, $snap, $blockers ) = @_;

    my $pool = OpenEJovianDSS::Common::get_pool($scfg);

    my $res;
    eval {
        $res = joviandss_cmd(
            $scfg,
            [
                "pool",     $pool, "volume",   $volname,
                "snapshot", $snap, "rollback", "check",
                '--concise'
            ]
        );
    };
    if ($@) {
        die
"Unable to rollback volume '${volname}' to snapshot '${snap}' because of: $@";
    }

    my $blocker_found = 0;
    $blockers //= [];
    foreach my $line ( split( /\n/, $res ) ) {
        foreach my $obj ( split( /\s+/, $line ) ) {
            push $blockers->@*, $obj;
            $blocker_found = 1;
        }
    }

    die
"Unable to rollback volume '${volname}' to snapshot ${snap}' as resources ${res} will be lost in the process\n"
      if $blocker_found > 0;

    return 1;
}

sub get_iscsi_addresses {
    my ( $scfg, $storeid, $addport ) = @_;

    my $da = get_data_addresses($scfg);

    my $dp = get_data_port($scfg);

    if ( defined($da) ) {
        my @iplist = split( /\s*,\s*/, $da );
        if ( defined($addport) && $addport ) {
            foreach (@iplist) {
                $_ .= ":${dp}";
            }
        }
        return @iplist;
    }

    my $getaddressescmd = [ 'hosts', '--iscsi' ];

    my $cmdout = joviandss_cmd( $scfg, $getaddressescmd );

    if ( length($cmdout) > 1 ) {
        my @hosts = ();

        foreach ( split( /\n/, $cmdout ) ) {
            my ($host) = split;
            if ( defined($addport) && $addport ) {
                push @hosts, "${host}:${dp}";
            }
            else {
                push @hosts, $host;
            }
        }

        if ( @hosts > 0 ) {
            return @hosts;
        }
    }

    my $ca = get_control_addresses($scfg);

    my @iplist = split( /\s*,\s*/, $ca );
    if ( defined($addport) && $addport ) {
        foreach (@iplist) {
            $_ .= ":${dp}";
        }
    }

    return @iplist;
}

sub get_iscsi_devices_paths {
    my ( $scfg, $target, $lunid, $hosts ) = @_;

    my @targets_block_devices = ();
    my $path;
    my $port = get_data_port( $scfg );
    foreach my $host (@$hosts) {
        $path = "/dev/disk/by-path/ip-${host}:${port}-iscsi-${target}-lun-${lunid}";
        if ( -e $path ) {
            debugmsg( $scfg, "debug", "Target ${target} mapped to ${path}\n" );
            push( @targets_block_devices, $path );
        }
    }
    return \@targets_block_devices;
}

sub target_active_info {
    my ( $scfg, $tgname, $volname, $snapname, $contentvolflag ) = @_;
    # Provides target info by requesting target info from joviandss

    my $pool   = get_pool($scfg);
    my $prefix = get_target_prefix($scfg);

    my $gettargetcmd = [
        'pool',            $pool,    'targets',             'get',
        '--target-prefix', $prefix,  '--target-group-name', $tgname,
        '-v',              $volname, '--current'
    ];
    if ($snapname) {
        push @$gettargetcmd, "--snapshot", $snapname;
    }
    if ( defined($contentvolflag) && $contentvolflag ) {
        push @$gettargetcmd, '-d';
    }

    my $out = joviandss_cmd( $scfg, $gettargetcmd, 80, 3 );

    if ( defined $out and clean_word($out) eq '' ) {
        return undef;
    }

    my ( $targetname, $lunid, $ips ) = split( ' ', $out );

    my @iplist = split /\s*,\s*/, $ips;
    debugmsg( $scfg, "debug",
        "Active target name for volume ${volname} is $targetname lun ${lunid}\n"
    );

    my %tinfo = (
        name   => $targetname,
        lun    => $lunid,
        iplist => \@iplist
    );
    return \%tinfo;
}

sub get_vm_target_group_name {
    my ( $scfg, $vmid ) = @_;
    return "vm-${vmid}";
}

sub get_content_target_group_name {
    my ($scfg) = @_;
    return "proxmox-content";
}

sub volume_publish {
    my ( $scfg, $tgname, $volname, $snapname, $content_volume_flag ) = @_;

    my $pool   = get_pool($scfg);
    my $prefix = get_target_prefix($scfg);

    my $create_target_cmd = [
        'pool',            $pool,   'targets',             'create',
        '--target-prefix', $prefix, '--target-group-name', $tgname,
        "-v",              $volname
    ];
    if ($snapname) {
        push( @$create_target_cmd, "--snapshot", $snapname );
    }
    else {
        if ( defined($content_volume_flag) && $content_volume_flag ) {
            push @$create_target_cmd, '-d';
        }
    }

    my $out = joviandss_cmd( $scfg, $create_target_cmd, 80, 3 );
    my ( $targetname, $lunid, $ips ) = split( ' ', $out );

    my @iplist = split /\s*,\s*/, $ips;

    my %tinfo = (
        target => $targetname,
        lunid  => $lunid,
        iplist => \@iplist
    );
    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Publish volume ${volname} "
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . 'acquired '
          . "target ${targetname} "
          . "lun ${lunid} "
          . "hosts @{iplist}");

    return \%tinfo;
}

sub volume_stage_iscsi {
    my ( $scfg, $storeid, $targetname, $lunid, $hosts ) = @_;

    debugmsg( $scfg, "debug", "Stage target ${targetname} lun ${lunid} over addresses @$hosts\n" );
    my $targets_block_devices =
      get_iscsi_devices_paths( $scfg, $targetname, $lunid, $hosts );

    if ( @$targets_block_devices == @$hosts ) {
        return $targets_block_devices;
    }

    foreach my $host (@$hosts) {

        eval {
            run_command(
                [
                    $ISCSIADM,
                    '--mode',       'node',
                    '-p',            $host,
                    '--targetname',  $targetname,
                    '-o', 'new'
                ],
                outfunc => sub { }
            );
        };
        warn $@ if $@;
        eval {
            run_command(
                [
                    $ISCSIADM,
                    '--mode',       'node',
                    '-p',           $host,
                    '--targetname', $targetname,
                    '--op',         'update',
                    '-n',           'node.startup',
                    '-v',           'automatic'
                ],
                outfunc => sub { }
            );
        };
        warn $@ if $@;
        eval {
            run_command(
                [
                    $ISCSIADM,
                    '--mode',       'node',
                    '-p',           $host,
                    '--targetname', $targetname,
                    '--login'
                ],
                outfunc => sub { }
            );
        };
        warn $@ if $@;
        debugmsg( $scfg, "debug", "Staging target ${targetname} of host ${host} done\n" );
    }

    for ( my $i = 1 ; $i <= 5 ; $i++ ) {
        sleep(1);

        $targets_block_devices =
          get_iscsi_devices_paths( $scfg, $targetname, $lunid, $hosts );

        if (@$targets_block_devices) {
            debugmsg( $scfg, "debug", "Stage iSCSI block devices @{ $targets_block_devices }\n" );
            return $targets_block_devices;
        }
    }
    die "Unable to locate target ${targetname} block device location.\n";
}

sub volume_stage_multipath {
    my ( $scfg, $scsiid ) = @_;

    eval {
        run_command( [ $MULTIPATH, '-a', $scsiid ], outfunc => sub { } );
    };
    die "Unable to add the SCSI ID ${scsiid} $@\n" if $@;
    eval {
        run_command( [$MULTIPATH], outfunc => sub { } );
    };
    die "Unable to call multipath: $@\n" if $@;

    my $mpathname = get_device_mapper_name( $scfg, $scsiid );
    unless ( defined($mpathname) ) {
        die "Unable to identify the multipath name for scsiid ${scsiid}\n";
    }

    $mpathname = "/dev/mapper/${mpathname}";
    if ( -e $mpathname ) {
        return $mpathname;
    }

    return undef;
}

#sub block_device_path {
#    my ( $scfg, $tgname, $volname, $snapname, $content_volume_flag ) = @_;
#
#    debugmsg( $scfg, "debug",
#            "Getting path of volume ${volname} "
#          . safe_var_print( "snapshot", $snapname )
#          . "\n" );
#
#    my $target = get_active_target_name(
#        scfg     => $scfg,
#        volname  => $volname,
#        snapname => $snapname,
#        content  => $content_volume_flag
#    );
#
#    if ( !defined($target) ) {
#        return undef;
#    }
#
#    my ( $tname, $lunid, @hosts ) =
#      get_active_target_info( $scfg, $tgname, $volname, $snapname,
#        $content_volume_flag );
#
#    my @iscsi_block_devices =
#      get_iscsi_device_paths( $scfg, $tname, $lunid, @hosts );
#
#    my @bdpaths = ();
#
#    if (@iscsi_block_devices) {
#        for my $bd (@iscsi_block_devices) {
#            eval {
#                run_command( [ "readlink", "-f", $bd ],
#                    outfunc => sub { push( @bdpaths, OpenEJovianDSS::Common::clean_word( shift ) ); } );
#            };
#        }
#    }
#    else {
#        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
#            "Target path for ${volname} not found\n" );
#
#        return undef;
#    }
#
#    for my $bdp (@bdpaths) {
#        my $block_device_name = File::Basename::basename($bdp);
#        unless ( $block_device_name =~ /^[a-z0-9]+$/ ) {
#            debugmsg( $scfg, "debug",
#                "Invalide block device name ${block_device_name} for iscsi target ${target}\n");
#              next;
#        }
#
#    }
#
#    # $bdpath = $bdpath);
#
#
#    if ( get_multipath($scfg) ) {
#        $tpath = bget_multipath_path( $storeid, $scfg, $target );
#    }
#    if ( defined($tpath) ) {
#        debugmsg( $scfg, "debug",
#                "Block device path is ${tpath} of volume ${volname} "
#              . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
#              . "\n" );
#    }
#    else {
#        debugmsg( $scfg, "debug",
#                "Unable to identify path for volume ${volname} "
#              . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
#              . "\n" );
#    }
#    return $tpath;
#}

sub block_device_path_from_lun_rec {
    my ( $scfg, $storeid, $targetname, $lunid, $lunrec ) = @_;

    my $block_dev;

    if ( get_multipath($scfg) ) {

        unless ($lunrec->{multipath}) {
            $lunrec->{multipath} = 1;
            lun_record_local_update( $scfg, $storeid,
                                     $targetname, $lunid,
                                     $lunrec->{volname}, $lunrec->{snapname},
                                     $lunrec );
        }
        $block_dev = volume_stage_multipath( $scfg, $lunrec->{scsiid} );
        return $block_dev;

    }
    my @hosts = @{ $lunrec->{hosts} };


    my @iscsi_block_devices = block_device_iscsi_paths ( $scfg, $targetname, $lunid, @hosts );

    if (@iscsi_block_devices) {
        print("Block device path from lun rec $iscsi_block_devices[0]\n");

        return $iscsi_block_devices[0];
    }
    return undef;
}

sub get_device_mapper_name {
    my ( $scfg, $wwid ) = @_;

    open( my $multipath_topology, '-|', "multipath -ll $wwid" )
      or die "Unable to list multipath topology: $!\n";

    my $device_mapper_name;

    while ( my $line = <$multipath_topology> ) {
        chomp $line;
        if ( $line =~ /\b$wwid\b/ ) {
            my @parts = split( /\s+/, $line );
            $device_mapper_name = $parts[0];
        }
    }
    unless ($device_mapper_name) {
        return undef;
    }

    close $multipath_topology;

    if ( $device_mapper_name =~ /^([\:\-\@\w.\/]+)$/ ) {

        debugmsg( $scfg, "debug", "Mapper name for ${wwid} is ${1}\n" );
        return $1;
    }
    return undef;
}

sub get_multipath_device_name {
    my ($device_path) = @_;

    my $cmd = [
        'lsblk',
        '-J',
        '-o',
'NAME,SIZE,FSTYPE,UUID,LABEL,MOUNTPOINT,SERIAL,VENDOR,ZONED,HCTL,KNAME,TYPE,TRAN',
        $device_path
    ];

    my $json_out = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };

    run_command(
        $cmd,
        errmsg  => "Getting multipath device for ${device_path} failed",
        outfunc => $outfunc
    );

    my $data = decode_json($json_out);

    my @mpath_names;
    for my $dev ( @{ $data->{blockdevices} } ) {
        if ( exists $dev->{children} && ref( $dev->{children} ) eq 'ARRAY' ) {
            for my $child ( @{ $dev->{children} } ) {
                if ( defined $child->{type} && $child->{type} eq 'mpath' ) {
                    push @mpath_names, $child->{name};
                }
            }
        }
    }

    # Return the proper result based on the number of multipath devices found.
    if ( @mpath_names == 1 ) {
        return $mpath_names[0];
    }
    elsif ( @mpath_names == 0 ) {
        return undef;
    }
    else {
        die "More than one multipath device found: "
          . join( ", ", @mpath_names );
    }
}

#sub block_device_multipath_path {
#    my ( $scfg, $storeid, $targetname, $lunid, @hosts ) = @_;
#
#    my $tpaths = get_iscsi_device_paths( $scfg, $targetname, $lunid, $hosts );
#
#    unless ( @$tpaths ) {
#        debugmsg( $scfg, "debug",
#            "Unable to identify device path for target ${targetname}\n" );
#        return undef;
#    }
#    my $bdpath = undef;
#    foreach my $tpath (@$tpaths) {
#        eval {
#            run_command(
#                [ "readlink", "-f", $tpath ],
#                outfunc => sub { $bdpath = shift; }
#            );
#        };
#        if ( defined($bdpath) ) {
#            last;
#        }
#    }
#    unless ( defined($bdpath) ) {
#        die "Unable to identify block device related to target " .
#        "${targetname} lun ${lunid}\n";
#    }
#
#    $bdpath = clean_word($bdpath);
#    my $block_device_name = File::Basename::basename($bdpath);
#    unless ( $block_device_name =~ /^[a-z0-9]+$/ ) {
#        die "Invalide block device name ${block_device_name} " .
#                "for iscsi target ${targetname}\n";
#    }
#
#    my $mpathname = get_multipath_device_name($bdpath);
#
#    if ( !defined($mpathname) ) {
#        return undef;
#    }
#
#    my $mpathpath = "/dev/mapper/${mpathname}";
#
#    if ( -b $mpathpath ) {
#        debugmsg( $scfg, "debug", "Multipath block device is ${mpathpath}\n" );
#        return $mpathpath;
#    }
#    return undef;
#}

sub block_device_iscsi_paths {
    my ( $scfg, $target, $lunid, @hosts ) = @_;

    my @targets_block_devices = ();
    my $path;
    foreach my $host (@hosts) {
        $path = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-${lunid}";
        print("Cheking block device path ${path}\n");
        if ( -e $path ) {
            print("Found block device path ${path}\n");
            debugmsg( $scfg, "debug", "Target ${target} mapped to ${path}\n" );
            push( @targets_block_devices, $path );
        }
    }
    return @targets_block_devices;
}

#sub scsiid_from_target {
#    my ( $scfg, $storeid, $target, $lunid ) = @_;
#
#    my @hosts =
#      OpenEJovianDSS::Common::get_iscsi_addresses( $scfg, $storeid, 1 );
#
#    foreach my $host (@hosts) {
#        my $targetpath = "/dev/disk/by-path/ip-${host}-iscsi-${target}-lun-${lunid}";
#        my $getscsiidcmd =
#          [ "/lib/udev/scsi_id", "-g", "-u", "-d", $targetpath ];
#        my $scsiid;
#
#        if ( -e $targetpath ) {
#            eval {
#                run_command( $getscsiidcmd,
#                    outfunc => sub { $scsiid = shift; } );
#            };
#
#            if ($@) {
#                die
#"Unable to get the iSCSI ID for ${targetpath} because of $@\n";
#            }
#        }
#        else {
#            next;
#        }
#
#        if ( defined($scsiid) ) {
#            if ( $scsiid =~ /^([\-\@\w.\/]+)$/ ) {
#                OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
#                    "Identified scsi id ${1}\n" );
#                return $1;
#            }
#        }
#    }
#    return undef;
#}

sub scsiid_from_blockdevs {
    my ( $scfg, $targetpaths ) = @_;

    foreach my $targetpath (@$targetpaths) {
        my $getscsiidcmd =
          [ "/lib/udev/scsi_id", "-g", "-u", "-d", $targetpath ];
        my $scsiid;

        if ( -e $targetpath ) {
            eval {
                run_command( $getscsiidcmd,
                    outfunc => sub { $scsiid = shift; } );
            };

            if ($@) {
                die
"Unable to get the iSCSI ID for ${targetpath} because of $@\n";
            }
        }
        else {
            next;
        }

        if ( defined($scsiid) ) {
            if ( $scsiid =~ /^([\-\@\w.\/]+)$/ ) {
                OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
                    "Identified scsi id ${1}\n" );
                return $1;
            }
        }
    }
    return undef;
}

sub volume_unstage_iscsi {
    my ( $scfg, $storeid, $targetname, $lunid, $hosts ) = @_;

    debugmsg( $scfg, "debug", "Unstaging target ${targetname}\n" );

    # Driver should not commit any write operation including sync before unmounting
    # Because that myght lead to data corruption in case of active migration
    # Also we do not do volume unmounting

    eval {
        run_command(
            [   $ISCSIADM,
                '--mode', 'node',
                '--targetname',  $targetname,
                '--logout'
            ],
            outfunc => sub {}); 
    };
    warn $@ if $@;

    foreach my $host (@$hosts) {
        #my $tpath = get_iscsi_device_paths( $scfg, $targetname, $lunid, ($host) );

        #if (defined($tpath) && -e $tpath) {

        eval {
            run_command(
                [   $ISCSIADM,
                    '--mode', 'node',
                    '-p', $host,
                    '--targetname',  $targetname,
                    '-o', 'delete'
                ], outfunc => sub {}); };
        warn $@ if $@;
            #}
    }
}

sub volume_multipath_unstage {
    my ( $scfg, $scsiid ) = @_;

# Driver should not commit any write operation including sync before unmounting
# Because that myght lead to data corruption in case of active migration
# Also we do not do any unmnounting to volume as that might cause unexpected writes

    eval {
        run_command( [ $MULTIPATH, '-f', $scsiid ], outfunc => sub { } );
    };
    if ($@) {
        warn
"Unable to remove the multipath mapping for scsi id ${scsiid} because of $@\n"
          if $@;
        my $mapper_name = get_device_mapper_name( $scfg, $scsiid );
        if ( defined($mapper_name) ) {
            eval {
                run_command( [ $DMSETUP, "remove", "-f", $mapper_name ],
                    outfunc => sub { } );
            };
            die
"Unable to remove the multipath mapping for volume with scsi id ${scsiid} with dmsetup: $@\n"
              if $@;
        }
        else {
            warn
"Unable to identify multipath mapper name for volume with scsi id ${scsiid}\n";
        }
    }

    eval {
        run_command( [$MULTIPATH], outfunc => sub { } );
    };
    die "Unable to restart the multipath daemon $@\n" if $@;
}

sub volume_unpublish {
    my ( $scfg, $storeid, $vmid, $volname, $snapname, $content_volume_flag ) = @_;

    my $pool = get_pool( $scfg );
    my $prefix = get_target_prefix($scfg);

    my $tgname;

    if ( defined($content_volume_flag) && $content_volume_flag != 0 ) {
        $tgname = get_content_target_group_name($scfg);
    } else {
        $tgname = get_vm_target_group_name($scfg, $vmid);
    }

    # Volume deletion will result in deletetion of all its snapshots
    # Therefore we have to detach all volume snapshots that is expected to be
    # removed along side with volume
    unless ( defined($snapname) ) {
        my $delitablesnaps = joviandss_cmd(
            $scfg,
            [
                "pool",   $pool,
                "volume", $volname,
                "delete", "-c",  "-p",
                '--target-prefix', $prefix,
                '--target-group-name', $tgname
            ]
        );
        my @dsl = split( " ", $delitablesnaps );

        unless ( $content_volume_flag ) {
            foreach my $snap (@dsl) {
                volume_deactivate( $scfg, $storeid, $vmid,
                    $volname, $snap, undef );
            }
        }

        joviandss_cmd(
            $scfg,
            [
                "pool", $pool,
                "targets", "delete",
                '--target-prefix', $prefix,
                '--target-group-name', $tgname,
                "-v", $volname
            ]
        );
    }

    if ( defined( $snapname ) ) {
        joviandss_cmd(
            $scfg,
            [
                "pool", $pool,
                "targets", "delete",
                '--target-prefix', $prefix,
                "-v", $volname,
                "--snapshot", $snapname]);
    }
    1;
}

sub lun_record_local_create {
    my (
        $scfg,    $storeid,
        $targetname, $lunid, $volname, $snapname,
        $iscsiid, $size,
        $multipath, $shared,
        @hosts
    ) = @_;

    my $ltldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR,
                                     $storeid, $targetname, $lunid );

    my @errmsg = ();

    make_path( $ltldir,
                {
                    verbose => 1,
                    mode => 0644,
                }
            );

            #if (@errmsg) {
            #    for my $diag (@errmsg) {
            #        my ($path, $message) = %{$diag};
            #        print "Couldn’t create $path: $message\n";
            #    }
            #}
    # or die "Cannot create $ltldir: $!";

    my $ltlfile = File::Spec->catfile( $ltldir, $volname );

    if ($snapname) {
        my $ltlfile = File::Spec->catfile( $ltldir, $snapname );
    }

    my $record = {
        iscsiid   => $iscsiid,
        volname   => $volname,
        snapname  => $snapname,
        size      => $size,
        hosts     => \@hosts,
        multipath => $multipath ? \1 : \0,
        shared    => $shared ? \1 : \0,
    };

    if ( $snapname ) {
        $record->{snapname} = $snapname;
    } else {
        $record->{snapname} = undef;
    }

    my $json_text = JSON::encode_json($record) . "\n";

    open my $fh, '>', $ltlfile
      or die "Failed to create local lun record at '$ltlfile': $!\n";
    print {$fh} $json_text;
    close $fh or die "Failed to finish writing to local lun file '$ltlfile': $!\n";

    return $ltlfile;
}

sub lun_record_local_update {
    my (
        $scfg,    $storeid,
        $targetname, $lunid, $volname, $snapname,
        $lunrec
    ) = @_;

    my $ltldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR,
                                     $storeid, $targetname, $lunid );

    make_path( $ltldir,
                {
                    verbose => 1,
                    chmode => '0644'
                }
            ) or die "Cannot create $ltldir: $!";

    my $ltlfile = File::Spec->catfile( $ltldir, $volname );

    if ($snapname) {
        $ltlfile = File::Spec->catfile( $ltldir, $snapname );
    }

    my $json_text = JSON::encode_json($lunrec) . "\n";

    open my $fh, '>', $ltlfile
      or die "Failed to create local lun record at '$ltlfile': $!\n";
    print {$fh} $json_text;
    close $fh or die "Failed to finish writing to local lun file '$ltlfile': $!\n";

    return $ltlfile;
}

#sub lun_record_local_copy_update {
#    my (
#        $scfg,    $storeid,
#        $targetname, $lunid, $volname, $snapname,
#        $lunrec
#    ) = @_;
#
#    my $shared = get_shared( $scfg );
#
#    my $ltldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR,
#                                     $storeid, $targetname, $lunid );
#
#    make_path( $ltldir, { mode => 0755 } )
#      or die "Cannot create $ltldir: $!";
#
#    my $ltlfile = File::Spec->catfile( $ltldir, $volname );
#
#    if ($snapname) {
#        $ltlfile = File::Spec->catfile( $ltldir, $snapname );
#    }
#
#    my $json_text = JSON::encode_json($record) . "\n";
#
#    open my $fh, '>', $ltlfile
#      or die "Failed to create local lun record at '$ltlfile': $!\n";
#    print {$fh} $json_text;
#    close $fh or die "Failed to finish writing to local lun file '$ltlfile': $!\n";
#
#    return $ltlfile;
#}

sub lun_record_local_get_info_list {
    my ($scfg, $storeid, $volname, $snapname, $tgname ) = @_;

    # Provides
    # ( target name, lun number, path to lun record file, lun record data )
    my @matches = ();

    my $name = $volname;

    if ( $snapname ) {
        $name = $snapname;
    }
    my $ldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR, $storeid );

    unless( -d $ldir ){
        die "Unable to locate folder containing ${ ldir } plugin state\n";
    }

    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                #return unless $_ eq "$name";
                my $full = $File::Find::name;
                print("Lun record found ${full} Addition: $_\n");

                # Expect path .../<storeid>/<target>/<lun_id>/$name
                unless ($full =~ m!^\Q$ldir\E/([^/]+)/(\d+)/\Q$name\E$!) {
                    return;
                }
                print("Lun record passed check ${full}\n");
                my ($targetname, $lunid) = ($1, $2);

                if (defined $tgname) {
                    # escape any special chars in the pattern
                    my $tp = quotemeta($tgname);

                    unless ($targetname =~ /$tp-\d+\z/) {
                        next;
                    }
                }
                my $lunrec = lun_record_local_get_by_path( $scfg, $storeid, $full);
                if ($lunrec) {
                    if ( $lunrec->{volname} eq $volname ) {
                        if ( defined($snapname) ) {
                            if ( defined($lunrec->{snapname}) &&
                                ( $lunrec->{snapname} eq $snapname ) ) {
                                push @matches, [ $targetname, $lunid, $full, $lunrec ];
                            }
                        } else {
                            unless( defined($lunrec->{snapname}) ) {
                                push @matches, [ $targetname, $lunid, $full, $lunrec ];
                            }
                        }
                    }
                }

            },
        },
        $ldir);

    return \@matches;
}

sub lun_record_local_get_by_target {
    my ($scfg, $storeid,
        $targetname, $lunid, $volname
    ) = @_;

    my $ltldir = File::Spec->catfile( $PLUGIN_LOCAL_STATE_DIR,
                                      $storeid, $targetname, $lunid, $volname);
    unless ( -d $ltldir ) {
        return undef;
    }

    my $ltlfile = File::Spec->catfile($ltldir, $volname);

    unless (-f $ltlfile && -r $ltlfile) {
        return undef;
    }

    return lun_record_local_get_by_path( $scfg, $storeid, $ltlfile );
}

sub lun_record_local_get_by_path {
    my ( $scfg, $storeid, $path ) = @_;

    unless (-f $path && -r $path) {
        return undef;
    }

    open my $fh, '<', $path
      or die "Cannot open lun file $path for reading: $!\n";
    local $/ = undef;
    my $jsontext = <$fh>;
    close $fh;

    my $jdata = eval { JSON::decode_json($jsontext) };
    if ($@) {
        die "Failed to process lun file $path $@\n";
    }
    unless (ref($jdata) eq 'HASH') {
        die "Unexpected content in $path";
    }

    for my $key (qw(iscsiid volname snapname size multipath hosts multipath shared)) {
        die "Local lun record ${path} is missing '$key'"
            unless exists $jdata->{$key};
    }

    return $jdata;
}

#sub delete_global_lun_record {
#    my ( $scfg, $storeid, $targetname, $lunid, $volname ) = @_;
#
#    # Global Target Directory
#    my $gtdir = File::Spec->catdir( $PLUGIN_GLOBAL_STATE_DIR,
#                                     $storeid, $targetname );
#
#    unless ( -d $gtdir ) {
#        return undef;
#    }
#
#    # Global Target Lun Directory
#    my $gtldir = File::Spec->catdir( $PLUGIN_GLOBAL_STATE_DIR,
#                                     $storeid, $targetname, $lunid );
#
#    my $gtlfile = File::Spec->catfile( $gtldir, $volname );
#
#    # Remove data record
#    if ( -f $gtlfile ) {
#        unless ( unlink($gtlfile) ) {
#            die "Unable to remove global target lun file ${gtlfile} because $!\n";
#        }
#    }
#
#    # Remove lun record
#    if ( -d $gtldir ) {
#        if ( rmdir( $gtldir ) ) {
#            my $dh;
#            opendir( $dh, $gtdir );
#            my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
#            closedir $dh;
#
#            unless ( @entries ) {
#                unless ( rmdir( $gtdir ) ) {
#                    if ( -d $gtdir) {
#                        opendir ( $dh, $gtdir) or die "Cannot open directory '$gtdir': $!\n";
#                        @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
#                        closedir $dh;
#                        unless ( @entries ) {
#                            die "Failed to remove global target record at ${gtdir} that seem to be empty '$!'\n";
#                        }
#                    }
#                }
#            }
#        } else {
#            OpenEJovianDSS::Common::debugmsg( $scfg, "warning",
#                    "Skip removing lun dir of global target ${targetname} " .
#                    "lun ${lunid} because of $!");
#        }
#    }
#    return 1;
#}

sub lun_record_local_delete {
    my ( $scfg, $storeid, $targetname, $lunid, $volname, $snapname ) = @_;

    my $ltdir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR,
                                    $storeid, $targetname );

    unless ( -d $ltdir ) {
        return undef;
    }

    # Local Target Lun Directory
    my $ltldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR,
                                     $storeid, $targetname, $lunid );

    my $ltlfile = File::Spec->catfile( $ltldir, $volname );

    if ( -f $ltlfile ) {
        unless ( unlink($ltlfile) ) {
            die "Unable to remove lun file ${ltlfile} because $!\n";
        }
    }

    if ( -d $ltldir ) {
        if ( rmdir( $ltldir ) ) {
            my $dh;
            opendir( $dh, $ltdir );
            my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
            closedir $dh;

            unless ( @entries ) {
                unless ( rmdir( $ltdir ) ) {
                    if ( -d $ltdir) {
                        opendir ( $dh, $ltdir) or die "Cannot open directory '$ltdir': $!\n";
                        @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
                        closedir $dh;
                        unless ( @entries ) {
                            die "Failed to remove global target record at ${ltdir} that seem to be empty '$!'\n";
                        }
                    }
                }
            }
        } else {
            OpenEJovianDSS::Common::debugmsg( $scfg, "warning",
                    "Skip removing lun dir of global target ${targetname} " .
                    "lun ${lunid} because of $!");
        }
    }
    return 1;
}

sub volume_activate {
    my ($scfg, $storeid,
        $vmid, $volname, $snapname,
        $content_volume_flag ) = @_;

    my $published                 = 0;
    my $iscsi_staged              = 0;
    my $scsiid_acquired           = 0;
    my $multipath_staged          = 0;
    my $local_record_created      = 0;

    my $block_devs;
    my $tinfo; # Target information when it is published

    my $tgname;
    my $scsiid;
    my $shared = get_shared( $scfg );
    my $multipath = get_multipath( $scfg );
    my $targetname;
    my $lunid;
    my $hosts;

    if ( defined($content_volume_flag) && $content_volume_flag != 0 ) {
        $tgname = OpenEJovianDSS::Common::get_content_target_group_name($scfg);
    } else {
        $tgname = OpenEJovianDSS::Common::get_vm_target_group_name($scfg, $vmid);
    }

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Activating volume ${volname} "
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . "\n" );

    eval {
        $published = 1;
        $tinfo = volume_publish($scfg,
                                $tgname,
                                $volname,
                                $snapname,
                                $content_volume_flag
        );
        my $dumpdata = Data::Dumper->new([$tinfo]);

        if ($tinfo) {
            $targetname = $tinfo->{target};
            $lunid = $tinfo->{lunid};
            $hosts = $tinfo->{iplist};
        } else {
            die "Publishing volume ${volname} " . safe_var_print( "snapshot", $snapname ) .
                " failed to provide target info\n";
        }

        $iscsi_staged = 1;
        my $tbdlist = volume_stage_iscsi(
            $scfg,
            $storeid,
            $targetname,
            $lunid,
            $hosts
        );
        $block_devs = $tbdlist;

        unless (scalar(@$block_devs) == scalar(@$hosts)) {
            die "Unable to connect all storage addresses\n";
        }
        $scsiid = scsiid_from_blockdevs( $scfg, $block_devs );

        if (defined( $scsiid ) ) {
            $scsiid_acquired = 1;
        } else {
            die "Unable to identify scsi id for ${volname}" .
                safe_var_print( "snapshot", $snapname ) . "\n";
        }

        if ($multipath) {
            $multipath_staged = 1;
            my $multipath_path = volume_stage_multipath( $scfg, $scsiid );
            my $mpdl = ( $multipath_path );
            $block_devs = $mpdl;
        }

        #unless ( $snapname ) {
        my $size = volume_get_size( $scfg, $storeid, $volname);

        $local_record_created      = 1;
        lun_record_local_create(
                $scfg, $storeid,
                $targetname, $lunid, $volname, $snapname,
                $scsiid, $size,
                $multipath, $shared,
                @{ $hosts } );
            #}
    };
    my $err = $@;

    if ($err) {
        warn "Volume ${volname} " . safe_var_print( "snapshot", $snapname ) . " activation failed: $err";

        my $local_cleanup = 0;
        if ($local_record_created) {
            eval {
                lun_record_local_delete( $scfg, $storeid, $targetname, $lunid, $volname, $snapname );
            };
            my $cerr = $@;
            if ($cerr) {
                $local_cleanup = 1;
                warn "delete_lun_record failed: $@" if $@;
            }
        }

        if ($multipath_staged) {
            eval {
                volume_multipath_unstage( $scfg, $scsiid );
            };
            my $cerr = $@;
            if ($cerr) {
                $local_cleanup = 1;
                warn "unstage_volume_multipath failed: $@" if $@;
            }
        }

        if ($iscsi_staged) {
            eval {
                volume_unstage_iscsi(
                    $scfg,
                    $storeid,
                    $targetname,
                    $lunid,
                    $hosts
                );
            };
            my $cerr = $@;
            if ($cerr) {
                $local_cleanup = 1;
                warn "unstage_volume_iscsi failed: $@" if $@;
            }
        }

        if ( $snapname ) {
            # We do not delete target on joviandss as this will lead to race condition
            # in case of migration
            if ( $published ) {
                eval {
                    volume_unpublish( $scfg, $targetname );
                };
                my $cerr = $@;
                if ($cerr) {
                    $local_cleanup = 1;
                    warn "unpublish_volume failed: $@" if $@;
                }
            }
        }
        unless ($local_cleanup) {
            lun_record_local_delete( $scfg, $storeid, $targetname, $lunid, $volname, $snapname );
        }
        die $err;
    }
    unless ( defined( $block_devs ) ) {
        die "Unable to provide block device for volume ${volname}"
                . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
                . " after activation\n";
    } else {
        return $block_devs;
    }
}

sub volume_deactivate {
    my ($scfg, $storeid,
        $vmid, $volname, $snapname,
        $contentvolumeflag )
      = @_;

    my $published                 = 0;
    my $iscsi_staged              = 0;
    my $multipath_staged          = 0;
    my $local_record_created      = 0;

    my @block_devs;

    my $resname;

    my $shared;
    my $multipath;

    my @hosts;

    my $tgname; # Target group name

    my $targetname;
    my $lunid;
    my $lunrecpath;
    my $lunrecord = undef;

    my $local_cleanup = 0;

    my $pool   = OpenEJovianDSS::Common::get_pool($scfg);

    OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
            "Deactivate volume ${volname} "
          . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname )
          . "\n" );

    if ( defined($contentvolumeflag) && $contentvolumeflag != 0 ) {
        $tgname = OpenEJovianDSS::Common::get_content_target_group_name($scfg);
    } else {
        $tgname = OpenEJovianDSS::Common::get_vm_target_group_name($scfg, $vmid);
    }

    my $lunrecinfolist = lun_record_local_get_info_list( $scfg, $storeid, $volname, $snapname );

    print("Lun record info @$lunrecinfolist");
    print(Dumper(@$lunrecinfolist));

    if ( @$lunrecinfolist ) {
        if ( @$lunrecinfolist == 1 ) {
            print("Single Lun record found\n");
            print(Dumper(@{ $lunrecinfolist->[0] }));
            ($targetname, $lunid, $lunrecpath, $lunrecord) = @{ $lunrecinfolist->[0] };
        } else {
            print("Multiple Lun record found\n");

            foreach my $rec (@$lunrecinfolist) {
                print(Dumper($rec));
                my $tinfo = target_active_info( $scfg, $tgname, $volname, $snapname, $contentvolumeflag );
                if ( defined( $tinfo ) ){
                    my $lr;
                    ($targetname, $lunid, $lunrecpath, $lr) = $rec;

                    if ( $tinfo->{name} eq $targetname ) {
                        if ( $tinfo->{lun} eq $lunid ) {
                            if ( $lr->{volname} eq $volname ) {
                                if (defined($snapname) && $lr->{snapname} eq $snapname ) {
                                    $lunrecord = $lr;
                                    last;
                                } else {
                                    unless(defined($lr->{snapname})) {
                                        $lunrecord = $lr;
                                        last;
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    unless( defined( $lunrecord ) ) {
        die "Unable to identify lun record for volume ${volname} "
            . OpenEJovianDSS::Common::safe_var_print( "snapshot", $snapname ) .
            "\n";
    }

    if ( $multipath ) {
        eval {
            unstage_volume_multipath( $scfg, $lunrecord->{scsiid} );
        };
        my $cerr = $@;
        if ($cerr) {
            $local_cleanup = 1;
            warn "unstage_volume_multipath failed: $@" if $@;
        }
    }

    my @hostsarray = @{ $lunrecord->{hosts} };
    eval {
        unstage_volume_iscsi(
            $scfg,
            $storeid,
            $targetname,
            $lunrecord->{lunid},
            @hostsarray
        );
    };
    my $cerr = $@;
    if ($cerr) {
        $local_cleanup = 1;
        warn "unstage_volume_iscsi failed: $@" if $@;
    }

    if ( $snapname ) {
    # We do not delete target on joviandss as this will lead to race condition
    # in case of migration
        eval {
            volume_unpublish( $scfg, $targetname );
        };
        $cerr = $@;
        if ($cerr) {
            $local_cleanup = 1;
            warn "unpublish_volume failed: $@" if $@;
        }
    }
    lun_record_local_delete( $scfg, $storeid, $targetname, $lunid, $volname, $snapname );
    1;
}

sub lun_record_update_device {
    my ( $scfg, $storeid, $targetname, $lunid, $lunrecpath, $lunrec, $expectedsize ) = @_;

    my @hosts = @{ $lunrec->{hosts} };
    my $multipath = $lunrec->{multipath};

    my @update_device_try = ( 1 .. 10 );
    foreach (@update_device_try) {

        my @iscsi_block_devices = block_device_iscsi_paths ( $scfg, $targetname, $lunid, @hosts );
        my $block_device_path;
        foreach my $iscsi_block_device ( @iscsi_block_devices ) {
            eval {
                run_command(
                    [ "readlink", "-f", $iscsi_block_device ],
                    outfunc => sub { $block_device_path = shift; }
                );
            };

            $block_device_path = OpenEJovianDSS::Common::clean_word($block_device_path);
            my $block_device_name = basename($block_device_path);
            unless ( $block_device_name =~ /^[a-z0-9]+$/ ) {
                die "Invalide block device name ${block_device_name} " .
                    " for iscsi target ${targetname}\n";
            }
            my $rescan_file = "/sys/block/${block_device_name}/device/rescan";
            open my $fh, '>', $rescan_file or die "Cannot open $rescan_file $!";
            print $fh "1" or die "Cannot write to $rescan_file $!";
            close $fh     or die "Cannot close ${rescan_file} $!";
            #$block_device_path = $bd ;
        }

        eval {
            run_command( [ $ISCSIADM, '-m', 'node', '-R', '-T', ${targetname} ],
                outfunc => sub { } );
        };

        my $updateudevadm = [ 'udevadm', 'trigger', '-t', 'all' ];
        run_command( $updateudevadm,
            errmsg =>
              "Failed to update udev devices after iscsi target attachment" );

        if ( get_multipath($scfg) ) {

            unless ($lunrec->{multipath}) {
                $lunrec->{multipath} = 1;
                lun_record_local_update( $scfg, $storeid,
                                         $targetname, $lunid,
                                         $lunrec->{volname}, $lunrec->{snapname},
                                         $lunrec );
            }
            my $block_device_path = volume_stage_multipath( $scfg, $lunrec->{scsiid} );
            eval {
                run_command( [ $MULTIPATH, '-r', ${block_device_path} ],
                    outfunc => sub { } );
            };
        }

        sleep(1);

        my $updated_size;
        run_command(
            [ '/sbin/blockdev', '--getsize64', $block_device_path ],
            outfunc => sub {
                my ($line) = @_;
                die "unexpected output from /sbin/blockdev: $line\n"
                  if $line !~ /^(\d+)$/;
                $updated_size = int($1);
            }
        );

        if ($expectedsize) {
            if ( $updated_size eq $expectedsize ) {
                $lunrec->{size} = $expectedsize;
                lun_record_local_update( $scfg, $storeid,
                                         $targetname, $lunid,
                                         $lunrec->{volname}, $lunrec->{snapname},
                                         $lunrec );
                last;
            }
        }
        else {
            last;
        }
        sleep(1);
    }
}

sub volume_update_size {
    my ( $scfg, $storeid, $vmid, $volname, $size ) = @_;

    my $tgname;
    my $lunrecinfolist = OpenEJovianDSS::Common::lun_record_local_get_info_list( $scfg, $storeid, $volname, undef );

    $tgname = OpenEJovianDSS::Common::get_vm_target_group_name($scfg, $vmid);

    if ( @$lunrecinfolist ) {
        if ( @$lunrecinfolist == 1 ) {
            my ($targetname, $lunid, $lunrecpath, $lunrecord) = @{ $lunrecinfolist->[0] };
            lun_record_update_device( $scfg, $storeid, $targetname, $lunid, $lunrecpath, $lunrecord, $size);
        } else {
            foreach my $rec (@$lunrecinfolist) {
                my $tinfo = target_active_info( $scfg, $tgname, $volname, undef, undef );
                if ( defined( $tinfo ) ){
                    my ($targetname, $lunid, $lunrecpath, $lunrecord) = $rec;

                    if ( $tinfo->{name} eq $targetname ) {
                        if ( $tinfo->{lun} eq $lunid ) {
                            if ( $lunrecord->{volname} eq $volname ) {
                                unless(defined($lunrecord->{snapname})) {
                                        lun_record_update_device( $scfg, $storeid, $targetname, $lunid, $lunrecpath, $lunrecord, $size);
                                        return;
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    1;
}

sub volume_get_size {
    my ( $scfg, $storeid, $volname ) = @_;

    my $pool = get_pool($scfg);

    my $output = joviandss_cmd($scfg, ["pool", $pool, "volume", $volname, "get", "-s"]);

    my $size = int( clean_word( $output ) + 0 );
    return $size;
}

sub store_settup {
    my ( $scfg, $storeid ) = @_;

    my $path = OpenEJovianDSS::Common::get_content_path($scfg);

    my $lldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR, $storeid );

    unless ( -d $lldir ) {
        make_path( $lldir, { mode => 0755 } )
                or die "Unable to create local lun record dirrectory $lldir: $!";
    }
}
1;
