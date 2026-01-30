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
use Carp qw( confess longmess );
use Cwd qw( );
use Data::Dumper;
use File::Basename;
use File::Find qw(find);
use File::Path qw(make_path);
use File::Spec;
use String::Util;

use Fcntl qw(:DEFAULT O_WRONLY O_APPEND O_CREAT O_SYNC);
use IO::Handle;

use JSON qw(decode_json from_json to_json);
#use PVE::SafeSyslog;

use Time::HiRes qw(gettimeofday);

use PVE::INotify;
use PVE::Tools qw(run_command);

our @EXPORT_OK = qw(

  block_device_path_from_lun_rec
  block_device_path_from_rest

  clean_word

  get_default_control_port
  get_default_content_size
  get_default_data_port
  get_default_debug
  get_default_luns_per_target
  get_default_multipath
  get_default_path
  get_default_pool
  get_default_prefix
  get_default_user_name
  get_default_ssl_cert_verify
  get_default_target_prefix

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
  get_block_size_bytes
  get_thin_provisioning
  get_log_file
  get_content
  get_content_volume_name
  get_content_volume_type
  get_content_volume_size
  get_content_path
  get_multipath

  get_log_level
  get_debug

  password_file_set_password

  password_file_delete

  safe_var_print
  debugmsg
  joviandss_cmd
  volume_snapshots_info
  volume_rollback_check

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

  ha_state_get
  ha_state_is_defined
  ha_type_get

);

our %EXPORT_TAGS = ( all => [@EXPORT_OK], );

my $PLUGIN_LOCAL_STATE_DIR = '/etc/joviandss/state';
my $PLUGIN_GLOBAL_STATE_DIR = '/etc/pve/priv/joviandss/state';


my $ISCSIADM = '/usr/bin/iscsiadm';
$ISCSIADM = undef if !-X $ISCSIADM;

my $MULTIPATH = '/usr/sbin/multipath';
$MULTIPATH = undef if !-X $MULTIPATH;

my $MULTIPATHD = '/usr/sbin/multipathd';
$MULTIPATHD = undef if !-X $MULTIPATHD;

my $DMSETUP = '/usr/sbin/dmsetup';
$DMSETUP = undef if !-X $DMSETUP;

my $default_block_size       = '16K';
my $default_content_size     = 100;
my $default_control_port     = 82;
my $default_create_base_path = 1;
my $default_data_port        = 3260;
my $default_debug            = 0;
my $default_prefix           = 'jdss-';
my $default_pool             = 'Pool-0';
my $default_log_file         = '/var/log/joviandss/joviandss.log';
my $default_luns_per_target  = 8;
my $default_multipath        = 0;
my $default_path             = '/mnt/joviandss';
my $default_shared           = 0;
my $default_target_prefix    = 'iqn.2025-04.proxmox.joviandss.iscsi:';
my $default_user_name        = 'admin';
my $default_ssl_cert_verify  = 1;


sub get_default_block_size       { return $default_block_size }
sub get_default_create_base_path { return $default_create_base_path }
sub get_default_prefix           { return $default_prefix }
sub get_default_pool             { return $default_pool }
sub get_default_debug            { return $default_debug }
sub get_default_multipath        { return $default_multipath }
sub get_default_content_size     { return $default_content_size }
sub get_default_path             { return $default_path }
sub get_default_target_prefix    { return $default_target_prefix }
sub get_default_log_file         { return $default_log_file }
sub get_default_luns_per_target  { return $default_luns_per_target }
sub get_default_ssl_cert_verify  { return $default_ssl_cert_verify }
sub get_default_control_port     { return $default_control_port }
sub get_default_data_port        { return $default_data_port }
sub get_default_user_name        { return $default_user_name }

sub get_path {
    my ($scfg) = @_;

    return $scfg->{'path'} if defined( $scfg->{ 'path' } );
    return get_default_path();
}

sub get_pool {
    my ($scfg) = @_;

    die "pool name required in storage.cfg \n"
      if !defined( $scfg->{'pool_name'} );
    return $scfg->{'pool_name'};
}

sub get_create_base_path {
    my ($scfg) = @_;

    return $scfg->{'create-base-path'} if ( defined( $scfg->{ 'create-base-path' } ) );

    return get_default_create_base_path();
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
    return clean_word($prefix);
}

sub get_luns_per_target {
    my ($scfg) = @_;
    my $luns_per_target = $scfg->{luns_per_target} || $default_luns_per_target;

    return int($luns_per_target);
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
    return get_data_addresses( $scfg );
}

sub get_control_port {
    my ($scfg) = @_;
    my $port = $scfg->{control_port} || $default_control_port;

    return int( clean_word($port) + 0);
}

sub get_data_addresses {
    my ($scfg) = @_;

    if ( defined( $scfg->{data_addresses} ) ) {
        return clean_word($scfg->{data_addresses});
    } else {
        die "JovianDSS data addresses are not provided.\n";
    }
}

sub get_data_port {
    my ($scfg) = @_;

    if ( defined( $scfg->{data_port} ) ) {
        return  int( clean_word($scfg->{data_port}) + 0);
    }
    return get_default_data_port();
}

sub get_user_name {
    my ($scfg) = @_;
    return $scfg->{user_name} || $default_user_name;
}

sub get_user_password {
    my ($storeid) = @_;
    my $pwfile = get_password_file_name($storeid);

    return undef if ! -f $pwfile;

    my $content = PVE::Tools::file_get_contents($pwfile);
    my $config = {};

    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || $line eq '';

        if ($line =~ /^(\S+)\s+(.+)$/) {
            $config->{$1} = $2;
        }
    }

    return $config->{user_password};
}

sub get_password_file_name {
    my ($storeid) = @_;
    return "/etc/pve/priv/storage/joviandss/${storeid}.pw";
}

sub password_file_set_password {
    my ($password, $storeid) = @_;
    my $pwfile = get_password_file_name($storeid);

    # Create directory with full path
    my $dir = "/etc/pve/priv/storage/joviandss";
    if (! -d $dir) {
        File::Path::make_path($dir, { mode => 0700 });
    }

    PVE::Tools::file_set_contents($pwfile, "user_password $password\n", 0600, 1);
}

sub password_file_delete {
    my ($storeid) = @_;
    my $pwfile = get_password_file_name($storeid);
    unlink $pwfile;
}

sub get_block_size {
    my ($scfg) = @_;

    # This function is used by others
    # and should return only valid block size strings

    if (defined( $scfg->{block_size} ) ) {
        my $block_size_str = $scfg->{block_size};

        my %valid_sizes = map { $_ => 1 } qw(
            4K 8K 16K 32K 64K 128K 256K 512K 1M
        );

        $block_size_str =~ s/\s+//g;
        $block_size_str = uc($block_size_str);

        if ( exists $valid_sizes{$block_size_str} ) {
            return $block_size_str;
        } else {
            die "Block size ${block_size_str} is not supported\n";
        }
    }
    return $default_block_size;
}

sub get_block_size_bytes {
    my ($scfg) = @_;

    my $block_size_str = get_block_size($scfg);

    $block_size_str =~ s/\s+//g;
    $block_size_str = uc($block_size_str);

    if ($block_size_str =~ /^(\d+)([KM]?)$/) {
        my ($number, $unit) = ($1, $2);

        if ($unit eq 'K') {
            return $number * 1024;
        } elsif ($unit eq 'M') {
            return $number * 1024 * 1024;
        }
    }
    die "Unable to calculate proper number of bytes in ${block_size_str}";
}

sub get_thin_provisioning {
    my ($scfg) = @_;
    if ( defined( $scfg->{thin_provisioning} ) ) {
        if ( $scfg->{thin_provisioning} ) {
            return 'y';
        } else {
            return 'n';
        }
    }
    # Default to enabled (thin provisioning)
    return 'y';
}

sub get_log_file {
    my ($scfg) = @_;
    return $scfg->{log_file} || $default_log_file;
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
        die "Unknown type of content storage required\n";
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

    #unless(defined($word)) {
    #    confess "Undefined word for cleaning\n";
    #}
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

sub debugmsg_trace {
    my ( $scfg, $dlevel, $msg ) = @_;
    my $stack = longmess($msg || "Stack trace:");
    debugmsg( $scfg, $dlevel, $stack );
}

sub debugmsg {
    my ( $scfg, $dlevel, $msg ) = @_;

    chomp $msg;

    return if !$msg;

    my $msg_level = map_log_level_to_number($dlevel);

    my $config_level = get_log_level($scfg);
    if ( $config_level >= $msg_level ) {

        $log_file_path = get_log_file($scfg);

        my ( $seconds, $microseconds ) = gettimeofday();

        my $milliseconds = int( $microseconds / 1000 );

        my ( $sec, $min, $hour, $day, $month, $year ) = localtime($seconds);
        $year  += 1900;
        $month += 1;
        my $line =
          sprintf( "%04d-%02d-%02d %02d:%02d:%02d.%03d - plugin - %s - %s",
            $year, $month,        $day,        $hour, $min,
            $sec,  $milliseconds, uc($dlevel), $msg );

        if ( $log_file_path =~ /^([\:\-\@\w.\/]+)$/ ) {
            my $log_file_abs_path;
            $log_file_abs_path = File::Spec->rel2abs($log_file_path);

            if ( $log_file_abs_path =~ /^([\:\-\@\w.\/]+)$/ ) {
                my $log_file_abs_dir = File::Basename::dirname($log_file_abs_path);

                unless ( -d $log_file_abs_dir ) {
                    if ( $log_file_abs_dir =~ /^([\:\-\@\w.\/]+)$/ ) {
                        make_path $log_file_abs_dir, { owner => 'root', group => 'root' };
                        chmod 0755, $log_file_abs_dir;
                    } else {
                        die "Log file dir name is incorrect\n";
                    }
                }
            } else {
                die "Log file path is incorrect\n";
            }
        }

        my $fh;

        if ( !sysopen( $fh, $log_file_path, O_WRONLY|O_APPEND|O_CREAT|O_SYNC, 0644 ) ) {
            warn "log file '$log_file_path' opening failed: $!";
            return;
        }
        if ( !print {$fh} "$line\n" ) {
            warn "log file '$log_file_path' writing failed: $!";
            close $fh;
            return;
        }
        close($fh) or warn "log file '$log_file_path' closing failed: $!";
    }
}

sub safe_var_print {
    my ( $varname, $variable ) = @_;
    return defined($variable) ? "${varname} ${variable}" : "";
}

sub joviandss_cmd {
    my ( $scfg, $storeid, $cmd, $timeout, $retries, $force_debub_level ) = @_;

    my $msg = '';
    my $err = undef;
    my $target;
    my $retry_count = 0;

    $timeout = 40 if !$timeout;
    $retries = 0  if !$retries;
    my $connection_options = [];

    my $debug_level = map_log_level_to_number('debug');

    if ( defined($force_debub_level) ) {
        push @$connection_options, '--loglvl', $force_debub_level;
    } else {
        my $config_level = get_log_level($scfg);
        if ( $config_level >= $debug_level ) {
            push @$connection_options, '--loglvl', 'debug';
        }
    }
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
    } else {
        die "JovianDSS REST user name is not provided.\n";
    }

    my $user_password = get_user_password($storeid);
    if ( defined($user_password) ) {
        push @$connection_options, '--user-password', $user_password;
    } else {
        die "JovianDSS REST user password is not provided.\n";
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

        my $exitcode = 0;
        eval {
            my $jcmd = [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ];

            my $output   = sub {
                                    $msg .= "$_[0]\n";
                               };
            my $errfunc  = sub {
                                    $err .= "$_[0]\n";
                               };

            $exitcode = run_command( $jcmd,
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
            sleep( int( rand( $timeout + 1 ) ) );
            next;
        }

        if ($err) {
            die "${err}\n";
        }
        die "$rerr\n";
    }

    die "Unhandled state during running JovianDSS command\n";
}


sub cmd_log_output {
    my ( $scfg, $level , $cmd, $data ) = @_;
    my $cmd_str = join ' ', map {
        (my $a = $_) =~ s/'/'\\''/g; "'$a'"
    } @$cmd;
    debugmsg( $scfg, $level, "CMD ${cmd_str} output ${data}");
}

# Returns a hash with the snapshot names as keys and the following data:
# id        - Unique id to distinguish different snapshots even if the have the same name.
# timestamp - Creation time of the snapshot (seconds since epoch).
# Returns an empty hash if the volume does not exist.
sub volume_snapshots_info {
    my ( $scfg, $storeid, $volname ) = @_;

    my $pool = get_pool($scfg);

    my $output = joviandss_cmd(
        $scfg,
        $storeid,
        [
            'pool',      $pool,  'volume', $volname,
            'snapshots', 'list', '--guid', '--creation'
        ]
    );

    my $snapshots = {};
    my @lines     = split( /\n/, $output );
    for my $line (@lines) {
        my ( $name, $guid, $creation ) = split( /\s+/, $line );
        #my ($sname) = split;
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

sub vmid_is_qemu {
    my ( $scfg, $vmid) = @_;

    my $nodename = PVE::INotify::nodename();
    my $cmd = [
        'pvesh', 'get', "/nodes/${nodename}/qemu/${vmid}/status",
        '--output-format', 'json'
    ];
    my $json_out = '';
    my $err_out  = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };
    my $errfunc  = sub { $err_out  .= "$_[0]\n" };

    my $exitcode = run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => $errfunc,
        noerr   => 1
    );

    if ($exitcode != 0) {
        if ($err_out =~ /does not exist/) {
            debugmsg($scfg, 'debug', "${vmid} is not Qemu");
            return 0;
        }
        debugmsg($scfg, 'debug', "Unable to check if ${vmid} is Qemu: ${err_out}");
        return 0;
    }
    return 1;
}

sub vmid_is_lxc {
    my ($scfg, $vmid) = @_;

    my $nodename = PVE::INotify::nodename();
    my $cmd = [
        'pvesh', 'get', "/nodes/${nodename}/lxc/${vmid}/status",
        '--output-format', 'json'
    ];
    my $json_out = '';
    my $err_out  = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };
    my $errfunc  = sub { $err_out  .= "$_[0]\n" };

    my $exitcode = run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => $errfunc,
        noerr   => 1
    );

    if ($exitcode != 0) {
        if ($err_out =~ /does not exist/) {
            debugmsg($scfg, 'debug', "${vmid} is not LXC");
            return 0;
        }
        debugmsg($scfg, 'debug', "Unable to check if ${vmid} is LXC ${err_out}");
        return 0;
    }
    return 1;
}

sub vmid_identify_virt_type {
    # Check if there is a qemu config file or lxc config file
    # If one config file found reply with it
    # If unable to identify config reply with undef
    my ($scfg, $vmid) = @_;

    my $is_qemu = vmid_is_qemu($scfg, $vmid);

    my $is_lxc = vmid_is_lxc($scfg, $vmid);

    if ( $is_qemu == 1 && $is_lxc == 0 ) {
        return 'qemu';
    }
    if ( $is_qemu == 0 && $is_lxc == 1) {
        return 'lxc';
    }
    if ($is_qemu == 1 && $is_lxc == 1 ) {
        debugmsg($scfg, 'debug', "Unable to identify virtualisation type for ${vmid}, seams to be both Qemu and LXC");
        return undef;
    }
    debugmsg($scfg, 'debug', "Unable to identify virtualisation type for ${vmid}, seams neither Qemu nor LXC");
    return undef;
}

sub snapshots_list_from_vmid {
    my ( $scfg, $vmid) = @_;

    my $nodename = PVE::INotify::nodename();

    my $virtualisation = vmid_identify_virt_type( $scfg, $vmid);

    if (!defined($virtualisation)) {
        die "Unable to identify snapshots belonging to VM/CT. Unable to conduct forced rollback\n";
    }

    my @names;

    my $cmd = [
        'pvesh', 'get', "/nodes/${nodename}/${virtualisation}/${vmid}/snapshot",
        '--output-format', 'json'
    ];
    my $json_out = '';
    my $err_out  = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };
    my $errfunc  = sub { $err_out  .= "$_[0]\n" };

    my $exitcode = run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => $errfunc,
        noerr   => 1
    );

    if ($exitcode != 0) {
        die "Unable to acquire snapshots for ${vmid}\n";
    }

    my $snapshots = eval { decode_json($json_out) };
    return [] if ref($snapshots) ne 'ARRAY';

    foreach my $snap (@$snapshots) {
        next if !exists $snap->{name};
        next if $snap->{name} eq 'current';

        push @names, $snap->{name};
    }

    return \@names;
}

sub format_rollback_block_reason {
    my ($volname, $target_snap, $snapshots, $clones, $unmanaged_snaps, $blockers_unknown) = @_;

    my $msg = '';

    my $format_list = sub {
        my ($items) = @_;
        return '' if !$items || ref($items) ne 'ARRAY';
        return '' if @$items == 0;

        my @out;
        if (@$items > 5) {
            push @out, $items->[0], $items->[1], '...', $items->[-1];
        } else {
            @out = @$items;
        }
        return join('; ', @out);
    };

    my $has_managed   = $snapshots && @$snapshots;
    my $has_clones    = $clones && @$clones;
    my $has_unmanaged = $unmanaged_snaps && @$unmanaged_snaps;
    my $has_unknown   = $blockers_unknown && @$blockers_unknown;



    # ------------------------------------------------------------
    # Special case: ONLY unmanaged snapshots exist
    # ------------------------------------------------------------
    if ($has_unmanaged && !$has_managed && !$has_clones && !$has_unknown) {

        my $count = scalar(@$unmanaged_snaps);

        $msg .= "There are $count newer storage side snapshots:\n";
        $msg .= $format_list->($unmanaged_snaps) . "\n";

        $msg .= "\n";
        $msg .= "Hint: User can add 'force_rollback' tag to VM/Container in order to conduct rollback.\n";
        $msg .= "!! DANGER !! Rolling back with 'force_rollback' tag will result in destruction of newer storage side snapshots.\n";

        return $msg;
    }

    # ONLY unknown blockers exist
    if ($has_unknown && !$has_managed && !$has_clones && !$has_unmanaged) {

        my $count = scalar(@$blockers_unknown);

        $msg .= "There are $count newer rollback blockers of unknown origin:\n";
        $msg .= $format_list->($blockers_unknown) . "\n";

        $msg .= "\n";
        $msg .= "Hint: User can add 'force_rollback' tag to VM/Container in order to conduct rollback.\n";
        $msg .= "!! DANGER !! Rolling back with 'force_rollback' tag will result in destruction of newer storage side resources.\n";

        return $msg;
    }

    $msg .= "Rollback is possible to the latest Proxmox managed snapshot only.\n\n";

    # Normal combined cases
    my $printed = 0;
    my $append_section = sub {
        my ($label, $items) = @_;
        return if !$items || ref($items) ne 'ARRAY' || !@$items;
        $msg .= "---\n" if $printed;
        $msg .= $label . "\n";
        $msg .= $format_list->($items) . "\n\n";
        $printed = 1;
    };

    $msg .= "Hint: please remove newer resources:\n";

    $append_section->(
          scalar(@$snapshots)
          . " Proxmox managed snapshots: ",
        $snapshots
    ) if $has_managed;

    $append_section->(
        scalar(@$unmanaged_snaps)
        . " storage side snapshots: ",
        $unmanaged_snaps
    ) if $has_unmanaged;

    $append_section->(
        scalar(@$clones)
        . " dependent clones : ",
        $clones
    ) if $has_clones;

    $append_section->(
        scalar(@$blockers_unknown)
        . " newer rollback blockers with unknown origin: ",
        $blockers_unknown
    ) if $has_unknown;

    $msg .= "\n";

    return $msg;
}

sub volume_rollback_check {
    my ( $scfg, $storeid, $vmid, $volname, $snap, $blockers ) = @_;

    my $pool = get_pool($scfg);

    $blockers //= [];
    my $res;
    eval {
        $res = joviandss_cmd(
            $scfg,
            $storeid,
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

    my $blockers_found_flag = 0;
    my $blockers_found = [];
    foreach my $line ( split( /\n/, $res ) ) {
        foreach my $obj ( split( /\s+/, $line ) ) {
            push $blockers_found->@*, $obj;
            $blockers_found_flag = 1;
        }
    }

    if ( ! $blockers_found_flag ) {
        return 1;
    }

    my $blockers_snapshots_untracked = [];
    my $blockers_snapshots_tracked = [];
    my $blockers_clones = [];
    my $blockers_unknown = [];

    my $force_rollback = vm_tag_force_rollback_is_set($scfg, $vmid);

    my $managed_snapshots = snapshots_list_from_vmid($scfg, $vmid);
    my $force_rollback_possible = 1;

    foreach my $blocker ( $blockers_found->@* ) {
        if ( $blocker =~ /^snap:(.+)$/ ) {
            my $snap_blocker = $1;
            push $blockers->@*, $snap_blocker;
            my $managed_found = 0;
            foreach my $snap ( $managed_snapshots->@* ) {
                if ($snap eq $snap_blocker) {
                    $force_rollback_possible = 0;
                    $managed_found = 1;
                    push $blockers_snapshots_tracked->@*, $snap_blocker;
                    last;
                }
            }
            if ( ! $managed_found ) {
                    push $blockers_snapshots_untracked->@*, $snap_blocker;
            }

        } elsif ($blocker =~ /^clone:(.+)$/) {
            my $clone_blocker = $1;
            $force_rollback_possible = 0;
            push $blockers->@*, $clone_blocker;
            push $blockers_clones->@*, $clone_blocker;
        } else {
            $force_rollback_possible = 0;
            push $blockers->@*, $blocker;
            push $blockers_unknown->@*, $blocker;
        }
    }

    if ( $force_rollback && $force_rollback_possible) {
        return 1;
    }

    my $msg = format_rollback_block_reason($volname, $snap,
        $blockers_snapshots_tracked,
        $blockers_clones,
        $blockers_snapshots_untracked,
        $blockers_unknown);

    die $msg;
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

    my $cmdout = joviandss_cmd( $scfg, $storeid, $getaddressescmd );

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

sub block_device_iscsi_paths {
    my ( $scfg, $target, $lunid, $hosts ) = @_;

    my @targets_block_devices = ();
    my $path;
    my $port = get_data_port( $scfg );
    foreach my $host (@$hosts) {
        $path = "/dev/disk/by-path/ip-${host}:${port}-iscsi-${target}-lun-${lunid}";
        if ( -b $path ) {
            debugmsg( $scfg, "debug", "Target ${target} mapped to ${path}\n" );
            $path = clean_word($path);
            ($path) = $path =~ m{^(/dev/disk/by-path/[\w\-\.:/]+)$} or die "Tainted path: $path";
            push( @targets_block_devices, $path );
        }
    }
    return \@targets_block_devices;
}

sub target_active_info {
    my ( $scfg, $storeid, $tgname, $volname, $snapname, $contentvolflag ) = @_;
    # Provides target info by requesting target info from joviandss
    debugmsg( $scfg, "debug", "Acquiring active target info for "
                . "target group name ${tgname} "
                . "volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n"
            );

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

    my $out = joviandss_cmd( $scfg, $storeid, $gettargetcmd, 80, 3 );

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
    my ( $scfg, $storeid, $tgname, $volname, $snapname, $content_volume_flag ) = @_;

    my $pool   = get_pool($scfg);
    my $prefix = get_target_prefix($scfg);
    my $luns_per_target = get_luns_per_target($scfg);

    my $create_target_cmd = [
        'pool',            $pool,   'targets',             'create',
        '--target-prefix', $prefix, '--target-group-name', $tgname,
        '-v',              $volname, '--luns-per-target', $luns_per_target
    ];
    if ($snapname) {
        push( @$create_target_cmd, "--snapshot", $snapname );
    }
    else {
        if ( defined($content_volume_flag) && $content_volume_flag ) {
            push @$create_target_cmd, '-d';
        }
    }

    my $out = joviandss_cmd( $scfg, $storeid, $create_target_cmd, 80, 3 );
    my ( $targetname, $lunid, $ips ) = split( ' ', $out );

    my @iplist = split /\s*,\s*/, clean_word($ips);

    my %tinfo = (
        target => clean_word($targetname),
        lunid  => clean_word($lunid),
        iplist => \@iplist
    );
    debugmsg( $scfg, "debug",
            "Publish volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
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
      block_device_iscsi_paths( $scfg, $targetname, $lunid, $hosts );

    if ( @$targets_block_devices == @$hosts ) {
        return $targets_block_devices;
    }

    foreach my $host (@$hosts) {

        # Check if session already exists
        my $session_exists = 0;
        eval {
            my $cmd = [
                $ISCSIADM,
                '--mode', 'session'
            ];
            run_command(
                $cmd,
                outfunc => sub {
                    my $line = shift;
                    if ($line =~ /\Q$targetname\E/ && $line =~ /\Q$host\E/) {
                        $session_exists = 1;
                    }
                },
                errfunc => sub {
                    cmd_log_output($scfg, 'error', $cmd, shift);
                },
                noerr   => 1
            );
        };

        if ($session_exists) {
            debugmsg($scfg, "debug", "iSCSI session already exists for target ${targetname} on host ${host}");
        } else {
            eval {
                my $cmd = [
                        $ISCSIADM,
                        '--mode',       'node',
                        '-p',            $host,
                        '--targetname',  $targetname,
                        '-o', 'new'
                    ];

                run_command(
                    $cmd,
                    outfunc => sub { },
                    errfunc => sub {
                        cmd_log_output($scfg, 'warn', $cmd, shift);
                    },
                    noerr   => 1
                );
            };
            # Don't warn on node creation errors - already existing is normal

            # Attempt login
            eval {
                my $cmd = [
                        $ISCSIADM,
                        '--mode',       'node',
                        '-p',           $host,
                        '--targetname', $targetname,
                        '--login'
                    ];

                run_command(
                    $cmd,
                    outfunc => sub { },
                    errfunc => sub {
                        cmd_log_output($scfg, 'warn', $cmd, shift);
                    },
                    noerr   => 1
                );
            };
        } # End of iscsi session creation for given address
        debugmsg( $scfg, "debug", "Staging target ${targetname} of host ${host} done\n" );
    } # end of for loop over all addresses

    for ( my $i = 1 ; $i <= 5 ; $i++ ) {
        sleep(1);

        $targets_block_devices = block_device_iscsi_paths( $scfg, $targetname, $lunid, $hosts );

        if (@$targets_block_devices) {
            debugmsg( $scfg, "debug", "Stage iSCSI block devices @{ $targets_block_devices }\n" );
            return $targets_block_devices;
        }

        if ( $lunid =~ /^\A\d+\z$/ ) {
            my $cmd = [ '/usr/bin/rescan-scsi-bus.sh', '--sparselun', '--reportlun2', '--largelun', "--luns=${lunid}", '-a'];
            run_command(
                $cmd ,
                outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        } else {
            debugmsg( $scfg, "warn", "Lun id ${lunid} contains non digit symbols" );
        }
    }

    log_dir_content($scfg, $storeid, '/dev/disk/by-path');
    debugmsg( $scfg, "warn", "Unable to identify iscsi block device location @{ $targets_block_devices }\n" );

    die "Unable to locate target ${targetname} block device location.\n";
}

sub volume_stage_multipath {
    my ( $scfg, $scsiid ) = @_;
    $scsiid = clean_word($scsiid);

    my $mpath;

    if ( $scsiid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $id = $1;

        eval {
            my $cmd = [ $MULTIPATH, '-a', $id ];
            run_command(
                $cmd ,
                outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        my $is_multipath = 1;

        $mpath = block_device_path_from_serial( $id, $is_multipath);

        for my $attempt ( 1 .. 10) {
            eval {
                my $cmd = [ $MULTIPATH ];
                run_command(
                    $cmd,
                    outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                    noerr   => 1
                );
            };

            if ( -b $mpath ) {
                return clean_word($mpath);
            }

            debugmsg( $scfg,
                    "debug",
                    "Unable to identify block device mapper name for "
                    . "scsiid ${id} "
                    . "attempt ${attempt}"
                );
            eval {
                my $cmd = [ $MULTIPATH, '-a', $id ];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                    noerr   => 1
                );
            };

            eval {
                my $cmd = [ $MULTIPATHD, 'add', 'map', $id ];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                    noerr   => 1
                );
            };
            sleep(1);
        }
    } else {
        die "Invalid characters in scsiid: ${scsiid}";
    }

    if ( -b $mpath ) {
        return clean_word($mpath);
    }

    die "Unable to identify the multipath name for scsiid ${scsiid}\n";
}

# This function provides expecte path of block device
# on the side of proxmox server
sub block_device_path_from_serial {
    my ($id_serial, $multipath) = @_;

    if ( $multipath ) {
        return "/dev/mapper/${id_serial}";
    }
    return "/dev/disk/by-id/scsi-${id_serial}";
}

sub block_device_path_from_rest {
    my ( $scfg, $storeid, $volname, $snapname ) = @_;

    my $id_serial = id_serial_from_rest( $scfg, $storeid, $volname, $snapname );

    return block_device_path_from_serial(
                $id_serial,
                get_multipath($scfg) );
}

sub block_device_path_from_lun_rec {
    my ( $scfg, $storeid, $targetname, $lunid, $lunrec ) = @_;

    my $block_dev;

    my $block_device_path = undef;
    if ( get_multipath($scfg) ) {

        unless ($lunrec->{multipath}) {
            $lunrec->{multipath} = 1;
            lun_record_local_update( $scfg, $storeid,
                                     $targetname, $lunid,
                                     $lunrec->{volname}, $lunrec->{snapname},
                                     $lunrec );
            $block_dev = volume_stage_multipath( $scfg, $lunrec->{scsiid} );
            return $block_dev;
        }

        if ( $lunrec->{scsiid} =~ /^([\:\-\@\w.\/]+)$/ ) {
            my $id = $1;
            my $is_multipath = 1;
            $block_device_path = block_device_path_from_serial( $id, $is_multipath );
        } else {
            die "Incorrect symbols in scsi id $lunrec->{scsiid}\n";
        }
    }

    # Return scsi device path
    if ( $lunrec->{scsiid} =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $id = $1;
        my $is_not_multipath = 0;

        $block_device_path = block_device_path_from_serial( $id, $is_not_multipath );
    } else {
        die "Incorrect symbols in scsi id $lunrec->{scsiid}\n";
    }

    unless ( defined($block_device_path) ) {
        debugmsg( $scfg,
                "debug",
                "Block device path from lun record for "
                . "target ${targetname} "
                . "lun ${lunid} "
                . "not found\n"
            );
        die "Unable to identify path from lun record.\n";
    }

    debugmsg( $scfg,
            "debug",
            "Block device path from lun record for "
            . "target ${targetname} "
            . "lun ${lunid} "
            . "is ${block_device_path}\n"
        );
    return $block_device_path;
}

sub get_device_mapper_name {
    my ( $scfg, $wwid ) = @_;

    my $device_mapper_name;

    if ( $wwid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $id = $1;

        my $cmd = [ $MULTIPATH, '-ll', $id ];
        run_command(
            $cmd ,
            outfunc => sub {
                    my $line = shift;
                    chomp $line;
                    cmd_log_output($scfg, 'debug', $cmd, $line);
                    if ( $line =~ /\b$wwid\b/ ) {
                        my @parts = split( /\s+/, $line );
                        $device_mapper_name = $parts[0];
                    }
                },
            errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
            noerr   => 1
        );
    } else {
        die "Invalid characters in wwid: ${wwid}\n";
    }
    unless ( $device_mapper_name ) {
        return undef;
    }

    if ( $device_mapper_name =~ /^([\:\-\@\w.\/]+)$/ ) {

        debugmsg( $scfg, "debug", "Mapper name for ${wwid} is ${1}\n" );
        return $1;
    }
    return undef;
}

sub ha_state_is_defined {
     my ($scfg, $vmid) = @_;

     my $cmd = [
         'pvesh', 'get', "/cluster/ha/resources/${vmid}",
         '--output-format', 'json'
     ];
     my $json_out = '';
     my $err_out  = '';
     my $outfunc  = sub { $json_out .= "$_[0]\n" };
     my $errfunc  = sub { $err_out  .= "$_[0]\n" };

     my $exitcode = run_command(
         $cmd,
         outfunc => $outfunc,
         errfunc => $errfunc,
         noerr   => 1
     );

     if ($exitcode != 0) {
         if ($err_out =~ /no such resource/) {
             debugmsg($scfg, 'debug', "VM ${vmid} is not HA-managed");
             return 0;
         }
         die "Failed to check HA status for ${vmid}: ${err_out}";
     }

     if ($json_out eq '') {
         debugmsg($scfg, 'debug', "VM ${vmid} is not HA-managed (empty response)");
         return 0;
     }

     my $jdata = eval { decode_json($json_out) };
     if ($@ || ref($jdata) ne 'HASH') {
         die "Unexpected HA status response for ${vmid}: ${json_out}";
     }

     debugmsg($scfg, 'debug', "VM ${vmid} is HA-managed");
     return 1;
 }


sub ha_state_get {
    my ($scfg, $vmid) = @_;

    my $cmd = ['pvesh', 'get', "/cluster/ha/resources/${vmid}", '--output-format', 'json'];
    my $json_out = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };

    run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => sub {
            cmd_log_output($scfg, 'error', $cmd, shift);
        },
        noerr   => 1
    );
    my $jdata = decode_json($json_out);
    unless (ref($jdata) eq 'HASH') {
        die "Unexpected HA status content ${json_out}";
    }
    if (exists $jdata->{'state'}) {
        my $state = $jdata->{'state'};
        debugmsg( $scfg, 'debug', "HA state of ${vmid} is ${state}");
        return $state;
    } else {
        die "Unable to identify state of ${vmid}\n";
    }
}

sub ha_type_get {
    my ($scfg, $vmid) = @_;

    my $cmd = ['pvesh', 'get', "/cluster/ha/resources/${vmid}", '--output-format', 'json'];
    my $json_out = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };

    run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => sub {
            cmd_log_output($scfg, 'error', $cmd, shift);
        },
        noerr   => 1
    );
    my $jdata = decode_json($json_out);
    unless (ref($jdata) eq 'HASH') {
        die "Unexpected HA resource content ${json_out}";
    }
    if (exists $jdata->{'type'}) {
        my $type = $jdata->{'type'};
        debugmsg( $scfg, 'debug', "HA type of ${vmid} is ${type}");
        return $type;
    } else {
        die "Unable to identify type of ${vmid}\n";
    }
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

sub id_serial_from_rest {
    my ( $scfg, $storeid, $volname, $snapname ) = @_;

    my $pool = get_pool( $scfg );

    debugmsg( $scfg,"debug",
                "Obtain SCSI ID for volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n");

    my $jscsiid;
    if (defined($volname) && !defined($snapname)) {
        $jscsiid = joviandss_cmd(
            $scfg,
            $storeid,
            [
                "pool",   $pool,
                "volume", $volname,
                "get", "-i"
            ]
        );
    } elsif (defined($volname) && defined($snapname)) {
        $jscsiid = joviandss_cmd(
            $scfg,
            $storeid,
            [
                "pool",   $pool,
                "volume", $volname,
                "snapshot", $snapname,
                "get", "-i"
            ]
        );
    } else {
        die "Volume name is required to acquire scsi id\n";
    }

    if ( $jscsiid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $id = $1;
        my $uei64_bytes = substr( $id, 0, 16 );

        debugmsg( $scfg,"debug",
                "Obtain SCSI ID for volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n");

        return "2${uei64_bytes}";
    } else {
        die "Invalid characters in scsi id ${jscsiid}\n";
    }
}

sub volume_unstage_iscsi_device {
    my ( $scfg, $storeid, $targetname, $lunid, $hosts ) = @_;

    debugmsg( $scfg, "debug", "Volume unstage iscsi device ${targetname} with lun ${lunid}\n" );
    my $block_devs = block_device_iscsi_paths ( $scfg, $targetname, $lunid, $hosts );

    foreach my $idp (@$block_devs) {
        if ( -b $idp ) {

            my $bdp; # Block Device Path
            if ( $idp =~ /^([\:\-\@\w.\/]+)$/ ) {
                my $cmd = [ "readlink", "-f", $1 ];
                run_command(
                    $cmd,
                    outfunc => sub {
                        my $path = shift;
                        if ( $path =~ /^([\:\-\@\w.\/]+)$/ ) {
                            $bdp = $1;
                        }
                        cmd_log_output($scfg, 'debug', $cmd, $path);
                    },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); }
                );
            }
            my $block_device_name = File::Basename::basename($bdp);
            unless ( $block_device_name =~ /^[a-z0-9]+$/ ) {
                die "Invalid block device name ${block_device_name} " .
                        "for iscsi target ${targetname}\n";
            }
            my $delete_file = "/sys/block/${block_device_name}/device/delete";
            open my $fh, '>', $delete_file or die "Cannot open $delete_file $!";

            print $fh "1" or die "Cannot write to $delete_file $!";

            close $fh     or die "Cannot close ${delete_file} $!";
            debugmsg( $scfg, "debug", "Sending delete request to ${delete_file} done\n" );
        }
    }
    debugmsg( $scfg, "debug", "Volume unstage iscsi device ${targetname} done\n" );
}


sub volume_unstage_iscsi {
    my ( $scfg, $storeid, $targetname ) = @_;

    debugmsg( $scfg, "debug", "Volume unstage iscsi target ${targetname}\n" );

    # Driver should not commit any write operation including sync before unmounting
    # Because that myght lead to data corruption in case of active migration
    # Also we do not do volume unmounting

    eval {
        my $cmd = [ $ISCSIADM,
                    '--mode', 'node',
                    '--targetname',  $targetname,
                    '--logout' ];

        run_command(
            $cmd,
            outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
            errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
            noerr   => 1
        );
    };

    eval {
        my $cmd =[ $ISCSIADM,
                   '--mode', 'node',
                   '--targetname',  $targetname,
                   '-o', 'delete' ];

        run_command(
            $cmd,
            outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
            errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
            noerr   => 1
        );
    };
    debugmsg( $scfg, "debug", "Volume unstage iscsi target ${targetname} done\n" );
}

sub volume_unstage_multipath {
    my ( $scfg, $scsiid ) = @_;

    # Driver should not commit any write operation including sync before unmounting
    # Because that might lead to data corruption in case of active migration
    # Also we do not do any unmounting to volume as that might cause unexpected writes

    # Validate SCSI ID early to prevent injection attacks
    unless ( $scsiid =~ /^([\:\-\@\w.\/]+)$/ ) {
        die "SCSI ID contains forbidden symbols: ${scsiid}\n";
    }
    my $clean_scsiid = $1;

    debugmsg( $scfg, "debug", "Volume unstage multipath scsiid ${clean_scsiid}" );

    # Phase 1: Wait for device to become unused
    # There are strong suspicions that proxmox does not terminate qemu during migration
    # before calling volume deactivation. This prevents data corruption.
    my $device_ready = _volume_unstage_multipath_wait_unused($scfg, $clean_scsiid);
    unless ($device_ready) {
        debugmsg( $scfg, "warn", "Device ${clean_scsiid} may still be in use, proceeding with cleanup" );
    }

    # Phase 2: Remove multipath device with retries
    my $cleanup_successful = _volume_unstage_multipath_remove_device($scfg, $clean_scsiid);

    if ($cleanup_successful) {
        debugmsg( $scfg, "debug", "Volume unstage multipath scsiid ${clean_scsiid} completed successfully" );
        return;
    } else {
        die "Failed to remove multipath device for SCSI ID ${clean_scsiid} after multiple attempts\n";
    }
}

sub _volume_unstage_multipath_wait_unused {
    my ( $scfg, $scsiid ) = @_;

    # Before we try to remove multipath device
    # Let's check if no process is using it
    # The problem with such approach is that there might be some data syscalls to multipath
    # block device that remain unfinished while we conduct multipath deactivation
    # That might probably affect volume migration under heavy load when part of that data gets buffered

    for my $tick ( 1 .. 60) {
        # lets give it 1 minute to finish its business
        my $should_continue = 1;

        eval {
            my $pid;
            my $blocker_name;

            my $mapper_name = get_device_mapper_name( $scfg, $scsiid );

            # Check if mapper exists and is valid
            if ( !defined($mapper_name) ) {
                debugmsg( $scfg, "debug", "Multipath device mapper name is not defined");
                $should_continue = 0;
                return;
            }

            if ( $mapper_name !~ /^([\:\-\@\w.\/]+)$/ ) {
                debugmsg( $scfg, "debug", "Multipath device mapper name is incorrect: ${mapper_name}");
                $should_continue = 0;
                return;
            }

            my $clean_mapper_name = $1;
            my $mapper_path = "/dev/mapper/${clean_mapper_name}";

            # Check if mapper device file exists
            if ( !-b $mapper_path ) {
                debugmsg( $scfg, "debug", "Multipath device mapping ${mapper_path} does not exist");
                return;
            }

            # Check device usage
            debugmsg( $scfg, "debug", "Check usage of multipath mapping ${mapper_path}" );
            my $cmd = [ 'lsof', '-t', $mapper_path ];
            eval {
                run_command(
                    $cmd,
                    outfunc => sub {
                        $pid = clean_word(shift);
                        cmd_log_output($scfg, 'debug', $cmd, $pid);
                    },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); }
                );
            };
            if ($@) {
                my $err = $@;
                debugmsg( $scfg, "warn", "Unable to identify mapper user for ${mapper_path}: ${err}");
                $should_continue = 0;
                return 1;
            }

            debugmsg( $scfg, "debug", "Multipath device mapping ${mapper_path} is used by ${pid}");

            if ($pid) {
                $pid = clean_word($pid);
                print("Block device with SCSI ${scsiid} is used by ${pid}\n");

                # Get process name for diagnostics
                if ( $pid =~ /^([\:\-\@\w.\/]+)$/ ) {
                    my $clean_pid = $1;
                    my $cmd = [ 'ps', '-o', 'comm=', '-p', $clean_pid ];
                    run_command(
                        $cmd,
                        outfunc => sub {
                            $blocker_name = clean_word(shift);
                            cmd_log_output($scfg, 'debug', $cmd, $blocker_name);
                        },
                        errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); }
                    );
                    my $warningmsg = "Multipath device "
                        . "with scsi id ${scsiid}, "
                        . "is used by ${blocker_name} with pid ${pid}";
                    debugmsg( $scfg, 'warn', $warningmsg );
                    warn "${warningmsg}\n";
                }
            } else {
                print("Block device with SCSI ${scsiid} is not used\n");
                $should_continue = 0;
            }
        };

        if ($@) {
            debugmsg( $scfg, 'warn', "Error during device usage check: $@" );
        }

        # Exit loop if device is unused or we encountered an exit condition
        unless ($should_continue) {
            return 1;
        }

        sleep(1);
    }

    return 1; # Always return success after timeout
}

sub _volume_unstage_multipath_remove_device {
    my ( $scfg, $scsiid ) = @_;

    for my $attempt ( 1 .. 5) {
        debugmsg( $scfg, "debug", "Multipath removal attempt ${attempt} for SCSI ID ${scsiid}" );

        # Step 1: Remove SCSI ID from WWID file
        eval {
            my $cmd = [ $MULTIPATH, '-w', $scsiid ];
            run_command(
                $cmd,
                outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };
        if ($@) {
            debugmsg( $scfg, 'warn', "Unable to remove scsi id ${scsiid} from wwid file: $@" );
        }

        # Step 2: Reload multipath maps
        eval {
            my $cmd = [ $MULTIPATH, '-r' ];
            run_command(
                $cmd,
                outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        # Step 3: Refresh multipath state
        eval {
            my $cmd = [ $MULTIPATH ];
            run_command(
                $cmd,
                outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        # Step 4: Force remove via dmsetup if mapper still exists
        my $mapper_name = get_device_mapper_name( $scfg, $scsiid );
        if ( defined($mapper_name) ) {
            if ( $mapper_name =~ /^([\:\-\@\w.\/]+)$/ ) {
                my $clean_mapper_name = $1;
                eval {
                    my $cmd = [ $DMSETUP, "remove", "-f", $clean_mapper_name ];
                    run_command( $cmd,
                        outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                        errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); }
                    );
                };
                if ($@) {
                    debugmsg( $scfg, 'warn', "Unable to remove the multipath mapping for volume with scsi id ${scsiid} with dmsetup: $@" );
                }
            } else {
                debugmsg( $scfg, 'warn', "Mapper name contains forbidden symbols: ${mapper_name}" );
            }
        } else {
            debugmsg( $scfg, "debug", "Volume unstage multipath scsiid ${scsiid} done" );
            return 1;
        }

        # Step 5: Final multipath refresh and check
        eval {
            my $cmd = [ $MULTIPATH ];
            run_command(
                $cmd,
                outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        sleep(1);
        $mapper_name = get_device_mapper_name( $scfg, $scsiid );
        unless ( defined($mapper_name) ) {
            debugmsg( $scfg, "debug", "Volume unstage multipath scsiid ${scsiid} done" );
            return 1;
        }

        # Log remaining device usage for diagnostics
        _volume_unstage_multipath_log_blockers($scfg, $scsiid, $mapper_name);
        debugmsg( $scfg, "debug", "Unable to remove multipath mapping for scsiid ${scsiid} in attempt ${attempt}" );
    }

    return 0; # All attempts failed
}

sub _volume_unstage_multipath_log_blockers {
    my ( $scfg, $scsiid, $mapper_name ) = @_;

    my $mapper_path = "/dev/mapper/${mapper_name}";
    if ( -b $mapper_path) {
        my $pid;
        my $blocker_name;
        eval {
            my $cmd = [ 'lsof', '-t', $mapper_path ];
            run_command(
                $cmd,
                outfunc => sub {
                    $pid = clean_word(shift);
                    cmd_log_output($scfg, 'debug', $cmd, $pid);
                },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); }
            );
            if ( $pid =~ /^([\:\-\@\w.\/]+)$/ ) {
                my $clean_pid = $1;
                $cmd = [ 'ps', '-o', 'comm=', '-p', $clean_pid ];
                run_command(
                    $cmd,
                    outfunc => sub {
                        $blocker_name = clean_word(shift);
                        cmd_log_output($scfg, 'debug', $cmd, $blocker_name);
                    },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); }
                );
                my $warningmsg = "Unable to deactivate multipath device "
                    . "with scsi id ${scsiid}, "
                    . "device is used by ${blocker_name} with pid ${pid}";
                debugmsg( $scfg, 'warn', $warningmsg );
                warn "${warningmsg}\n";
            }
        };
        if ($@) {
            debugmsg( $scfg, 'warn', "Unable to identify multipath blocker: $@" );
        }
    } else {
        debugmsg( $scfg, "debug", "Multipath device file ${mapper_path} removed" );
    }
}

sub volume_unpublish {
    my ( $scfg, $storeid, $vmid, $volname, $snapname, $content_volume_flag ) = @_;

    my $pool = get_pool( $scfg );
    my $prefix = get_target_prefix($scfg);

    debugmsg( $scfg,"debug",
                "Unpublish volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n");

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
            $storeid,
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
            $storeid,
            [
                'pool', $pool,
                'targets', 'delete',
                '--target-prefix', $prefix,
                '--target-group-name', $tgname,
                '-v', $volname
            ]
        );
    }

    if ( defined( $snapname ) ) {
        joviandss_cmd(
            $scfg,
            $storeid,
            [
                'pool', $pool,
                'targets', 'delete',
                '--target-prefix', $prefix,
                '--target-group-name', $tgname,
                '-v', $volname,
                '--snapshot', $snapname]);
    }
    1;
}

sub lun_record_local_create {
    my (
        $scfg,    $storeid,
        $targetname, $lunid, $volname, $snapname,
        $scsiid, $size,
        $multipath, $shared,
        @hosts
    ) = @_;

    my $ltldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR,
                                     $storeid, $targetname, $lunid );
    make_path $ltldir, { owner => 'root', group => 'root' };

    my $ltlfile = File::Spec->catfile( $ltldir, $volname );

    my $record = {
        scsiid   => clean_word($scsiid),
        volname   => clean_word($volname),
        snapname  => defined($snapname) ? clean_word($snapname) : undef,
        size      => $size,
        hosts     => \@hosts,
        multipath => $multipath ? \1 : \0,
        shared    => $shared ? \1 : \0,
    };

    my $json_text = JSON::encode_json($record) . "\n";

    if ( $ltlfile =~ /^([\:\-\@\w.\/]+)$/ ) {
        open my $fh, '>', $ltlfile
          or die "Failed to create local lun record at '$ltlfile': $!\n";
        print {$fh} $json_text;
        close $fh or die "Failed to finish writing to local lun file '$ltlfile': $!\n";
    } else {
        die "Incorrect local lun file path $ltlfile\n";
    }
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
    $ltldir = clean_word($ltldir);
    unless ( -d $ltldir) {
        make_path $ltldir, { owner => 'root', group => 'root' };
    }

    my $ltlfile = File::Spec->catfile( $ltldir, $volname );

    my $json_text = JSON::encode_json($lunrec) . "\n";

    if ( $ltlfile =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $filename = $1;
        open my $fh, '>', $filename
          or die "Failed to create local lun record at '$filename': $!\n";
        print {$fh} $json_text;
        close $fh or die "Failed to finish writing to local lun file '$filename': $!\n";
    } else {
        die "Invalid character in lun file path: ${ltlfile}\n";
    }
    return $ltlfile;
}

sub lun_record_local_get_info_list {
    my ($scfg, $storeid, $volname, $snapname, $tgname ) = @_;

    # Provides
    # ( target name, lun number, path to lun record file, lun record data )

    debugmsg( $scfg, "debug", "Searching for lun record of volume ${volname} "
        . safe_var_print( "snapshot", $snapname )
        . safe_var_print( "target group", $tgname )
        . "\n");

    my @matches = ();

    my $name = $volname;

    my $ldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR, $storeid );

    unless( -d $ldir ){
        die "Unable to locate folder containing ${ ldir } plugin state\n";
    }

    File::Find::find(
        {
            no_chdir => 1,
            wanted   => sub {
                my $full = $File::Find::name;

                # Expect path .../<storeid>/<target>/<lun_id>/$name
                unless ($full =~ m!^\Q$ldir\E/([^/]+)/(\d+)/\Q$name\E$!) {
                    return;
                }
                my ($targetname, $lunid) = ($1, $2);
                $targetname = clean_word($targetname);
                $lunid = clean_word($lunid);

                # TODO: consider using target group name
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
                                debugmsg( $scfg, "debug", "Found lun record of volume ${volname} "
                                    . safe_var_print( "snapshot", $snapname )
                                    . safe_var_print( "target group", $tgname )
                                    . " targetname ${targetname}"
                                    . " lunid ${lunid}\n");
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

    for my $key (qw(scsiid volname snapname size multipath hosts multipath shared)) {
        die "Local lun record ${path} is missing '$key'"
            unless exists $jdata->{$key};
    }

    return $jdata;
}


sub log_dir_content {
    my ( $scfg, $storeid, $dir ) = @_;

    if (opendir my $dh, $dir) {
        my @files = grep { $_ ne '.' && $_ ne '..' } readdir $dh;

        closedir $dh;

        foreach my $file ( @files ) {
            debugmsg( $scfg, "debug", "Folder ${dir} contains ${file}");
        }
    } else {
        warn "Cannot open directory '$dir': $!";
    }

}

sub lun_record_local_delete {
    my ( $scfg, $storeid, $targetname, $lunid, $volname, $snapname ) = @_;

    debugmsg( $scfg, "debug", "Deleting local lun record for "
        . "target ${targetname} "
        . "lun ${lunid} "
        . "volume ${volname} "
        . safe_var_print( "snapshot", $snapname )
        . "\n");

    debugmsg($scfg, 'debug', "delete lun record check\n");
    my $ltdir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR,
                                    $storeid, $targetname );
    unless ( -d $ltdir ) {
        eval {
            volume_unstage_iscsi(
                $scfg,
                $storeid,
                $targetname
            );
        };
        my $cerr = $@;
        if ($cerr) {
            warn "volume_unstage_iscsi failed: $@" if $@;
        }
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

                volume_unstage_iscsi( $scfg, $storeid, $targetname );

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
            debugmsg( $scfg, 'warn',
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
        $tgname = get_content_target_group_name($scfg);
    } else {
        $tgname = get_vm_target_group_name($scfg, $vmid);
    }

    debugmsg( $scfg, "debug",
            "Activating volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );

    eval {
        $published = 1;
        $tinfo = volume_publish($scfg,
                                $storeid,
                                $tgname,
                                $volname,
                                $snapname,
                                $content_volume_flag
        );

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
        $scsiid = id_serial_from_rest( $scfg, $storeid, $volname, $snapname );

        if (defined( $scsiid ) ) {
            $scsiid_acquired = 1;
        } else {
            die "Unable to identify scsi id for ${volname}" .
                safe_var_print( "snapshot", $snapname ) . "\n";
        }

        if ($multipath) {
            $multipath_staged = 1;
            my $multipath_path = volume_stage_multipath( $scfg, $scsiid );
            my $mpdl = [ clean_word($multipath_path) ];
            $block_devs = $mpdl;
        }

        my $size = volume_get_size( $scfg, $storeid, $volname);

        $local_record_created      = 1;
        my $ltlfile;

        $ltlfile = lun_record_local_create(
                $scfg, $storeid,
                $targetname, $lunid, $volname, $snapname,
                $scsiid, $size,
                $multipath, $shared,
                @{ $hosts } );
        # We do it to recheck device size and properties
        # That is needed to ensure that proxmox recognize device as present
        # after volume migrates back
        my $lunrec = lun_record_local_get_by_path( $scfg, $storeid, $ltlfile );
        lun_record_update_device( $scfg, $storeid, $targetname, $lunid, $ltlfile, $lunrec, $size );

    };
    my $err = $@;

    if ($err) {
        warn "Volume ${volname} " . safe_var_print( "snapshot", $snapname ) . " activation failed: $err";

        my $local_cleanup = 0;


        if ($multipath_staged) {
            eval {
                volume_unstage_multipath( $scfg, $scsiid );
            };
            my $cerr = $@;
            if ($cerr) {
                $local_cleanup = 1;
                warn "volume_unstage_multipath failed: $@" if $@;
            }
        }

        if ( $iscsi_staged ) {
            volume_unstage_iscsi_device( $scfg, $storeid, $targetname, $lunid, $hosts );
        }

        # volume_unstage_iscsi call is moved to lun_record_local_delete

        if ( $snapname ) {
            # We do not delete target on joviandss as this will lead to race condition
            # in case of migration
            if ( $published ) {
                eval {
                    volume_unpublish( $scfg, $storeid, $vmid, $volname, $snapname, undef );
                };
                my $cerr = $@;
                if ($cerr) {
                    $local_cleanup = 1;
                    warn "unpublish_volume failed: $@" if $@;
                }
            }
        }

        # This is a last step of volume activation error handling
        # We alsways do lun record delete as this function checks for volumes provided by given iscsi target
        # and conducts iscsi logout if none is present

        if (defined($targetname) && defined($lunid) && $targetname ne "" && $lunid ne "") {
            eval {
                lun_record_local_delete( $scfg, $storeid, $targetname, $lunid, $volname, $snapname );
            };
        } else {
            debugmsg($scfg, 'debug', "Skipping volume ${volname} "
                     . safe_var_print( "snapshot", $snapname ) . ' '
                     .  'local LUN record delete - invalid target name or LUN ID'
                     . "\n" );
        }

        my $cerr = $@;
        if ($cerr) {
            $local_cleanup = 1;
            if ($local_record_created) {
                warn "delete_lun_record failed: $@" if $@;
            }
        }
        die $err;
    }
    unless ( defined( $block_devs ) ) {
        die "Unable to provide block device for volume ${volname}"
                . safe_var_print( "snapshot", $snapname )
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

    my $pool   = get_pool($scfg);
    my $prefix = get_target_prefix($scfg);

    debugmsg( $scfg, "debug",
            "Volume ${volname} deactivate "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );

    if ( defined($contentvolumeflag) && $contentvolumeflag != 0 ) {
        $tgname = get_content_target_group_name($scfg);
    } else {
        $tgname = get_vm_target_group_name($scfg, $vmid);
    }

    unless( $snapname ) {
        my $delitablesnaps = joviandss_cmd(
            $scfg,
            $storeid,
            [
                "pool",   $pool,
                "volume", $volname,
                "delete", "-c",  "-p",
                '--target-prefix', $prefix,
                '--target-group-name', $tgname
            ]
        );
        my @dsl = split( " ", $delitablesnaps );

        foreach my $snap (@dsl) {
            volume_deactivate( $scfg, $storeid, $vmid,
                $volname, $snap, undef );
        }
    }
    my $lunrecinfolist = lun_record_local_get_info_list( $scfg, $storeid, $volname, $snapname );

    if (scalar(@$lunrecinfolist) == 0) {
        debugmsg(
            $scfg,
            'warn',
            "Unable to identify lun record for "
                . "volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n"
            );
        return 1;
    }
    if ( @$lunrecinfolist ) {
        if ( @$lunrecinfolist == 1 ) {
            ($targetname, $lunid, $lunrecpath, $lunrecord) = @{ $lunrecinfolist->[0] };
        } else {

            foreach my $rec (@$lunrecinfolist) {
                my $tinfo = target_active_info( $scfg, $storeid, $tgname, $volname, $snapname, $contentvolumeflag );
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
        debugmsg(
            $scfg,
            'warn',
            "Unable to identify lun record for "
                . "volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n"
            );
        return 1;
    }

    if ( $lunrecord->{multipath} ) {
        eval {
            volume_unstage_multipath( $scfg, $lunrecord->{scsiid} );
        };
        my $cerr = $@;
        if ($cerr) {
            $local_cleanup = 1;
            warn "volume_unstage_multipath failed: $@" if $@;
        }
    }

    volume_unstage_iscsi_device ( $scfg, $storeid, $targetname, $lunid, $lunrecord->{hosts} );

    my $cerr;
    if ( $snapname ) {
    # We do not delete target on joviandss as this will lead to race condition
    # in case of migration
        eval {
            volume_unpublish( $scfg, $storeid, $vmid, $volname, $snapname, undef );
        };
        $cerr = $@;
        if ($cerr) {
            $local_cleanup = 1;
            warn "unpublish_volume failed: $@" if $@;
        }
    }
    lun_record_local_delete( $scfg, $storeid, $targetname, $lunid, $volname, $snapname );
    debugmsg( $scfg, "debug",
            "Volume ${volname} deactivate done "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );
    1;
}

sub lun_record_update_device {
    my ( $scfg, $storeid, $targetname, $lunid, $lunrecpath, $lunrec, $expectedsize ) = @_;

    unless(defined($lunrec)) {
        confess "Undefined lun record for updating\n";
    }

    my @hosts = @{ $lunrec->{hosts} };
    my $multipath = $lunrec->{multipath};

    my @update_device_try = ( 1 .. 10 );
    foreach (@update_device_try) {

        for my $iscsihost (glob '/sys/class/scsi_host/host*') {
            my $scan_file = "$iscsihost/scan";
            if ( $scan_file =~ /^([\:\-\@\w.\/]+)$/ ) {
                open my $fh, '>', $1
                  or warn "Cannot open $scan_file for writing: $!";
                print $fh "- - -\n"
                  or warn "Failed to write to $scan_file: $!";
                close $fh
                  or warn "Failed to close $scan_file: $!";
            }
        }

        my $iscsi_block_devices = block_device_iscsi_paths ( $scfg, $targetname, $lunid, $lunrec->{hosts} );
        my $block_device_path;
        foreach my $iscsi_block_device ( @{ $iscsi_block_devices } ) {
            eval {
                my $cmd = [ "readlink", "-f", $iscsi_block_device ];

                run_command(
                    $cmd,
                    outfunc => sub { $block_device_path = shift; },
                    errfunc => sub {
                        cmd_log_output($scfg, 'error', $cmd, shift);
                    },
                    noerr   => 1
                );
            };

            $block_device_path = clean_word($block_device_path);
            my $block_device_name = basename($block_device_path);
            unless ( $block_device_name =~ /^[a-z0-9]+$/ ) {
                die "Invalid block device name ${block_device_name} " .
                    " for iscsi target ${targetname}\n";
            }
            my $rescan_file = "/sys/block/${block_device_name}/device/rescan";
            open my $fh, '>', $rescan_file or die "Cannot open $rescan_file $!";
            print $fh "1" or die "Cannot write to $rescan_file $!";
            close $fh     or die "Cannot close ${rescan_file} $!";
        }


        eval {
            my $cmd = [ $ISCSIADM, '-m', 'session', '--rescan' ];

            run_command( $cmd,
                outfunc => sub { },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        eval {
            my $cmd = [ $ISCSIADM, '-m', 'node', '-R', '-T', ${targetname} ];
            run_command( $cmd,
                outfunc => sub { },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        eval {
            my $cmd = [ 'udevadm', 'trigger', '-t', 'all' ];
            run_command( $cmd,
                outfunc => sub { },
                errmsg =>
                  "Failed to update udev devices after iscsi target attachment",
                noerr   => 1
              );
        };
        if ( get_multipath($scfg) ) {

            unless ($lunrec->{multipath}) {
                $lunrec->{multipath} = 1;
                lun_record_local_update( $scfg, $storeid,
                                         $targetname, $lunid,
                                         $lunrec->{volname}, $lunrec->{snapname},
                                         $lunrec );
            }
            $block_device_path = volume_stage_multipath( $scfg, $lunrec->{scsiid} );
            eval {
                my $cmd = [ $MULTIPATH, '-r', ${block_device_path} ];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                    noerr   => 1
                );
                $cmd = [ $MULTIPATH, 'reconfigure'];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($scfg, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                    noerr   => 1
                );
            };
        }

        sleep(1);

        unless( -b $block_device_path ) {
            next;
        }
        my $updated_size;
        eval {
            my $cmd = [ '/sbin/blockdev', '--getsize64', $block_device_path ];
            run_command(
                $cmd,
                outfunc => sub {
                    my ($line) = @_;
                    die "unexpected output from /sbin/blockdev: $line\n"
                      if $line !~ /^(\d+)$/;
                    $updated_size = int($1);
                },
                errfunc => sub { cmd_log_output($scfg, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

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
    my $lunrecinfolist = lun_record_local_get_info_list( $scfg, $storeid, $volname, undef );

    $tgname = get_vm_target_group_name($scfg, $vmid);

    if ( @$lunrecinfolist ) {
        if ( @$lunrecinfolist == 1 ) {
            my ($targetname, $lunid, $lunrecpath, $lunrecord) = @{ $lunrecinfolist->[0] };
            lun_record_update_device( $scfg, $storeid, $targetname, $lunid, $lunrecpath, $lunrecord, $size);
        } else {
            foreach my $rec (@$lunrecinfolist) {
                my $tinfo = target_active_info( $scfg, $storeid, $tgname, $volname, undef, undef );
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

    my $output = joviandss_cmd($scfg, $storeid, ['pool', $pool, 'volume', $volname, 'get', '-s']);

    my $size = int( clean_word( $output ) + 0 );
    return $size;
}

sub store_settup {
    my ( $scfg, $storeid ) = @_;

    my $path = get_content_path($scfg);

    my $lldir = File::Spec->catdir( $PLUGIN_LOCAL_STATE_DIR, $storeid );

    unless ( -d $lldir) {
        make_path $lldir, { owner => 'root', group => 'root' };
    }
}

sub vm_tag_force_rollback_is_set {
    my ( $scfg, $vmid ) = @_;

    my $virt_type = vmid_identify_virt_type($scfg, $vmid);

    if ( ! defined($virt_type) ) {
        return 0;
    }
    my $nodename = PVE::INotify::nodename();

    my $cmd = [
        'pvesh', 'get', "/nodes/${nodename}/${virt_type}/${vmid}/config",
        '--output-format', 'json'
    ];
    my $json_out = '';
    my $err_out  = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };
    my $errfunc  = sub { $err_out  .= "$_[0]\n" };

    my $exitcode = run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => $errfunc,
        noerr   => 1
    );

    my $conf;
    eval {
        $conf = decode_json($json_out);
    };

    return 0 if $@ || ref($conf) ne 'HASH';

    return 0 if !defined $conf->{tags};

    my @tags = split(/[,;]/, $conf->{tags});

    foreach my $tag (@tags) {
        if ($tag eq 'force_rollback') {
            return 1;
        }
    }

    return 0;
}

1;
