#!/usr/bin/env perl
use strict;
use warnings;
use Getopt::Long;
use File::Temp qw(tempdir);
use File::Basename;

# Always load required modules
use JSON;
use LWP::UserAgent;


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
my $ssh_user = "root";
my $remove_plugin = 0;
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
    "user=s"        => \$ssh_user,
    "ssh-flags=s"   => \$SSH_FLAGS,
    "remove"        => \$remove_plugin,
    "help|h"        => \$help,
) or die "Error parsing options\n";

if ($help) {
    print_usage();
    exit 0;
}


# Simple readline function
sub simple_readline {
    my ($prompt, $completion_options) = @_;

    # For piped input (like curl | perl -), open TTY directly
    if (!-t STDIN) {
        # Try to open /dev/tty for direct terminal access
        if (open(my $tty_in, '<', '/dev/tty') && open(my $tty_out, '>', '/dev/tty')) {
            print $tty_out $prompt;
            $tty_out->flush();

            my $input = <$tty_in>;
            chomp($input) if defined $input;

            close($tty_in);
            close($tty_out);
            return $input;
        } else {
            # Fallback if TTY not available - this will likely fail
            die "Error: Cannot read from terminal when STDIN is piped. Try running the script directly instead of piping.\n";
        }
    }

    # Normal terminal input
    print $prompt;
    STDOUT->flush();

    my $input = <STDIN>;
    chomp($input) if defined $input;
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
  -h, --help                 Show this help

Cluster:
  --all-nodes                Install/remove on all nodes (uses IPs from cluster membership)
  --user <name>              SSH user for remote operations (default: root)
  --ssh-flags "<flags>"      Extra SSH flags (default: $SSH_FLAGS)

Examples:
  # Install latest stable on this node only
  $prog


  # Install pre-release on all nodes (automatically uses cluster IPs)
  $prog --pre --all-nodes


  # Install using sudo (when not running as root)
  $prog --sudo

  # Remove plugin from local node only
  $prog --remove

  # Remove plugin from all cluster nodes
  $prog --remove --all-nodes

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

    # PVE::Tools::run_command must be available for Proxmox plugin
    if (!defined &PVE::Tools::run_command) {
        die "Error: PVE::Tools::run_command not available. This script must run on Proxmox VE.\n";
    }

    eval {
        # Set DEBIAN_FRONTEND for apt operations
        local $ENV{DEBIAN_FRONTEND} = 'noninteractive';
        if ($capture_output) {
            # For output capture, use run_command with outfunc to collect output
            my @output_lines;
            PVE::Tools::run_command(\@cmd,
                outfunc => sub { push @output_lines, $_[0] . "\n" },
                errfunc => $errfunc || sub { }
            );
            $$output_ref = join("", @output_lines);
        } elsif (defined $outfunc || defined $errfunc) {
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
}

sub need_cmd {
    my $cmd = shift;
    my $optional = shift || 0;

    # Check if PVE::Tools::run_command is available
    if (!defined &PVE::Tools::run_command) {
        die "Error: PVE::Tools::run_command not available. This script must run on Proxmox VE.\n";
    }

    # Use whereis -b to check if command exists
    my $found = 0;
    my @output_lines;
    my $eval_error;
    eval {
        PVE::Tools::run_command(["whereis", "-b", $cmd],
            outfunc => sub {
                my $line = shift;
                chomp $line;
                # whereis output format: "cmd: /path/to/cmd" or "cmd:"
                # Command found if there's a colon followed by a path
                if ($line =~ /^\Q$cmd\E:\s+(.+)/) {
                    push @output_lines, $1;  # Store the path
                }
            },
            errfunc => sub { }  # Ignore errors
        );
        # Command found if whereis returned a path
        $found = (scalar(@output_lines) > 0);
    };
    if ($@) {
        $eval_error = $@;
        $found = 0;
    }

    if (!$found) {
        if ($optional) {
            return 0;
        } else {
            if ($eval_error) {
                die "Error checking for '$cmd': $eval_error\n";
            } else {
                die "Error: '$cmd' not found.\n";
            }
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
need_cmd("apt-get");
need_cmd("awk");
need_cmd("sed");
need_cmd("grep");
need_cmd("sha256sum", 1);

if ($install_all_nodes) {
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
    if ($status_output && $status_output =~ /Name:\s*(\S+)/) {
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

    say "Removing plugin from node $local_display_name";
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

    say "Installing plugin on node $local_display_name";
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

    say "✓ Installation completed successfully on node $local_display_name\n";
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

sub remove_remote_node {
    my $node = shift;
    my $ssh_tgt = "$ssh_user\@$node";
    my $r_sudo = remote_sudo_prefix();

    my $display_name = get_node_display_name($node);
    say "Removing plugin from node $display_name";

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
    say "Installing plugin on node $display_name";

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

    return $success_count;
}


my @remote_targets;
my $process_local = 1;  # Always process local node
my $total_successful = 0;  # Track total successful operations

# Determine what operations will be performed
if ($install_all_nodes) {
    say "Identifying nodes belonging to cluster $cluster_name";
    my @nodes = discover_remote_nodes();
    if (@nodes) {
        push @remote_targets, @nodes;

        # Show confirmation for ALL operations (local + remote)
        my $operation = $remove_plugin ? "removed from" : "installed on";
        if ($remove_plugin) {
            say "Plugin will be $operation the following nodes:";
        } else {
            say "Plugin $tag will be $operation the following nodes:";
        }

        # Get local node display name with IP
        my $local_display = get_node_display_name($local_node_short || "local node");
        # If local display doesn't include IP, try to add one
        if ($local_display eq ($local_node_short || "local node") && @local_ips) {
            my $local_ip = "";
            for my $ip (@local_ips) {
                next if $ip eq '127.0.0.1' || $ip eq 'localhost';
                $local_ip = $ip;
                last;
            }
            if ($local_ip) {
                $local_display = "$local_node_short ($local_ip)";
            }
        }
        say "  $local_display [LOCAL]";
        for my $node (@nodes) {
            my $display_name = get_node_display_name($node);
            say "  $display_name";
        }
        say "";

        my $confirm = simple_readline("Continue? (y/n): ");
        unless ($confirm && $confirm =~ /^y$/i) {
            say "Operation cancelled.";
            exit 0;
        }
        say "";
    } else {
        say "No remote nodes found - single node cluster or all nodes are local";
        say "";
    }
}

# Now perform the operations after confirmation
if ($process_local) {
    if ($remove_plugin) {
        remove_local();
        $total_successful++;
    } else {
        install_local();
        $total_successful++;
    }
}

# Handle remote operations
if (@remote_targets) {
    my %seen;
    @remote_targets = grep { !$seen{$_}++ } @remote_targets;
    my $remote_successful = perform_remote_operations(@remote_targets);
    $total_successful += $remote_successful;
}

if ($remove_plugin) {
    say "\n✓ All operations complete: Plugin removed from $total_successful node(s)";
} else {
    say "\n✓ All operations complete: Plugin installed on $total_successful node(s)";
    print "\nCheck introduction to configuration guide at https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start#configuration\n";
}
