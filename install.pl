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
my $SSH_FLAGS = "-o BatchMode=yes -o StrictHostKeyChecking=accept-new";
my $REMOTE_TMP = "/tmp/joviandss-plugin.deb";

# Global variables
my $tmpdir = tempdir(CLEANUP => 1);
chmod 0755, $tmpdir;
my $deb_path = "";
my $use_sudo = 0;
my $channel = "stable";
my $pinned_tag = "";
my $need_restart = 0;
my $dry_run = 0;
my $install_all_nodes = 0;
my $ssh_user = "root";
my $remove_plugin = 0;
my $help = 0;
my $add_default_multipath_config = 0;
my $force_multipath_config = 0;
my $use_reinstall = 0;  # Default to NOT using --reinstall flag
my @warning_nodes = ();  # Track nodes with warnings

# Variables for install operations
my $tag = "";
my ($deb_url, $sha_url);

# Parse command line options
GetOptions(
    "pre"           => sub { $channel = "pre" },
    "version=s"     => \$pinned_tag,
    "sudo"          => sub { $use_sudo = 1 },
    "restart"       => \$need_restart,
    "dry-run"       => \$dry_run,
    "all-nodes"     => \$install_all_nodes,
    "user=s"        => \$ssh_user,
    "ssh-flags=s"   => \$SSH_FLAGS,
    "remove"        => \$remove_plugin,
    "add-default-multipath-config" => \$add_default_multipath_config,
    "force-multipath-config" => \$force_multipath_config,
    "reinstall"     => \$use_reinstall,
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
  --restart                  Restart pvedaemon after install/remove
  --dry-run                  Show what would be done without doing it
  --add-default-multipath-config  Install default multipath configuration
  --force-multipath-config   Overwrite existing multipath config files
  --reinstall                Use --reinstall apt flag (default: disabled)
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

  # Install with default multipath config on all nodes
  $prog --all-nodes --add-default-multipath-config

  # Force overwrite existing multipath configs
  $prog --all-nodes --add-default-multipath-config --force-multipath-config

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

# Output collection functions
sub create_output_collector {
    my ($filter_func) = @_;
    my @collected_lines;

    return {
        collector => sub {
            my $line = $_[0];
            if ($filter_func) {
                $line = $filter_func->($line);
                push @collected_lines, $line if defined $line;
            } else {
                push @collected_lines, $line;
            }
        },
        get_output => sub { return join("\n", @collected_lines) . "\n" },
        get_lines => sub { return @collected_lines }
    };
}


sub create_hash_filter {
    my ($pattern) = @_;
    return sub {
        my $line = $_[0];
        if ($line =~ /$pattern/) {
            return $1 if defined $1;  # Return first capture group if exists
            return $line;             # Return full line if no capture group
        }
        return undef;  # Filter out non-matching lines
    };
}

# Custom error handlers for different contexts
sub create_context_error_handler {
    my ($context, $node_name) = @_;
    $node_name = $node_name || "local";

    return sub {
        my $error_line = $_[0];
        chomp $error_line if $error_line;
        warn "[$node_name] $context error: $error_line\n" if $error_line;
    };
}

sub create_silent_error_handler {
    return sub { };  # Suppress all errors (for expected failures like test commands)
}

sub create_checksum_error_handler {
    my ($file) = @_;
    return sub {
        my $error_line = $_[0];
        chomp $error_line if $error_line;
        warn "Checksum calculation failed for $file: $error_line\n" if $error_line;
    };
}

sub run_cmd {
    my @args = @_;
    my $outfunc;
    my $errfunc;

    # Check if last argument is a hash with outfunc/errfunc
    if (ref($args[-1]) eq 'HASH') {
        my $opts = pop @args;
        $outfunc = $opts->{outfunc} || undef;
        $errfunc = $opts->{errfunc} || undef;
    }

    my @cmd = @args;

    if ($dry_run) {
        print "[dry-run] " . join(" ", @cmd) . "\n";
        # In dry-run mode, call outfunc with fake output if provided
        if ($outfunc) {
            if ($cmd[0] eq 'sha256sum') {
                $outfunc->("09a5d9de16e9356342613dfd588fb3f30db181ee01dac845fbd4f65764b4c210  $cmd[1]");
            } else {
                $outfunc->("[dry-run output]");
            }
        }
        return 1;
    }

    # PVE::Tools::run_command must be available for Proxmox plugin
    if (!defined &PVE::Tools::run_command) {
        die "Error: PVE::Tools::run_command not available. This script must run on Proxmox VE.\n";
    }

    my $exitcode = 0;
    eval {
        $exitcode = PVE::Tools::run_command(\@cmd,
            outfunc => $outfunc,
            errfunc => $errfunc,
            noerr   => 1
        );
    };
    if ($@) {
        return 0;
    }

    # Return 1 for success (exit code 0), 0 for failure
    return ($exitcode == 0) ? 1 : 0;
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
            errfunc => undef  # Use PVE default error handling
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

sub validate_remote_argument {
    my $arg = shift;
    # Allow: \w (word chars: a-z A-Z 0-9 _), / . - @ :
    if ($arg =~ /[^\w\/.:\-@]/) {
        die "Error: Invalid characters in argument for remote execution: $arg\n";
    }
    return $arg;
}

sub execute_command {
    my $is_local = shift;
    my $node = shift;
    my @cmd = @_;
    my $opts = ref($_[-1]) eq 'HASH' ? pop @cmd : {};

    if ($is_local) {
        my $sudo = maybe_sudo();
        my @full_cmd = $sudo ? ($sudo, @cmd) : @cmd;
        return run_cmd(@full_cmd, $opts);
    } else {
        # Validate and quote all arguments for remote
        my @quoted_cmd;
        for my $arg (@cmd) {
            validate_remote_argument($arg); # Validate all arguments
            push @quoted_cmd, "'$arg'";
        }

        my $ssh_tgt = "$ssh_user\@$node";
        my $r_sudo = remote_sudo_prefix();
        my $cmd_str = "${r_sudo}" . join(" ", @quoted_cmd);
        return run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, $cmd_str, $opts);
    }
}

sub handle_multipath_config {
    my $is_local = shift;
    my $node_or_name = shift;

    return 1 unless $add_default_multipath_config;

    my $template_file = "/etc/joviandss/multipath-open-e-joviandss.conf.example";
    my $target_file = "/etc/multipath/conf.d/open-e-joviandss.conf";

    # Get display name for local vs remote
    my $node_name;
    if ($is_local) {
        $node_name = $node_or_name || "local node";
    } else {
        $node_name = get_node_display_name($node_or_name);
    }

    if ($dry_run) {
        my $prefix = $is_local ? "" : "[$node_name] ";
        say "[dry-run] ${prefix}Checking for multipath template: $template_file";
        say "[dry-run] ${prefix}Would install multipath config to: $target_file";
        return 1;
    }

    # Check if template exists
    unless (execute_command($is_local, $node_or_name, "test", "-f", $template_file, { outfunc => undef, errfunc => sub {} })) {
        warn "[$node_name] ✗ Multipath template not found: $template_file (older package version?)\n";
        return 0;
    }

    # Check if target exists
    my $target_exists = execute_command($is_local, $node_or_name, "test", "-f", $target_file, { outfunc => undef, errfunc => sub {} });

    if ($target_exists && !$force_multipath_config) {
        push @warning_nodes, "$node_name: Multipath config already exists, use --force-multipath-config to overwrite";
        say "⚠ Warning on $node_name: Multipath config file already exists, skipping";
        return 1;  # Not an error, just skipped
    }

    # Create target directory and copy file
    unless (execute_command($is_local, $node_or_name, "mkdir", "-p", "/etc/multipath/conf.d", { outfunc => undef })) {
        warn "[$node_name] ✗ Failed to create multipath config directory\n";
        return 0;
    }

    unless (execute_command($is_local, $node_or_name, "cp", $template_file, $target_file, { outfunc => undef })) {
        warn "[$node_name] ✗ Failed to copy multipath config\n";
        return 0;
    }

    # Reconfigure multipathd
    unless (execute_command($is_local, $node_or_name, "multipathd", "-k", "reconfigure")) {
        say "[$node_name] ⚠ Warning: Failed to reconfigure multipathd (may not be running)";
    }

    say "[$node_name] ✓ Multipath configuration installed";
    return 1;
}


sub remote_sudo_prefix {
    if ($use_sudo) {
        return "sudo ";
    }
    return "";
}

sub fetch_release_metadata {
    my ($channel, $pinned_tag) = @_;
    
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
    unless ($response->is_success) {
        say "✗ Error: Could not fetch release metadata from GitHub: " . $response->status_line;
        return ();
    }

    my $rel_json;
    eval {
        # Use PVE::JSONSchema::from_json if available for better error handling
        if (defined &PVE::JSONSchema::from_json) {
            $rel_json = PVE::JSONSchema::from_json($response->content);
        } else {
            $rel_json = decode_json($response->content);
        }
    };
    if ($@) {
        say "✗ Error: Invalid JSON response from GitHub API";
        return ();
    }

    # Extract tag and URLs
    my $tag;
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
        unless ($matching_release) {
            say "✗ Error: Release tag not found: $pinned_tag";
            return ();
        }
        $rel_json = $matching_release;
    } else {
        if ($channel eq "pre" && ref($rel_json) eq 'ARRAY') {
            $rel_json = $rel_json->[0];
        }
        $tag = $rel_json->{tag_name};
    }

    # Extract download URLs and checksum
    my ($deb_url, $sha_url, $expected_sha256);
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

    unless ($deb_url) {
        say "✗ Error: Could not locate a .deb asset in $tag";
        return ();
    }

    return ($tag, $deb_url, $expected_sha256, $sha_url);
}

sub download_package {
    my ($deb_url, $tmpdir) = @_;
    
    say "Downloading package...";

    my $ua = LWP::UserAgent->new(timeout => 30);
    my $deb_path = "$tmpdir/plugin.deb";
    my $deb_response = $ua->get($deb_url, ':content_file' => $deb_path);
    
    unless ($deb_response->is_success) {
        say "✗ Error downloading .deb file: " . $deb_response->status_line;
        return "";
    }

    return $deb_path;
}

sub verify_package_checksum {
    my ($deb_path, $expected_sha256, $sha_url, $deb_url) = @_;
    
    # Skip verification if no checksum available
    unless ($expected_sha256 || $sha_url) {
        say "⚠ Checksum verification skipped (no checksum available).";
        return 1;
    }

    # Skip verification if sha256sum not available
    unless (need_cmd("sha256sum", 1)) {
        say "⚠ Checksum verification skipped (sha256sum command not available).";
        return 1;
    }

    say "Verifying package checksum...";
    my $collector = create_output_collector(create_hash_filter(qr/^([a-f0-9]{64})/));
    run_cmd("sha256sum", $deb_path, { 
        outfunc => $collector->{collector}, 
        errfunc => create_checksum_error_handler($deb_path) 
    });
    my $file_sum = ($collector->{get_lines}())[0] || "";

    my $ref_sum;

    if ($expected_sha256) {
        # Use SHA256 from GitHub API response
        $ref_sum = $expected_sha256;
    } elsif ($sha_url) {
        # Fallback: download and parse separate checksum file
        my $ua = LWP::UserAgent->new(timeout => 30);
        my $checksum_file = "$tmpdir/checksums.txt";
        my $sha_response = $ua->get($sha_url, ':content_file' => $checksum_file);

        if ($sha_response->is_success) {
            my $deb_basename = basename($deb_url);
            my $collector = create_output_collector(create_hash_filter(qr/^([a-f0-9]{64})/));
            run_cmd("sh", "-c", "grep -E '$deb_basename' '$checksum_file' 2>/dev/null | grep -Eo '^[a-f0-9]{64}' | head -n1", { outfunc => $collector->{collector} });
            $ref_sum = ($collector->{get_lines}())[0] || "";
        }
    }

    if ($ref_sum) {
        if ($file_sum ne $ref_sum) {
            say "✗ Checksum verification failed!";
            say "Expected: $ref_sum";
            say "Got:      $file_sum";
            return 0;
        } else {
            say "✓ Package verified.";
            return 1;
        }
    } else {
        say "⚠ Checksum verification skipped (no valid checksum found).";
        return 1;
    }
}

# Generate unified apt install command
sub get_apt_install_command {
    my $package_path = shift;
    my $cmd = "apt-get -y -q";
    $cmd .= " --reinstall" if $use_reinstall;
    $cmd .= " install $package_path";
    return $cmd;
}

# Generate unified apt remove command
sub get_apt_remove_command {
    my $package_name = shift;
    my $cmd = "apt-get -y -q remove $package_name";
    return $cmd;
}


# Remove plugin locally
sub remove_node {
    my $is_local = shift;
    my $node_or_name = shift;  # For local: display name, for remote: node IP/hostname
    my $local_node_short = shift;  # Only used for local operations
    my $local_ips_ref = shift;     # Only used for local operations

    # Generate display name
    my $display_name;
    if ($is_local) {
        # Get local node display name similar to remote nodes
        if ($local_node_short) {
            # Try to get first non-loopback IP for display
            my $display_ip = "";
            for my $ip (@$local_ips_ref) {
                next if $ip eq '127.0.0.1' || $ip eq 'localhost';
                $display_ip = $ip;
                last;
            }
            if ($display_ip && $display_ip ne $local_node_short) {
                $display_name = "$local_node_short ($display_ip)";
            } else {
                $display_name = $local_node_short;
            }
        } else {
            $display_name = "local node";
        }
    } else {
        $display_name = get_node_display_name($node_or_name);
    }
    
    say "Removing plugin from node $display_name";
    
    # Remove package
    my $removal_success;
    if ($is_local) {
        # Local removal
        my $sudo = maybe_sudo();
        my $apt_cmd = get_apt_remove_command("open-e-joviandss-proxmox-plugin");
        my @cmd;
        if ($sudo) {
            @cmd = ($sudo, split(/\s+/, $apt_cmd));
        } else {
            @cmd = split(/\s+/, $apt_cmd);
        }
        
        $removal_success = run_cmd(@cmd, { 
            outfunc => undef, 
            errfunc => create_context_error_handler("Package removal") 
        });
    } else {
        # Remote removal
        my $ssh_tgt = "$ssh_user\@$node_or_name";
        my $r_sudo = remote_sudo_prefix();
        
        my $apt_cmd = get_apt_remove_command("open-e-joviandss-proxmox-plugin");
        $removal_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}${apt_cmd}", { 
            outfunc => undef, 
            errfunc => create_context_error_handler("Remote package removal", $display_name) 
        });
    }
    
    # Handle removal failure
    unless ($removal_success) {
        if ($is_local) {
            die "Error: Local removal failed\n";
        } else {
            warn "[$node_or_name] ✗ Failed to remove package\n";
            return 0;
        }
    }
    
    # Restart pvedaemon if needed
    if ($need_restart) {
        my $restart_success;
        if ($is_local) {
            my $sudo = maybe_sudo();
            my @restart_cmd;
            if ($sudo) {
                @restart_cmd = ($sudo, "systemctl", "restart", "pvedaemon");
            } else {
                @restart_cmd = ("systemctl", "restart", "pvedaemon");
            }
            $restart_success = run_cmd(@restart_cmd, { 
                outfunc => undef, 
                errfunc => create_context_error_handler("Service restart") 
            });
        } else {
            my $ssh_tgt = "$ssh_user\@$node_or_name";
            my $r_sudo = remote_sudo_prefix();
            $restart_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon", { 
                outfunc => undef, 
                errfunc => create_context_error_handler("Remote service restart", $display_name) 
            });
        }
        
        unless ($restart_success) {
            if ($is_local) {
                die "Error: Failed to restart pvedaemon locally\n";
            } else {
                warn "[$node_or_name] ✗ Failed to restart pvedaemon\n";
                return 0;
            }
        }
    }
    
    say "✓ Removal completed successfully on node $display_name\n";
    return 1;
}

sub remove_local {
    my ($local_node_short, $local_ips_ref) = @_;
    return remove_node(1, undef, $local_node_short, $local_ips_ref);
}

# Install locally
sub install_node {
    my $is_local = shift;
    my $node_or_name = shift;  # For local: display name, for remote: node IP/hostname
    my $local_node_short = shift;  # Only used for local operations
    my $local_ips_ref = shift;     # Only used for local operations
    
    # Generate display name
    my $display_name;
    if ($is_local) {
        # Get local node display name similar to remote nodes
        if ($local_node_short) {
            # Try to get first non-loopback IP for display
            my $display_ip = "";
            for my $ip (@$local_ips_ref) {
                next if $ip eq '127.0.0.1' || $ip eq 'localhost';
                $display_ip = $ip;
                last;
            }
            if ($display_ip && $display_ip ne $local_node_short) {
                $display_name = "$local_node_short ($display_ip)";
            } else {
                $display_name = $local_node_short;
            }
        } else {
            $display_name = "local node";
        }
    } else {
        $display_name = get_node_display_name($node_or_name);
    }
    
    say "Installing plugin on node $display_name";
    
    # Install package
    my $install_success;
    if ($is_local) {
        # Local installation
        my $sudo = maybe_sudo();
        my $apt_cmd = get_apt_install_command($deb_path);
        my @cmd;
        if ($sudo) {
            @cmd = ($sudo, split(/\s+/, $apt_cmd));
        } else {
            @cmd = split(/\s+/, $apt_cmd);
        }
        
        $install_success = run_cmd(@cmd, { 
            outfunc => undef, 
            errfunc => create_context_error_handler("Package installation") 
        });
    } else {
        # Remote installation
        my $ssh_tgt = "$ssh_user\@$node_or_name";
        my $r_sudo = remote_sudo_prefix();
        
        # Copy package
        unless (run_cmd("scp", split(/\s+/, $SSH_FLAGS), $deb_path, "$ssh_tgt:$REMOTE_TMP", { 
            outfunc => undef, 
            errfunc => create_context_error_handler("Remote file transfer", $display_name) 
        })) {
            warn "[$node_or_name] ✗ Failed to copy package\n";
            return 0;
        }
        
        # Install package
        my $apt_cmd = get_apt_install_command($REMOTE_TMP);
        $install_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}${apt_cmd}", { 
            outfunc => undef, 
            errfunc => create_context_error_handler("Remote package installation", $display_name) 
        });
    }
    
    # Handle installation failure
    unless ($install_success) {
        if ($is_local) {
            die "Error: Local installation failed\n";
        } else {
            warn "[$node_or_name] ✗ Failed to install package\n";
            return 0;
        }
    }
    
    # Handle multipath configuration after package installation
    unless (handle_multipath_config($is_local, $is_local ? $display_name : $node_or_name)) {
        if ($add_default_multipath_config) {
            if ($is_local) {
                die "Error: Multipath configuration failed on local node\n";
            } else {
                warn "[$node_or_name] ✗ Multipath configuration failed\n";
                return 0;
            }
        }
    }
    
    # Restart pvedaemon if needed
    if ($need_restart) {
        my $restart_success;
        if ($is_local) {
            my $sudo = maybe_sudo();
            my @restart_cmd;
            if ($sudo) {
                @restart_cmd = ($sudo, "systemctl", "restart", "pvedaemon");
            } else {
                @restart_cmd = ("systemctl", "restart", "pvedaemon");
            }
            $restart_success = run_cmd(@restart_cmd, { 
                outfunc => undef, 
                errfunc => create_context_error_handler("Service restart") 
            });
        } else {
            my $ssh_tgt = "$ssh_user\@$node_or_name";
            my $r_sudo = remote_sudo_prefix();
            $restart_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon", { 
                outfunc => undef, 
                errfunc => create_context_error_handler("Remote service restart", $display_name) 
            });
        }
        
        unless ($restart_success) {
            if ($is_local) {
                die "Error: Failed to restart pvedaemon locally\n";
            } else {
                warn "[$node_or_name] ✗ Failed to restart pvedaemon\n";
                return 0;
            }
        }
    }
    
    say "✓ Installation completed successfully on node $display_name\n";
    return 1;
}

sub install_local {
    my ($local_node_short, $local_ips_ref) = @_;
    return install_node(1, undef, $local_node_short, $local_ips_ref);
}

# Discover cluster nodes with their IP addresses
sub is_local_node {
    my ($node, $local_node_short, $local_ips_ref) = @_;

    # Check if it's the local hostname
    return 1 if ($local_node_short && $node eq $local_node_short);

    # Check against local IP addresses
    return 1 if (grep { $_ eq $node } @$local_ips_ref);

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
    my ($local_node_short, $local_ips_ref) = @_;
    my @all_node_info = discover_all_nodes_with_info();
    my @remote_nodes;

    for my $node (@all_node_info) {
        unless (is_local_node($node->{name}, $local_node_short, $local_ips_ref) || 
                is_local_node($node->{ip}, $local_node_short, $local_ips_ref)) {
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
    return remove_node(0, $node);
}

sub install_remote_node {
    my $node = shift;
    return install_node(0, $node);
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

sub main {
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
        # Fetch release metadata
        my ($tag, $deb_url, $expected_sha256, $sha_url) = fetch_release_metadata($channel, $pinned_tag);
        unless ($tag) {
            return 0;  # fetch_release_metadata already printed error
        }

        # Download package
        $deb_path = download_package($deb_url, $tmpdir);
        unless ($deb_path) {
            return 0;  # download_package already printed error
        }

        # Verify package checksum
        unless (verify_package_checksum($deb_path, $expected_sha256, $sha_url, $deb_url)) {
            return 0;  # verify_package_checksum already printed error
        }
    }

    # Core application logic
    my @remote_targets;
    my $process_local = 1;  # Always process local node
    my $total_successful = 0;  # Track total successful operations

    # Determine what operations will be performed
    if ($install_all_nodes) {
        say "Identifying nodes belonging to cluster $cluster_name";
        my @nodes = discover_remote_nodes($local_node_short, \@local_ips);
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
            my $local_display = $local_node_short || "local node";
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
                return 0;
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
            remove_local($local_node_short, \@local_ips);
            $total_successful++;
        } else {
            install_local($local_node_short, \@local_ips);
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

    if (@warning_nodes) {
        say "\n⚠ Warnings encountered on " . scalar(@warning_nodes) . " node(s):";
        for my $warning (@warning_nodes) {
            my ($node, $msg) = split(': ', $warning, 2);
            $msg =~ s/JOVIANDSS_WARNING:\s*//;
            chomp $msg;
            say "  - $node: $msg";
        }
    }
    return 1;  # Success
}

# Run the main function and exit with its return code
exit(main() ? 0 : 1);
