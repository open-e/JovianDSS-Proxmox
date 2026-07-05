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
  get_default_jdssc_timeout
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
  get_cluster_prefix
  get_content
  get_content_volume_name
  get_content_volume_type
  get_content_volume_size
  get_content_path
  get_create_base_path
  get_multipath

  get_jdssc_timeout
  get_log_level

  password_file_set_password
  password_file_set_chap_password

  password_file_delete
  password_file_delete_chap_password

  safe_var_print
  safe_word
  safe_mount_options
  volume_name_clustered
  volume_name_unclustered
  debugmsg
  lock_properties
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
    PLUGIN_LOCAL_STATE_DIR               => '/etc/joviandss/state',
    PLUGIN_GLOBAL_STATE_DIR              => '/etc/pve/priv/joviandss/state',
    PLUGIN_TYPE_JOVIANDSS                => 'joviandss',
    PLUGIN_TYPE_JOVIANDSS_NFS            => 'joviandss-nfs',
    PLUGIN_PASSWORD_DIR_BASE             => '/etc/pve/priv/storage',
    # Max jdssc execution timeout while a Proxmox cluster (pmxcfs) lock is held. run_command
    # uses timeout+1, so the jdssc process runs <= 118 s — under the 120 s pmxcfs
    # CFS_LOCK_TIMEOUT, leaving ~2 s margin so the held cluster lock can never expire mid-run.
    # Also the cluster-backend hold-alarm ceiling in Lock::_lock_exec (design Finding #15).
    PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX     => 117,
    # Max total time a cluster-scope lock acquisition retries before dying with
    # "got lock request timeout" (design Finding #13; replaces a hardcoded 1200).
    PROXMOX_CLUSTER_LOCK_ACQUIRE_TIMEOUT_MAX => 600,
    # Cluster (pmxcfs) lock poll-loop tuning — each mkdir/utime can involve corosync
    # round-trips, so the inter-poll sleep backs off linearly and is jittered to keep
    # contending nodes out of lockstep.
    PROXMOX_CLUSTER_POLL_BASE_SLEEP      => 0.3,   # initial inter-poll sleep (s)
    PROXMOX_CLUSTER_POLL_BACKOFF_STEP    => 0.1,   # added to the base each iteration (s)
    PROXMOX_CLUSTER_POLL_JITTER_MAX      => 5,     # uniform jitter upper bound (s)
    PROXMOX_CLUSTER_POLL_SLEEP_CAP       => 10,    # max base sleep (s)
    # Bounds of the target-session query (target_get_sessions → jdssc
    # `sessions list`, docs/design/jdssc-target-sessions.md): the per-try
    # timeout is short — a healthy appliance answers in seconds — and
    # persistence across transient stalls comes from the retry count
    # (joviandss_cmd retries only on process timeouts; error exits die
    # immediately).
    TARGET_SESSIONS_QUERY_TIMEOUT        => 30,    # seconds per run
    TARGET_SESSIONS_QUERY_RETRIES        => 7,     # timeout-retries
};


my $ISCSIADM = '/usr/bin/iscsiadm';
$ISCSIADM = undef if !-X $ISCSIADM;

my $MULTIPATH = '/usr/sbin/multipath';
$MULTIPATH = undef if !-X $MULTIPATH;

my $MULTIPATHD = '/usr/sbin/multipathd';
$MULTIPATHD = undef if !-X $MULTIPATHD;

my $DMSETUP = '/usr/sbin/dmsetup';
$DMSETUP = undef if !-X $DMSETUP;

# Bounds of the host device-layer command chokepoint (multipath_cmd) and the
# volume-activation reactivation cycle
# (docs/design/volume-activation-with-reactivation.md, Table 4b).
use constant {
    # multipath_cmd timeout tiers (seconds; the TERM bound - the wrapper's
    # SIGKILL escalation follows MULTIPATH_CMD_KILL_GRACE later, and
    # run_command's last-resort kill sits MULTIPATH_CMD_BACKSTOP_MARGIN
    # above that; the whole ladder fits under the multipath lock's 60 s
    # hold cap).
    MULTIPATH_CMD_TIMEOUT_DEFAULT          => 20,
    MULTIPATH_CMD_TIMEOUT                  => 20,
    MULTIPATHD_CMD_TIMEOUT_FAST            => 5,
    MULTIPATH_CMD_TIMEOUT_MAX              => 30,
    MULTIPATH_CMD_KILL_GRACE               => 5,
    MULTIPATH_CMD_BACKSTOP_MARGIN          => 5,
    # Age bound of the stale-cookie sweep - MINUTES (udevcomplete_all's own
    # unit, unlike every other constant here).
    MULTIPATH_COOKIE_STALE_AGE             => 3,
    # Staging rounds (the volume_stage_multipath driver loop; deliberately
    # smaller than the previous hardcoded 60 - the reactivation cycle
    # supplies the deep retries).
    MULTIPATH_STAGE_ATTEMPTS               => 20,
    MULTIPATH_STAGE_SLEEP                  => 1,
    MULTIPATH_VPD_WAIT_ATTEMPTS            => 30,
    MULTIPATH_VPD_WAIT_SLEEP               => 1,
    # Unstage bounds - both keep today's effective behavior: the wait exits
    # early the moment the device is free, so the full bound is paid only
    # while something genuinely holds it (the migration corruption window
    # the wait guards).
    MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS => 60,
    MULTIPATH_UNSTAGE_WAIT_UNUSED_SLEEP    => 1,
    MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS      => 10,
    MULTIPATH_UNSTAGE_REMOVE_SETTLE        => 1,
    MULTIPATH_UNSTAGE_BLOCKER_WAIT         => 5,
    MULTIPATH_UNSTAGE_REMOVE_SLEEP         => 2,
    # The reactivation cycle in volume_activate.
    VOLUME_ACTIVATE_CYCLE_ATTEMPTS         => 4,
    VOLUME_ACTIVATE_CYCLE_SLEEP            => 5,
    VOLUME_ACTIVATE_CYCLE_MIN_BUDGET       => 120,
    VOLUME_ACTIVATE_VERIFY_ATTEMPTS        => 10,
    VOLUME_ACTIVATE_VERIFY_SLEEP           => 1,
};

use constant {
    DEFAULT_BLOCK_SIZE                => '16K',
    DEFAULT_CONTENT_SIZE              => 100,
    DEFAULT_CONTROL_PORT              => 82,
    DEFAULT_CREATE_BASE_PATH          => 1,
    DEFAULT_DATA_PORT                 => 3260,
    DEFAULT_DEBUG                     => 0,
    DEFAULT_PREFIX                    => 'jdss-',
    DEFAULT_POOL                      => 'Pool-0',
    DEFAULT_LOG_FILE                  => '/var/log/joviandss/joviandss.log',
    DEFAULT_JDSSC_TIMEOUT             => 113,
    DEFAULT_LUNS_PER_TARGET           => 8,
    DEFAULT_MULTIPATH                 => 0,
    DEFAULT_PATH                      => '/mnt/pve/joviandss',
    DEFAULT_SHARED                    => 0,
    DEFAULT_TARGET_PREFIX             => 'iqn.2025-04.proxmox.joviandss.iscsi:',
    DEFAULT_USER_NAME                 => 'admin',
    DEFAULT_SSL_CERT_VERIFY           => 1,
};



sub get_default_block_size       { return DEFAULT_BLOCK_SIZE }
sub get_default_create_base_path { return DEFAULT_CREATE_BASE_PATH }
sub get_default_prefix           { return DEFAULT_PREFIX }
sub get_default_pool             { return DEFAULT_POOL }
sub get_default_debug            { return DEFAULT_DEBUG }
sub get_default_multipath        { return DEFAULT_MULTIPATH }
sub get_default_content_size     { return DEFAULT_CONTENT_SIZE }
sub get_default_path             { die "Please set up path property in storage.cfg\n"; }
sub get_default_target_prefix    { return DEFAULT_TARGET_PREFIX }
sub get_default_log_file         { return DEFAULT_LOG_FILE }
sub get_proxmox_cluster_lock_timeout_max      { return PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX }
sub get_default_jdssc_timeout         { return DEFAULT_JDSSC_TIMEOUT }
sub get_default_luns_per_target           { return DEFAULT_LUNS_PER_TARGET }
sub get_default_ssl_cert_verify    { return DEFAULT_SSL_CERT_VERIFY }
sub get_default_control_port     { return DEFAULT_CONTROL_PORT }
sub get_default_data_port        { return DEFAULT_DATA_PORT }
sub get_default_user_name        { return DEFAULT_USER_NAME }

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
    return safe_word($scfg->{'pool_name'});
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
    my $prefix = $scfg->{target_prefix} || DEFAULT_TARGET_PREFIX;

    $prefix =~ s/:$//;
    return safe_word( clean_word($prefix) );
}

sub get_jdssc_timeout {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return int( $scfg->{jdssc_timeout} || DEFAULT_JDSSC_TIMEOUT );
}

sub get_luns_per_target {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    my $luns_per_target = $scfg->{luns_per_target} || DEFAULT_LUNS_PER_TARGET;

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

    return $scfg->{delete_timeout} || 118;
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
    my $port = $scfg->{control_port} || DEFAULT_CONTROL_PORT;

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
    return $scfg->{user_name} || DEFAULT_USER_NAME;
}

sub get_plugin_type {
    my ($ctx) = @_;
    my $type = $ctx->{scfg}{type};

    if (!defined $type) {
        die "JovianDSS: storage 'type' is not set in scfg\n";
    }
    if ($type eq PLUGIN_TYPE_JOVIANDSS) {
        return PLUGIN_TYPE_JOVIANDSS;
    }
    if ($type eq PLUGIN_TYPE_JOVIANDSS_NFS) {
        return PLUGIN_TYPE_JOVIANDSS_NFS;
    }

    die "JovianDSS: unexpected storage type '$type'\n";
}

sub get_plugin_password_dir {
    my ($ctx) = @_;
    return PLUGIN_PASSWORD_DIR_BASE . '/' . get_plugin_type($ctx);
}

sub get_password_file_path {
    my ($ctx) = @_;
    return get_plugin_password_dir($ctx) . "/$ctx->{storeid}.pw";
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

    my $dir = get_plugin_password_dir($ctx);
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
        # No keys left (no user password, no chap password) — drop the whole file.
        password_file_delete($ctx);
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

sub password_file_delete_user_password {
    my ($ctx) = @_;
    # user_password is mandatory while the storage exists: it can be changed but
    # never individually cleared. The whole file is removed only on storage
    # deletion (on_delete_hook -> password_file_delete).
    die "user_password cannot be cleared; provide a new value or remove the storage\n";
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
    return DEFAULT_BLOCK_SIZE;
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
    return $scfg->{log_file} || DEFAULT_LOG_FILE;
}

sub get_options {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    my $options = $scfg->{options};
    if (defined($options)) {
        if ( $options =~ /^([\:\-\@\w.,\/=]+)$/ ) {
            return $1;
        } else {
            die "Options property contains forbidden symbols: ${options}\n";
        }
    } else {
        return undef;
    }
}

sub get_cluster_prefix {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    if (defined( $scfg->{cluster_prefix}) ) {
        my $prefix = $scfg->{cluster_prefix};
        if ($prefix =~ /^([a-zA-Z][a-zA-Z0-9]*)$/) {
            return $1;
        }
        die "cluster_prefix '${prefix}' is invalid: only letters and digits are allowed, "
          . "and it must start with a letter\n";
    }
    return undef;
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

    my $size = $scfg->{content_volume_size} || DEFAULT_CONTENT_SIZE;
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
    return $scfg->{multipath} || DEFAULT_MULTIPATH;
}

sub get_shared {
    my ($ctx) = @_;
    my $scfg = $ctx->{scfg};
    return $scfg->{shared} || DEFAULT_SHARED;
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

sub safe_mount_options {
    my ($word, $word_desc) = @_;

    if ( $word =~ /^([\:\-\@\w.,\/=]+)$/ ) {
        return $1;
    } else {
        die "${word_desc} contains forbidden symbols: ${word}\n";
    }
}

sub volume_name_clustered {
    my ($ctx, $volname) = @_;

    my $prefix = get_cluster_prefix($ctx);

    return defined($prefix) ? "${prefix}_${volname}" : $volname;
}

sub volume_name_unclustered {
    my ($ctx, $volname_clustered) = @_;

    my $prefix = get_cluster_prefix($ctx);

    return $volname_clustered unless defined($prefix);
    return undef unless $volname_clustered =~ s/^\Q${prefix}\E_//;
    return $volname_clustered;
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
        scfg        => $scfg,
        storeid     => $storeid,
        reqid       => _new_reqid(),
        _held_locks => [],
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

# storage.cfg schema for the lock-class properties, defined once here.
# PVE::SectionConfig registers property names globally: the iSCSI plugin
# splices this into its properties() (re-declaring the names in the NFS plugin
# would be a duplicate property error); BOTH plugins list the names in their
# options(). Values are read by the generic OpenEJovianDSS::Lock getters
# (get_lock_class_type / _dir / _acquire_timeout / _hold_timeout).
sub lock_properties {
    return {
        jdssc_general_lock_type => {
            description => "Scope of the general-tier jdssc lock",
            type        => 'string',
            enum        => [ 'node', 'cluster' ],
        },
        jdssc_general_lock_path => {
            description => "Directory override for the general-tier jdssc lock"
                         . " (must suit the chosen type's backend)",
            type        => 'string',
        },
        jdssc_general_lock_acquire_timeout => {
            description => "Seconds to wait to acquire the general-tier jdssc lock",
            type        => 'integer',
            minimum     => 1,
        },
        jdssc_general_lock_hold_timeout => {
            description => "Hold cap in seconds for the general-tier jdssc lock"
                         . " (0 disables the wall-clock deadline)",
            type        => 'integer',
            minimum     => 0,
        },
        jdssc_info_lock_type => {
            description => "Scope of the info-tier jdssc lock",
            type        => 'string',
            enum        => [ 'node', 'cluster' ],
        },
        jdssc_info_lock_path => {
            description => "Directory override for the info-tier jdssc lock"
                         . " (must suit the chosen type's backend)",
            type        => 'string',
        },
        jdssc_info_lock_acquire_timeout => {
            description => "Seconds to wait to acquire the info-tier jdssc lock",
            type        => 'integer',
            minimum     => 1,
        },
        jdssc_info_lock_hold_timeout => {
            description => "Hold cap in seconds for the info-tier jdssc lock"
                         . " (0 disables the wall-clock deadline)",
            type        => 'integer',
            minimum     => 0,
        },
        multipath_lock_type => {
            description => "Scope of the multipath host-device-command lock",
            type        => 'string',
            enum        => [ 'node', 'cluster' ],
        },
        multipath_lock_path => {
            description => "Directory override for the multipath lock"
                         . " (must suit the chosen type's backend)",
            type        => 'string',
        },
        multipath_lock_acquire_timeout => {
            description => "Seconds to wait to acquire the multipath lock",
            type        => 'integer',
            minimum     => 1,
        },
        multipath_lock_hold_timeout => {
            description => "Hold cap in seconds for the multipath lock"
                         . " (0 disables the wall-clock deadline)",
            type        => 'integer',
            minimum     => 0,
        },
    };
}

# $lock_class — which jdssc component lock class to take around the run
# (trailing optional arg). One of:
#   'jdssc_general'  → cluster-wide serialization (state-changing commands)  [default]
#   'jdssc_info'     → per-host serialization only (host-safe read commands)
sub joviandss_cmd {
    my ( $ctx, $cmd, $timeout, $retries, $force_debug_level, $lock_class ) = @_;
    my $scfg    = $ctx->{scfg};
    my $storeid = $ctx->{storeid};

    $lock_class //= 'jdssc_general';

    my $msg = '';
    my $err = undef;
    my $target;
    my $retry_count = 0;

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

    my $user_password = get_user_password($ctx);
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

    # jdssc_timeout (scfg) supplies the default per-call execution timeout when
    # the caller passes none; jdssc itself gets no --timeout — run_command's
    # kill (timeout + 1) is the sole bound on the process.
    $timeout //= get_jdssc_timeout($ctx);

    # One run — run_command's timeout + 1 — must stay below the pmxcfs
    # CFS_LOCK_TIMEOUT idle expiry under a cluster-backend jdssc lock, and below
    # every class's hold cap on any backend; the per-call execution timeout is
    # therefore clamped centrally here for every call (over-cap call-site
    # literals like 118 are bounded automatically). The old
    # "process_timeout + 5" floor is gone for the same reason: it could
    # re-inflate the hold past the clamp.
    $timeout = PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX
        if $timeout > PROXMOX_CLUSTER_LOCK_TIMEOUT_MAX;

    while ( $retry_count <= $retries ) {

        my $exitcode = 0;
        eval {
            my $output   = sub {
                                    $msg .= "$_[0]\n";
                               };
            my $errfunc  = sub {
                                    $err .= "$_[0]\n";
                               };

            my $jrun = sub {
                my $jcmd = [ '/usr/local/bin/jdssc', @$connection_options, @$cmd ];
                $exitcode = run_command( $jcmd,
                    outfunc => $output,
                    errfunc => $errfunc,
                    timeout => $timeout + 1,
                    noerr   => 1
                );
            };

            # The jdssc component lock — taken per single jdssc execution,
            # inside the retry loop. with_lock refreshes every held lock
            # around the body (replacing the old touch_cluster_lock brackets)
            # and dies on any failure, so $@ feeds the retry handling below
            # unchanged.
            OpenEJovianDSS::Lock::with_lock($ctx, $lock_class, undef, undef, $jrun);
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

# multipath_cmd($ctx, $cmd, $timeout, $outfunc)
#   $cmd      argv arrayref of ONE multipath/multipathd/udevadm/dmsetup
#             invocation
#   $timeout  seconds for the command (TERM bound), or undef ->
#             MULTIPATH_CMD_TIMEOUT_DEFAULT; clamped to
#             MULTIPATH_CMD_TIMEOUT_MAX
#   $outfunc  optional stdout line handler (default: capture + debug log)
# The locked chokepoint for every host device-layer command, mirroring how
# joviandss_cmd is the single chokepoint for jdssc: runs the one command
# under the node-scope 'multipath' lock (docs/design/
# volume-activation-with-reactivation.md). The locked body is the bare
# run - the lock design's leaf rule: it takes no other with_lock and never
# calls joviandss_cmd. All retry sleeps stay at the callers, OUTSIDE the
# lock. Returns { exitcode, out } (fixed shape). A failing command reports
# through ->{exitcode} (noerr) instead of dying; a lock-machinery failure
# deliberately propagates - the reactivation cycle's error classification
# decides what happens next.
sub multipath_cmd {
    my ( $ctx, $cmd, $timeout, $outfunc ) = @_;

    $timeout //= MULTIPATH_CMD_TIMEOUT_DEFAULT;
    $timeout = MULTIPATH_CMD_TIMEOUT_MAX
        if $timeout > MULTIPATH_CMD_TIMEOUT_MAX;
    $timeout = 1 if $timeout < 1;   # coreutils timeout treats 0 as NO
                                    # bound - it would disarm the
                                    # TERM-first ladder, leaving only
                                    # run_command's SIGKILL backstop

    my $out = '';
    my $capture = $outfunc // sub {
        my ($line) = @_;
        $out .= "$line\n";
        cmd_log_output( $ctx, 'debug', $cmd, $line );
    };

    # TERM-first bounding: coreutils timeout(1) sends SIGTERM at $timeout -
    # multipath's signal handler releases the IPC semaphore (ISSUES.md
    # Issue 2) - and escalates to SIGKILL only MULTIPATH_CMD_KILL_GRACE
    # later. run_command's own kill is SIGKILL, the exact re-strand hazard
    # this ladder exists to avoid, so it is armed a full
    # MULTIPATH_CMD_BACKSTOP_MARGIN above the escalation: it can only fire
    # after the graceful termination already failed.
    my $tcmd = [ '/usr/bin/timeout', '--signal=TERM',
                 '--kill-after=' . MULTIPATH_CMD_KILL_GRACE,
                 $timeout, @$cmd ];

    my $exitcode;
    my $run = sub {
        $exitcode = run_command( $tcmd,
            outfunc => $capture,
            errfunc => sub { cmd_log_output( $ctx, 'error', $cmd, shift ) },
            timeout => $timeout + MULTIPATH_CMD_KILL_GRACE
                       + MULTIPATH_CMD_BACKSTOP_MARGIN,
            noerr   => 1,
        );
    };
    OpenEJovianDSS::Lock::with_lock( $ctx, 'multipath', undef, undef, $run );

    # Stranded-cookie signature (124 = TERM'd at the bound, 137 = KILL'd
    # after the grace): remembered on $ctx for the reactivation cycle's
    # sweep gate (_multipath_cookie_sweep) - the chokepoint itself retries
    # and repairs nothing.
    $ctx->{_multipath_cmd_ladder_exhausted} = 1
        if defined($exitcode) && ( $exitcode == 124 || $exitcode == 137 );

    return { exitcode => $exitcode, out => $out };
}

# Probe-then-sweep for stranded device-mapper udev cookies (ISSUES.md
# Issue 2: a cookie whose owner was SIGKILL'd is never completed by anyone,
# and every later waiter blocks forever in semtimedop). Called from
# volume_activate's failure branch - only while the 124/137 strand
# signature is armed, before the teardown. Both commands route through
# multipath_cmd - same node lock, same bounds. Returns the number of
# outstanding cookies found (diagnostic).
sub _multipath_cookie_sweep {
    my ($ctx) = @_;

    my $probe = multipath_cmd( $ctx, [ $DMSETUP, 'udevcookies' ],
                               MULTIPATH_CMD_TIMEOUT );
    return 0                              # dm layer unreachable - nothing to do
        if !defined( $probe->{exitcode} ) || $probe->{exitcode} != 0;

    # udevcookies prints a header row and a version-dependent column
    # layout; matching cookie lines by the leading 0x is the portable read.
    my @cookies = grep { /^0x/ } split /\n/, $probe->{out};
    return 0 if !@cookies;                # no outstanding cookies - nothing to sweep

    debugmsg( $ctx, 'warn',
        scalar(@cookies) . " outstanding udev cookie(s) after a failed "
      . "activation attempt; completing those older than "
      . MULTIPATH_COOKIE_STALE_AGE . " minutes" );

    # Age-bounded: touches nothing younger than MULTIPATH_COOKIE_STALE_AGE
    # minutes - far above any legitimate udev latency, so live operations
    # (including node-local LVM, which shares the cookie mechanism) are
    # never completed early. -y answers dmsetup's confirmation prompt.
    multipath_cmd( $ctx,
        [ $DMSETUP, '-y', 'udevcomplete_all', MULTIPATH_COOKIE_STALE_AGE ] );

    return scalar(@cookies);
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
        ],
        118,
        5
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
            ],
            118,
            5
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

    my $cmdout = joviandss_cmd( $ctx, $getaddressescmd, 118, 3 );

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

    my $out = joviandss_cmd( $ctx, $gettargetcmd, 118, 5 );

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

sub target_get_sessions {
    my ( $ctx, $target_name ) = @_;

    my $pool = get_pool( $ctx );    # untainted inside get_pool

    # Untaint the target name (regex-capture via safe_word): it arrives from
    # parsed jdssc output — tainted under -T — and an unsanitized exec dies
    # with "Insecure dependency", which the session gate would misread as a
    # permanently failed query (the volume_unpublish taint lesson).
    $target_name = safe_word( clean_word($target_name), 'target name' );

    debugmsg( $ctx, "debug", "Getting sessions for target ${target_name}\n" );

    my $out = joviandss_cmd( $ctx,
        [ 'pool', $pool, 'target', $target_name, 'sessions', 'list' ],
        TARGET_SESSIONS_QUERY_TIMEOUT, TARGET_SESSIONS_QUERY_RETRIES );

    my %sessions = ();
    for my $line ( split /\n/, $out ) {
        $line = clean_word($line);
        next if $line eq '';
        my ( $initiator, $ips_str ) = split( /\s+/, $line, 2 );
        my @ips = split( /,/, $ips_str );
        $sessions{$initiator} = \@ips;
    }

    for my $initiator ( keys %sessions ) {
        debugmsg( $ctx, "debug",
            "Target ${target_name} session: initiator ${initiator} "
            . "ips " . join( ',', @{ $sessions{$initiator} } ) . "\n"
        );
    }

    return \%sessions;
}

sub get_local_initiator_name {
    my ( $ctx ) = @_;

    my $initiatorname_file = '/etc/iscsi/initiatorname.iscsi';

    debugmsg( $ctx, "debug", "Reading local initiator name from ${initiatorname_file}\n" );

    open( my $fh, '<', $initiatorname_file )
        or die "Cannot open ${initiatorname_file}: $!\n";

    my $initiator_name = undef;
    while ( my $line = <$fh> ) {
        chomp $line;
        if ( $line =~ /^InitiatorName=(.+)$/ ) {
            $initiator_name = $1;
            last;
        }
    }
    close($fh);

    die "InitiatorName not found in ${initiatorname_file}\n"
        unless defined $initiator_name;

    debugmsg( $ctx, "debug", "Local initiator name is ${initiator_name}\n" );

    return $initiator_name;
}

# Foreign-session probe for the reactivation cycle's recovery detach:
# returns an arrayref of initiator IQNs - OTHER THAN THIS NODE'S - holding
# active sessions on $targetname; empty means "only local sessions (or
# none) - safe to detach". Dies when the query fails; the caller reads a
# die as "no evidence, no detach". The local identity is what the node's
# own initiator sends on login (/etc/iscsi/initiatorname.iscsi), which is
# byte-for-byte what the appliance reports back - compared
# case-insensitively anyway (RFC 3722 prescribes lowercase; guard against
# case drift). target_get_sessions groups by initiator, so a multipath
# node's several sessions (one per portal) are one key here.
sub _target_foreign_sessions {
    my ( $ctx, $targetname ) = @_;

    my $sessions = target_get_sessions( $ctx, $targetname );  # initiator -> [ips]
    my $local_initiator = lc( get_local_initiator_name($ctx) );

    my @foreign;
    for my $initiator ( sort keys %$sessions ) {
        push @foreign, $initiator
            if lc($initiator) ne $local_initiator;
    }

    debugmsg( $ctx, 'debug',
        "Target ${targetname} foreign sessions: "
      . ( @foreign ? join( ',', @foreign ) : 'none' ) );

    return \@foreign;
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

    my $out = joviandss_cmd( $ctx, $create_target_cmd, 118, 15 );
    my ( $targetname, $lunid, $ips, $scsiid ) = split( ' ', $out );

    my @iplist = split /\s*,\s*/, clean_word($ips);

    my %tinfo = (
        target  => clean_word($targetname),
        lunid   => clean_word($lunid),
        iplist  => \@iplist,
        scsiid  => clean_word($scsiid),
    );
    debugmsg( $ctx, "debug",
            "Publish volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . 'acquired '
          . "target ${targetname} "
          . "lun ${lunid} "
          . "hosts @{iplist} "
          . "scsiid " . ( $scsiid // 'undef' ) );

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
        eval { joviandss_cmd($ctx, $cmd, 118, 4); };
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


# Runs rescan-scsi-bus.sh for $lunid only when no other instance is active.
# retrun 0 and skips silently when a concurrent rescan is already in progress
# return 0 if error happens
# return 1 if rescan is completed
sub _scsi_bus_rescan_try {
    my ($ctx, $lunid) = @_;

    my $busy = 0;
    eval {
        my $chk = ['pgrep', '-f', 'rescan-scsi-bus.sh'];
        run_command(
            $chk,
            outfunc => sub { $busy = 1; },
            errfunc => sub { },
            noerr   => 1,
        );
    };

    if ($busy) {
        debugmsg($ctx, 'debug',
            "rescan-scsi-bus.sh already running, skipping rescan for lun ${lunid}\n");
        return 0;
    }

    my $cmd = [
        '/usr/bin/rescan-scsi-bus.sh',
        '--sparselun', '--reportlun2', '--largelun',
        "--luns=${lunid}", '-a',
    ];

    my $errcode = run_command(
        $cmd,
        outfunc => sub { cmd_log_output($ctx, 'debug', $cmd, shift); },
        errfunc => sub { cmd_log_output($ctx, 'error', $cmd, shift); },
        timeout => 55,
        noerr   => 1,
    );
    if ($errcode == 0 ) {
        return 1;
    }
    return 0;
}


# _rescan_target_hosts($ctx, $targetname, $lunid)
#
# Trigger a SCSI LUN rescan only on the hosts that carry an iSCSI session
# for $targetname.  Reads the mapping from sysfs:
#   /sys/class/iscsi_session/session{N}/targetname  -> IQN
#   /sys/class/iscsi_session/session{N}/device      -> symlink -> host{H}
#   /sys/class/scsi_host/host{H}/scan               -> write "- - {lun}"
#
# Safe to call from multiple parallel processes: each touches only its own
# session hosts, so there is no cross-VM interference.
#
# if targetd rescan is not possible will attempt brorad scsi scan for all targets
# broad scan will happen only if no other scan scritps are going at the moment
sub _rescan_target_hosts {
    my ( $ctx, $targetname, $lunid ) = @_;

    my $session_dir = '/sys/class/iscsi_session';
    opendir( my $session_dir_desc, $session_dir ) or do {
        debugmsg( $ctx, 'warn', "Cannot open $session_dir $!\n" );

        # Unable to open iscsi_session folder containing mappings of
        # iscsi sessions
        # proceed will broad scan

        _scsi_bus_rescan_try($ctx, $lunid);
        return;
    };
    my @sessions = grep { /^session\d+$/ } readdir($session_dir_desc);
    closedir($session_dir_desc);

    # Iterate over iscsi sessions projected in /sys/class/iscsi_session folder
    # to identigy session related to target @targetname

    my $found_session = 0;
    for my $session (@sessions) {
        my $targetname_file_path = "$session_dir/$session/targetname";

        if ( !-f $targetname_file_path ) {
            next;
        }

        open( my $targetfile_desc, '<', $targetname_file_path ) or next;

        my $session_target = <$targetfile_desc>;

        $session_target = clean_word($session_target);
        $session_target = safe_word($session_target);

        close $targetfile_desc;

        if ( !defined $session_target ) {
            next;
        }

        if ( $session_target ne $targetname ) {
            next;
        }

        $found_session = 1;

        # iscsi $session is related to $targetname
        my $session_rescan_completed = 0;
        my $session_device_link = "$session_dir/$session/device";
        if ( -l $session_device_link ) {
            my $session_device_path = Cwd::realpath($session_device_link);
            if ( defined( $session_device_path ) ) {
                my ( $session_host_name ) = ( $session_device_path =~ m{/(host\d+)/} );

                my $session_scan_path = "/sys/class/scsi_host/$session_host_name/scan";
                if ( open( my $session_scan_desc, '>', $session_scan_path ) ) {
                    print $session_scan_desc "- - $lunid\n";
                    close $session_scan_desc;
                    $session_rescan_completed = 1;
                    debugmsg( $ctx, 'debug',
                        "Targeted rescan: $session_device_path for target $targetname lun $lunid\n" );
                } else {
                    debugmsg( $ctx, 'warn', "Cannot write to $session_scan_path: $!\n" );
                }
            }
        }
        if ( $session_rescan_completed == 0) {
            debugmsg( $ctx, 'debug',
                "Because of inability to send targeted rescan for target $targetname lun $lunid, try conducting General rescan across all targets\n" );
            _scsi_bus_rescan_try($ctx, $lunid);
        }
    }

    unless ($found_session) {
        debugmsg( $ctx, 'debug',
            "No session found for target $targetname, conducting broad rescan\n" );
        _scsi_bus_rescan_try($ctx, $lunid);
    }
}

# $expected_size (option A, finding #23): the authoritative control-plane
# size. When given, the exit contract requires the exported LUN to report
# this exact non-zero capacity (a fresh READ CAPACITY via rescan-then-read)
# before returning - the backend-export health check at the raw-LUN layer.
# undef falls back to "non-zero capacity" (still catches a size-0 export).
sub volume_stage_iscsi {
    my ( $ctx, $targetname, $lunid, $hosts, $scsiid, $expected_size ) = @_;

    debugmsg( $ctx, "debug", "Stage target ${targetname} lun ${lunid} over addresses @$hosts\n" );

    # Fast path: block device already present AND reporting the right size.
    my $serial_path = block_device_path_from_serial( $scsiid, 0 );
    if ( -b $serial_path && _iscsi_capacity_ok( $ctx, $serial_path, $expected_size ) ) {
        return [$serial_path];
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

        # Cooperation tick: refresh every held outer lock and run its
        # hold-deadline check - the iSCSI phase runs no locked commands,
        # so without explicit ticks it is the activation's longest
        # uncooperative stretch (volume-activation design, follow-up #4).
        OpenEJovianDSS::Lock::refresh_locks($ctx);

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

    for ( my $i = 1 ; $i <= 240 ; $i++ ) {
        # The device must be present AND report the correct non-zero
        # capacity (option A / finding #23): a present-but-wrong-size LUN
        # is SCST's under-load export failure - looks fine, non-functional.
        # _iscsi_capacity_ok forces a fresh READ CAPACITY (rescan-then-read).
        if ( -b $serial_path ) {
            if ( _iscsi_capacity_ok( $ctx, $serial_path, $expected_size ) ) {
                debugmsg( $ctx, "debug", "Stage iSCSI block device ${serial_path}\n" );
                return [$serial_path];
            }
            debugmsg( $ctx, "debug",
                "iSCSI device ${serial_path} present but capacity not yet "
              . "verified against " . ( $expected_size || 'non-zero' )
              . " (attempt ${i})\n" );
        } else {
            debugmsg( $ctx, "debug", "Waiting for block device ${serial_path} attempt ${i}\n" );
        }

        # Cooperation tick every 10th wait tick (follow-up #4): refresh
        # held locks + hold-deadline check inside the 240 s device wait.
        OpenEJovianDSS::Lock::refresh_locks($ctx) if $i % 10 == 0;

        sleep(1);

        # Run rescan-scsi-bus only every 3rd attempt — under concurrent load
        # each rescan takes minutes and many concurrent rescans cause SCSI bus
        # congestion.
        if ( $i % 3 == 0 ) {
            _rescan_target_hosts( $ctx, $targetname, $lunid );
        }
    }

    #log_dir_content($ctx, '/dev/disk/by-id');
    debugmsg( $ctx, "warn",
        "Unable to identify block device for scsi id ${scsiid}\n" );

    die "Unable to verify target ${targetname} block device "
      . "(present + correct capacity) for scsi id ${scsiid}.\n";
}

# Backend-export capacity health check (option A, finding #23). Returns
# true only when the block device at $path reports a non-zero size that
# matches $expected (when given). CRITICAL: it forces a fresh READ CAPACITY
# first (write to the device's /sys rescan), because blockdev --getsize64
# reads the kernel's CACHED capacity - reading the cache alone could show a
# stale-but-plausible value and miss a broken export (finding #23,
# measured). $path is a /dev/disk/by-id/scsi-<id> symlink to the sd device;
# these are read-only device / sysfs operations, deliberately NOT under the
# multipath lock (Table 1 "not locked").
sub _iscsi_capacity_ok {
    my ( $ctx, $path, $expected ) = @_;

    # Force READ CAPACITY on the underlying sd device (untaint the sd name
    # from the resolved symlink before using it in a /sys path).
    my $real = eval { Cwd::abs_path($path) };
    if ( defined($real) && $real =~ m{^/dev/(sd[a-z]+)$} ) {
        my $rescan = "/sys/block/$1/device/rescan";
        if ( -w $rescan ) {
            eval {
                open my $fh, '>', $rescan or die "open ${rescan}: $!\n";
                print $fh "1"              or die "write ${rescan}: $!\n";
                close $fh                  or die "close ${rescan}: $!\n";
            };
            debugmsg( $ctx, 'debug', "READ CAPACITY rescan of $1 failed: $@" ) if $@;
        }
    }

    my $sz;
    my $cmd = [ '/sbin/blockdev', '--getsize64', $path ];
    eval {
        run_command( $cmd,
            outfunc => sub { my $l = shift; $sz = int($1) if $l =~ /^(\d+)$/; },
            errfunc => sub { cmd_log_output( $ctx, 'error', $cmd, shift ); },
            noerr   => 1 );
    };

    return 0 if !defined($sz) || $sz == 0;          # zero never verifies
    return 1 if !$expected;                          # non-zero suffices
    return int($sz) == int($expected) ? 1 : 0;
}

sub volume_stage_multipath {
    my ( $ctx, $scsiid, $block_devs, $attempts, $verify_map ) = @_;

    $scsiid    = safe_word( clean_word($scsiid), 'multipath scsi id' );
    $attempts //= MULTIPATH_STAGE_ATTEMPTS;

    my $mpath = clean_word( block_device_path_from_serial( $scsiid, 1 ) );

    # Fast path - the map already exists (typical for the direct callers
    # re-resolving an active volume): return before any command, no lock
    # taken at all. Mirrors volume_stage_iscsi's own fast path.
    # $verify_map (set by the ACTIVATION flow - every cycle; direct callers
    # keep the bare -b): existence is not evidence there - a leftover map
    # whose teardown could not remove it, or one marked for deferred
    # removal, still owns a device node while its paths belong to a
    # logged-out session; trusting it would replay the same wedged map,
    # and size verification cannot catch a dead-but-intact map (blockdev
    # --getsize64 answers from the dm table without touching a path).
    # Require at least one active path before returning, else fall through
    # into the rounds and rebuild/repair in place.
    if ( -b $mpath ) {
        return $mpath if !$verify_map;
        return $mpath if _multipath_map_has_active_path( $ctx, $scsiid );
        debugmsg( $ctx, 'warn',
            "Existing map for ${scsiid} has no active path - rebuilding" );
    }

    # Whitelist the WWID FIRST: it needs no device present, and multipathd
    # reacts to udev events on its own - so the VPD wait below overlaps
    # with the daemon already claiming paths as they appear instead of
    # being dead time.
    multipath_cmd( $ctx, [ $MULTIPATH, '-a', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT );

    # Phase 1 - wait for the SCSI VPD symlink (multipathd cannot associate
    # paths with the WWID before the inquiry completes; under load the
    # inquiry queue backs up 30+ s). In the ACTIVATION flow this is a no-op
    # guard: volume_stage_iscsi's exit condition is this very symlink - it
    # waits up to 240 s for it, rescanning, or dies - so the first -e here
    # succeeds with zero sleeps. The wait only ever waits for the direct
    # callers that stage multipath without a fresh iSCSI stage
    # (block_device_path_from_lun_rec, lun_record_update_device).
    my $scsi_by_id = block_device_path_from_serial( $scsiid, 0 );
    for my $tick ( 1 .. MULTIPATH_VPD_WAIT_ATTEMPTS ) {
        last if -e $scsi_by_id;
        debugmsg( $ctx, 'debug',
            "Waiting for SCSI device ${scsi_by_id} (${tick})" )
            if $tick == 1 || $tick % 10 == 0;
        sleep(MULTIPATH_VPD_WAIT_SLEEP);
    }
    debugmsg( $ctx, 'warn',
        "SCSI device ${scsi_by_id} not found, attempting staging anyway" )
        if !-e $scsi_by_id;

    # Resolve iSCSI by-path symlinks to sd names ONCE - reused every round.
    my $sd_devnames = [];
    if ( $block_devs && ref($block_devs) eq 'ARRAY' ) {
        for my $bp (@$block_devs) {
            my $real = Cwd::abs_path($bp);
            push @$sd_devnames, $1 if $real && $real =~ m{^/dev/(sd[a-z]+)$};
        }
        if (@$sd_devnames) {
            debugmsg( $ctx, 'debug',
                "Resolved iSCSI paths for multipath: "
              . join( ', ', @$sd_devnames ) );
        }
    }

    # Phase 2 - bounded staging rounds; sleeps out here, never under the
    # lock. ACCEPTANCE runs at the TOP of each iteration - after the
    # previous round's sleep, so multipathd's path checker has had its
    # window before a fresh map is judged - and, with the settle check
    # below, is the rounds' only gate: a map is returned only with at
    # least one active path; the round's return value is advisory (its -b
    # short-circuits only stop escalation within the round).
    # $last: the final round of a REAL ladder fires EVERY escalation
    # whatever its modulo gate - the last chance must not depend on the
    # attempts count's divisibility. An attempts bound of 1 requests one
    # GENTLE repair round instead (the verify loop's embedded re-stage),
    # so the blast is suppressed: $attempts > 1.
    for my $attempt ( 1 .. $attempts ) {
        return $mpath
            if -b $mpath && _multipath_map_has_active_path( $ctx, $scsiid );
        my $last = $attempt == $attempts && $attempts > 1;
        _volume_stage_multipath( $ctx, $scsiid, $sd_devnames,
                                 $attempt, $last );
        sleep(MULTIPATH_STAGE_SLEEP);    # after the final round this is
                                         # the settle window for its async
                                         # escalations - see below
    }

    # The final round fired trigger/reconfigure-class escalations whose
    # effect lands asynchronously - look once more after the settle sleep
    # instead of dying on their heels; same acceptance predicate, never a
    # bare -b.
    return $mpath
        if -b $mpath && _multipath_map_has_active_path( $ctx, $scsiid );

    die "Unable to stage multipath device for scsiid ${scsiid} "
      . "after ${attempts} attempts\n";
}

# One staging round - no loops, no sleeps (the caller owns both), NO
# acceptance: the driver's loop-top predicate is the only judge of success
# (an entry -b return here would re-trust the very zombie map the driver's
# fast path had just rejected, before any repair command ran). The -b
# short-circuits below only stop further escalation inside the round; the
# returned path is advisory. The modulo escalation schedule is preserved
# from the previous 60-round loop MINUS its %15 del-map recovery - the
# reactivation cycle's teardown supersedes it - and the round count shrank
# instead (MULTIPATH_STAGE_ATTEMPTS): the cycle now supplies the deep
# retries a broken stack actually needs. On the final round of a real
# ladder ($last) every escalation fires regardless of its modulo gate.
# NOTE a deliberate consequence of the -b short-circuits: when the node
# PRE-EXISTS (a rejected zombie), every round returns right after
# add path / -a / add map - the escalations never fire. By design: the
# escalation ladder exists to MATERIALIZE a missing node; attaching paths
# to an existing map is exactly the add path / add map pair, and a daemon
# too wedged for those fails the attempt into the cycle's teardown, which
# removes the node - re-opening the full ladder for the next cycle's
# rebuild.
sub _volume_stage_multipath {
    my ( $ctx, $scsiid, $sd_devnames, $attempt, $last ) = @_;

    my $mpath = clean_word( block_device_path_from_serial( $scsiid, 1 ) );

    # Register the resolved sd paths with multipathd FIRST - under load
    # udev events lag and map creation fails unless the daemon is told its
    # paths explicitly.
    multipath_cmd( $ctx, [ $MULTIPATHD, 'add', 'path', $_ ],
                   MULTIPATH_CMD_TIMEOUT_MAX ) for @$sd_devnames;

    # Re-assert the whitelist (the driver did it once before its VPD wait).
    multipath_cmd( $ctx, [ $MULTIPATH, '-a', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT );
    multipath_cmd( $ctx, [ $MULTIPATHD, 'add', 'map', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT_MAX );
    return $mpath if -b $mpath;

    # Escalations, cheapest first:
    if ( $last || $attempt == 1 || $attempt % 5 == 0 ) {   # heavier per-WWID scan
        multipath_cmd( $ctx, [ $MULTIPATH, $scsiid ], MULTIPATH_CMD_TIMEOUT_MAX );
        return $mpath if -b $mpath;
    }

    if ( $last || $attempt % 4 == 0 ) {              # udev event replay
        if (@$sd_devnames) {                         # targeted - never broad
            multipath_cmd( $ctx, [ 'udevadm', 'trigger', "/sys/block/$_" ],
                           MULTIPATH_CMD_TIMEOUT_MAX ) for @$sd_devnames;
        } else {
            multipath_cmd( $ctx, [ 'udevadm', 'trigger',
                                   '--subsystem-match=block',
                                   "--property-match=ID_SERIAL=${scsiid}" ],
                           MULTIPATH_CMD_TIMEOUT );
        }
        return $mpath if -b $mpath;
    }

    if ( $last || $attempt % 10 == 0 ) {             # daemon-wide re-read
        multipath_cmd( $ctx, [ $MULTIPATHD, 'reconfigure' ],
                       MULTIPATH_CMD_TIMEOUT_MAX );
        return $mpath if -b $mpath;
    }

    return -b $mpath ? $mpath : undef;
}

# The staging exit contract's acceptance probe: ONE locked
# `multipath -ll <wwid>` read; true when at least one PATH row reports the
# dm state `active` - a path the kernel will route IO to. Path-GROUP rows
# (`status=active`) are ignored: a group can be the serving group while
# every path inside it has failed. Command failure, timeout or empty
# output all return 0 - no evidence reads as "no active path", failing
# toward the rebuild rounds and, ultimately, the reactivation cycle's
# teardown (never toward trusting a zombie map). A fresh map whose paths
# the checker has not visited yet can legitimately return 0 for a round or
# two - the staging driver probes at its loop top, after each inter-round
# sleep, precisely to absorb that window. PARSE IS LOAD-BEARING: a false
# "no active path" fails activation through every cycle - if `-ll`
# scraping proves fragile across multipath-tools versions, the fallback
# evidence is `dmsetup status <name>` A-flag counting
# (get_device_mapper_name supplies the name).
sub _multipath_map_has_active_path {
    my ( $ctx, $scsiid ) = @_;

    my $cmd    = [ $MULTIPATH, '-ll', $scsiid ];
    my $active = 0;
    my $lines  = 0;
    my $res    = multipath_cmd( $ctx, $cmd, MULTIPATH_CMD_TIMEOUT, sub {
        my ($line) = @_;
        $lines++;
        cmd_log_output( $ctx, 'debug', $cmd, $line );
        # PATH rows carry an H:C:T:L tuple then devnode and major:minor
        # ("7:0:0:0 sdb 8:16 active ready running"); require the dm state
        # column to say `active`, and disqualify a row whose checker
        # already says `faulty` (checker verdicts lag dm state).
        $active = 1
            if $line =~ /\b\d+:\d+:\d+:\d+\s+\S+\s+\d+:\d+\s+active\b/
            && $line !~ /\bfaulty\b/;
    } );

    # Always leave a trace: an empty -ll logs no output lines at all, which
    # would make a failing probe invisible in the debug log without this.
    debugmsg( $ctx, 'debug',
        "Map active-path probe for ${scsiid}: exitcode "
      . ( $res->{exitcode} // 'undef' )
      . ", lines ${lines}, active ${active}" );

    return 1 if $active
        && defined( $res->{exitcode} ) && $res->{exitcode} == 0;

    # Fallback evidence - dmsetup status A-flag counting: `multipath -ll`
    # has been OBSERVED returning exit 0 with EMPTY output for a live,
    # seconds-old map (PVE 9.1, 2026-07-03: 40 consecutive empty reads
    # during one activation while the map stayed assembled and healthy).
    # Silence is not evidence of death when the dm node exists - ask
    # device-mapper directly. A multipath status line carries one A
    # (active) or F (failed) flag per path after each major:minor:
    # "0 8192 multipath 2 0 0 0 1 1 A 0 2 0 8:208 A 0 65:0 A 0".
    if ( $lines == 0 && -b block_device_path_from_serial( $scsiid, 1 ) ) {
        my $dmactive = 0;
        my $dcmd = [ $DMSETUP, 'status', $scsiid ];
        my $dres = multipath_cmd( $ctx, $dcmd, MULTIPATH_CMD_TIMEOUT, sub {
            my ($line) = @_;
            cmd_log_output( $ctx, 'debug', $dcmd, $line );
            $dmactive = 1
                if $line =~ /\bmultipath\b/
                && $line =~ /\d+:\d+\s+A\b/;
        } );
        debugmsg( $ctx, 'debug',
            "Map active-path dmsetup fallback for ${scsiid}: exitcode "
          . ( $dres->{exitcode} // 'undef' ) . ", active ${dmactive}" );
        return 1 if $dmactive
            && defined( $dres->{exitcode} ) && $dres->{exitcode} == 0;
    }

    return 0;
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
        multipath_cmd( $ctx, $cmd, MULTIPATH_CMD_TIMEOUT, sub {
            my $line = shift;
            chomp $line;
            cmd_log_output( $ctx, 'debug', $cmd, $line );
            if ( $line =~ /\b$wwid\b/ ) {
                my @parts = split( /\s+/, $line );
                $device_mapper_name = $parts[0];
            }
        } );
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
            ], 118, 5);
    } elsif (defined($volname) && defined($snapname)) {
        $jscsiid = joviandss_cmd(
            $ctx,
            [
                "pool",   $pool,
                "volume", $volname,
                "snapshot", $snapname,
                "get", "-i"
            ], 118, 5 );
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
    my ( $ctx, $scsiid, $attempts_wait_unused, $attempts_remove_device ) = @_;

    # No writes or sync before unmounting, and no unmounting of the volume -
    # unexpected writes during an active migration are a data-corruption
    # hazard.

    $scsiid = safe_word( clean_word($scsiid), 'multipath scsi id' );
    $attempts_wait_unused   //= MULTIPATH_UNSTAGE_WAIT_UNUSED_ATTEMPTS;
    $attempts_remove_device //= MULTIPATH_UNSTAGE_REMOVE_ATTEMPTS;

    debugmsg( $ctx, 'debug', "Volume unstage multipath scsiid ${scsiid}" );

    # Phase 1 - wait for the device to fall unused (Proxmox may deactivate
    # before qemu is gone; racing that is the corruption hazard above). One
    # tick per call - the loop and the sleep live here, mirroring the
    # staging split; no post-loop recheck is needed (we proceed either
    # way), so the sleep is skipped on the last tick.
    my $device_ready = 0;
    for my $tick ( 1 .. $attempts_wait_unused ) {
        $device_ready =
            _volume_unstage_multipath_wait_unused( $ctx, $scsiid, $tick );
        last if $device_ready;
        sleep(MULTIPATH_UNSTAGE_WAIT_UNUSED_SLEEP)
            if $tick < $attempts_wait_unused;
    }
    debugmsg( $ctx, 'warn',
        "Device ${scsiid} may still be in use, proceeding with cleanup" )
        unless $device_ready;

    # Phase 2 - removal rounds. One round per call; the round's own tail
    # (blocker grace) is the inter-round pacing, so no sleep here.
    my $removed = 0;
    for my $round ( 1 .. $attempts_remove_device ) {
        $removed = _volume_unstage_multipath_remove_device( $ctx, $scsiid,
                                                            $round );
        last if $removed;
    }

    # Final fallback - AFTER the rounds, never inside one: deferred removal
    # marks the device to disappear when its last opener closes it. A
    # device that vanished on its own between the last round and this probe
    # counts as removed (the previous code read that as failure).
    if ( !$removed ) {
        if ( _dmsetup_device_exists( $ctx, $scsiid ) ) {
            debugmsg( $ctx, 'info',
                "Using deferred dmsetup removal for ${scsiid}" );
            my $res = multipath_cmd( $ctx,
                [ $DMSETUP, 'remove', '--deferred', $scsiid ],
                MULTIPATH_CMD_TIMEOUT_MAX );
            die "Failed to remove multipath device for SCSI ID ${scsiid}: "
              . "${attempts_remove_device} rounds exhausted and deferred "
              . "removal failed\n"
                if !defined( $res->{exitcode} ) || $res->{exitcode} != 0;
        }
        # else: gone on its own - success
    }

    return;
}

# ONE wait-unused tick - returns 1 when the mapper device is free or gone
# (stop waiting, removal may proceed), 0 while a process still holds it
# (wait another tick). No outer catch-all eval: a `multipath` lock failure
# inside get_device_mapper_name propagates by design - in the reactivation
# teardown the per-step best-effort wrapper warns and moves on (fatal lock
# errors rethrow through it); in a standalone deactivation it fails the
# operation loud.
sub _volume_unstage_multipath_wait_unused {
    my ( $ctx, $scsiid, $tick ) = @_;

    my $mapper_name = get_device_mapper_name( $ctx, $scsiid );   # locked probe
    return 1 if !defined $mapper_name;        # no map - nothing to wait on

    if ( $mapper_name !~ /^([\:\-\@\w.\/]+)$/ ) {
        debugmsg( $ctx, 'debug',
            "Multipath device mapper name is incorrect: ${mapper_name}" );
        return 1;                             # unusable name - proceed
    }
    my $mapper_path = "/dev/mapper/$1";       # mapper-NAME path - the one
                                              # place the serial helper
                                              # cannot build
    return 1 if !-b $mapper_path;             # node gone - nothing to wait
                                              # on (the previous loop kept
                                              # waiting here)

    # lsof/ps are read-only process queries - deliberately NOT under the
    # lock. lsof -t exits non-zero when NOBODY holds the device - the
    # success case - so noerr is required; an empty pid list means "free".
    my $pid;
    my $cmd = [ 'lsof', '-t', $mapper_path ];
    eval {
        run_command( $cmd,
            outfunc => sub { $pid = clean_word(shift); },  # last line wins -
                                                           # diagnostics only
            errfunc => sub { cmd_log_output( $ctx, 'error', $cmd, shift ) },
            noerr   => 1,
        );
    };
    if ($@) {
        debugmsg( $ctx, 'warn',
            "Unable to identify mapper user for ${mapper_path}: $@" );
        return 1;                             # cannot tell - proceed
    }
    return 1 if !$pid;                        # free

    # Still held - name the blocker for diagnostics, gated so a long wait
    # does not emit one warning per tick.
    if ( ( $tick == 1 || $tick % 10 == 0 ) && $pid =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $blocker_name;
        my $pscmd = [ 'ps', '-o', 'comm=', '-p', $1 ];
        eval {
            run_command( $pscmd,
                outfunc => sub { $blocker_name = clean_word(shift); },
                errfunc => sub { cmd_log_output( $ctx, 'error', $pscmd, shift ) },
                noerr   => 1,
            );
        };
        $blocker_name //= 'unknown';
        my $warningmsg = "Multipath device with scsi id ${scsiid} "
                       . "is used by ${blocker_name} with pid ${pid}";
        debugmsg( $ctx, 'warn', $warningmsg );
        warn "${warningmsg}\n";
    }

    return 0;                                 # still in use - wait another tick
}

# ONE removal round - returns 1 when map and dm device are gone, 0 when
# something still holds them (the caller retries; the deferred fallback
# runs in the caller AFTER the rounds). $scsiid arrives sanitized by the
# caller. The round tail's blocker grace doubles as the inter-round
# pacing - the caller's loop adds no sleep.
sub _volume_unstage_multipath_remove_device {
    my ( $ctx, $scsiid, $round ) = @_;

    debugmsg( $ctx, 'debug',
        "Multipath removal round ${round} for SCSI ID ${scsiid}" );

    # Step 1 - un-whitelist the WWID.
    multipath_cmd( $ctx, [ $MULTIPATH, '-w', $scsiid ] );

    # Step 2 - drop the map: daemon first, then flush (-f, never a bare
    # rescan, which would recreate the device), then daemon again if the
    # map survived. Order preserved from the previous code.
    multipath_cmd( $ctx, [ $MULTIPATHD, 'del', 'map', $scsiid ],
                   MULTIPATHD_CMD_TIMEOUT_FAST ) if $MULTIPATHD;
    multipath_cmd( $ctx, [ $MULTIPATH, '-f', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT_MAX );
    multipath_cmd( $ctx, [ $MULTIPATHD, 'del', 'map', $scsiid ],
                   MULTIPATHD_CMD_TIMEOUT_FAST )
        if $MULTIPATHD && _multipathd_map_exists( $ctx, $scsiid );

    # Step 3 - the flush can leave an orphaned dm device; probe with
    # dmsetup (multipath -ll only sees the multipath map) and remove it
    # directly.
    return 1 if !_dmsetup_device_exists( $ctx, $scsiid );

    multipath_cmd( $ctx, [ $DMSETUP, 'remove', '-f', $scsiid ],
                   MULTIPATH_CMD_TIMEOUT_MAX );

    sleep(MULTIPATH_UNSTAGE_REMOVE_SETTLE);       # let the removal land
    return 1 if !_dmsetup_device_exists( $ctx, $scsiid );

    # Still held - bounded grace for the blocker before the next round.
    my $mapper_name = get_device_mapper_name( $ctx, $scsiid ) // $scsiid;
    my $blocker_pid =
        _volume_unstage_multipath_get_blocker( $ctx, $scsiid, $mapper_name );
    if ($blocker_pid) {
        debugmsg( $ctx, 'debug',
            "Waiting for blocker pid ${blocker_pid} (round ${round})" );
        for ( 1 .. MULTIPATH_UNSTAGE_BLOCKER_WAIT ) {    # 1 s ticks
            last unless -d "/proc/${blocker_pid}";
            sleep(1);
        }
    } else {
        sleep(MULTIPATH_UNSTAGE_REMOVE_SLEEP);
    }

    debugmsg( $ctx, 'debug',
        "Multipath mapping for ${scsiid} still present after round ${round}" );
    return 0;
}

# Check if a device-mapper device exists by SCSI ID / dm name.
# Uses dmsetup info directly instead of multipath -ll, because
# multipath -f can remove the multipath map while leaving the
# underlying dm device behind as an orphan.
sub _dmsetup_device_exists {
    my ( $ctx, $name ) = @_;

    my $exists = 0;
    my $cmd = [ $DMSETUP, "info", $name ];
    multipath_cmd( $ctx, $cmd, MULTIPATH_CMD_TIMEOUT, sub {
        my $line = shift;
        $exists = 1 if $line =~ /State:\s+ACTIVE/;
        cmd_log_output( $ctx, 'debug', $cmd, $line );
    } );
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

sub _multipathd_map_exists {
    my ( $ctx, $wwid ) = @_;

    my $found = 0;
    my $cmd = [ $MULTIPATH, '-ll', $wwid ];
    multipath_cmd( $ctx, $cmd, MULTIPATH_CMD_TIMEOUT, sub {
        my $line = shift;
        $found = 1 if $line =~ /\Q$wwid\E/;
        cmd_log_output( $ctx, 'debug', $cmd, $line );
    } );
    return $found;
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

    $tgname = safe_word($tgname);
    # Volume deletion will result in deletetion of all its snapshots
    # Therefore we have to detach all volume snapshots that is expected to be
    # removed along side with volume
    unless ( defined($snapname) ) {

        joviandss_cmd(
            $ctx,
            [
                'pool', $pool,
                'targets', 'delete',
                '--target-prefix', $prefix,
                '--target-group-name', $tgname,
                '-v', $volname
            ],
            118, 4
        );
    }

    if ( defined( $snapname ) ) {

        $pool = safe_word($pool);
        $prefix = safe_word($prefix);
        $tgname = safe_word($tgname);
        $volname = safe_word($volname);
        $snapname = safe_word($snapname);

        debugmsg( $ctx,"debug",
                "Unpublish volume ${volname} "
                . safe_var_print( "snapshot", $snapname )
                . " in check\n");
        joviandss_cmd(
            $ctx,
            [
                'pool', $pool,
                'targets', 'delete',
                '--target-prefix', $prefix,
                '--target-group-name', $tgname,
                '-v', $volname,
                '--snapshot', $snapname,
            ],
            118, 4
        );
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

    eval {
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
    };
    if ($@) {
        debugmsg($ctx, 'warn',
            "lun record search interrupted: $@"
            . " (likely a concurrent deactivation removed a target directory)");
    }

    return \@matches;
}

sub lun_record_local_get_snapshot_list {
    my ($ctx, $volname) = @_;
    my $storeid = $ctx->{storeid};

    # Returns [ targetname, lunid, path, lunrec ] for every locally-recorded
    # snapshot activation of $volname (lunrec->{snapname} is defined).
    # Used by volume_deactivate to clean up snapshot state without calling
    # jdssc to discover which snapshots were activated on this node.

    my @matches = ();

    my $ldir = File::Spec->catdir( PLUGIN_LOCAL_STATE_DIR, $storeid );

    unless ( -d $ldir ) {
        die "Unable to locate folder containing plugin state\n";
    }

    eval {
        File::Find::find(
            {
                no_chdir => 1,
                wanted   => sub {
                    my $full = $File::Find::name;

                    unless ($full =~ m!^\Q$ldir\E/([^/]+)/(\d+)/\Q$volname\E$!) {
                        return;
                    }
                    my ($targetname, $lunid) = ($1, $2);
                    $targetname = clean_word($targetname);
                    $lunid      = clean_word($lunid);

                    my $lunrec = lun_record_local_get_by_path($ctx, $full);
                    return unless $lunrec;
                    return unless $lunrec->{volname} eq $volname;
                    return unless defined($lunrec->{snapname});

                    push @matches, [ $targetname, $lunid, $full, $lunrec ];
                },
            },
            $ldir
        );
    };
    if ($@) {
        debugmsg($ctx, 'warn',
            "snapshot lun record search interrupted: $@"
            . " (likely a concurrent deactivation removed a target directory)");
    }

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

    for my $key (qw(scsiid volname snapname size multipath hosts shared)) {
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
    if ( $ltdir =~ /^([\:\-\@\w.\/]+)$/ ) {
        $ltdir = $1;
    } else {
        die "Invalid character in target dir path: ${ltdir}\n";
    }
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
    if ( $ltldir =~ /^([\:\-\@\w.\/]+)$/ ) {
        $ltldir = $1;
    } else {
        die "Invalid character in lun dir path: ${ltldir}\n";
    }

    my $ltlfile = File::Spec->catfile( $ltldir, $volname );
    if ( $ltlfile =~ /^([\:\-\@\w.\/]+)$/ ) {
        my $file = $1;
        if ( -f $file ) {
            unless ( unlink($file) ) {
                die "Unable to remove lun file ${file} because $!\n";
            }
        }
    } else {
        die "Invalid character in lun file path: ${ltlfile}\n";
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

sub volume_deactivate_by_lun_record {
    my ($ctx, $vmid, $targetname, $lunid, $lunrecord) = @_;

    my $volname  = $lunrecord->{volname};
    my $snapname = $lunrecord->{snapname};

    debugmsg( $ctx, "debug",
            "Deactivate volume ${volname} "
            . safe_var_print( "snapshot", $snapname )
            . " by lun record target ${targetname} lun ${lunid} "
          . "start\n" );

    # Logout iSCSI BEFORE removing multipath.  If we remove multipath
    # first, the `multipath $scsiid` refresh commands in the removal
    # function recreate the device because iSCSI paths are still active.
    # By logging out iSCSI first, the underlying paths disappear and
    # multipath removal succeeds cleanly.
    volume_unstage_iscsi_device ( $ctx, $targetname, $lunid, $lunrecord->{hosts} );


    if ( $lunrecord->{multipath} ) {

        my $unstage_multipath_done = 0;
        for my $attempt ( 1 .. 3) {
            eval {
                volume_unstage_multipath( $ctx, $lunrecord->{scsiid} );
            };
            my $cerr = $@;
            if ($cerr) {
                warn "volume_unstage_multipath failed: $@" if $@;
            } else {
                $unstage_multipath_done = 1;
                last;
            }
        }

        unless ($unstage_multipath_done ) {
            die "Unable to unstage multipath device for "
              . safe_var_print( "volume", $volname )
              . safe_var_print( "snapshot", $snapname )
              . "\n";
        }
    }

    if ( defined($snapname) ) {
        # We do not delete target on joviandss as this will lead to race
        # condition in case of migration
        eval {
            volume_unpublish( $ctx, $vmid, $volname, $snapname, undef );
        };
        warn "unpublish_volume failed: $@" if $@;
    }

    lun_record_local_delete( $ctx, $targetname, $lunid, $volname, $snapname );


    debugmsg( $ctx, "debug",
            "Deactivate volume ${volname} "
            . safe_var_print( "snapshot", $snapname )
            . " by lun record target ${targetname} lun ${lunid} "
          . "done\n" );
    return 1;
}

sub volume_activate {
    my ($ctx,
        $vmid, $volname, $snapname,
        $content_volume_flag ) = @_;

    my $tgname;
    if ( defined($content_volume_flag) && $content_volume_flag != 0 ) {
        $tgname = get_content_target_group_name($ctx);
    } else {
        $tgname = get_vm_target_group_name($ctx, $vmid);
    }

    debugmsg( $ctx, "debug",
            "Activating volume ${volname} "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );

    my $last_err;
    delete $ctx->{_multipath_cmd_ladder_exhausted};   # isolate from earlier
                                                      # operations on this
                                                      # $ctx - ONCE, not per
                                                      # cycle: a signature
                                                      # set inside a
                                                      # teardown or sweep
                                                      # must survive into
                                                      # the next attempt's
                                                      # gate
    for my $cycle ( 1 .. VOLUME_ACTIVATE_CYCLE_ATTEMPTS ) {
        my $state = {};    # reached stages + target coordinates - the
                           # teardown reads it
        my $block_devs = eval {
            _volume_activate_attempt( $ctx, $vmid, $volname, $snapname,
                                      $content_volume_flag, $tgname, $state,
                                      $cycle );
        };
        return $block_devs if !$@ && defined($block_devs);

        $last_err = $@ || "activation produced no block devices\n";
        debugmsg( $ctx, 'warn',
            "Activation cycle ${cycle} of volume ${volname} "
          . safe_var_print( 'snapshot', $snapname )
          . " failed: ${last_err}" );

        # ERROR CLASSIFICATION - before any recovery machinery runs.
        #
        # (1) FATAL: a marked lock-machinery die (hold-cap overrun, hold
        # alarm) means the locks protecting this operation can no longer
        # be trusted; retrying - or even running the teardown, whose steps
        # touch shared state up to and including the target detach - would
        # race whoever may have stale-reclaimed them. Rethrow: die ->
        # unwind -> every held lock released. The stack residue is
        # deliberate - nothing touches shared state without valid locks;
        # the next activation rebuilds or fast-paths over whatever is
        # left.
        die $last_err
            if OpenEJovianDSS::Lock::lock_error_fatal($last_err);

        # (2) CONTENTION: an acquire timeout reports a lock that was NEVER
        # OBTAINED - nothing was modified under it, every held lock is
        # still valid, and nothing says the device stack is broken.
        # Teardown buys nothing: skip the sweep and the teardown, and
        # re-attempt over whatever the attempt left behind
        # (publish/login/staging all fast-path or re-run idempotently).
        # On the pre-final-cycle pass this also skips the recovery detach -
        # deliberate: contention is not the backend wedge the detach
        # exists to reset.
        if ( !OpenEJovianDSS::Lock::lock_error_acquire($last_err) ) {

            # (3) DEVICE/STAGING FAILURE - repair, tear down, rebuild.

            # Stale-cookie sweep BEFORE the teardown - and only while the
            # strand signature is armed: set by this attempt, or re-armed
            # by the previous teardown's/sweep's own hung command (exit
            # 124/137: survived the whole termination ladder; recorded on
            # $ctx by multipath_cmd). If a stranded cookie broke the
            # attempt, the teardown's dm commands would hang on it too.
            # Best-effort - must not mask $last_err - except a fatal lock
            # error, which rethrows.
            if ( delete $ctx->{_multipath_cmd_ladder_exhausted} ) {
                eval { _multipath_cookie_sweep($ctx) };
                if ($@) {
                    die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
                    debugmsg( $ctx, 'warn', "Stale-cookie sweep failed: $@" );
                }
            }

            # Teardown so the next cycle rebuilds the stack from a clean
            # slate. ONE pass: its steps are individually best-effort, so
            # short of a fatal lock error - which rethrows - a pass cannot
            # fail; convergence across step failures is supplied by the
            # CYCLES themselves, whose every later failure runs this
            # teardown again over the residue. The pass BEFORE THE FINAL
            # CYCLE - and only that one - adds the target detach
            # (volume_unpublish): a one-shot recovery for backend state a
            # logout-level teardown cannot reset, gated on session
            # evidence - skipped while JovianDSS shows a foreign initiator
            # on the target.
            eval {
                _volume_deactivate_attempt( $ctx, $vmid, $volname,
                                            $snapname, $tgname, $state,
                                            $cycle );
            };
            if ($@) {
                # Defensive: reachable by a fatal lock error (which must
                # rethrow) or a future unwrapped step.
                die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
                debugmsg( $ctx, 'warn',
                    "Teardown after failed activation cycle ${cycle} "
                  . "failed: $@" );
            }
        }

        # Pre-cycle budget check: starting another cycle with less than a
        # typical cycle's budget left on the method lock's hold deadline
        # only moves the hold-cap die into the middle of the next attempt -
        # fail NOW, with the real error, while this cycle's teardown has
        # already run.
        if ( $cycle < VOLUME_ACTIVATE_CYCLE_ATTEMPTS ) {
            my $remaining =
                OpenEJovianDSS::Lock::lock_deadline_remaining($ctx);
            die $last_err
                if defined($remaining)
                && $remaining < VOLUME_ACTIVATE_CYCLE_MIN_BUDGET;
            sleep(VOLUME_ACTIVATE_CYCLE_SLEEP);
        }
    }

    die "Activation of volume ${volname} "
      . safe_var_print( 'snapshot', $snapname )
      . " failed after " . VOLUME_ACTIVATE_CYCLE_ATTEMPTS
      . " cycles: ${last_err}";
}

# ONE activation attempt - the previous volume_activate eval body. The
# reached-stage flags are set BEFORE each action: if a step dies midway,
# its inverse still runs in the teardown. Returns the block-device list;
# dies on any failure.
sub _volume_activate_attempt {
    # $vmid and $cycle are unused in this body - kept for signature
    # symmetry with _volume_deactivate_attempt, which needs them
    # (volume_unpublish; the detach rung's cycle gate).
    my ( $ctx, $vmid, $volname, $snapname, $content_volume_flag,
         $tgname, $state, $cycle ) = @_;

    my $multipath = get_multipath($ctx);
    my $shared    = get_shared($ctx);

    # Recorded for the teardown: volume_unpublish derives the target group
    # from the flag - without it a content volume would be unpublished
    # against the VM target group.
    $state->{content_volume_flag} = $content_volume_flag;

    # Stage 1 - attach the volume to its target (jdssc).
    $state->{published} = 1;
    my $tinfo = volume_publish( $ctx, $tgname, $volname, $snapname,
                                $content_volume_flag );
    die "Publishing volume ${volname} "
      . safe_var_print( 'snapshot', $snapname )
      . " failed to provide target info\n"
        if !$tinfo;

    # Target coordinates - recorded for the teardown's inverse steps.
    $state->{targetname} = $tinfo->{target};
    $state->{lunid}      = $tinfo->{lunid};
    $state->{hosts}      = $tinfo->{iplist};
    $state->{scsiid}     = $tinfo->{scsiid};

    # Checked BEFORE the login (previously it was checked after - a
    # missing scsi id wasted a full iSCSI stage before failing).
    die "Unable to identify scsi id for ${volname}"
      . safe_var_print( 'snapshot', $snapname ) . "\n"
        if !defined $state->{scsiid};

    # The authoritative (control-plane) size, fetched BEFORE staging so the
    # iSCSI exit contract can verify the exported LUN against it (option A,
    # finding #23). REST volsize is independent of the iSCSI data-plane
    # export, so comparing the two is the backend-export health cross-check.
    my $size = volume_get_size( $ctx, $volname );

    # Stage 2 - iSCSI login + capacity verification; exits only with the
    # device present, udev done, AND reporting the correct non-zero size
    # (a wrong/zero capacity means SCST exported the LUN wrong under load -
    # the backend-export failure the size check exists to catch, now
    # detected at the raw-LUN layer, finding #23).
    $state->{iscsi_staged} = 1;
    my $block_devs = volume_stage_iscsi( $ctx, $state->{targetname},
                                         $state->{lunid}, $state->{hosts},
                                         $state->{scsiid}, $size );
    die "Unable to connect to any storage address\n"
        if !( $block_devs && @$block_devs );

    # Stage 3 - multipath map (when enabled). $verify_map is TRUE on EVERY
    # cycle: a leftover map from an EARLIER failed operation passes a bare
    # -b in cycle 1 just as a torn-down attempt's map does in cycle 2. No
    # size check here - the map's size derives from the sd, which Stage 2
    # already verified (option A: no dm-layer size reconcile, no churn).
    if ($multipath) {
        $state->{multipath_staged} = 1;
        my $mpath = volume_stage_multipath( $ctx, $state->{scsiid},
                                            $block_devs, undef, 1 );
        $block_devs = [ clean_word($mpath) ];
    }

    # Stage 4 - persist the LUN record. Verification is done (Stage 2 for
    # size, Stage 3 for the live map); the strict post-staging verify loop
    # is retired from the activation flow (option A). lun_record_local_create
    # stores the authoritative $size, so the record is correct by
    # construction - no lun_record_update_device recheck needed.
    $state->{record_created} = 1;
    lun_record_local_create( $ctx,
        $state->{targetname}, $state->{lunid}, $volname, $snapname,
        $state->{scsiid}, $size, $multipath, $shared,
        @{ $state->{hosts} } );

    return $block_devs;
}

# The complete inverse of one activation attempt. Each step is best-effort
# (eval + warn) so one failed step never blocks the rest - EXCEPT a fatal
# lock error, which rethrows (lock_error_fatal: a step must not continue
# past evidence that its locks no longer protect it). Reads the
# reached-stage flags and target coordinates from $state; $cycle gates the
# recovery detach.
sub _volume_deactivate_attempt {
    my ( $ctx, $vmid, $volname, $snapname, $tgname, $state, $cycle ) = @_;

    # Best-effort step wrapper with the fatal-error exception.
    my $step = sub {
        my ($code) = @_;
        eval { $code->() };
        if ($@) {
            die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
            debugmsg( $ctx, 'warn', "Deactivation step failed: $@" );
        }
    };

    # 1 - iSCSI logout FIRST, so multipath removal cannot resurrect the
    # device (the multipath refresh commands recreate it while iSCSI paths
    # are still active - same rationale as the normal deactivation path).
    $step->( sub {
        volume_unstage_iscsi_device( $ctx, $state->{targetname},
                                     $state->{lunid}, $state->{hosts} );
    } ) if $state->{iscsi_staged};

    # 2 - multipath unstage (wait-unused ticks + removal rounds, the
    # unstage constants' defaults).
    $step->( sub { volume_unstage_multipath( $ctx, $state->{scsiid} ) } )
        if $state->{multipath_staged} && defined $state->{scsiid};

    # 3 - unpublish. Snapshots keep the previous cleanup in EVERY pass
    # (that is unchanged behavior, not the recovery detach). For volumes,
    # this is the RECOVERY DETACH, behind two gates, neither of them
    # temporal:
    #   (a) CYCLE POSITION: only the teardown BEFORE THE FINAL CYCLE -
    #       counter-keyed and structural.
    #   (b) SESSION EVIDENCE: JovianDSS must show no foreign initiator on
    #       the target; a failed query counts as foreign - no evidence,
    #       no detach.
    if ( defined $snapname ) {
        $step->( sub {
            volume_unpublish( $ctx, $vmid, $volname, $snapname,
                              $state->{content_volume_flag} );
        } ) if $state->{published};
    }
    elsif ( $state->{published}
         && defined $state->{targetname}   # publish may have died before
                                           # returning coordinates -
                                           # nothing to probe or detach
         && $cycle == VOLUME_ACTIVATE_CYCLE_ATTEMPTS - 1 )
    {
        my $foreign = eval {
            _target_foreign_sessions( $ctx, $state->{targetname} );
        };
        if ($@) {
            die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
            debugmsg( $ctx, 'warn',
                "Session query for $state->{targetname} failed - "
              . "skipping recovery detach (no evidence, no detach): $@" );
        }
        elsif (@$foreign) {
            my $warningmsg =
                "Skipping recovery detach of volume ${volname}: target "
              . "$state->{targetname} has foreign session(s) from "
              . join( ',', @$foreign );
            debugmsg( $ctx, 'warn', $warningmsg );
            warn "${warningmsg}\n";
        }
        else {
            $step->( sub {
                volume_unpublish( $ctx, $vmid, $volname, $snapname,
                                  $state->{content_volume_flag} );
            } );
        }
    }

    # 4 - LUN record delete LAST: it checks the target's remaining volumes
    # and performs the residual iSCSI logout when none are left.
    $step->( sub {
        lun_record_local_delete( $ctx, $state->{targetname},
                                 $state->{lunid}, $volname, $snapname );
    } ) if defined $state->{targetname} && defined $state->{lunid};

    return;
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
        my $snap_records = lun_record_local_get_snapshot_list( $ctx, $volname );
        # We conduct full deactivation by lun record
        foreach my $snaprec (@$snap_records) {
            my ($snap_target, $snap_lun, undef, $snap_lunrec) = @$snaprec;
            volume_deactivate_by_lun_record( $ctx, $vmid, $snap_target, $snap_lun, $snap_lunrec );
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
                    ($targetname, $lunid, $lunrecpath, $lr) = @{$rec};

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

    volume_deactivate_by_lun_record( $ctx, $vmid, $targetname, $lunid, $lunrecord );
    debugmsg( $ctx, "debug",
            "Volume ${volname} deactivate done "
          . safe_var_print( "snapshot", $snapname )
          . "\n" );
    1;
}

sub lun_record_update_device {
    my ( $ctx, $targetname, $lunid, $lunrecpath, $lunrec, $expectedsize,
         $strict ) = @_;
    my $storeid = $ctx->{storeid};

    unless(defined($lunrec)) {
        confess "Undefined lun record for updating\n";
    }

    # An expected size of 0 can never verify a device - treat it as "no
    # expected size supplied" (a zero-size device still fails).
    undef $expectedsize if defined($expectedsize) && !$expectedsize;

    my $storage_multipath = get_multipath($ctx);
    # Untaint the scsiid from the on-disk record ONCE at the boundary: the
    # verify loop feeds it directly into command argv (udevadm ID_SERIAL,
    # `multipath -ll`, `dmsetup status`) and the /dev/mapper path, so an
    # unsanitized value from the record file would exec-die under taint.
    my $scsiid = $lunrec->{scsiid};
    $scsiid = safe_word( clean_word($scsiid), 'multipath scsi id' )
        if defined $scsiid;

    my $verified   = 0;
    my $last_state = 'device node absent';

    for my $round ( 1 .. VOLUME_ACTIVATE_VERIFY_ATTEMPTS ) {

        _rescan_target_hosts( $ctx, $targetname, $lunid );

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

        # WWID-scoped udev replay - the previous broad `-t all` trigger
        # disrupted active multipath devices.
        if ( defined($scsiid) ) {
            multipath_cmd( $ctx, [ 'udevadm', 'trigger',
                                   '--subsystem-match=block',
                                   "--property-match=ID_SERIAL=${scsiid}" ],
                           MULTIPATH_CMD_TIMEOUT );
        }

        if ( $storage_multipath && defined($scsiid) ) {

            unless ($lunrec->{multipath}) {
                $lunrec->{multipath} = 1;
                lun_record_local_update( $ctx,
                                         $targetname, $lunid,
                                         $lunrec->{volname}, $lunrec->{snapname},
                                         $lunrec );
            }

            my $mpath = clean_word( block_device_path_from_serial( $scsiid, 1 ) );
            if ( -b $mpath ) {
                $block_device_path = $mpath;
            } else {
                # Re-stage only when the map node is MISSING - one gentle
                # staging round (an attempts bound of 1 suppresses the
                # final-round escalation blast); eval-wrapped: its die is
                # this round's failure, not a lenient-caller abort.
                eval {
                    $block_device_path =
                        volume_stage_multipath( $ctx, $scsiid, undef, 1 );
                };
                if ($@) {
                    die $@ if OpenEJovianDSS::Lock::lock_error_fatal($@);
                    debugmsg( $ctx, 'debug',
                        "Verify round ${round}: multipath re-stage "
                      . "failed: $@" );
                }
            }

            if ( defined($block_device_path) && -b $block_device_path ) {
                multipath_cmd( $ctx, [ $MULTIPATH, '-r', $block_device_path ],
                               MULTIPATH_CMD_TIMEOUT_DEFAULT );
                # Heavy daemon-wide re-read on a sparse schedule only (the
                # previous `multipath reconfigure` was an invalid
                # invocation - a silent no-op).
                multipath_cmd( $ctx, [ $MULTIPATHD, 'reconfigure' ],
                               MULTIPATH_CMD_TIMEOUT_MAX )
                    if $round % 5 == 0;
            }
        }

        sleep(1);    # let the rescans land before judging

        # Full per-round trace of what verification is looking at, so a
        # "map has no active path" / "size 0" failure shows exactly which
        # rounds saw what (the trailing state is only the LAST round's).
        my $mnode = ( $storage_multipath && defined($scsiid) )
                  ? ( -b block_device_path_from_serial( $scsiid, 1 ) ? 1 : 0 )
                  : 'n/a';
        debugmsg( $ctx, 'debug',
            "Verify round ${round}/" . VOLUME_ACTIVATE_VERIFY_ATTEMPTS
          . " for target ${targetname} lun ${lunid}: "
          . "iscsi_path=" . ( defined($block_device_path) ? $block_device_path : 'undef' )
          . " mapper_node=${mnode}" );

        unless ( defined($block_device_path) && -b $block_device_path ) {
            $last_state = 'device node absent';
            sleep(VOLUME_ACTIVATE_VERIFY_SLEEP);
            next;
        }

        # Path evidence for multipath devices: size cannot expose a
        # dead-but-intact map (blockdev --getsize64 answers from the dm
        # table without touching a path).
        if ( $storage_multipath && defined($scsiid)
          && !_multipath_map_has_active_path( $ctx, $scsiid ) ) {
            $last_state = 'map has no active path';
            sleep(VOLUME_ACTIVATE_VERIFY_SLEEP);
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

        # A zero size never verifies - the observed wedged-attachment
        # failure this check exists for.
        if ( !defined($updated_size) || $updated_size == 0 ) {
            $last_state = 'device size 0';
            sleep(VOLUME_ACTIVATE_VERIFY_SLEEP);
            next;
        }

        if ( defined($expectedsize) ) {
            if ( int($updated_size) == int($expectedsize) ) {
                $lunrec->{size} = $expectedsize;
                lun_record_local_update( $ctx,
                                         $targetname, $lunid,
                                         $lunrec->{volname}, $lunrec->{snapname},
                                         $lunrec );
                $verified = 1;
                last;
            }
            $last_state = "device size ${updated_size} does not match "
                        . "expected ${expectedsize}";
            sleep(VOLUME_ACTIVATE_VERIFY_SLEEP);
            next;
        }

        # No expected size supplied - device present with non-zero size
        # suffices.
        $verified = 1;
        last;
    }

    return if $verified;

    my $failmsg = "Device verification for target ${targetname} "
                . "lun ${lunid} failed after "
                . VOLUME_ACTIVATE_VERIFY_ATTEMPTS
                . " rounds: ${last_state}\n";

    # STRICT (the activation flow) dies - the reactivation cycle's
    # teardown and re-login are the repair; LENIENT (default -
    # volume_update_size, the cross-node resize flow) warns and returns: a
    # transient mismatch there is expected while rescans propagate.
    die $failmsg if $strict;
    debugmsg( $ctx, 'warn', $failmsg );
    return;
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
                    my ($targetname, $lunid, $lunrecpath, $lunrecord) = @{$rec};

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
            debugmsg( $ctx, 'warn',
                "Unable to identify active lun record for volume ${volname}, size not updated\n" );
        }
    }
    1;
}

sub volume_get_size {
    my ( $ctx, $volname ) = @_;

    my $pool = get_pool($ctx);

    my $output = joviandss_cmd($ctx, ['pool', $pool, 'volume', $volname, 'get', '-s'], 118, 5);

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

    # A wrong "no tag" answer silently downgrades a force rollback to a
    # blocked one, so a failed tag read must never be mistaken for absence.
    # Transient read failures (e.g. a pvesh hiccup) are retried; only a
    # persistent failure dies. A genuine present/absent answer returns at
    # once -- the loop never spins on a definitive result.
    my $attempts = 5;
    my $last_err;
    for my $attempt ( 1 .. $attempts ) {
        my $is_set = eval { _vm_tag_force_rollback_read( $ctx, $vmid ); };
        return $is_set unless $@;

        $last_err = $@;
        debugmsg( $ctx, 'warn',
            "force_rollback tag read for vmid ${vmid} failed "
          . "(attempt ${attempt}/${attempts}): ${last_err}" );
        sleep(2) if $attempt < $attempts;
    }
    die $last_err;
}

sub _vm_tag_force_rollback_read {
    my ( $ctx, $vmid ) = @_;

    my $virt_type = vmid_identify_virt_type($ctx, $vmid);

    if ( ! defined($virt_type) ) {
        die "Unable to identify virtualisation type of VM/CT ${vmid} "
          . "while checking force_rollback tag\n";
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

    if ( $exitcode != 0 ) {
        die "Unable to read VM/CT ${vmid} config "
          . "while checking force_rollback tag: ${err_out}\n";
    }

    my $conf;
    eval {
        $conf = decode_json($json_out);
    };

    if ( $@ || ref($conf) ne 'HASH' ) {
        die "Unable to parse VM/CT ${vmid} config "
          . "while checking force_rollback tag: $@\n";
    }

    if ( !defined $conf->{tags} ) {
        debugmsg( $ctx, "debug",
            "force_rollback tag for vmid ${vmid}: absent (no tags)" );
        return 0;
    }

    my @tags = split(/[,;]/, $conf->{tags});

    foreach my $tag (@tags) {
        $tag =~ s/^\s+|\s+$//g;
        if ($tag eq 'force_rollback') {
            debugmsg( $ctx, "debug",
                "force_rollback tag for vmid ${vmid}: present "
              . "(tags='$conf->{tags}')" );
            return 1;
        }
    }

    debugmsg( $ctx, "debug",
        "force_rollback tag for vmid ${vmid}: absent "
      . "(tags='$conf->{tags}')" );
    return 0;
}

1;
