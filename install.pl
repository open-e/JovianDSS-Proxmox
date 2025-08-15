#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Temp qw(tempdir);
use File::Basename;

# Always load required modules
use JSON;
use LWP::UserAgent;

# Try to load Term::ReadLine for interactive input with tab completion
BEGIN {
    eval {
        # Try Term::ReadLine::Gnu first for better arrow key support
        require Term::ReadLine::Gnu;
        require Term::ReadLine;
        Term::ReadLine->import();
    };
    if ($@) {
        # Fallback to basic Term::ReadLine
        eval {
            require Term::ReadLine;
            Term::ReadLine->import();
        };
    }
}

# Try to use PVE modules if available
BEGIN {
    eval {
        require PVE::JSONSchema;
        require PVE::Tools;
        require PVE::Cluster;
        require PVE::INotify;
        PVE::JSONSchema->import();
        PVE::Tools->import();
        PVE::Cluster->import();
        PVE::INotify->import();
    };
    # PVE modules are optional - we'll check for them with defined() calls
}

# Configuration
my $REPO = "open-e/JovianDSS-Proxmox";
my $API_BASE = "https://api.github.com/repos/$REPO/releases";
my $APT_INSTALL = "apt-get -y -q --reinstall install";
my $SSH_FLAGS = "-o BatchMode=yes -o StrictHostKeyChecking=accept-new";
my $REMOTE_TMP = "/tmp/joviandss-plugin.deb";

# Global variables
my $tmpdir = tempdir(CLEANUP => 1);
chmod 0755, $tmpdir;
my $deb_path = "";
my $use_sudo = 0;
my $channel = "stable";
my $pinned_tag = "";
my $need_restart = 1;
my $dry_run = 0;
my $install_all_nodes = 0;
my $node_list = "";
my $ssh_user = "root";
my $remove_plugin = 0;
my $interactive = 0;
my $help = 0;

# Variables for install operations
my $tag = "";
my ($deb_url, $sha_url);

# Parse command line options
GetOptions(
    "pre"           => sub { $channel = "pre" },
    "version=s"     => \$pinned_tag,
    "sudo"          => sub { $use_sudo = 1 },
    "no-restart"    => sub { $need_restart = 0 },
    "dry-run"       => \$dry_run,
    "all-nodes"     => \$install_all_nodes,
    "nodes=s"       => \$node_list,
    "user=s"        => \$ssh_user,
    "ssh-flags=s"   => \$SSH_FLAGS,
    "remove"        => \$remove_plugin,
    "interactive|i" => \$interactive,
    "help|h"        => \$help,
) or die "Error parsing options\n";

if ($help) {
    print_usage();
    exit 0;
}

sub check_readline_support {
    my $has_gnu = 0;
    my $has_basic = 0;

    eval {
        require Term::ReadLine::Gnu;
        $has_gnu = 1;
    };

    eval {
        require Term::ReadLine;
        $has_basic = 1;
    };

    if (!$has_basic) {
        warn "Warning: Term::ReadLine not available. Interactive features will be limited.\n";
        warn "For better experience, install: apt-get install libterm-readline-perl-perl\n";
    } elsif (!$has_gnu) {
        warn "Note: For better arrow key support in interactive mode, install: apt-get install libterm-readline-gnu-perl\n";
    }

    return ($has_gnu, $has_basic);
}

# Custom readline function with arrow key support
sub simple_readline {
    my ($prompt, $completion_options) = @_;

    # For piped input, open TTY directly
    if (!-t STDIN) {
        # Try to open /dev/tty for direct terminal access
        if (open(my $tty_in, '<', '/dev/tty') && open(my $tty_out, '>', '/dev/tty')) {
            print $tty_out $prompt;
            $tty_out->flush();

            # Set raw mode on TTY
            system('stty -F /dev/tty raw -echo 2>/dev/null');

            my $input = "";
            my $cursor_pos = 0;

            while (1) {
                my $key;
                my $bytes_read = sysread($tty_in, $key, 1);
                next unless $bytes_read && defined $key;
                my $ord = ord($key);

                if ($ord == 27) {  # ESC sequence
                    my $seq1, my $seq2;
                    sysread($tty_in, $seq1, 1);
                    sysread($tty_in, $seq2, 1);
                    next unless defined $seq1 && defined $seq2;

                    if ($seq1 eq '[') {
                        if ($seq2 eq 'D' && $cursor_pos > 0) {      # Left arrow
                            $cursor_pos--;
                            print $tty_out "\b";
                            $tty_out->flush();
                        } elsif ($seq2 eq 'C' && $cursor_pos < length($input)) { # Right arrow
                            print $tty_out substr($input, $cursor_pos, 1);
                            $cursor_pos++;
                            $tty_out->flush();
                        }
                    }
                } elsif ($ord == 127 || $ord == 8) {  # Backspace
                    if ($cursor_pos > 0) {
                        substr($input, $cursor_pos-1, 1) = '';
                        $cursor_pos--;
                        print $tty_out "\r" . $prompt . $input . " \r" . $prompt . substr($input, 0, $cursor_pos);
                        $tty_out->flush();
                    }
                } elsif ($ord == 13 || $ord == 10) {  # Enter
                    print $tty_out "\n";
                    $tty_out->flush();
                    last;
                } elsif ($ord >= 32 && $ord <= 126) {  # Printable characters
                    substr($input, $cursor_pos, 0) = $key;
                    $cursor_pos++;
                    print $tty_out substr($input, $cursor_pos-1);
                    if ($cursor_pos < length($input)) {
                        my $remaining = length($input) - $cursor_pos;
                        print $tty_out "\b" x $remaining;
                    }
                    $tty_out->flush();
                }
            }

            # Restore TTY mode
            system('stty -F /dev/tty cooked echo 2>/dev/null');
            close($tty_in);
            close($tty_out);
            return $input;
        } else {
            # Fallback to simple input if TTY not available
            print $prompt;
            STDOUT->flush();
            my $input = <STDIN>;
            chomp($input) if defined $input;
            return $input;
        }
    }

    # For normal terminal input, use POSIX approach
    print $prompt;
    STDOUT->flush();

    # Try to set terminal to raw mode for better key handling
    my $old_termios;
    my $raw_mode_enabled = 0;

    eval {
        require POSIX;
        my $termios = POSIX::Termios->new();
        $termios->getattr(0);
        $old_termios = $termios->getlflag();

        # Disable canonical mode and echo for raw input
        $termios->setlflag($old_termios & ~(POSIX::ECHO | POSIX::ICANON));
        $termios->setcc(POSIX::VMIN, 1);
        $termios->setcc(POSIX::VTIME, 0);
        $termios->setattr(0, POSIX::TCSANOW);
        $raw_mode_enabled = 1;
    };

    my $input = "";
    my $cursor_pos = 0;
    my @history = ();
    my $history_pos = -1;

    if ($raw_mode_enabled) {
        # Raw mode - handle each key individually
        while (1) {
            my $key;
            sysread(STDIN, $key, 1);
            my $ord = ord($key);

            if ($ord == 27) {  # ESC sequence (arrow keys)
                my $seq1, my $seq2;
                sysread(STDIN, $seq1, 1);
                sysread(STDIN, $seq2, 1);

                if ($seq1 eq '[') {
                    if ($seq2 eq 'D') {      # Left arrow
                        if ($cursor_pos > 0) {
                            $cursor_pos--;
                            print "\b";  # Move cursor left
                            STDOUT->flush();
                        }
                    } elsif ($seq2 eq 'C') { # Right arrow
                        if ($cursor_pos < length($input)) {
                            print substr($input, $cursor_pos, 1);
                            $cursor_pos++;
                            STDOUT->flush();
                        }
                    }
                }
            } elsif ($ord == 127 || $ord == 8) {  # Backspace/Delete
                if ($cursor_pos > 0) {
                    substr($input, $cursor_pos-1, 1) = '';
                    $cursor_pos--;
                    # Redraw line
                    print "\r" . $prompt . $input . " \r" . $prompt . substr($input, 0, $cursor_pos);
                    STDOUT->flush();
                }
            } elsif ($ord == 13 || $ord == 10) {  # Enter
                print "\n";
                last;
            } elsif ($ord == 9) {   # Tab (completion)
                if ($completion_options && @$completion_options) {
                    my $partial = substr($input, 0, $cursor_pos);
                    my @matches = grep { index($_, $partial) == 0 } @$completion_options;
                    if (@matches == 1) {
                        # Complete the word
                        my $completion = $matches[0];
                        substr($input, 0, $cursor_pos) = $completion;
                        $cursor_pos = length($completion);
                        # Redraw line
                        print "\r" . $prompt . $input;
                        STDOUT->flush();
                    } elsif (@matches > 1) {
                        print "\n";
                        print "  " . join("  ", @matches) . "\n";
                        print $prompt . $input;
                        STDOUT->flush();
                    }
                }
            } elsif ($ord >= 32 && $ord <= 126) {  # Printable characters
                substr($input, $cursor_pos, 0) = $key;
                $cursor_pos++;
                # Redraw from cursor position
                print substr($input, $cursor_pos-1);
                if ($cursor_pos < length($input)) {
                    my $remaining = length($input) - $cursor_pos;
                    print "\b" x $remaining;
                }
                STDOUT->flush();
            }
        }

        # Restore terminal mode
        eval {
            my $termios = POSIX::Termios->new();
            $termios->getattr(0);
            $termios->setlflag($old_termios);
            $termios->setattr(0, POSIX::TCSANOW);
        };
    } else {
        # Fallback to simple line input
        $input = <STDIN>;
        chomp($input) if defined $input;
    }

    return $input;
}

sub print_usage {
    my $prog = basename($0);
    print <<EOF;
JovianDSS Proxmox plugin installer

Usage: $prog [options]

General:
  --pre                      Use latest pre-release (instead of latest stable)
  --version <tag>            Install a specific release tag (e.g. v0.9.9-3)
  --remove                   Remove/uninstall the plugin instead of installing
  --sudo                     Use sudo for commands (default: run without sudo)
  --no-restart               Do not restart pvedaemon after install/remove
  --dry-run                  Show what would be done without doing it
  --interactive, -i          Interactively select nodes to install to
  -h, --help                 Show this help

Cluster:
  --interactive, -i          Interactively select nodes with tab completion
  --all-nodes                Install/remove on all nodes (uses IPs from cluster membership)
  --nodes "n1,n2,..."        Install/remove on specific nodes (use IPs or hostnames)
  --user <name>              SSH user for remote operations (default: root)
  --ssh-flags "<flags>"      Extra SSH flags (default: $SSH_FLAGS)

Examples:
  # Install latest stable on this node only
  $prog

  # Interactive node selection with tab completion
  $prog --interactive

  # Install pre-release on all nodes (automatically uses cluster IPs)
  $prog --pre --all-nodes

  # Install specific tag on two nodes using IP addresses
  $prog --version v0.9.9-3 --nodes "192.168.1.10,192.168.1.11"

  # Install using sudo (when not running as root)
  $prog --sudo

  # Remove plugin from local node only
  $prog --remove

  # Interactive removal from selected nodes
  $prog --remove --interactive

  # Remove plugin from all cluster nodes
  $prog --remove --all-nodes

Note: For --nodes option, use IP addresses unless you have proper DNS records
or /etc/hosts entries configured for the node hostnames.
EOF
}

sub say {
    my $message = shift;
    print "$message\n";
}

sub run_cmd {
    my @args = @_;
    my $capture_output = 0;
    my $output_ref;
    my $outfunc;
    my $errfunc;

    # Check if last argument is a reference for output capture (backward compatibility)
    if (ref($args[-1]) eq 'SCALAR') {
        $output_ref = pop @args;
        $capture_output = 1;
    }
    # Check if last argument is a hash with outfunc/errfunc
    elsif (ref($args[-1]) eq 'HASH') {
        my $opts = pop @args;
        $outfunc = $opts->{outfunc};
        $errfunc = $opts->{errfunc};
    }

    my @cmd = @args;

    if ($dry_run) {
        print "[dry-run] " . join(" ", @cmd) . "\n";
        if ($capture_output) {
            # For sha256sum in dry-run, provide a fake hash
            if ($cmd[0] eq 'sha256sum') {
                $$output_ref = "09a5d9de16e9356342613dfd588fb3f30db181ee01dac845fbd4f65764b4c210  $cmd[1]\n";
            } else {
                $$output_ref = "[dry-run output]";
            }
        }
        return 1;
    }

    # Use PVE::Tools::run_command if available (only for non-output commands)
    if (defined &PVE::Tools::run_command && !$capture_output) {
        eval {
            # Set DEBIAN_FRONTEND for apt operations
            local $ENV{DEBIAN_FRONTEND} = 'noninteractive';
            if (defined $outfunc || defined $errfunc) {
                PVE::Tools::run_command(\@cmd,
                    outfunc => $outfunc || sub { },
                    errfunc => $errfunc || sub { }
                );
            } else {
                PVE::Tools::run_command(\@cmd);
            }
        };
        if ($@) {
            warn "Command failed: " . join(" ", @cmd) . "\nError: $@\n";
            return 0;
        }
        return 1;
    } else {
        # Fallback to system() calls or backticks for output capture
        if ($capture_output) {
            local $ENV{DEBIAN_FRONTEND} = 'noninteractive';
            my $cmd_str = join(" ", map { "'$_'" } @cmd);
            $$output_ref = `$cmd_str`;
            my $ret = $?;
            return $ret == 0;
        } else {
            local $ENV{DEBIAN_FRONTEND} = 'noninteractive';
            my $cmd_str = join(" ", map { "'$_'" } @cmd);
            my $ret = system($cmd_str);
            return $ret == 0;
        }
    }
}

sub need_cmd {
    my $cmd = shift;
    my $optional = shift || 0;

    if (system("command -v '$cmd' >/dev/null 2>&1") != 0) {
        if ($optional) {
            return 0;
        } else {
            die "Error: '$cmd' not found.\n";
        }
    }
    return 1;
}

sub maybe_sudo {
    if ($use_sudo) {
        return "sudo";
    }
    return "";
}

sub remote_sudo_prefix {
    if ($use_sudo) {
        return "sudo ";
    }
    return "";
}

# Check prerequisites
need_cmd("curl");
need_cmd("dpkg");
need_cmd("apt-get");
need_cmd("awk");
need_cmd("sed");
need_cmd("grep");
need_cmd("sha256sum", 1);

if ($install_all_nodes || $node_list) {
    need_cmd("ssh");
    need_cmd("scp");
}

# Detect Proxmox (optional check)
if (!need_cmd("pveversion", 1)) {
    say "Warning: 'pveversion' not found. Proceeding anyway (Debian-based install assumed).";
}

# Get local node info using PVE modules if available
my $local_node_short;
my @local_ips;
my $cluster_name;
if (defined &PVE::INotify::nodename) {
    $local_node_short = PVE::INotify::nodename();
} else {
    # Fallback to hostname command
    $local_node_short = `hostname -s 2>/dev/null` || `hostname 2>/dev/null`;
    chomp $local_node_short;
    $local_node_short =~ s/\..*//;  # Remove domain part
}

# Get cluster name
if (need_cmd("pvecm", 1)) {
    my $status_output = `pvecm status 2>/dev/null`;
    if ($status_output && $status_output =~ /Cluster name:\s*(\S+)/) {
        $cluster_name = $1;
    }
}
$cluster_name = $cluster_name || "proxmox-cluster";

# Get local IP addresses for filtering
my $local_ips_output = `ip addr show 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d'/' -f1`;
if ($local_ips_output) {
    @local_ips = split /\n/, $local_ips_output;
    chomp @local_ips;
    push @local_ips, '127.0.0.1', 'localhost';  # Add standard local addresses
}

# Only resolve and download for install operations
if (!$remove_plugin) {
    # Resolve release
    if ($pinned_tag) {
        say "Fetching release: $pinned_tag";
    } else {
        say "Fetching latest $channel release";
    }

    my $ua = LWP::UserAgent->new(timeout => 30);
    my $url;

    if ($pinned_tag) {
        $url = $API_BASE;
    } else {
        if ($channel eq "stable") {
            $url = "$API_BASE/latest";
        } else {
            $url = $API_BASE;
        }
    }

    my $response = $ua->get($url);
    die "Error: Could not fetch release metadata from GitHub: " . $response->status_line . "\n"
        unless $response->is_success;

    my $rel_json;
    eval {
        # Use PVE::JSONSchema::from_json if available for better error handling
        if (defined &PVE::JSONSchema::from_json) {
            $rel_json = PVE::JSONSchema::from_json($response->content);
        } else {
            $rel_json = decode_json($response->content);
        }
    };
    die "Error: Invalid JSON response from GitHub API\n" if $@;

    # Extract tag and URLs

    if ($pinned_tag) {
        $tag = $pinned_tag;
        # Find the matching release
        my $matching_release;
        if (ref($rel_json) eq 'ARRAY') {
            for my $release (@$rel_json) {
                if ($release->{tag_name} eq $pinned_tag) {
                    $matching_release = $release;
                    last;
                }
            }
        }
        die "Error: Release tag not found: $pinned_tag\n" unless $matching_release;
        $rel_json = $matching_release;
    } else {
        if ($channel eq "pre" && ref($rel_json) eq 'ARRAY') {
            $rel_json = $rel_json->[0];
        }
        $tag = $rel_json->{tag_name};
    }

    # Extract download URLs and checksum
    my $expected_sha256;
    for my $asset (@{$rel_json->{assets}}) {
        my $url = $asset->{browser_download_url};
        if ($url =~ /\.deb$/) {
            $deb_url = $url;

            # Check for sha256 field
            if ($asset->{sha256}) {
                $expected_sha256 = $asset->{sha256};
            }

            # Check for digest field (format: "sha256:hash")
            if ($asset->{digest} && $asset->{digest} =~ /^sha256:([a-f0-9]{64})$/) {
                $expected_sha256 = $1;
            }
        }
        # Still check for separate checksum files as fallback
        if ($url =~ /(sha256sum|sha256\.txt|\.sha256|hashsum|checksums?\.txt|\.checksums?)$/i) {
            $sha_url = $url;
        }
    }

    die "Error: Could not locate a .deb asset in $tag\n" unless $deb_url;

    say "Downloading $tag package...";

    # Download .deb file
    $deb_path = "$tmpdir/plugin.deb";
    my $deb_response = $ua->get($deb_url, ':content_file' => $deb_path);
    die "Error downloading .deb file: " . $deb_response->status_line . "\n"
        unless $deb_response->is_success;

    # Verify checksum if available
    if ($expected_sha256 || $sha_url) {
        if (need_cmd("sha256sum", 1)) {
            say "Verifying package checksum...";
            my $file_sum = "";
            run_cmd("sha256sum", $deb_path, \$file_sum);
            $file_sum =~ /^([a-f0-9]{64})/;
            $file_sum = $1;

            my $ref_sum;

            if ($expected_sha256) {
                # Use SHA256 from GitHub API response
                $ref_sum = $expected_sha256;
            } elsif ($sha_url) {
                # Fallback: download and parse separate checksum file
                my $checksum_file = "$tmpdir/checksums.txt";
                my $sha_response = $ua->get($sha_url, ':content_file' => $checksum_file);

                if ($sha_response->is_success) {
                    my $deb_basename = basename($deb_url);
                    run_cmd("sh", "-c", "grep -E '$deb_basename' '$checksum_file' 2>/dev/null | grep -Eo '^[a-f0-9]{64}' | head -n1", \$ref_sum);
                    chomp $ref_sum if $ref_sum;
                }
            }

            if ($ref_sum) {
                if ($file_sum ne $ref_sum) {
                    say "✗ Checksum verification failed!";
                    say "Expected: $ref_sum";
                    say "Got:      $file_sum";
                    die "Error: Package integrity check failed. Download may be corrupted.\n";
                } else {
                    say "✓ Package verified.";
                }
            } else {
                say "⚠ Checksum verification skipped (no valid checksum found).";
            }
        } else {
            say "⚠ Checksum verification skipped (sha256sum command not available).";
        }
    } else {
        say "⚠ Checksum verification skipped (no checksum available).";
    }

} # End of install-only logic

# Remove plugin locally
sub remove_local {
    # Get local node display name similar to remote nodes
    my $local_display_name;
    if ($local_node_short) {
        # Try to get first non-loopback IP for display
        my $display_ip = "";
        for my $ip (@local_ips) {
            next if $ip eq '127.0.0.1' || $ip eq 'localhost';
            $display_ip = $ip;
            last;
        }
        if ($display_ip && $display_ip ne $local_node_short) {
            $local_display_name = "$local_node_short ($display_ip)";
        } else {
            $local_display_name = $local_node_short;
        }
    } else {
        $local_display_name = "local node";
    }

    say "Removing the plugin from node $local_display_name";
    my $sudo = maybe_sudo();
    my @cmd;
    if ($sudo) {
        @cmd = ($sudo, "apt-get", "-y", "-q", "remove", "open-e-joviandss-proxmox-plugin");
    } else {
        @cmd = ("apt-get", "-y", "-q", "remove", "open-e-joviandss-proxmox-plugin");
    }

    unless (run_cmd(@cmd, { outfunc => sub { } })) {
        die "Error: Local removal failed\n";
    }

    if ($need_restart) {
        my @restart_cmd;
        if ($sudo) {
            @restart_cmd = ($sudo, "systemctl", "restart", "pvedaemon");
        } else {
            @restart_cmd = ("systemctl", "restart", "pvedaemon");
        }
        unless (run_cmd(@restart_cmd, { outfunc => sub { } })) {
            die "Error: Failed to restart pvedaemon locally\n";
        }
    }

    say "✓ Removal completed successfully on node $local_display_name\n";
}

# Install locally
sub install_local {
    # Get local node display name similar to remote nodes
    my $local_display_name;
    if ($local_node_short) {
        # Try to get first non-loopback IP for display
        my $display_ip = "";
        for my $ip (@local_ips) {
            next if $ip eq '127.0.0.1' || $ip eq 'localhost';
            $display_ip = $ip;
            last;
        }
        if ($display_ip && $display_ip ne $local_node_short) {
            $local_display_name = "$local_node_short ($display_ip)";
        } else {
            $local_display_name = $local_node_short;
        }
    } else {
        $local_display_name = "local node";
    }

    say "Installing the plugin on node $local_display_name";
    my $sudo = maybe_sudo();
    my @cmd;
    if ($sudo) {
        @cmd = ($sudo, split(/\s+/, $APT_INSTALL));
    } else {
        @cmd = split(/\s+/, $APT_INSTALL);
    }
    push @cmd, $deb_path;

    unless (run_cmd(@cmd, { outfunc => sub { } })) {
        die "Error: Local installation failed\n";
    }

    if ($need_restart) {
        my @restart_cmd;
        if ($sudo) {
            @restart_cmd = ($sudo, "systemctl", "restart", "pvedaemon");
        } else {
            @restart_cmd = ("systemctl", "restart", "pvedaemon");
        }
        unless (run_cmd(@restart_cmd, { outfunc => sub { } })) {
            die "Error: Failed to restart pvedaemon locally\n";
        }
    }

    say "✓ Installation completed successfully on node $local_display_name ($tag)\n";
}

# Discover cluster nodes with their IP addresses
sub is_local_node {
    my $node = shift;

    # Check if it's the local hostname
    return 1 if ($local_node_short && $node eq $local_node_short);

    # Check against local IP addresses
    return 1 if (grep { $_ eq $node } @local_ips);

    return 0;
}

sub discover_all_nodes_with_info {
    my @node_info;  # Array of {name => 'hostname', ip => 'ip'} hashes

    # Try .members file first to get both hostname and IP
    if (-r "/etc/pve/.members") {
        open my $fh, '<', "/etc/pve/.members" or return ();
        my $content = do { local $/; <$fh> };
        close $fh;

        eval {
            my $data;
            if (defined &PVE::JSONSchema::from_json) {
                $data = PVE::JSONSchema::from_json($content);
            } else {
                $data = decode_json($content);
            }
            if ($data->{nodelist}) {
                for my $node_name (keys %{$data->{nodelist}}) {
                    my $node_data = $data->{nodelist}->{$node_name};
                    push @node_info, {
                        name => $node_name,
                        ip => $node_data->{ip} || $node_name
                    };
                }
            }
        };
        return @node_info if @node_info;
    }

    # Use PVE::Cluster if available (fallback)
    if (defined &PVE::Cluster::get_members) {
        eval {
            my $members = PVE::Cluster::get_members();
            if ($members && ref($members) eq 'HASH') {
                for my $node_name (keys %$members) {
                    push @node_info, {
                        name => $node_name,
                        ip => $node_name  # No separate IP available
                    };
                }
            }
        };
        return @node_info if @node_info;
    }

    # Fallback to pvecm
    if (need_cmd("pvecm", 1)) {
        my $output = `pvecm nodes 2>/dev/null`;
        for my $line (split /\n/, $output) {
            if ($line =~ /^\s*\d+\s+\d+\s+(\S+)/) {
                my $name = $1;
                $name =~ s/\s*\(local\)\s*$//;
                $name =~ s/^\s+|\s+$//g;
                if ($name) {
                    push @node_info, {
                        name => $name,
                        ip => $name
                    };
                }
            }
        }
    }

    return @node_info;
}

sub discover_remote_nodes {
    my @all_node_info = discover_all_nodes_with_info();
    my @remote_nodes;

    for my $node (@all_node_info) {
        unless (is_local_node($node->{name}) || is_local_node($node->{ip})) {
            push @remote_nodes, $node->{ip};  # Return IP for compatibility
        }
    }

    return @remote_nodes;
}

sub interactive_node_selection {
    my @all_nodes = discover_all_nodes_with_info();

    unless (@all_nodes) {
        say "No cluster nodes found for interactive selection.";
        return ();
    }

    # Separate local and remote nodes for display
    my @local_nodes;
    my @remote_nodes;

    for my $node (@all_nodes) {
        if (is_local_node($node->{name}) || is_local_node($node->{ip})) {
            push @local_nodes, $node;
        } else {
            push @remote_nodes, $node;
        }
    }

    say "Available cluster nodes:";
    say "";

    # Show local node(s)
    if (@local_nodes) {
        say "Local node(s):";
        for my $node (@local_nodes) {
            my $display = $node->{name} eq $node->{ip} ? $node->{name} : "$node->{name} ($node->{ip})";
            say "  $display [LOCAL]";
        }
        say "";
    }

    # Show remote nodes
    if (@remote_nodes) {
        say "Remote node(s):";
        for my $node (@remote_nodes) {
            my $display = $node->{name} eq $node->{ip} ? $node->{name} : "$node->{name} ($node->{ip})";
            say "  $display";
        }
        say "";
    }

    # Prepare completion options (both hostnames and IPs)
    my @completion_options;
    for my $node (@all_nodes) {
        push @completion_options, $node->{name};
        push @completion_options, $node->{ip} unless $node->{name} eq $node->{ip};
    }

    # Set up readline with tab completion if available
    my $term;
    if (defined &Term::ReadLine::new) {
        $term = Term::ReadLine->new('node-selection');

        # Set up completion function
        if ($term->can('Attribs')) {
            my $attribs = $term->Attribs;
            if ($attribs) {
                my @cached_matches;
                my $last_text = '';
                $attribs->{completion_entry_function} = sub {
                    my ($text, $state) = @_;
                    if ($state == 0 || $text ne $last_text) {
                        @cached_matches = grep { index($_, $text) == 0 } @completion_options;
                        $last_text = $text;
                    }
                    return $state < @cached_matches ? $cached_matches[$state] : undef;
                };
            }
        }
    }

    say "Enter node names or IPs to install to (space or comma separated):";
    say "Press Enter when done.";
    print "> ";

    my $input;
    if ($term) {
        $input = $term->readline("");
    } else {
        $input = <STDIN>;
        chomp($input) if defined $input;
    }

    return () unless defined $input && $input =~ /\S/;


    # Parse input (space or comma separated)
    my @selected = split /[\s,]+/, $input;
    @selected = grep { $_ && $_ !~ /^\s*$/ } @selected;

    # Convert hostnames to IPs and validate
    my @target_ips;
    my %node_lookup;

    # Build lookup table
    for my $node (@all_nodes) {
        $node_lookup{$node->{name}} = $node->{ip};
        $node_lookup{$node->{ip}} = $node->{ip};
    }

    for my $selection (@selected) {
        if (exists $node_lookup{$selection}) {
            my $ip = $node_lookup{$selection};
            unless (is_local_node($selection)) {
                push @target_ips, $ip unless grep { $_ eq $ip } @target_ips;  # Avoid duplicates
            } else {
                say "Skipping local node: $selection";
            }
        } else {
            warn "Warning: Unknown node '$selection' - skipping\n";
        }
    }

    return @target_ips;
}

sub get_node_display_name {
    my $ip = shift;

    # Try to get hostname from discovered nodes
    my @all_nodes = discover_all_nodes_with_info();
    for my $node (@all_nodes) {
        if ($node->{ip} eq $ip) {
            return $node->{name} eq $ip ? $ip : "$node->{name} ($ip)";
        }
    }

    # Fallback to just IP
    return $ip;
}

sub interactive_full_selection {
    # Note: TTY handling removed - using custom readline with raw terminal mode instead

    my @all_nodes = discover_all_nodes_with_info();

    unless (@all_nodes) {
        say "No cluster nodes found for interactive selection.";
        return ();
    }

    # Build a lookup for getting node names from IPs
    my %ip_to_name;
    for my $node (@all_nodes) {
        $ip_to_name{$node->{ip}} = $node->{name};
    }

    say "Available cluster nodes:";
    say "";

    # Sort nodes alphabetically by name
    @all_nodes = sort { $a->{name} cmp $b->{name} } @all_nodes;

    # Show all nodes with numbers for easy selection
    my $i = 1;
    for my $node (@all_nodes) {
        my $is_local = is_local_node($node->{name}) || is_local_node($node->{ip});
        my $display = $node->{name} eq $node->{ip} ? $node->{name} : "$node->{name} ($node->{ip})";
        my $local_tag = $is_local ? " [LOCAL]" : "";
        say sprintf("  %2d. %s%s", $i++, $display, $local_tag);
    }
    say "";

    # Prepare completion options (both hostnames and IPs)
    my @completion_options;
    for my $node (@all_nodes) {
        push @completion_options, $node->{name};
        push @completion_options, $node->{ip} unless $node->{name} eq $node->{ip};
    }

    # Set up readline with tab completion if available
    my $term;
    if (defined &Term::ReadLine::new) {
        $term = Term::ReadLine->new('node-selection');

        # Enable better readline features if available
        eval {
            if ($term->can('Attribs')) {
                my $attribs = $term->Attribs;
                if ($attribs) {
                    # Enable history and better editing
                    $attribs->{completion_append_character} = ' ';
                    $attribs->{completion_suppress_append} = 0;

                    # Set up tab completion
                    if (exists $attribs->{completion_entry_function}) {
                        my @cached_matches;
                        my $last_text = '';
                        $attribs->{completion_entry_function} = sub {
                            my ($text, $state) = @_;
                            if ($state == 0 || $text ne $last_text) {
                                @cached_matches = grep { index($_, $text) == 0 } @completion_options;
                                $last_text = $text;
                            }
                            return $state < @cached_matches ? $cached_matches[$state] : undef;
                        };
                    }
                }
            }
        };

        # Try to enable GNU readline specific features for better arrow key support
        eval {
            if ($term->ReadLine eq 'Term::ReadLine::Gnu') {
                # Enable vi or emacs editing mode
                $term->parse_and_bind('set editing-mode emacs');
                $term->parse_and_bind('set enable-keypad on');
            }
        };
    }

    # Show available options for easy reference
    say "Available options for quick reference:";
    my @hostnames = grep { $_ !~ /^\d+\.\d+\.\d+\.\d+$/ } @completion_options;
    my @ips = grep { /^\d+\.\d+\.\d+\.\d+$/ } @completion_options;
    say "  Hostnames: " . join(", ", @hostnames) if @hostnames;
    say "  IPs: " . join(", ", @ips) if @ips;
    say "";

    # Input loop with validation
    while (1) {
        say "Enter node names, IPs, or numbers (space or comma separated):";
        say "Examples: 'node2 node3', '2 3', or mix: 'node2 172.28.143.16'";

        my $input;
        if ($term && $term->ReadLine eq 'Term::ReadLine::Gnu') {
            # Use full readline if GNU version is available
            $input = $term->readline("> ");
        } else {
            # Use our custom readline with arrow key support
            $input = simple_readline("> ", \@completion_options);
        }

        # Handle empty input or exit
        unless (defined $input && $input =~ /\S/) {
            return ();
        }


        # Parse input (space or comma separated, including numbers)
        my @selected = split /[\s,]+/, $input;
        @selected = grep { $_ && $_ !~ /^\s*$/ } @selected;

        # Convert input to IPs and validate
        my @target_ips;
        my @invalid_nodes;
        my %node_lookup;

        # Build lookup table
        for my $i (0..$#all_nodes) {
            my $node = $all_nodes[$i];
            my $num = $i + 1;
            $node_lookup{$num} = $node->{ip};           # Number -> IP
            $node_lookup{$node->{name}} = $node->{ip}; # Name -> IP
            $node_lookup{$node->{ip}} = $node->{ip};   # IP -> IP
        }

        # Validate all selections first
        for my $selection (@selected) {
            if (exists $node_lookup{$selection}) {
                my $ip = $node_lookup{$selection};
                push @target_ips, $ip unless grep { $_ eq $ip } @target_ips;  # Avoid duplicates
            } else {
                push @invalid_nodes, $selection;
            }
        }

        # If there are invalid nodes, show error and ask again
        if (@invalid_nodes) {
            say "";
            say "⚠ Error: The following nodes are not recognized:";
            for my $invalid (@invalid_nodes) {
                say "  '$invalid'";
            }
            say "";
            say "Valid options are:";
            say "  Numbers: 1-" . scalar(@all_nodes);
            say "  Hostnames: " . join(", ", map { $_->{name} } @all_nodes);
            say "  IPs: " . join(", ", map { $_->{ip} } @all_nodes);
            say "";
            say "Please try again.";
            say "";
            next;  # Ask for input again
        }

        # All selections are valid - show confirmation
        if (@target_ips) {
            say "";
            my $operation = $remove_plugin ? "removed from" : "installed on";
            say "Plugin will be $operation the following nodes:";

            for my $ip (@target_ips) {
                my $display_name = get_node_display_name($ip);
                say "  $display_name";
            }

            say "";
            my $confirm;
            if ($term && $term->ReadLine eq 'Term::ReadLine::Gnu') {
                # Use full readline if GNU version is available
                $confirm = $term->readline("Continue? (y/n): ");
            } else {
                # Use our custom readline with arrow key support
                $confirm = simple_readline("Continue? (y/n): ");
            }

            if ($confirm && $confirm =~ /^y$/i) {
                return @target_ips;
            } else {
                say "Operation cancelled.";
                return ();  # Exit instead of asking again
            }
        }

        # Empty selection
        return @target_ips;
    }
}

sub parse_node_list {
    my $raw = shift;
    my @nodes = split /[,\s]+/, $raw;
    @nodes = grep { $_ && $_ !~ /^\s*$/ } @nodes;
    return @nodes;
}

sub remove_remote_node {
    my $node = shift;
    my $ssh_tgt = "$ssh_user\@$node";
    my $r_sudo = remote_sudo_prefix();

    my $display_name = get_node_display_name($node);
    say "Removing the plugin from node $display_name";

    # Remove package
    unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}DEBIAN_FRONTEND=noninteractive apt-get -y -q remove open-e-joviandss-proxmox-plugin", { outfunc => sub { } })) {
        warn "[$node] ✗ Failed to remove package\n";
        return 0;
    }

    # Restart pvedaemon
    if ($need_restart) {
        unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon", { outfunc => sub { } })) {
            warn "[$node] ✗ Failed to restart pvedaemon\n";
            return 0;
        }
    }

    $display_name = get_node_display_name($node);
    say "✓ Removal completed successfully on node $display_name\n";
    return 1;
}

sub install_remote_node {
    my $node = shift;
    my $ssh_tgt = "$ssh_user\@$node";
    my $r_sudo = remote_sudo_prefix();

    my $display_name = get_node_display_name($node);
    say "Installing the plugin on node $display_name";

    # Copy package
    unless (run_cmd("scp", split(/\s+/, $SSH_FLAGS), $deb_path, "$ssh_tgt:$REMOTE_TMP", { outfunc => sub { } })) {
        warn "[$node] ✗ Failed to copy package\n";
        return 0;
    }

    # Install package
    unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}DEBIAN_FRONTEND=noninteractive apt-get -y -q --reinstall install $REMOTE_TMP", { outfunc => sub { } })) {
        warn "[$node] ✗ Failed to install package\n";
        return 0;
    }

    # Restart pvedaemon
    if ($need_restart) {
        unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon", { outfunc => sub { } })) {
            warn "[$node] ✗ Failed to restart pvedaemon\n";
            return 0;
        }
    }

    $display_name = get_node_display_name($node);
    say "✓ Installation completed successfully on node $display_name\n";
    return 1;
}

sub perform_remote_operations {
    my @targets = @_;

    return unless @targets;

    my $operation = $remove_plugin ? "removal" : "installation";

    # Don't print the remote operation header since we already showed the nodes above
    my @failed_nodes;
    my $success_count = 0;

    for my $node (@targets) {
        my $success;
        if ($remove_plugin) {
            $success = remove_remote_node($node);
        } else {
            $success = install_remote_node($node);
        }

        if ($success) {
            $success_count++;
        } else {
            push @failed_nodes, $node;
        }
    }

    # Report summary
    if (@failed_nodes) {
        say "\n✗ Remote $operation failed on " . scalar(@failed_nodes) . " node(s): " . join(", ", @failed_nodes);
        say "  ✓ Successful: $success_count";
        exit 1;
    } else {
        say "\n✓ Remote $operation completed: $success_count successful";
    }
}

my @all_targets;  # All nodes to process (may include local)

# Handle node selection based on mode
if ($interactive) {
    say "Interactive node selection mode";
    say "";

    # Check and inform about readline support
    my ($has_gnu, $has_basic) = check_readline_support();
    if ($has_gnu) {
        say "✓ Full readline support available (arrow keys, history)";
    } elsif ($has_basic) {
        say "✓ Basic readline support available";
    }
    say "";

    my @selected = interactive_full_selection();
    if (@selected) {
        @all_targets = @selected;
        # Node selection and confirmation already shown in interactive_full_selection
        say "";
    } else {
        say "No nodes selected - exiting.";
        exit 0;
    }
} else {
    # Non-interactive mode: always process local node first
    if ($remove_plugin) {
        remove_local();
    } else {
        install_local();
    }
}

my @remote_targets;

# Continue with existing logic for non-interactive modes
unless ($interactive) {
    if ($install_all_nodes) {
    say "Identifying other nodes belonging to cluster $cluster_name";
    my @nodes = discover_remote_nodes();
    if (@nodes) {
        push @remote_targets, @nodes;
        say "Identified nodes: " . join(", ", @nodes);
        say "";
    } else {
        say "No remote nodes found - single node cluster or all nodes are local";
        say "";
    }
} elsif ($node_list) {
    say "Installing on specified nodes";
    my @manual = parse_node_list($node_list);
    my @remote_manual = grep { !is_local_node($_) } @manual;
    if (@remote_manual < @manual) {
        my $filtered_count = @manual - @remote_manual;
        say "Filtered out $filtered_count local node(s) from specified list";
    }
    if (@remote_manual) {
        push @remote_targets, @remote_manual;
        say "Target nodes: " . join(", ", @remote_manual);
        say "";
    }
}
}

# Handle operations based on mode
if ($interactive && @all_targets) {
    # Interactive mode: process all selected nodes (including local if selected)
    my @local_targets = grep { is_local_node($_) } @all_targets;
    my @remote_targets_interactive = grep { !is_local_node($_) } @all_targets;

    # Process local node if selected
    if (@local_targets) {
        if ($remove_plugin) {
            remove_local();
        } else {
            install_local();
        }
    }

    # Process remote nodes if any
    if (@remote_targets_interactive) {
        my %seen;
        @remote_targets_interactive = grep { !$seen{$_}++ } @remote_targets_interactive;
        perform_remote_operations(@remote_targets_interactive);
    }
} elsif (@remote_targets) {
    # Non-interactive mode: process remote targets
    my %seen;
    @remote_targets = grep { !$seen{$_}++ } @remote_targets;
    perform_remote_operations(@remote_targets);
}

if ($remove_plugin) {
    say "\n✓ All operations complete: Plugin removed";
} else {
    say "\n✓ All operations complete: Plugin $tag installed";
    print "\nCheck introduction to configuration guide at https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start#configuration\n";
}
