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

use Fcntl qw(:DEFAULT :flock O_WRONLY O_APPEND O_CREAT O_SYNC);
use IO::Handle;

use JSON qw(decode_json from_json to_json);
#use PVE::SafeSyslog;

use Time::HiRes qw(gettimeofday);

use PVE::INotify;
use PVE::Tools qw(run_command file_set_contents);

our @EXPORT_OK = qw(

  new_ctx

  block_device_path_from_lun_rec
  block_device_path_from_rest

  clean_word
  cmd_log_output

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

  get_path
  get_pool
  get_config
  get_debug
  get_target_prefix
  get_ssl_cert_verify
  get_control_addresses
  get_control_port
  get_data_address
  get_data_addresses
  get_data_port
  get_delete_timeout
  get_user_name
  get_user_password
  get_chap_enabled
  get_chap_user_name
  get_chap_user_password
  get_block_size
  get_block_size_bytes
  get_thin_provisioning
  get_log_file
  get_options
  get_content
  get_content_volume_name
  get_content_volume_type
  get_content_volume_size
  get_content_path
  get_create_base_path
  get_multipath

  get_log_level
  get_debug

  password_file_set_password
  password_file_set_chap_password

  password_file_delete
  password_file_delete_chap_password

  safe_var_print
  safe_word
  debugmsg
  joviandss_cmd
  volume_snapshots_info
  volume_rollback_check
  remove_vm_snapshot_config

  get_iscsi_addresses
  get_target_path
  get_active_target_name
  get_vm_target_group_name
  get_content_target_group_name

  volume_get_size
  volume_update_size

  volume_publish
  volume_unpublish

  volume_activate
  volume_deactivate
  store_setup

  lun_record_local_get_info_list
  lun_record_update_device

  ha_state_get
  ha_state_is_defined
  ha_type_get

  vm_tag_force_rollback_is_set

);

our %EXPORT_TAGS = ( all => [@EXPORT_OK], );

use constant {
    PLUGIN_LOCAL_STATE_DIR          => '/etc/joviandss/state',
    PLUGIN_GLOBAL_STATE_DIR         => '/etc/pve/priv/joviandss/state',
    PLUGIN_GLOBAL_PASSWORD_FILE_DIR => '/etc/pve/priv/storage/joviandss',
};


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
my $default_path             = '/mnt/pve/joviandss';
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
sub get_default_path             { die "Please set up path property in storage.cfg\n"; }
sub get_default_target_prefix    { return $default_target_prefix }
sub get_default_log_file         { return $default_log_file }
sub get_default_luns_per_target  { return $default_luns_per_target }
sub get_default_ssl_cert_verify  { return $default_ssl_cert_verify }
sub get_default_control_port     { return $default_control_port }
sub get_default_data_port        { return $default_data_port }
sub get_default_user_name        { return $default_user_name }

sub get_path {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    return $scfg->{'path'} if defined( $scfg->{ 'path' } );
    return get_default_path();
}

sub get_pool {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    die "pool name required in storage.cfg \n"
      if !defined( $scfg->{'pool_name'} );
    return $scfg->{'pool_name'};
}

sub get_create_base_path {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    return $scfg->{'create-base-path'} if ( defined( $scfg->{ 'create-base-path' } ) );

    return get_default_create_base_path();
}

sub get_config {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    return $scfg->{config} if ( defined( $scfg->{config} ) );

    return undef;
}


sub get_debug {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    if ( defined( $scfg->{debug} ) && $scfg->{debug} ) {
        return 1;
    }
    return undef;
}

sub get_log_level {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    if ( defined( $scfg->{debug} ) && $scfg->{debug} ) {
        return map_log_level_to_number("DEBUG");
    }
    return map_log_level_to_number("INFO");
}

sub get_target_prefix {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    my $prefix = $scfg->{target_prefix} || $default_target_prefix;

    $prefix =~ s/:$//;
    return clean_word($prefix);
}

sub get_luns_per_target {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    my $luns_per_target = $scfg->{luns_per_target} || $default_luns_per_target;

    return int($luns_per_target);
}

sub get_ssl_cert_verify {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    return $scfg->{ssl_cert_verify};
}

sub get_delete_timeout {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    return $scfg->{delete_timeout} || 600;
}

sub get_control_addresses {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    if ( defined( $scfg->{control_addresses} ) ) {
        if ( length( $scfg->{control_addresses} ) > 2 ) {
            return $scfg->{control_addresses};
        }
    }
    return get_data_addresses( $ctx );
}

sub get_control_port {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    my $port = $scfg->{control_port} || $default_control_port;

    return int( clean_word($port) + 0);
}

sub get_data_address {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    # We do not not do traditional check, because address might be ipv6
    # with [] around it
    if (defined( $scfg->{server} ) ) {
        return clean_word($scfg->{server});
    }

    if (defined( $scfg->{data_addresses} )) {
        my $da = clean_word($scfg->{data_addresses});
        my @iplist = split( /\s*,\s*/, $da );
        return $iplist[0];
    }
    die "JovianDSS data addresses are not provided.\n";
}

sub get_data_addresses {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    if ( defined( $scfg->{data_addresses} ) ) {
        return clean_word($scfg->{data_addresses});
    } else {
        my $data_address = get_data_address($ctx);
        if ( defined($data_address) ) {
            return $data_address;
        }
        die "JovianDSS data addresses are not provided.\n";
    }
}

sub get_data_port {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    if ( defined( $scfg->{data_port} ) ) {
        return  int( clean_word($scfg->{data_port}) + 0);
    }
    return get_default_data_port();
}

sub get_user_name {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return $scfg->{user_name} || $default_user_name;
}

sub get_password_file_path {
    my ($ctx) = @_;
    my $storeid = $ctx->{storeid};
    return PLUGIN_GLOBAL_PASSWORD_FILE_DIR . "/${storeid}.pw";
}

sub _password_file_get_key {
    my ($ctx, $key) = @_;
    my $pwfile_path = get_password_file_path($ctx);

    return undef if ! -f $pwfile_path;

    my $content = PVE::Tools::file_get_contents($pwfile_path);
    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || $line eq '';
        if ($line =~ /^(\S+)\s+(.+)$/ && $1 eq $key) {
            return $2;
        }
    }
    return undef;
}

sub _password_file_set_key {
    my ($ctx, $key, $value) = @_;

    my $dir = PLUGIN_GLOBAL_PASSWORD_FILE_DIR;
    my $pwfile_path = get_password_file_path($ctx);

    File::Path::make_path($dir, { mode => 0700 }) if ! -d $dir;

    my %config;
    if (-f $pwfile_path) {
        my $content = PVE::Tools::file_get_contents($pwfile_path);
        foreach my $line (split /\n/, $content) {
            $line =~ s/^\s+|\s+$//g;
            next if $line =~ /^#/ || $line eq '';
            $config{$1} = $2 if $line =~ /^(\S+)\s+(.+)$/;
        }
    }

    $config{$key} = $value;

    my $out = '';
    for my $k (sort keys %config) {
        $out .= "$k $config{$k}\n";
    }
    PVE::Tools::file_set_contents($pwfile_path, $out, 0600, 1);
}

sub _password_file_delete_key {
    my ($ctx, $key) = @_;

    my $pwfile_path = get_password_file_path($ctx);
    die "password file '$pwfile_path' does not exist\n" unless -f $pwfile_path;

    my %config;
    my $content = PVE::Tools::file_get_contents($pwfile_path);
    foreach my $line (split /\n/, $content) {
        $line =~ s/^\s+|\s+$//g;
        next if $line =~ /^#/ || $line eq '';
        $config{$1} = $2 if $line =~ /^(\S+)\s+(.+)$/;
    }

    return unless exists $config{$key};
    delete $config{$key};

    if (%config) {
        my $password_file_data = '';
        for my $k (sort keys %config) {
            $password_file_data .= "$k $config{$k}\n";
        }
        PVE::Tools::file_set_contents($pwfile_path, $password_file_data, 0600, 1);
    } else {
        unlink $pwfile_path;
    }
}

sub get_user_password {
    my ($ctx) = @_;
    return _password_file_get_key($ctx, 'user_password');
}

sub get_chap_enabled {
    my ($ctx) = @_;
    return $ctx->{scfg}{chap_enabled} // 0;
}

sub get_chap_user_name {
    my ($ctx) = @_;
    return $ctx->{scfg}{chap_user_name};
}

sub get_chap_user_password {
    my ($ctx) = @_;
    return _password_file_get_key($ctx, 'chap_user_password');
}

sub password_file_set_password {
    my ($ctx, $password) = @_;
    _password_file_set_key($ctx, 'user_password', $password);
}

sub password_file_set_chap_password {
    my ($ctx, $password) = @_;
    _password_file_set_key($ctx, 'chap_user_password', $password);
}

sub password_file_delete {
    my ($ctx) = @_;
    my $pwfile_path = get_password_file_path($ctx);
    unlink $pwfile_path;
}

sub password_file_delete_chap_password {
    my ($ctx) = @_;
    _password_file_delete_key($ctx, 'chap_user_password');
}

sub get_block_size {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

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
    my ($ctx) = @_;

    my $block_size_str = get_block_size($ctx);

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
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
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
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return $scfg->{log_file} || $default_log_file;
}

sub get_options {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    my $options = $scfg->{options};
    if (defined($options)) {
        if ( $options =~ /^([\:\-\@\w.\/]+)$/ ) {
            return $1;
        } else {
            die "Options property contains forbiden symbols: ${options}\n";
        }
    } else {
        return undef;
    }
}

sub get_content {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return $scfg->{content};
}

sub get_content_volume_name {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

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
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
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
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    if ( get_debug($ctx) ) {
        print
"content_volume_size property is not set up, using default $default_content_size\n"
          if ( !defined( $scfg->{content_volume_size} ) );
    }
    my $size = $scfg->{content_volume_size} || $default_content_size;
    return $size;
}

sub get_content_path {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};

    if ( defined( $scfg->{path} ) ) {
        return $scfg->{path};
    }
    else {
        return undef;
    }
}

sub get_multipath {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return $scfg->{multipath} || $default_multipath;
}

sub get_shared {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return $scfg->{shared} || $default_shared;
}

sub clean_word {
    my ($word) = @_;

    #unless(defined($word)) {
    #    confess "Undefined word for cleaning\n";
    #}
    chomp($word);
    $word =~ s/[^[:ascii:]]//g;
    $word =~ s/^\s+|\s+$//g;

    return $word;
}

sub safe_word{
    my ($word, $word_desc) = @_;

    if ( $word =~ /^([\:\-\@\w.\/]+)$/ ) {
        return $1;
    } else {
        die "${word_desc} contains forbidden symbols: ${word}\n";
    }
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

sub _new_reqid {
    return sprintf("%08x", int(rand(0xFFFFFFFF)));
}

sub new_ctx {
    my ($scfg, $storeid) = @_;
    return {
        scfg    => $scfg,
        storeid => $storeid,
        reqid   => _new_reqid(),
    };
}

sub debugmsg_trace {
    my ( $ctx, $dlevel, $msg ) = @_;
    my $stack = longmess($msg || "Stack trace:");
    debugmsg( $ctx, $dlevel, $stack );
}

sub debugmsg {
    my ( $ctx, $dlevel, $msg ) = @_;
    my $scfg  = $ctx->{scfg};
    my $reqid = $ctx->{reqid} // '';

    chomp $msg;

    return if !$msg;

    my $msg_level = map_log_level_to_number($dlevel);

    my $config_level = get_log_level($ctx);
    if ( $config_level >= $msg_level ) {

        $log_file_path = get_log_file($ctx);

        my ( $seconds, $microseconds ) = gettimeofday();

        my $milliseconds = int( $microseconds / 1000 );

        my ( $sec, $min, $hour, $day, $month, $year ) = localtime($seconds);
        $year  += 1900;
        $month += 1;
        my $line =
          sprintf( "%04d-%02d-%02d %02d:%02d:%02d.%03d - plugin - %s - [%s] %s",
            $year, $month,        $day,        $hour, $min,
            $sec,  $milliseconds, uc($dlevel), $reqid, $msg );

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
    my ( $ctx, $cmd, $timeout, $retries, $force_debug_level, $password ) = @_;
    my $scfg    = $ctx->{scfg};
    my $storeid = $ctx->{storeid};

    my $msg = '';
    my $err = undef;
    my $target;
    my $retry_count = 0;

    $timeout = 40 if ! defined($timeout);
    $retries = 0  if ! defined($retries);
    my $connection_options = [];

    my $debug_level = map_log_level_to_number('debug');

    if ( defined($force_debug_level) ) {
        push @$connection_options, '--loglvl', $force_debug_level;
    } else {
        my $config_level = get_log_level($ctx);
        if ( $config_level >= $debug_level ) {
            push @$connection_options, '--loglvl', 'debug';
        }
    }
    my $ssl_cert_verify = get_ssl_cert_verify($ctx);
    if ( defined($ssl_cert_verify) ) {
        push @$connection_options, '--ssl-cert-verify', $ssl_cert_verify;
    }

    my $control_addresses = get_control_addresses($ctx);
    if ( defined($control_addresses) ) {
        push @$connection_options, '--control-addresses',
          "${control_addresses}";
    }

    my $control_port = get_control_port($ctx);
    if ( defined($control_port) ) {
        push @$connection_options, '--control-port', $control_port;
    }

    my $data_addresses = get_data_addresses($ctx);
    if ( defined($data_addresses) ) {
        push @$connection_options, '--data-addresses', $data_addresses;
    }

    my $data_port = get_data_port($ctx);
    if ( defined($data_port) ) {
        push @$connection_options, '--data-port', $data_port;
    }

    my $user_name = get_user_name($ctx);
    if ( defined($user_name) ) {
        push @$connection_options, '--user-name', $user_name;
    } else {
        die "JovianDSS REST user name is not provided.\n";
    }

    my $user_password = defined($password) ? $password : get_user_password($ctx);
    if ( defined($user_password) ) {
        push @$connection_options, '--user-password', $user_password;
    } else {
        die "JovianDSS REST user password is not provided.\n";
    }

    my $log_file = get_log_file($ctx);
    if ( defined($log_file) ) {
        push @$connection_options, '--logfile', $log_file;
    }

    my $reqid = $ctx->{reqid};
    if ( defined($reqid) ) {
        push @$connection_options, '--request-id', $reqid;
    }

    my $config_file = get_config($ctx);
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

        # Check for timeout BEFORE checking exitcode.  When run_command
        # dies with a timeout inside eval, $exitcode keeps its initial
        # value of 0, so the "exitcode == 0" check would incorrectly
        # return the (empty) output as success.
        if ( $rerr && $rerr =~ /got timeout/ ) {
            $retry_count++;
            $msg = '';
            $err = undef;
            sleep( 3 + int( rand( 5 ) ) );
            next;
        }

        if ( $rerr ) {
            die "$rerr\n";
        }

        if ( $exitcode == 0 ) {
            return $msg;
        }

        if ($err) {
            die "${err}\n";
        }
        die "jdssc exited with code $exitcode\n";
    }

    die "JovianDSS command timed out after $retries retries\n";
}


sub cmd_log_output {
    my ( $ctx, $level , $cmd, $data ) = @_;
    my $cmd_str = join ' ', map {
        (my $a = $_) =~ s/'/'\\''/g; "'$a'"
    } @$cmd;
    debugmsg( $ctx, $level, "CMD ${cmd_str} output ${data}");
}

# Returns a hash with the snapshot names as keys and the following data:
# id        - Unique id to distinguish different snapshots even if the have the same name.
# timestamp - Creation time of the snapshot (seconds since epoch).
# Returns an empty hash if the volume does not exist.
sub volume_snapshots_info {
    my ( $ctx, $volname ) = @_;

    my $pool = get_pool($ctx);

    my $output = joviandss_cmd(
        $ctx,
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
        debugmsg( $ctx, "debug",
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
    my ( $ctx, $vmid) = @_;

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
            debugmsg($ctx, 'debug', "${vmid} is not Qemu");
            return 0;
        }
        debugmsg($ctx, 'debug', "Unable to check if ${vmid} is Qemu: ${err_out}");
        return 0;
    }
    return 1;
}

sub vmid_is_lxc {
    my ($ctx, $vmid) = @_;

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
            debugmsg($ctx, 'debug', "${vmid} is not LXC");
            return 0;
        }
        debugmsg($ctx, 'debug', "Unable to check if ${vmid} is LXC ${err_out}");
        return 0;
    }
    return 1;
}

sub vmid_identify_virt_type {
    # Check if there is a qemu config file or lxc config file
    # If one config file found reply with it
    # If unable to identify config reply with undef
    my ($ctx, $vmid) = @_;

    my $is_qemu = vmid_is_qemu($ctx, $vmid);

    my $is_lxc = vmid_is_lxc($ctx, $vmid);

    if ( $is_qemu == 1 && $is_lxc == 0 ) {
        return 'qemu';
    }
    if ( $is_qemu == 0 && $is_lxc == 1) {
        return 'lxc';
    }
    if ($is_qemu == 1 && $is_lxc == 1 ) {
        debugmsg($ctx, 'debug', "Unable to identify virtualisation type for ${vmid}, seams to be both Qemu and LXC");
        return undef;
    }
    debugmsg($ctx, 'debug', "Unable to identify virtualisation type for ${vmid}, seams neither Qemu nor LXC");
    return undef;
}

sub snapshots_list_from_vmid {
    my ( $ctx, $vmid) = @_;

    my $nodename = PVE::INotify::nodename();

    my $virtualisation = vmid_identify_virt_type( $ctx, $vmid);

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

sub remove_vm_snapshot_config {
    my ($ctx, $vmid, $virt_type, $snapname) = @_;

    my $conf_path;
    if ($virt_type eq 'qemu') {
        $conf_path = "/etc/pve/qemu-server/${vmid}.conf";
    } elsif ($virt_type eq 'lxc') {
        $conf_path = "/etc/pve/lxc/${vmid}.conf";
    } else {
        debugmsg($ctx, 'debug',
            "Unknown virt type '${virt_type}' for vmid ${vmid},"
            . " skipping config update\n");
        return;
    }

    unless (-f $conf_path) {
        debugmsg($ctx, 'debug',
            "Config file ${conf_path} not found,"
            . " skipping snapshot config removal\n");
        return;
    }

    open(my $fh, '<', $conf_path)
        or die "Cannot open ${conf_path}: $!\n";
    my @lines = <$fh>;
    close($fh);

    my $found = 0;
    my @out;
    my $skip = 0;

    foreach my $line (@lines) {
        if ($line =~ /^\[(.+)\]\s*$/) {
            my $sect = $1;
            if ($sect eq $snapname) {
                $skip  = 1;
                $found = 1;
                # Strip blank separator line(s) preceding this section
                while (@out && $out[-1] =~ /^\s*$/) {
                    pop @out;
                }
            } else {
                $skip = 0;
                push @out, $line;
            }
        } elsif (!$skip) {
            push @out, $line;
        }
    }

    unless ($found) {
        debugmsg($ctx, 'debug',
            "Snapshot ${snapname} not found in ${conf_path},"
            . " nothing to remove\n");
        return;
    }

    debugmsg($ctx, 'debug',
        "Removing snapshot ${snapname} from ${conf_path}\n");

    file_set_contents($conf_path, join('', @out));
}

sub format_rollback_block_reason {
    my ($volname, $target_snap, $snapshots, $clones,
        $unmanaged_snaps, $blockers_unknown, $force_rollback) = @_;

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

    my $has_managed   = $snapshots        && @$snapshots;
    my $has_clones    = $clones           && @$clones;
    my $has_unmanaged = $unmanaged_snaps  && @$unmanaged_snaps;
    my $has_unknown   = $blockers_unknown && @$blockers_unknown;

    my $printed = 0;
    my $append_section = sub {
        my ($label, $items) = @_;
        return if !$items || ref($items) ne 'ARRAY' || !@$items;
        $msg .= "---\n" if $printed;
        $msg .= $label . "\n";
        $msg .= $format_list->($items) . "\n\n";
        $printed = 1;
    };

    # force_rollback is set but clones or unknown blockers prevent it.
    # Managed and storage-side snapshots are handled automatically;
    # only the resources listed below require manual removal.
    if ($force_rollback) {
        $msg .= "Unable to rollback.\n";
        $msg .= "'force_rollback' handles managed and storage-side"
              . " snapshots automatically,\n";
        $msg .= "but the following resources must be removed"
              . " manually first:\n\n";

        $append_section->(
            scalar(@$clones) . " dependent clones: ",
            $clones
        ) if $has_clones;

        $append_section->(
            scalar(@$blockers_unknown)
            . " blockers of unknown origin: ",
            $blockers_unknown
        ) if $has_unknown;

        return $msg;
    }

    # No force_rollback set.
    # When only snapshots block (no clones, no unknown),
    # adding the 'force_rollback' tag will handle them automatically.
    if (!$has_clones && !$has_unknown) {
        $msg .= "Rollback blocked by newer snapshots:\n\n";

        $append_section->(
            scalar(@$snapshots) . " Proxmox managed snapshots: ",
            $snapshots
        ) if $has_managed;

        $append_section->(
            scalar(@$unmanaged_snaps) . " storage side snapshots: ",
            $unmanaged_snaps
        ) if $has_unmanaged;

        $msg .= "Hint: add 'force_rollback' tag to VM/Container"
              . " to roll back automatically.\n";
        $msg .= "!! DANGER !! All listed snapshots will be destroyed.\n";

        return $msg;
    }

    # Clones or unknown blockers present — must be removed manually.
    $msg .= "Rollback blocked. Remove the following resources first:\n\n";

    $append_section->(
        scalar(@$snapshots) . " Proxmox managed snapshots: ",
        $snapshots
    ) if $has_managed;

    $append_section->(
        scalar(@$unmanaged_snaps) . " storage side snapshots: ",
        $unmanaged_snaps
    ) if $has_unmanaged;

    $append_section->(
        scalar(@$clones) . " dependent clones: ",
        $clones
    ) if $has_clones;

    $append_section->(
        scalar(@$blockers_unknown)
        . " rollback blockers of unknown origin: ",
        $blockers_unknown
    ) if $has_unknown;

    $msg .= "\n";

    return $msg;
}

sub volume_rollback_check {
    # Optional 6th arg: pre-computed $force_rollback (skips internal pvesh call).
    # Optional 7th arg: scalar ref to receive the managed-snapshots list so the
    # caller can cache it and avoid a duplicate pvesh call later.
    my ( $ctx, $vmid, $volname, $snap, $blockers,
         $force_rollback, $man_snaps_ref ) = @_;

    my $pool = get_pool($ctx);

    $blockers //= [];
    my $res;
    eval {
        $res = joviandss_cmd(
            $ctx,
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
            debugmsg($ctx, 'debug', "Rollback blocker found vol ${volname} snap ${snap} blocker ${obj}");
        }
    }

    if ( ! $blockers_found_flag ) {
        return 1;
    }

    my $blockers_snapshots_untracked = [];
    my $blockers_snapshots_tracked = [];
    my $blockers_clones = [];
    my $blockers_unknown = [];

    # Use caller-supplied value to avoid a redundant pvesh subprocess.
    $force_rollback //= vm_tag_force_rollback_is_set($ctx, $vmid);

    my $managed_snapshots = snapshots_list_from_vmid($ctx, $vmid);
    $$man_snaps_ref = $managed_snapshots if defined $man_snaps_ref;
    my $force_rollback_possible = 1;
    foreach my $blocker ( $blockers_found->@* ) {
        if ( $blocker =~ /^snap:(.+)$/ ) {
            my $snap_blocker = $1;
            push $blockers->@*, $snap_blocker;
            my $managed_found = 0;
            foreach my $snap ( $managed_snapshots->@* ) {
                if ($snap eq $snap_blocker) {
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
            debugmsg($ctx, 'debug', "Rollback blocker clone blocker for vol ${volname} snap ${snap} clone ${clone_blocker}");
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
        $blockers_unknown,
        $force_rollback);

    die $msg;
}

sub get_iscsi_addresses {
    my ( $ctx, $addport ) = @_;

    my $da = get_data_addresses($ctx);

    my $dp = get_data_port($ctx);

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

    my $cmdout = joviandss_cmd( $ctx, $getaddressescmd );

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

    my $ca = get_control_addresses($ctx);

    my @iplist = split( /\s*,\s*/, $ca );
    if ( defined($addport) && $addport ) {
        foreach (@iplist) {
            $_ .= ":${dp}";
        }
    }

    return @iplist;
}

sub block_device_iscsi_paths {
    my ( $ctx, $target, $lunid, $hosts ) = @_;

    my @targets_block_devices = ();
    my $path;
    my $port = get_data_port( $ctx );
    foreach my $host (@$hosts) {
        $path = "/dev/disk/by-path/ip-${host}:${port}-iscsi-${target}-lun-${lunid}";
        if ( -b $path ) {
            debugmsg( $ctx, "debug", "Target ${target} mapped to ${path}\n" );
            $path = clean_word($path);
            ($path) = $path =~ m{^(/dev/disk/by-path/[\:\-\@\w\./]+)$} or die "Tainted path: $path";
            push( @targets_block_devices, $path );
        }
    }
    return \@targets_block_devices;
}

sub target_active_info {
    my ( $ctx, $tgname, $volname, $snapname, $contentvolflag ) = @_;
    # Provides target info by requesting target info from joviandss
    debugmsg( $ctx, "debug", "Acquiring active target info for "
                . "target group name ${tgname} "
                . "volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n"
            );

    my $pool   = get_pool($ctx);
    my $prefix = get_target_prefix($ctx);

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

    my $out = joviandss_cmd( $ctx, $gettargetcmd, 180, 5 );

    if ( defined $out and clean_word($out) eq '' ) {
        return undef;
    }

    my ( $targetname, $lunid, $ips ) = split( ' ', $out );

    my @iplist = split /\s*,\s*/, $ips;
    debugmsg( $ctx, "debug",
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
    my ( $ctx, $vmid ) = @_;
    return "vm-${vmid}";
}

sub get_content_target_group_name {
    my ($ctx) = @_;
    return "proxmox-content";
}

sub volume_publish {
    my ( $ctx, $tgname, $volname, $snapname, $content_volume_flag ) = @_;

    my $pool   = get_pool($ctx);
    my $prefix = get_target_prefix($ctx);
    my $luns_per_target = get_luns_per_target($ctx);

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

    if ( get_chap_enabled($ctx) ) {
        my $chap_user = get_chap_user_name($ctx);
        my $chap_pass = get_chap_user_password($ctx);
        die "chap_user_name is required when chap_enabled is set\n"
            unless defined $chap_user && length($chap_user);
        die "chap_user_password is required when chap_enabled is set\n"
            unless defined $chap_pass;
        # TODO: credentials are passed as argv and are visible in /proc/<pid>/cmdline
        # for the duration of the jdssc process. Fix: add --chap-credentials-file <path>
        # to jdssc targets create, write credentials to a 0600 tempfile (File::Temp,
        # UNLINK=>1), pass the path instead of the values. Same change needed in
        # target_update_chap below and in the jdssc targets.py / target.py parsers.
        push @$create_target_cmd, '--chap-user', $chap_user, '--chap-password', $chap_pass;
    }

    my $out = joviandss_cmd( $ctx, $create_target_cmd, 180, 5 );
    my ( $targetname, $lunid, $ips ) = split( ' ', $out );

    my @iplist = split /\s*,\s*/, clean_word($ips);

    my %tinfo = (
        target => clean_word($targetname),
        lunid  => clean_word($lunid),
        iplist => \@iplist
    );
    debugmsg( $ctx, "debug",
            "Publish volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . 'acquired '
          . "target ${targetname} "
          . "lun ${lunid} "
          . "hosts @{iplist}");

    return \%tinfo;
}

sub target_update_chap {
    my ($ctx, $targetname) = @_;

    my $pool = get_pool($ctx);
    my $cmd  = ['pool', $pool, 'target', $targetname, 'update'];

    if (get_chap_enabled($ctx)) {
        my $chap_user = get_chap_user_name($ctx);
        my $chap_pass = get_chap_user_password($ctx);
        die "chap_user_name is required when chap_enabled is set\n"
            unless defined $chap_user && length($chap_user);
        die "chap_user_password is required when chap_enabled is set\n"
            unless defined $chap_pass;
        # TODO: same argv exposure as in volume_publish above — move to
        # --chap-credentials-file once jdssc target update supports it.
        push @$cmd, '--chap-user', $chap_user, '--chap-password', $chap_pass;
    } else {
        push @$cmd, '--no-chap';
    }

    my $last_err;
    for my $attempt (1 .. 3) {
        eval { joviandss_cmd($ctx, $cmd, 30); };
        $last_err = $@;
        return unless $last_err;
        debugmsg($ctx, 'warn',
            "target_update_chap attempt ${attempt} failed for "
            . "${targetname}: ${last_err}");
    }
    die $last_err if $last_err;
}

sub _iscsiadm_set_chap {
    my ($ctx, $host, $targetname, $chap_user, $chap_pass) = @_;
    for my $update (
        [ 'node.session.auth.authmethod', 'CHAP'      ],
        [ 'node.session.auth.username',   $chap_user  ],
        [ 'node.session.auth.password',   $chap_pass  ],
    ) {
        my ($param, $value) = @$update;
        my $cmd = [
            $ISCSIADM, '--mode', 'node',
            '-p', $host, '--targetname', $targetname,
            '-o', 'update', '-n', $param, '-v', $value,
        ];
        run_command(
            $cmd,
            outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
            errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
            timeout => 10,
        );
    }
}

sub _iscsiadm_clear_chap {
    my ($ctx, $host, $targetname) = @_;
    for my $update (
        [ 'node.session.auth.authmethod', 'None' ],
        [ 'node.session.auth.username',   ''     ],
        [ 'node.session.auth.password',   ''     ],
    ) {
        my ($param, $value) = @$update;
        my $cmd = [
            $ISCSIADM, '--mode', 'node',
            '-p', $host, '--targetname', $targetname,
            '-o', 'update', '-n', $param, '-v', $value,
        ];
        run_command(
            $cmd,
            outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
            errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
            timeout => 10,
        );
    }
}

sub volume_stage_iscsi {
    my ( $ctx, $targetname, $lunid, $hosts ) = @_;

    debugmsg( $ctx, "debug", "Stage target ${targetname} lun ${lunid} over addresses @$hosts\n" );

    # Fast path: all block devices already present.
    my $targets_block_devices = block_device_iscsi_paths( $ctx, $targetname, $lunid, $hosts );
    if ( @$targets_block_devices == @$hosts ) {
        return $targets_block_devices;
    }

    # Helper: refresh %host_has_session from iscsiadm --mode session output.
    my %host_has_session;
    my $refresh_sessions = sub {
        eval {
            my $cmd = [ $ISCSIADM, '--mode', 'session' ];
            my @session_lines;
            run_command(
                $cmd,
                outfunc => sub {
                    my $line = shift;
                    push @session_lines, $line;
                    for my $host (@$hosts) {
                        if ($line =~ /\Q$targetname\E/ && $line =~ /\Q$host\E/) {
                            $host_has_session{$host} = 1;
                        }
                    }
                },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                noerr   => 1
            );
            debugmsg($ctx, 'debug',
                "refresh_sessions: found " . scalar(@session_lines)
                . " session(s): @{session_lines}, looking for target ${targetname} "
                . "hosts [@$hosts]: "
                . join(', ', map { "$_=" . ($host_has_session{$_} ? 'yes' : 'no') } @$hosts));
        };
    };

    $refresh_sessions->();

    for my $host (grep { $host_has_session{$_} } @$hosts) {
        debugmsg($ctx, "debug",
            "iSCSI session already exists for target ${targetname} on host ${host}");
    }

    my %host_db_ready;
    my $chap_recovery_done = 0;
    my $max_login_attempts = 10;

    for my $attempt (1 .. $max_login_attempts) {

        # On retries: poll for sessions that may have appeared in the background
        # during iscsid's FAILED->IN-LOGIN->LOGGED-IN recovery cycle.
        if ($attempt > 1) {
            my %had_session;
            for my $host (@$hosts) {
                $had_session{$host} = 1 if $host_has_session{$host};
            }
            my $max_session_polls = 5;
            for my $poll (1 .. $max_session_polls) {
                $refresh_sessions->();
                my @still_pending = grep { !$host_has_session{$_} } @$hosts;
                last unless @still_pending;
                last if $poll >= $max_session_polls;
                sleep(2);
            }
            for my $host (@$hosts) {
                next unless $host_has_session{$host} && !$had_session{$host};
                debugmsg($ctx, 'debug',
                    "refresh_sessions: session for ${host} target ${targetname} "
                    . "appeared between login attempts");
            }
        }

        my @pending = grep { !$host_has_session{$_} } @$hosts;
        last unless @pending;

        debugmsg($ctx, "debug",
            "iSCSI login attempt ${attempt}/${max_login_attempts} "
            . "for hosts: @pending target ${targetname}");

        # Step 1: Read CHAP desired state.
        # Inside the loop so the next attempt after step 4 recovery automatically
        # picks up credentials that target_update_chap may have just synced.
        my $chap_enabled = get_chap_enabled($ctx);
        my ($chap_user, $chap_pass);
        if ($chap_enabled) {
            $chap_user = get_chap_user_name($ctx);
            $chap_pass = get_chap_user_password($ctx);
            die "chap_user_name is required when chap_enabled is set\n"
                unless defined $chap_user && length($chap_user);
            die "chap_user_password is required when chap_enabled is set\n"
                unless defined $chap_pass;
        }

        # Step 2: Configure iscsiadm node DB for each pending host.
        #
        # Node DB entry (-o new, login timeout) is created once per host and
        # reused across retry attempts.
        # CHAP state is written every attempt: credentials may have changed after
        # a step 4 recovery on the previous attempt.
        for my $host (@pending) {
            unless ($host_db_ready{$host}) {
                eval {
                    my $cmd = [
                        $ISCSIADM, '--mode', 'node',
                        '-p', $host, '--targetname', $targetname, '-o', 'new'
                    ];
                    run_command(
                        $cmd,
                        outfunc => sub { },
                        errfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                        noerr   => 1
                    );
                };
                eval {
                    my $cmd = [
                        $ISCSIADM, '--mode', 'node',
                        '-p', $host, '--targetname', $targetname,
                        '-o', 'update',
                        '-n', 'node.conn[0].timeo.login_timeout', '-v', '30'
                    ];
                    run_command(
                        $cmd,
                        outfunc => sub { },
                        errfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                        noerr   => 1
                    );
                };
                $host_db_ready{$host} = 1;
            }

            if ($chap_enabled) {
                _iscsiadm_set_chap($ctx, $host, $targetname, $chap_user, $chap_pass);
            } else {
                _iscsiadm_clear_chap($ctx, $host, $targetname);
            }
        }

        # Step 3: Attempt login for each pending host.
        # No server-side calls here — purely initiator-side iscsiadm operations.
        # CHAP auth failures are collected and handled once in step 4.
        my @chap_failed;
        for my $host (@pending) {
            my $already_present = 0;
            my $chap_auth_err   = 0;
            eval {
                my $cmd = [
                    $ISCSIADM, '--mode', 'node',
                    '-p', $host, '--targetname', $targetname, '--login'
                ];
                run_command(
                    $cmd,
                    outfunc => sub { },
                    errfunc => sub {
                        my $line = shift;
                        $already_present = 1 if $line =~ /already present/i;
                        $chap_auth_err   = 1 if $line =~ /authorization failure/i;
                        cmd_log_output($ctx,
                            $already_present ? 'debug' : 'warn', $cmd, $line);
                    }
                );
                $host_has_session{$host} = 1;
            };
            if ($@) {
                if ($already_present) {
                    debugmsg($ctx, 'debug',
                        "iSCSI session already present for host ${host} "
                        . "target ${targetname}, treating as success");
                    $host_has_session{$host} = 1;
                } elsif ($chap_auth_err) {
                    debugmsg($ctx, 'warn',
                        "CHAP authorization failure for host ${host} "
                        . "target ${targetname}");
                    push @chap_failed, $host;
                } else {
                    debugmsg($ctx, 'warn',
                        "iSCSI login attempt ${attempt}/${max_login_attempts} "
                        . "failed for host ${host} target ${targetname}: $@");
                }
            } else {
                debugmsg($ctx, 'debug',
                    "iSCSI login succeeded for host ${host} "
                    . "target ${targetname} on attempt ${attempt}/${max_login_attempts}");
            }
        }

        # Step 4: CHAP recovery.
        # target_update_chap is a single REST call that syncs the JovianDSS target
        # to current config — called at most once per invocation regardless of how
        # many hosts failed. The outer loop retries with fresh credentials on the
        # next attempt (step 1 re-reads them at the top of each iteration).
        # If auth failure persists after recovery, credentials are genuinely wrong —
        # die immediately rather than retrying further.
        if (@chap_failed) {
            if ($chap_recovery_done) {
                die "CHAP authentication failed for target ${targetname} "
                    . "on hosts @chap_failed after credential refresh - "
                    . "check CHAP configuration\n";
            }
            debugmsg($ctx, 'warn',
                "CHAP authorization failure on hosts @chap_failed "
                . "for target ${targetname}, refreshing target CHAP state");
            target_update_chap($ctx, $targetname);
            $chap_recovery_done = 1;
        }

        sleep(1) if $attempt < $max_login_attempts
                    && grep { !$host_has_session{$_} } @$hosts;
    }

    my @logged_in = grep {  $host_has_session{$_} } @$hosts;
    my @failed    = grep { !$host_has_session{$_} } @$hosts;

    if (!@logged_in) {
        die "Unable to establish iSCSI session for target ${targetname} "
            . "on any host after ${max_login_attempts} attempts. "
            . "Hosts tried: @$hosts\n";
    }
    if (@failed) {
        debugmsg($ctx, 'warn',
            "iSCSI login failed for hosts @failed after ${max_login_attempts} attempts; "
            . "proceeding with " . scalar(@logged_in) . " of " . scalar(@$hosts)
            . " hosts for target ${targetname}");
    }

    for ( my $i = 1 ; $i <= 30 ; $i++ ) {
        $targets_block_devices =
            block_device_iscsi_paths( $ctx, $targetname, $lunid, \@logged_in );

        if ( @$targets_block_devices == @logged_in ) {
            debugmsg( $ctx, "debug", "Stage iSCSI block devices @{ $targets_block_devices }\n" );
            return $targets_block_devices;
        }

        debugmsg( $ctx, "debug", "Waiting for block devices: got "
            . scalar(@$targets_block_devices) . " of " . scalar(@logged_in)
            . " (attempt ${i}/30)\n" );

        sleep(1);

        # Run rescan-scsi-bus only every 3rd attempt — under concurrent load
        # each rescan takes minutes and many concurrent rescans cause SCSI bus
        # congestion.
        if ( $i % 3 == 0 && $lunid =~ /^\A\d+\z$/ ) {
            eval {
                my $cmd = [
                    '/usr/bin/rescan-scsi-bus.sh',
                    '--sparselun', '--reportlun2', '--largelun',
                    "--luns=${lunid}", '-a'
                ];
                run_command(
                    $cmd,
                    outfunc  => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                    errfunc  => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                    timeout  => 60,
                    noerr    => 1
                );
            };
        } elsif ( $lunid !~ /^\A\d+\z$/ ) {
            debugmsg( $ctx, "warn", "Lun id ${lunid} contains non digit symbols" );
        }
    }

    log_dir_content($ctx, '/dev/disk/by-path');
    debugmsg( $ctx, "warn",
        "Unable to identify iscsi block device location @{ $targets_block_devices }\n" );

    die "Unable to locate target ${targetname} block device location.\n";
}

sub volume_stage_multipath {
    my ( $ctx, $scsiid, $block_devs ) = @_;
    $scsiid = clean_word($scsiid);

    my $mpath;

    if ( $scsiid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $id = $1;

        eval {
            my $cmd = [ $MULTIPATH, '-a', $id ];
            run_command(
                $cmd ,
                outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        my $is_multipath = 1;

        $mpath = block_device_path_from_serial( $id, $is_multipath);

        # Phase 1: Wait for SCSI VPD inquiry to complete.
        # The /dev/disk/by-id/scsi-$id symlink is created by udev after the
        # kernel reads the device serial via SCSI inquiry.  multipathd cannot
        # associate paths with our WWID until this is done.  During heavy
        # concurrent operations (many clones) the inquiry queue backs up and
        # this can take 30+ seconds.
        my $scsi_by_id = "/dev/disk/by-id/scsi-${id}";
        my $paths_ready = 0;
        for my $wait ( 1 .. 60 ) {
            if ( -e $scsi_by_id ) {
                $paths_ready = 1;
                debugmsg( $ctx, "debug",
                    "SCSI device ${scsi_by_id} ready after ${wait}s wait" );
                last;
            }
            if ( $wait == 1 || $wait % 10 == 0 ) {
                debugmsg( $ctx, "debug",
                    "Waiting for SCSI device ${scsi_by_id} (${wait}/60)" );
            }
            sleep(1);
        }
        unless ($paths_ready) {
            debugmsg( $ctx, "warn",
                "SCSI device ${scsi_by_id} not found after 60s, "
                . "attempting multipath creation anyway" );
        }

        # Resolve iSCSI by-path symlinks to real sd device names so we can
        # explicitly register them with multipathd.  Under concurrent load,
        # udev events may be delayed and multipathd might not know about the
        # paths yet, causing "multipathd add map" to fail.
        my @sd_devnames;
        if ($block_devs && ref($block_devs) eq 'ARRAY') {
            for my $bp (@$block_devs) {
                my $real = Cwd::abs_path($bp);
                if ($real && $real =~ m{^/dev/(sd[a-z]+)$}) {
                    push @sd_devnames, $1;
                }
            }
            if (@sd_devnames) {
                debugmsg( $ctx, "debug",
                    "Resolved iSCSI paths for multipath: " . join(', ', @sd_devnames) );
            }
        }

        # Phase 2: Create the multipath map.
        # Under concurrent load (many clones), multipathd gets overwhelmed
        # and "add map" fails.  The root cause is that udev events back up
        # under load, so multipathd doesn't know about the new paths.
        #
        # IMPORTANT: Do NOT use "udevadm trigger" here — it generates
        # CHANGE events on sd devices which causes multipathd to re-evaluate
        # paths, disrupting existing multipath devices that are actively
        # being used for data copies (causes qemu-img I/O errors).
        for my $attempt ( 1 .. 20) {

            # Explicitly register paths with multipathd before creating
            # the map.  This ensures multipathd knows which sd devices
            # belong to this WWID, even if udev events were delayed.
            for my $devname (@sd_devnames) {
                eval {
                    my $cmd = [ $MULTIPATHD, 'add', 'path', $devname ];
                    run_command(
                        $cmd,
                        outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                        errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                        timeout  => 20,
                        noerr   => 1
                    );
                };
            }

            # TODO: remove once multipath device appearance is reliable under load
            # Trigger udev rescan for the specific sd devices belonging to this
            # WWID every 4th attempt.  Unlike a broad "udevadm trigger -t all",
            # targeting individual sysfs paths only generates events for these
            # devices, avoiding disruption to other active multipath devices.
            if ( $attempt % 4 == 0 ) {
                if (@sd_devnames) {
                    for my $devname (@sd_devnames) {
                        eval {
                            my $cmd = [ 'udevadm', 'trigger',
                                        '/sys/block/' . $devname ];
                            run_command(
                                $cmd,
                                outfunc => sub { },
                                errfunc => sub {
                                    cmd_log_output($ctx, 'debug', $cmd, shift);
                                },
                                timeout  => 20,
                                noerr => 1
                            );
                        };
                    }
                    debugmsg( $ctx, 'debug',
                        "Triggered udev rescan for devices: "
                        . join(', ', @sd_devnames)
                        . " (attempt ${attempt})" );
                } else {
                    eval {
                        my $cmd = [ 'udevadm', 'trigger',
                                    '--subsystem-match=block',
                                    "--attr-match=ID_SERIAL=${id}" ];
                        run_command(
                            $cmd,
                            outfunc => sub { },
                            errfunc => sub {
                                cmd_log_output($ctx, 'debug', $cmd, shift);
                            },
                            timeout  => 20,
                            noerr => 1
                        );
                    };
                    debugmsg( $ctx, 'debug',
                        "Triggered udev rescan for scsiid ${id} "
                        . "(attempt ${attempt})" );
                }
            }

            # On first attempt and every 5th attempt, try the multipath
            # CLI which does a heavier scan.  On other attempts, use only
            # the lighter multipathd daemon commands.
            if ( $attempt == 1 || $attempt % 5 == 0 ) {
                eval {
                    my $cmd = [ $MULTIPATH, $id ];
                    run_command(
                        $cmd,
                        outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                        errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                        noerr   => 1,
                        timeout => 30
                    );
                };
            }

            $mpath = clean_word($mpath);
            if ( -b $mpath ) {
                return $mpath;
            }

            debugmsg( $ctx,
                    "debug",
                    "Unable to identify block device mapper name for "
                    . "scsiid ${id} "
                    . "attempt ${attempt}"
                );
            eval {
                my $cmd = [ $MULTIPATH, '-a', $id ];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                    timeout  => 20,
                    noerr   => 1
                );
            };

            eval {
                my $cmd = [ $MULTIPATHD, 'add', 'map', $id ];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                    timeout  => 20,
                    noerr   => 1
                );
            };

            # Every 10th attempt, try a full multipathd reconfigure as a
            # heavier fallback.  This forces the daemon to re-read all
            # paths and recreate maps from scratch.
            if ( $attempt % 10 == 0 ) {
                debugmsg( $ctx, "debug",
                    "Attempting multipathd reconfigure for scsiid ${id} "
                    . "(attempt ${attempt})" );
                eval {
                    my $cmd = [ $MULTIPATHD, 'reconfigure' ];
                    run_command(
                        $cmd,
                        outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                        errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                        noerr   => 1,
                        timeout => 30
                    );
                };
            }
            sleep(2);
        }
    } else {
        die "Invalid characters in scsiid: ${scsiid}";
    }

    $mpath = clean_word($mpath);
    if ( -b $mpath ) {
        return $mpath;
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
    my ( $ctx, $volname, $snapname ) = @_;

    my $id_serial = id_serial_from_rest( $ctx, $volname, $snapname );

    return block_device_path_from_serial(
                $id_serial,
                get_multipath($ctx) );
}

sub block_device_path_from_lun_rec {
    my ( $ctx, $targetname, $lunid, $lunrec ) = @_;

    my $block_dev;

    my $block_device_path = undef;
    if ( get_multipath($ctx) ) {

        unless ($lunrec->{multipath}) {
            $lunrec->{multipath} = 1;
            lun_record_local_update( $ctx,
                                     $targetname, $lunid,
                                     $lunrec->{volname}, $lunrec->{snapname},
                                     $lunrec );
            $block_dev = volume_stage_multipath( $ctx, $lunrec->{scsiid} );
            return $block_dev;
        }

        if ( $lunrec->{scsiid} =~ /^([\:\-\@\w.\/]+)$/ ) {
            my $id = $1;
            my $is_multipath = 1;
            $block_device_path = block_device_path_from_serial( $id, $is_multipath );
            return $block_device_path;
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
        debugmsg( $ctx,
                "debug",
                "Block device path from lun record for "
                . "target ${targetname} "
                . "lun ${lunid} "
                . "not found\n"
            );
        die "Unable to identify path from lun record.\n";
    }

    debugmsg( $ctx,
            "debug",
            "Block device path from lun record for "
            . "target ${targetname} "
            . "lun ${lunid} "
            . "is ${block_device_path}\n"
        );
    return $block_device_path;
}

sub get_device_mapper_name {
    my ( $ctx, $wwid ) = @_;

    my $device_mapper_name;

    if ( $wwid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $id = $1;

        my $cmd = [ $MULTIPATH, '-ll', $id ];
        run_command(
            $cmd ,
            outfunc => sub {
                    my $line = shift;
                    chomp $line;
                    cmd_log_output($ctx, 'debug', $cmd, $line);
                    if ( $line =~ /\b$wwid\b/ ) {
                        my @parts = split( /\s+/, $line );
                        $device_mapper_name = $parts[0];
                    }
                },
            errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
            timeout  => 20,
            noerr   => 1
        );
    } else {
        die "Invalid characters in wwid: ${wwid}\n";
    }
    unless ( $device_mapper_name ) {
        return undef;
    }

    if ( $device_mapper_name =~ /^([\:\-\@\w.\/]+)$/ ) {

        debugmsg( $ctx, "debug", "Mapper name for ${wwid} is ${1}\n" );
        return $1;
    }
    return undef;
}

sub ha_state_is_defined {
     my ($ctx, $vmid) = @_;

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
         timeout  => 20,
         noerr   => 1
     );

     if ($exitcode != 0) {
         if ($err_out =~ /no such resource/) {
             debugmsg($ctx, 'debug', "VM ${vmid} is not HA-managed");
             return 0;
         }
         die "Failed to check HA status for ${vmid}: ${err_out}";
     }

     if ($json_out eq '') {
         debugmsg($ctx, 'debug', "VM ${vmid} is not HA-managed (empty response)");
         return 0;
     }

     my $jdata = eval { decode_json($json_out) };
     if ($@ || ref($jdata) ne 'HASH') {
         die "Unexpected HA status response for ${vmid}: ${json_out}";
     }

     debugmsg($ctx, 'debug', "VM ${vmid} is HA-managed");
     return 1;
}


sub ha_state_get {
    my ($ctx, $vmid) = @_;

    my $cmd = ['pvesh', 'get', "/cluster/ha/resources/${vmid}", '--output-format', 'json'];
    my $json_out = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };

    my $errcode = run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => sub {
            cmd_log_output($ctx, 'error', $cmd, shift);
        },
        timeout  => 10,
        noerr   => 1
    );

    if ($errcode != 0) {
        die "Unable to check HA status of ${vmid}\n";
    }

    my $jdata = decode_json($json_out);
    unless (ref($jdata) eq 'HASH') {
        die "Unexpected HA status content ${json_out}";
    }
    if (exists $jdata->{'state'}) {
        my $state = $jdata->{'state'};
        debugmsg( $ctx, 'debug', "HA state of ${vmid} is ${state}");
        return $state;
    } else {
        die "Unable to identify state of ${vmid}\n";
    }
}

sub ha_type_get {
    my ($ctx, $vmid) = @_;

    my $cmd = ['pvesh', 'get', "/cluster/ha/resources/${vmid}", '--output-format', 'json'];
    my $json_out = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };

    my $errcode = run_command(
        $cmd,
        outfunc => $outfunc,
        errfunc => sub {
            cmd_log_output($ctx, 'error', $cmd, shift);
        },
        timeout  => 10,
        noerr   => 1
    );

    if ($errcode != 0) {
        die "Unable to check HA type of ${vmid}\n";
    }

    my $jdata = decode_json($json_out);
    unless (ref($jdata) eq 'HASH') {
        die "Unexpected HA resource content ${json_out}";
    }
    if (exists $jdata->{'type'}) {
        my $type = $jdata->{'type'};
        debugmsg( $ctx, 'debug', "HA type of ${vmid} is ${type}");
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
        outfunc => $outfunc,
        timeout  => 10,
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
    my ( $ctx, $volname, $snapname ) = @_;

    my $pool = get_pool( $ctx );

    debugmsg( $ctx,"debug",
                "Obtain SCSI ID for volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n");

    my $jscsiid;
    if (defined($volname) && !defined($snapname)) {
        $jscsiid = joviandss_cmd(
            $ctx,
            [
                "pool",   $pool,
                "volume", $volname,
                "get", "-i"
            ],
            80, 5
        );
    } elsif (defined($volname) && defined($snapname)) {
        $jscsiid = joviandss_cmd(
            $ctx,
            [
                "pool",   $pool,
                "volume", $volname,
                "snapshot", $snapname,
                "get", "-i"
            ],
            80, 5
        );
    } else {
        die "Volume name is required to acquire scsi id\n";
    }

    if ( $jscsiid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $id = $1;
        my $uei64_bytes = substr( $id, 0, 16 );

        debugmsg( $ctx,"debug",
                "Obtain SCSI ID for volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n");

        return "2${uei64_bytes}";
    } else {
        die "Invalid characters in scsi id ${jscsiid}\n";
    }
}

sub volume_unstage_iscsi_device {
    my ( $ctx, $targetname, $lunid, $hosts ) = @_;

    debugmsg( $ctx, "debug", "Volume unstage iscsi device ${targetname} with lun ${lunid}\n" );
    my $block_devs = block_device_iscsi_paths ( $ctx, $targetname, $lunid, $hosts );

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
                        cmd_log_output($ctx, 'debug', $cmd, $path);
                    },
                    errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); }
                );
            }
            unless ( defined $bdp ) {
                die "Could not resolve block device path for ${idp}: path contains invalid characters\n";
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
            debugmsg( $ctx, "debug", "Sending delete request to ${delete_file} done\n" );
        }
    }
    debugmsg( $ctx, "debug", "Volume unstage iscsi device ${targetname} done\n" );
}


sub volume_unstage_iscsi {
    my ( $ctx, $targetname ) = @_;

    debugmsg( $ctx, "debug", "Volume unstage iscsi target ${targetname}\n" );

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
            outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
            errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
            timeout  => 20,
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
            outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
            errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
            timeout  => 20,
            noerr   => 1
        );
    };
    debugmsg( $ctx, "debug", "Volume unstage iscsi target ${targetname} done\n" );
}

sub volume_unstage_multipath {
    my ( $ctx, $scsiid ) = @_;

    # Driver should not commit any write operation including sync before unmounting
    # Because that might lead to data corruption in case of active migration
    # Also we do not do any unmounting to volume as that might cause unexpected writes

    # Validate SCSI ID early to prevent injection attacks
    unless ( $scsiid =~ /^([\:\-\@\w.\/]+)$/ ) {
        die "SCSI ID contains forbidden symbols: ${scsiid}\n";
    }
    my $clean_scsiid = $1;

    debugmsg( $ctx, "debug", "Volume unstage multipath scsiid ${clean_scsiid}" );

    # Phase 1: Wait for device to become unused
    # There are strong suspicions that proxmox does not terminate qemu during migration
    # before calling volume deactivation. This prevents data corruption.
    my $device_ready = _volume_unstage_multipath_wait_unused($ctx, $clean_scsiid);
    unless ($device_ready) {
        debugmsg( $ctx, "warn", "Device ${clean_scsiid} may still be in use, proceeding with cleanup" );
    }

    # Phase 2: Remove multipath device with retries
    my $cleanup_successful = _volume_unstage_multipath_remove_device($ctx, $clean_scsiid);

    if ($cleanup_successful) {
        debugmsg( $ctx, "debug", "Volume unstage multipath scsiid ${clean_scsiid} completed successfully" );
        return;
    } else {
        die "Failed to remove multipath device for SCSI ID ${clean_scsiid} after multiple attempts\n";
    }
}

sub _volume_unstage_multipath_wait_unused {
    my ( $ctx, $scsiid ) = @_;

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

            my $mapper_name = get_device_mapper_name( $ctx, $scsiid );

            # Check if mapper exists and is valid
            if ( !defined($mapper_name) ) {
                debugmsg( $ctx, "debug", "Multipath device mapper name is not defined");
                $should_continue = 0;
                return;
            }

            if ( $mapper_name !~ /^([\:\-\@\w.\/]+)$/ ) {
                debugmsg( $ctx, "debug", "Multipath device mapper name is incorrect: ${mapper_name}");
                $should_continue = 0;
                return;
            }

            my $clean_mapper_name = $1;
            my $mapper_path = "/dev/mapper/${clean_mapper_name}";

            # Check if mapper device file exists
            if ( !-b $mapper_path ) {
                debugmsg( $ctx, "debug", "Multipath device mapping ${mapper_path} does not exist");
                return;
            }

            # Check device usage
            debugmsg( $ctx, "debug", "Check usage of multipath mapping ${mapper_path}" );
            my $cmd = [ 'lsof', '-t', $mapper_path ];
            eval {
                run_command(
                    $cmd,
                    outfunc => sub {
                        $pid = clean_word(shift);
                        cmd_log_output($ctx, 'debug', $cmd, $pid);
                    },
                    errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); }
                );
            };
            if ($@) {
                my $err = $@;
                debugmsg( $ctx, "warn", "Unable to identify mapper user for ${mapper_path}: ${err}");
                $should_continue = 0;
                return 1;
            }

            debugmsg( $ctx, "debug", "Multipath device mapping ${mapper_path} is used by ${pid}");

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
                            cmd_log_output($ctx, 'debug', $cmd, $blocker_name);
                        },
                        errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); }
                    );
                    my $warningmsg = "Multipath device "
                        . "with scsi id ${scsiid}, "
                        . "is used by ${blocker_name} with pid ${pid}";
                    debugmsg( $ctx, 'warn', $warningmsg );
                    warn "${warningmsg}\n";
                }
            } else {
                print("Block device with SCSI ${scsiid} is not used\n");
                $should_continue = 0;
            }
        };

        if ($@) {
            debugmsg( $ctx, 'warn', "Error during device usage check: $@" );
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
    my ( $ctx, $scsiid ) = @_;

    unless ( $scsiid =~ /^([\:\-\@\w.\/]+)$/ ) {
        debugmsg( $ctx, 'warn', "SCSI ID contains forbidden symbols: ${scsiid}" );
        return 0;
    }
    my $clean_scsiid = $1;

    for my $attempt ( 1 .. 10) {
        debugmsg( $ctx, "debug", "Multipath removal attempt ${attempt}/10 for SCSI ID ${clean_scsiid}" );

        # Step 1: Remove SCSI ID from WWID file
        eval {
            my $cmd = [ $MULTIPATH, '-w', $clean_scsiid ];
            run_command(
                $cmd,
                outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                timeout  => 20,
                noerr   => 1
            );
        };
        if ($@) {
            debugmsg( $ctx, 'warn', "Unable to remove scsi id ${clean_scsiid} from wwid file: $@" );
        }

        # Step 2: Flush (remove) the multipath device map.
        # Using -f (flush) instead of bare $scsiid which would
        # recreate/refresh the device — the opposite of what we want.
        eval {
            my $cmd = [ $MULTIPATH, '-f', $clean_scsiid ];
            run_command(
                $cmd,
                outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                noerr   => 1,
                timeout => 30
            );
        };

        # Step 3: Always attempt dmsetup removal.
        # multipath -f removes the multipath map but can leave
        # an orphaned dm device behind.  Use dmsetup info to check
        # if the dm device exists (not multipath -ll which only
        # sees the multipath map).
        my $dm_exists = _dmsetup_device_exists($ctx, $clean_scsiid);
        unless ($dm_exists) {
            debugmsg( $ctx, "debug", "Volume unstage multipath scsiid ${clean_scsiid} done (flush)" );
            return 1;
        }

        eval {
            my $cmd = [ $DMSETUP, "remove", "-f", $clean_scsiid ];
            run_command( $cmd,
                outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                timeout  => 20,
                noerr   => 1
            );
        };
        if ($@) {
            debugmsg( $ctx, 'warn', "dmsetup remove failed for ${clean_scsiid}: $@" );
        }

        # Check if dmsetup removal succeeded
        sleep(1);
        $dm_exists = _dmsetup_device_exists($ctx, $clean_scsiid);
        unless ($dm_exists) {
            debugmsg( $ctx, "debug", "Volume unstage multipath scsiid ${clean_scsiid} done (dmsetup)" );
            return 1;
        }

        # Identify what is blocking removal and wait for it
        my $mapper_name = get_device_mapper_name( $ctx, $clean_scsiid );
        $mapper_name = $clean_scsiid unless defined($mapper_name);
        my $blocker_pid = _volume_unstage_multipath_get_blocker($ctx, $clean_scsiid, $mapper_name);
        if ($blocker_pid) {
            debugmsg( $ctx, "debug", "Waiting for blocker pid ${blocker_pid} to finish (attempt ${attempt})" );
            # Wait up to 5 seconds for the blocker to finish
            for my $wait (1 .. 5) {
                last unless -d "/proc/${blocker_pid}";
                sleep(1);
            }
        } else {
            sleep(2);
        }

        debugmsg( $ctx, "debug", "Unable to remove multipath mapping for scsiid ${clean_scsiid} in attempt ${attempt}" );
    }

    # Final fallback: deferred removal — device will be removed when
    # the last opener (e.g. vgs) closes it.
    if (_dmsetup_device_exists($ctx, $clean_scsiid)) {
        debugmsg( $ctx, "info", "Using deferred dmsetup removal for ${clean_scsiid}" );
        eval {
            my $cmd = [ $DMSETUP, "remove", "--deferred", $clean_scsiid ];
            run_command( $cmd,
                outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                timeout  => 20,
                noerr   => 1
            );
        };
        # Deferred removal is "best effort" — the device will disappear
        # when the last holder releases it, so we return success.
        return 1;
    }

    return 0; # All attempts failed and deferred removal not possible
}

# Check if a device-mapper device exists by SCSI ID / dm name.
# Uses dmsetup info directly instead of multipath -ll, because
# multipath -f can remove the multipath map while leaving the
# underlying dm device behind as an orphan.
sub _dmsetup_device_exists {
    my ( $ctx, $name ) = @_;

    my $exists = 0;
    eval {
        my $cmd = [ $DMSETUP, "info", $name ];
        run_command( $cmd,
            outfunc => sub {
                my $line = shift;
                $exists = 1 if $line =~ /State:\s+ACTIVE/;
                cmd_log_output($ctx, 'debug', $cmd, $line);
            },
            errfunc => sub { },  # suppress "device not found" errors
            timeout  => 20,
            noerr   => 1
        );
    };
    return $exists;
}

sub _volume_unstage_multipath_log_blockers {
    my ( $ctx, $scsiid, $mapper_name ) = @_;

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
                    cmd_log_output($ctx, 'debug', $cmd, $pid);
                },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); }
            );
            if ( $pid =~ /^([\:\-\@\w.\/]+)$/ ) {
                my $clean_pid = $1;
                $cmd = [ 'ps', '-o', 'comm=', '-p', $clean_pid ];
                run_command(
                    $cmd,
                    outfunc => sub {
                        $blocker_name = clean_word(shift);
                        cmd_log_output($ctx, 'debug', $cmd, $blocker_name);
                    },
                    errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); }
                );
                my $warningmsg = "Unable to deactivate multipath device "
                    . "with scsi id ${scsiid}, "
                    . "device is used by ${blocker_name} with pid ${pid}";
                debugmsg( $ctx, 'warn', $warningmsg );
                warn "${warningmsg}\n";
            }
        };
        if ($@) {
            debugmsg( $ctx, 'warn', "Unable to identify multipath blocker: $@" );
        }
    } else {
        debugmsg( $ctx, "debug", "Multipath device file ${mapper_path} removed" );
    }
}

sub _volume_unstage_multipath_get_blocker {
    my ( $ctx, $scsiid, $mapper_name ) = @_;

    my $mapper_path = "/dev/mapper/${mapper_name}";
    return unless -b $mapper_path;

    my $pid;
    my $blocker_name;
    eval {
        my $cmd = [ 'lsof', '-t', $mapper_path ];
        run_command(
            $cmd,
            outfunc => sub {
                $pid = clean_word(shift);
                cmd_log_output($ctx, 'debug', $cmd, $pid);
            },
            errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); }
        );
    };
    return unless $pid;

    if ( $pid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $clean_pid = $1;
        eval {
            my $cmd = [ 'ps', '-o', 'comm=', '-p', $clean_pid ];
            run_command(
                $cmd,
                outfunc => sub {
                    $blocker_name = clean_word(shift);
                    cmd_log_output($ctx, 'debug', $cmd, $blocker_name);
                },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); }
            );
        };
        my $warningmsg = "Unable to deactivate multipath device "
            . "with scsi id ${scsiid}, "
            . "device is used by ${blocker_name} with pid ${pid}";
        debugmsg( $ctx, 'warn', $warningmsg );
        warn "${warningmsg}\n";
    }

    return $pid;
}

sub volume_unpublish {
    my ( $ctx, $vmid, $volname, $snapname, $content_volume_flag ) = @_;

    my $pool = get_pool( $ctx );
    my $prefix = get_target_prefix($ctx);

    debugmsg( $ctx,"debug",
                "Unpublish volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n");

    my $tgname;

    if ( defined($content_volume_flag) && $content_volume_flag != 0 ) {
        $tgname = get_content_target_group_name($ctx);
    } else {
        $tgname = get_vm_target_group_name($ctx, $vmid);
    }

    # Volume deletion will result in deletetion of all its snapshots
    # Therefore we have to detach all volume snapshots that is expected to be
    # removed along side with volume
    unless ( defined($snapname) ) {
        my $delitablesnaps = joviandss_cmd(
            $ctx,
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
                volume_deactivate( $ctx, $vmid,
                    $volname, $snap, undef );
            }
        }

        joviandss_cmd(
            $ctx,
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
            $ctx,
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
        $ctx,
        $targetname, $lunid, $volname, $snapname,
        $scsiid, $size,
        $multipath, $shared,
        @hosts
    ) = @_;
    my $storeid = $ctx->{storeid};

    my $ltldir = File::Spec->catdir( PLUGIN_LOCAL_STATE_DIR,
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
        $ctx,
        $targetname, $lunid, $volname, $snapname,
        $lunrec
    ) = @_;
    my $storeid = $ctx->{storeid};

    my $ltldir = File::Spec->catdir( PLUGIN_LOCAL_STATE_DIR,
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
    my ($ctx, $volname, $snapname, $tgname ) = @_;
    my $storeid = $ctx->{storeid};

    # Provides
    # ( target name, lun number, path to lun record file, lun record data )

    debugmsg( $ctx, "debug", "Searching for lun record of volume ${volname} "
        . safe_var_print( "snapshot", $snapname )
        . safe_var_print( "target group", $tgname )
        . "\n");

    my @matches = ();

    my $name = $volname;

    my $ldir = File::Spec->catdir( PLUGIN_LOCAL_STATE_DIR, $storeid );

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
                my $lunrec = lun_record_local_get_by_path( $ctx, $full);
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
                                debugmsg( $ctx, "debug", "Found lun record of volume ${volname} "
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
    my ($ctx,
        $targetname, $lunid, $volname
    ) = @_;
    my $storeid = $ctx->{storeid};

    my $ltldir = File::Spec->catfile( PLUGIN_LOCAL_STATE_DIR,
                                      $storeid, $targetname, $lunid, $volname);
    unless ( -d $ltldir ) {
        return undef;
    }

    my $ltlfile = File::Spec->catfile($ltldir, $volname);

    unless (-f $ltlfile && -r $ltlfile) {
        return undef;
    }

    return lun_record_local_get_by_path( $ctx, $ltlfile );
}

sub lun_record_local_get_by_path {
    my ( $ctx, $path ) = @_;

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
    my ( $ctx, $dir ) = @_;

    if (opendir my $dh, $dir) {
        my @files = grep { $_ ne '.' && $_ ne '..' } readdir $dh;

        closedir $dh;

        foreach my $file ( @files ) {
            debugmsg( $ctx, "debug", "Folder ${dir} contains ${file}");
        }
    } else {
        warn "Cannot open directory '$dir': $!";
    }

}

sub lun_record_local_delete {
    my ( $ctx, $targetname, $lunid, $volname, $snapname ) = @_;
    my $storeid = $ctx->{storeid};

    debugmsg( $ctx, "debug", "Deleting local lun record for "
        . "target ${targetname} "
        . "lun ${lunid} "
        . "volume ${volname} "
        . safe_var_print( "snapshot", $snapname )
        . "\n");

    debugmsg($ctx, 'debug', "delete lun record check\n");
    my $ltdir = File::Spec->catdir( PLUGIN_LOCAL_STATE_DIR,
                                    $storeid, $targetname );
    unless ( -d $ltdir ) {
        eval {
            volume_unstage_iscsi(
                $ctx,
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
    my $ltldir = File::Spec->catdir( PLUGIN_LOCAL_STATE_DIR,
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
            unless ( opendir( $dh, $ltdir ) ) {
                if ( $!{ENOENT} ) {
                    debugmsg($ctx, 'debug', "Target dir ${ltdir} already gone, skipping iSCSI unstage\n");
                    return 1;
                }
                die "Cannot open target dir ${ltdir}: $!\n";
            }
            my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
            closedir $dh;

            unless ( @entries ) {

                volume_unstage_iscsi( $ctx, $targetname );

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
            debugmsg( $ctx, 'warn',
                    "Skip removing lun dir of global target ${targetname} " .
                    "lun ${lunid} because of $!");
        }
    }
    return 1;
}

sub volume_activate {
    my ($ctx,
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
    my $shared = get_shared( $ctx );
    my $multipath = get_multipath( $ctx );
    my $targetname;
    my $lunid;
    my $hosts;

    if ( defined($content_volume_flag) && $content_volume_flag != 0 ) {
        $tgname = get_content_target_group_name($ctx);
    } else {
        $tgname = get_vm_target_group_name($ctx, $vmid);
    }

    debugmsg( $ctx, "debug",
            "Activating volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );

    eval {
        $published = 1;
        $tinfo = volume_publish($ctx,
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
            $ctx,
            $targetname,
            $lunid,
            $hosts,
        );
        $block_devs = $tbdlist;

        unless (scalar(@$block_devs) == scalar(@$hosts)) {
            die "Unable to connect all storage addresses\n";
        }
        $scsiid = id_serial_from_rest( $ctx, $volname, $snapname );

        if (defined( $scsiid ) ) {
            $scsiid_acquired = 1;
        } else {
            die "Unable to identify scsi id for ${volname}" .
                safe_var_print( "snapshot", $snapname ) . "\n";
        }

        if ($multipath) {
            $multipath_staged = 1;
            my $multipath_path = volume_stage_multipath( $ctx, $scsiid, $block_devs );
            my $mpdl = [ clean_word($multipath_path) ];
            $block_devs = $mpdl;
        }

        my $size = volume_get_size( $ctx, $volname);

        $local_record_created      = 1;
        my $ltlfile;

        $ltlfile = lun_record_local_create(
                $ctx,
                $targetname, $lunid, $volname, $snapname,
                $scsiid, $size,
                $multipath, $shared,
                @{ $hosts } );
        # We do it to recheck device size and properties
        # That is needed to ensure that proxmox recognize device as present
        # after volume migrates back
        my $lunrec = lun_record_local_get_by_path( $ctx, $ltlfile );
        lun_record_update_device( $ctx, $targetname, $lunid, $ltlfile, $lunrec, $size );

    };
    my $err = $@;

    if ($err) {
        warn "Volume ${volname} " . safe_var_print( "snapshot", $snapname ) . " activation failed: $err";

        my $local_cleanup = 0;


        # Logout iSCSI BEFORE removing multipath — same rationale as
        # in the normal deactivation path (see volume_deactivate).
        if ( $iscsi_staged ) {
            volume_unstage_iscsi_device( $ctx, $targetname, $lunid, $hosts );
        }

        if ($multipath_staged) {
            eval {
                volume_unstage_multipath( $ctx, $scsiid );
            };
            my $cerr = $@;
            if ($cerr) {
                $local_cleanup = 1;
                warn "volume_unstage_multipath failed: $@" if $@;
            }
        }

        # volume_unstage_iscsi call is moved to lun_record_local_delete

        if ( $snapname ) {
            # We do not delete target on joviandss as this will lead to race condition
            # in case of migration
            if ( $published ) {
                eval {
                    volume_unpublish( $ctx, $vmid, $volname, $snapname, undef );
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
                lun_record_local_delete( $ctx, $targetname, $lunid, $volname, $snapname );
            };
        } else {
            debugmsg($ctx, 'debug', "Skipping volume ${volname} "
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
    my ($ctx,
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

    my $pool   = get_pool($ctx);
    my $prefix = get_target_prefix($ctx);

    debugmsg( $ctx, "debug",
            "Volume ${volname} deactivate "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );

    if ( defined($contentvolumeflag) && $contentvolumeflag != 0 ) {
        $tgname = get_content_target_group_name($ctx);
    } else {
        $tgname = get_vm_target_group_name($ctx, $vmid);
    }

    unless( $snapname ) {
        my $delitablesnaps = joviandss_cmd(
            $ctx,
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
            volume_deactivate( $ctx, $vmid,
                $volname, $snap, undef );
        }
    }
    my $lunrecinfolist = lun_record_local_get_info_list( $ctx, $volname, $snapname );

    if (scalar(@$lunrecinfolist) == 0) {
        debugmsg(
            $ctx,
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
                my $tinfo = target_active_info( $ctx, $tgname, $volname, $snapname, $contentvolumeflag );
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
            $ctx,
            'warn',
            "Unable to identify lun record for "
                . "volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . "\n"
            );
        return 1;
    }

    # Logout iSCSI BEFORE removing multipath.  If we remove multipath
    # first, the `multipath $scsiid` refresh commands in the removal
    # function recreate the device because iSCSI paths are still active.
    # By logging out iSCSI first, the underlying paths disappear and
    # multipath removal succeeds cleanly.
    volume_unstage_iscsi_device ( $ctx, $targetname, $lunid, $lunrecord->{hosts} );

    if ( $lunrecord->{multipath} ) {
        eval {
            volume_unstage_multipath( $ctx, $lunrecord->{scsiid} );
        };
        my $cerr = $@;
        if ($cerr) {
            $local_cleanup = 1;
            warn "volume_unstage_multipath failed: $@" if $@;
        }
    }

    my $cerr;
    if ( $snapname ) {
    # We do not delete target on joviandss as this will lead to race condition
    # in case of migration
        eval {
            volume_unpublish( $ctx, $vmid, $volname, $snapname, undef );
        };
        $cerr = $@;
        if ($cerr) {
            $local_cleanup = 1;
            warn "unpublish_volume failed: $@" if $@;
        }
    }
    lun_record_local_delete( $ctx, $targetname, $lunid, $volname, $snapname );
    debugmsg( $ctx, "debug",
            "Volume ${volname} deactivate done "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );
    1;
}

sub lun_record_update_device {
    my ( $ctx, $targetname, $lunid, $lunrecpath, $lunrec, $expectedsize ) = @_;
    my $storeid = $ctx->{storeid};

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

        my $iscsi_block_devices = block_device_iscsi_paths ( $ctx, $targetname, $lunid, $lunrec->{hosts} );
        my $block_device_path;
        foreach my $iscsi_block_device ( @{ $iscsi_block_devices } ) {
            eval {
                my $cmd = [ "readlink", "-f", $iscsi_block_device ];

                run_command(
                    $cmd,
                    outfunc => sub { $block_device_path = shift; },
                    errfunc => sub {
                        cmd_log_output($ctx, 'error', $cmd, shift);
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
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        eval {
            my $cmd = [ $ISCSIADM, '-m', 'node', '-R', '-T', ${targetname} ];
            run_command( $cmd,
                outfunc => sub { },
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
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
        if ( get_multipath($ctx) ) {

            unless ($lunrec->{multipath}) {
                $lunrec->{multipath} = 1;
                lun_record_local_update( $ctx,
                                         $targetname, $lunid,
                                         $lunrec->{volname}, $lunrec->{snapname},
                                         $lunrec );
            }
            $block_device_path = volume_stage_multipath( $ctx, $lunrec->{scsiid} );
            eval {
                my $cmd = [ $MULTIPATH, '-r', ${block_device_path} ];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                    noerr   => 1
                );
                $cmd = [ $MULTIPATH, 'reconfigure'];
                run_command(
                    $cmd ,
                    outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
                    errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
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
                errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
                noerr   => 1
            );
        };

        if ($expectedsize) {
            if ( $updated_size eq $expectedsize ) {
                $lunrec->{size} = $expectedsize;
                lun_record_local_update( $ctx,
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
    my ( $ctx, $vmid, $volname, $size ) = @_;

    my $tgname;
    my $lunrecinfolist = lun_record_local_get_info_list( $ctx, $volname, undef );

    $tgname = get_vm_target_group_name($ctx, $vmid);

    if ( @$lunrecinfolist ) {
        if ( @$lunrecinfolist == 1 ) {
            my ($targetname, $lunid, $lunrecpath, $lunrecord) = @{ $lunrecinfolist->[0] };
            lun_record_update_device( $ctx, $targetname, $lunid, $lunrecpath, $lunrecord, $size);
        } else {
            foreach my $rec (@$lunrecinfolist) {
                my $tinfo = target_active_info( $ctx, $tgname, $volname, undef, undef );
                if ( defined( $tinfo ) ){
                    my ($targetname, $lunid, $lunrecpath, $lunrecord) = $rec;

                    if ( $tinfo->{name} eq $targetname ) {
                        if ( $tinfo->{lun} eq $lunid ) {
                            if ( $lunrecord->{volname} eq $volname ) {
                                unless(defined($lunrecord->{snapname})) {
                                        lun_record_update_device( $ctx, $targetname, $lunid, $lunrecpath, $lunrecord, $size);
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
    my ( $ctx, $volname ) = @_;

    my $pool = get_pool($ctx);

    my $output = joviandss_cmd($ctx, ['pool', $pool, 'volume', $volname, 'get', '-s'], 80, 5);

    my $size = int( clean_word( $output ) + 0 );
    return $size;
}

sub store_setup {
    my ( $ctx ) = @_;
    my $storeid = $ctx->{storeid};

    my $path = get_content_path($ctx);

    my $lldir = File::Spec->catdir( PLUGIN_LOCAL_STATE_DIR, $storeid );

    unless ( -d $lldir) {
        make_path $lldir, { owner => 'root', group => 'root' };
    }
}

sub vm_tag_force_rollback_is_set {
    my ( $ctx, $vmid ) = @_;

    my $virt_type = vmid_identify_virt_type($ctx, $vmid);

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
        if (clean_word($tag) eq 'force_rollback') {
            return 1;
        }
    }

    return 0;
}

1;
