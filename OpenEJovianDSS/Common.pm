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
);

our %EXPORT_TAGS = ( all => [@EXPORT_OK], );

my $default_prefix          = "jdss-";
my $default_pool            = "Pool-0";
my $default_config_path     = "/etc/pve/";
my $default_debug           = 0;
my $default_multipath       = 0;
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
    return $scfg->{target_prefix} || $default_target_prefix;
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
        return $scfg->{thin_provisioning};
    }
    return undef;
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

    #my $path = get_content_volume_name($scfg);
    #warn "path property is not set up, using default ${path}\n";
    #return $path;
}

sub get_multipath {
    my ($scfg) = @_;
    return $scfg->{multipath} || $default_multipath;
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
sub joviandss_volume_snapshot_info {
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
        OpenEJovianDSS::Common::debugmsg( $scfg, "debug",
"Volume ${volname} has snapshot ${name} with id ${guid} made at ${creation}\n"
        );
        $snapshots->{$name} = {
            id        => $guid,
            timestamp => $creation,
        };
    }

    return $snapshots;
}

sub joviandss_volume_rollback_is_possible {
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

sub get_vm_statate {
    my ($vmid) = @_;

    my $cmd = [
        'pvesh', 'get', 'cluster/resources', '-type', 'vm', '--output-format',
        'json'
    ];

    my $json_out = '';
    my $outfunc  = sub { $json_out .= "$_[0]\n" };

    run_command(
        $cmd,
        errmsg  => "Getting VM/CT info failed",
        outfunc => $outfunc
    );

    my $data = decode_json($json_out);
    foreach my $entry (@$data) {
        if ( $entry->{vmid} == $vmid ) {
            return $entry->{status};
        }
    }
    return undef;
}
1;
