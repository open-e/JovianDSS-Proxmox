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
                    . "on hosts @chap_failed after credential refresh — "
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
