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
my $TMPDIR = tempdir(CLEANUP => 1);
chmod 0755, $TMPDIR;
my $DEB_PATH = "";
my $USE_SUDO = 0;
my $CHANNEL = "stable";
my $PINNED_TAG = "";
my $NEED_RESTART = 0;
my $DRY_RUN = 0;
my $ALL_NODES_OPERATION = 0;
my $SSH_USER = "root";
my $REMOVE_PLUGIN = 0;
my $HELP = 0;
my $ADD_DEFAULT_MULTIPATH_CONFIG = 0;
my $FORCE_MULTIPATH_CONFIG = 0;
my $USE_REINSTALL = 0;  # Default to NOT using --reinstall flag
my $ALLOW_DOWNGRADES = 0;  # Default to NOT allowing downgrades
my $VERBOSE = 0;  # Default to non-verbose output
my $ASSUME_YES = 0;  # Default to interactive confirmation
my @WARNING_NODES = ();  # Track nodes with warnings
my @SKIPPED_NODES = ();  # Track nodes where operations were skipped

# Variables for install operations
my $TAG = "";
my ($DEB_URL, $SHA_URL);

# Parse command line options
GetOptions(
    "pre"           => sub { $CHANNEL = "pre" },
    "version=s"     => \$PINNED_TAG,
    "sudo"          => sub { $USE_SUDO = 1 },
    "restart"       => \$NEED_RESTART,
    "dry-run"       => \$DRY_RUN,
    "all-nodes"     => \$ALL_NODES_OPERATION,
    "user=s"        => \$SSH_USER,
    "ssh-flags=s"   => \$SSH_FLAGS,
    "remove"        => \$REMOVE_PLUGIN,
    "add-default-multipath-config" => \$ADD_DEFAULT_MULTIPATH_CONFIG,
    "force-multipath-config" => \$FORCE_MULTIPATH_CONFIG,
    "reinstall"     => \$USE_REINSTALL,
    "allow-downgrades" => \$ALLOW_DOWNGRADES,
    "assume-yes"    => \$ASSUME_YES,
    "verbose|v"     => \$VERBOSE,
    "help|h"        => \$HELP,
) or die "Error parsing options\n";

if ($HELP) {
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
  --allow-downgrades         Allow installing older package versions
  --assume-yes               Automatic yes to prompts (non-interactive mode)
  -v, --verbose              Show detailed output during installation/removal
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

sub create_checksum_error_handler {
    my ($file) = @_;
    return sub {
        my $error_line = $_[0];
        chomp $error_line if $error_line;
        warn "Checksum calculation failed for $file: $error_line\n" if $error_line;
    };
}

sub create_package_removal_error_handler {
    my ($context, $display_name, $package_not_installed_ref) = @_;
    return sub {
        my $line = shift;
        chomp $line if $line;
        # Check if error indicates package is not installed
        if ($line && ($line =~ /Package '.*' is not installed/ ||
            $line =~ /Unable to locate package/ ||
            $line =~ /dpkg: warning:.*not installed/)) {
            # Set flag to indicate this should be treated as success
            $$package_not_installed_ref = 1 if $package_not_installed_ref;
            return;  # Don't print this as an error
        }
        # Handle other errors normally
        if ($line) {
            if ($display_name) {
                say "[$display_name] Error during $context: $line";
            } else {
                say "Error during $context: $line";
            }
        }
    };
}

sub get_output_handler {
    my ($node_name) = @_;
    if ($VERBOSE) {
        return sub {
            my $line = shift;
            chomp $line if defined $line;
            if ($node_name) {
                say "[$node_name] $line" if $line;
            } else {
                say $line if $line;
            }
        };
    } else {
        return sub { };  # Suppress output
    }
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

    if ($DRY_RUN) {
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
    if ($USE_SUDO) {
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

        my $ssh_tgt = "$SSH_USER\@$node";
        my $r_sudo = remote_sudo_prefix();
        my $cmd_str = "${r_sudo}" . join(" ", @quoted_cmd);
        return run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, $cmd_str, $opts);
    }
}

sub handle_multipath_config {
    my $is_local = shift;
    my $ip = shift;

    return 1 unless $ADD_DEFAULT_MULTIPATH_CONFIG;

    my $template_file = "/etc/joviandss/multipath-open-e-joviandss.conf.example";
    my $target_file = "/etc/multipath/conf.d/open-e-joviandss.conf";

    # Get display name for local vs remote
    my $node_name;
    if ($is_local) {
        $node_name = $ip || "local node";
    } else {
        $node_name = get_node_display_name($ip);
    }

    if ($DRY_RUN) {
        my $prefix = $is_local ? "" : "[$node_name] ";
        say "[dry-run] ${prefix}Checking for multipath template: $template_file";
        say "[dry-run] ${prefix}Would check for existing SCST vendor devices in multipath configs";
        say "[dry-run] ${prefix}Would install multipath config to: $target_file";
        return 1;
    }

    # Check if template exists
    unless (execute_command($is_local, $ip, "test", "-f", $template_file, { outfunc => undef, errfunc => sub {} })) {
        warn "[$node_name] ✗ Multipath template not found: $template_file (older package version?)\n";
        return 0;
    }

    # Check if target exists
    my $target_exists = execute_command($is_local, $ip, "test", "-f", $target_file, { outfunc => undef, errfunc => sub {} });

    if ($target_exists && !$FORCE_MULTIPATH_CONFIG) {
        push @WARNING_NODES, "$node_name: Multipath config already exists, use --force-multipath-config to overwrite";
        say "⚠ Warning on $node_name: Multipath config file already exists, skipping";
        return 1;  # Not an error, just skipped
    }

    # Check for existing SCST vendor devices in multipath configuration
    my $scst_warning_shown = 0;
    my $multipath_config_files = [
        "/etc/multipath.conf",
        "/etc/multipath/multipath.conf"
    ];
    
    # Check individual config files
    for my $config_file (@$multipath_config_files) {
        # Check if config file exists using the same pattern as template check
        if (execute_command($is_local, $ip, "test", "-f", $config_file, { outfunc => undef, errfunc => sub {} })) {
            # Search for SCST vendor entries in the config file
            my $scst_collector = create_output_collector();
            if (execute_command($is_local, $ip, "grep", "-i", "vendor.*scst", $config_file, { 
                outfunc => $scst_collector->{collector}, 
                errfunc => sub {} 
            })) {
                my @scst_entries = $scst_collector->{get_lines}();
                if (@scst_entries && !$scst_warning_shown) {
                    say "⚠ Warning on $node_name: Found existing SCST vendor device configurations in multipath config";
                    say "  Installing default multipath config may affect operation of existing SCST devices";
                    say "  Consider reviewing multipath configuration after installation";
                    push @WARNING_NODES, "$node_name: SCST vendor devices found in multipath config, review after installation";
                    $scst_warning_shown = 1;
                    last;
                }
            }
        }
    }

    # Check conf.d directory files if no SCST found yet
    unless ($scst_warning_shown) {
        # Check if conf.d directory exists first
        if (execute_command($is_local, $ip, "test", "-d", "/etc/multipath/conf.d", { outfunc => undef, errfunc => sub {} })) {
            # List .conf files in the directory using ls instead of find
            my $conf_collector = create_output_collector();
            if (execute_command($is_local, $ip, "ls", "/etc/multipath/conf.d/", { 
                outfunc => $conf_collector->{collector}, 
                errfunc => sub {} 
            })) {
                my @all_files = $conf_collector->{get_lines}();

                # Check all files in the directory regardless of suffix
                for my $file (@all_files) {
                    chomp $file;
                    next unless $file; # Skip empty lines
                    next if $file eq '.' || $file eq '..'; # Skip directory entries
                    next if $file eq 'open-e-joviandss.conf'; # Skip our own config file - handled separately

                    my $full_path = "/etc/multipath/conf.d/$file";

                    # Search for SCST vendor entries
                    my $scst_collector = create_output_collector();
                    if (execute_command($is_local, $ip, "grep", "-i", "vendor.*scst", $full_path, { 
                        outfunc => $scst_collector->{collector}, 
                        errfunc => sub {} 
                    })) {
                        my @scst_entries = $scst_collector->{get_lines}();
                        if (@scst_entries) {
                            say "⚠ Warning on $node_name: Found existing SCST vendor device configurations in multipath config";
                            say "  Installing default multipath config may affect operation of existing SCST devices";
                            say "  Consider reviewing multipath configuration after installation";
                            push @WARNING_NODES, "$node_name: SCST vendor devices found in multipath config, review after installation";
                            last;
                        }
                    }
                }
            }
        }
    }

    # Create target directory and copy file
    unless (execute_command($is_local, $ip, "mkdir", "-p", "/etc/multipath/conf.d", { outfunc => undef })) {
        warn "[$node_name] ✗ Failed to create multipath config directory\n";
        return 0;
    }

    unless (execute_command($is_local, $ip, "cp", $template_file, $target_file, { outfunc => undef })) {
        warn "[$node_name] ✗ Failed to copy multipath config\n";
        return 0;
    }

    # Reconfigure multipathd
    unless (execute_command($is_local, $ip, "multipathd", "-k", "reconfigure")) {
        say "[$node_name] ⚠ Warning: Failed to reconfigure multipathd (may not be running)";
    }

    say "[$node_name] ✓ Multipath configuration installed";
    return 1;
}


sub remote_sudo_prefix {
    if ($USE_SUDO) {
        return "sudo ";
    }
    return "";
}

sub fetch_release_metadata {
    my ($CHANNEL, $PINNED_TAG) = @_;

    # Resolve release
    if ($PINNED_TAG) {
        say "Fetching release: $PINNED_TAG";
    } else {
        say "Fetching latest $CHANNEL release";
    }

    my $ua = LWP::UserAgent->new(timeout => 30);
    my $url;

    if ($PINNED_TAG) {
        $url = $API_BASE;
    } else {
        if ($CHANNEL eq "stable") {
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
    my $TAG;
    if ($PINNED_TAG) {
        $TAG = $PINNED_TAG;
        # Find the matching release
        my $matching_release;
        if (ref($rel_json) eq 'ARRAY') {
            for my $release (@$rel_json) {
                if ($release->{tag_name} eq $PINNED_TAG) {
                    $matching_release = $release;
                    last;
                }
            }
        }
        unless ($matching_release) {
            say "✗ Error: Release tag not found: $PINNED_TAG";
            return ();
        }
        $rel_json = $matching_release;
    } else {
        if ($CHANNEL eq "pre" && ref($rel_json) eq 'ARRAY') {
            $rel_json = $rel_json->[0];
        }
        $TAG = $rel_json->{tag_name};
    }

    # Extract download URLs and checksum
    my ($DEB_URL, $SHA_URL, $expected_sha256);
    for my $asset (@{$rel_json->{assets}}) {
        my $url = $asset->{browser_download_url};
        if ($url =~ /\.deb$/) {
            $DEB_URL = $url;

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
            $SHA_URL = $url;
        }
    }

    unless ($DEB_URL) {
        say "✗ Error: Could not locate a .deb asset in $TAG";
        return ();
    }

    return ($TAG, $DEB_URL, $expected_sha256, $SHA_URL);
}

sub download_package {
    my ($DEB_URL, $TMPDIR) = @_;

    say "Downloading package...";

    my $ua = LWP::UserAgent->new(timeout => 30);
    my $DEB_PATH = "$TMPDIR/plugin.deb";
    my $deb_response = $ua->get($DEB_URL, ':content_file' => $DEB_PATH);

    unless ($deb_response->is_success) {
        say "✗ Error downloading .deb file: " . $deb_response->status_line;
        return "";
    }

    return $DEB_PATH;
}

sub verify_package_checksum {
    my ($DEB_PATH, $expected_sha256, $SHA_URL, $DEB_URL) = @_;

    # Skip verification if no checksum available
    unless ($expected_sha256 || $SHA_URL) {
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
    run_cmd("sha256sum", $DEB_PATH, {
        outfunc => $collector->{collector},
        errfunc => create_checksum_error_handler($DEB_PATH)
    });
    my $file_sum = ($collector->{get_lines}())[0] || "";

    my $ref_sum;

    if ($expected_sha256) {
        # Use SHA256 from GitHub API response
        $ref_sum = $expected_sha256;
    } elsif ($SHA_URL) {
        # Fallback: download and parse separate checksum file
        my $ua = LWP::UserAgent->new(timeout => 30);
        my $checksum_file = "$TMPDIR/checksums.txt";
        my $sha_response = $ua->get($SHA_URL, ':content_file' => $checksum_file);

        if ($sha_response->is_success) {
            my $deb_basename = basename($DEB_URL);
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
    $cmd .= " --reinstall" if $USE_REINSTALL;
    $cmd .= " --allow-downgrades" if $ALLOW_DOWNGRADES;
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
    my ($is_local, $ip, $hostname) = @_;

    # Generate display name
    my $display_name;
    if ($is_local) {
        $display_name = $hostname || "local node";
        if ($ip && $ip ne $hostname) {
            $display_name = "$hostname ($ip)";
        }
    } else {
        $display_name = $hostname || $ip;
        if ($hostname && $ip ne $hostname) {
            $display_name = "$hostname ($ip)";
        }
    }

    say "Removing plugin from node $display_name";

    # Remove package
    my $removal_success;
    my $package_not_installed = 0;
    if ($is_local) {
        # Local removal - set environment variable for non-interactive mode
        local $ENV{DEBIAN_FRONTEND} = 'noninteractive';
        my $sudo = maybe_sudo();
        my $apt_cmd = get_apt_remove_command("open-e-joviandss-proxmox-plugin");
        my @cmd;
        if ($sudo) {
            @cmd = ($sudo, split(/\s+/, $apt_cmd));
        } else {
            @cmd = split(/\s+/, $apt_cmd);
        }
        $removal_success = run_cmd(@cmd, {
            outfunc => get_output_handler("local"),
            errfunc => create_package_removal_error_handler("Package removal", undef, \$package_not_installed)
        });
    } else {
        # Remote removal
        my $ssh_tgt = "$SSH_USER\@$ip";
        my $r_sudo = remote_sudo_prefix();

        my $apt_cmd = get_apt_remove_command("open-e-joviandss-proxmox-plugin");
        $removal_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "DEBIAN_FRONTEND=noninteractive ${r_sudo}${apt_cmd}", {
            outfunc => get_output_handler($display_name),
            errfunc => create_package_removal_error_handler("Remote package removal", $display_name, \$package_not_installed)
        });
    }

    # Handle removal failure (but treat "package not installed" as success)
    unless ($removal_success || $package_not_installed) {
        if ($is_local) {
            warn "✗ Failed to remove package from local node\n";
            return 0;
        } else {
            warn "[$ip] ✗ Failed to remove package\n";
            return 0;
        }
    }

    # Inform user if package wasn't installed
    if ($package_not_installed) {
        say "ℹ Package was not installed on node $display_name (skipping removal)";
        push @SKIPPED_NODES, $display_name;
    }

    # Restart pvedaemon if needed
    if ($NEED_RESTART) {
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
                outfunc => get_output_handler("local"),
                errfunc => create_context_error_handler("Service restart")
            });
        } else {
            my $ssh_tgt = "$SSH_USER\@$ip";
            my $r_sudo = remote_sudo_prefix();
            $restart_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon", {
                outfunc => get_output_handler($display_name),
                errfunc => create_context_error_handler("Remote service restart", $display_name)
            });
        }

        unless ($restart_success) {
            if ($is_local) {
                warn "✗ Failed to restart pvedaemon on local node\n";
                return 0;
            } else {
                warn "[$ip] ✗ Failed to restart pvedaemon\n";
                return 0;
            }
        }
    }

    say "✓ Removal completed successfully on node $display_name\n";
    return 1;
}


# Install locally
sub install_node {
    my ($is_local, $ip, $hostname) = @_;

    # Generate display name
    my $display_name;
    if ($is_local) {
        $display_name = $hostname || "local node";
        if ($ip && $ip ne $hostname) {
            $display_name = "$hostname ($ip)";
        }
    } else {
        $display_name = $hostname || $ip;
        if ($hostname && $ip ne $hostname) {
            $display_name = "$hostname ($ip)";
        }
    }

    say "Installing plugin on node $display_name";

    # Install package
    my $install_success;
    if ($is_local) {
        # Local installation - set environment variable for non-interactive mode
        local $ENV{DEBIAN_FRONTEND} = 'noninteractive';
        my $sudo = maybe_sudo();
        my $apt_cmd = get_apt_install_command($DEB_PATH);
        my @cmd;
        if ($sudo) {
            @cmd = ($sudo, split(/\s+/, $apt_cmd));
        } else {
            @cmd = split(/\s+/, $apt_cmd);
        }

        $install_success = run_cmd(@cmd, {
            outfunc => get_output_handler("local"),
            errfunc => create_context_error_handler("Package installation")
        });
    } else {
        # Remote installation
        my $ssh_tgt = "$SSH_USER\@$ip";
        my $r_sudo = remote_sudo_prefix();

        # Copy package
        unless (run_cmd("scp", split(/\s+/, $SSH_FLAGS), $DEB_PATH, "$ssh_tgt:$REMOTE_TMP", {
            outfunc => undef,
            errfunc => create_context_error_handler("Remote file transfer", $display_name)
        })) {
            warn "[$ip] ✗ Failed to copy package\n";
            return 0;
        }

        # Install package
        my $apt_cmd = get_apt_install_command($REMOTE_TMP);
        $install_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "DEBIAN_FRONTEND=noninteractive ${r_sudo}${apt_cmd}", {
            outfunc => get_output_handler($display_name),
            errfunc => create_context_error_handler("Remote package installation", $display_name)
        });
    }

    # Handle installation failure
    unless ($install_success) {
        if ($is_local) {
            warn "✗ Failed to install package on local node\n";
            return 0;
        } else {
            warn "[$ip] ✗ Failed to install package\n";
            return 0;
        }
    }

    # Handle multipath configuration after package installation
    unless (handle_multipath_config($is_local, $is_local ? $display_name : $ip)) {
        if ($ADD_DEFAULT_MULTIPATH_CONFIG) {
            if ($is_local) {
                die "Error: Multipath configuration failed on local node\n";
            } else {
                warn "[$ip] ✗ Multipath configuration failed\n";
                return 0;
            }
        }
    }

    # Restart pvedaemon if needed
    if ($NEED_RESTART) {
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
                outfunc => get_output_handler("local"),
                errfunc => create_context_error_handler("Service restart")
            });
        } else {
            my $ssh_tgt = "$SSH_USER\@$ip";
            my $r_sudo = remote_sudo_prefix();
            $restart_success = run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon", {
                outfunc => get_output_handler($display_name),
                errfunc => create_context_error_handler("Remote service restart", $display_name)
            });
        }

        unless ($restart_success) {
            if ($is_local) {
                warn "✗ Failed to restart pvedaemon on local node\n";
                return 0;
            } else {
                warn "[$ip] ✗ Failed to restart pvedaemon\n";
                return 0;
            }
        }
    }

    say "✓ Installation completed successfully on node $display_name\n";
    return 1;
}


# Helper function to add nodes based on ALL_NODES_OPERATION filtering
sub add_node_if_applicable {
    my ($node_info_ref, $node_name, $node_ip, $local_node_short, $local_ips_ref) = @_;

    # Helper function to determine if a node is local
    my $is_local_node = sub {
        my ($node_name, $node_ip) = @_;

        # Check by hostname
        return 1 if $node_name eq $local_node_short;

        # Check by IP address
        if ($local_ips_ref && @$local_ips_ref) {
            for my $local_ip (@$local_ips_ref) {
                return 1 if $node_ip eq $local_ip;
            }
        }

        return 0;
    };

    my $is_local = $is_local_node->($node_name, $node_ip);

    # Apply filtering logic based on ALL_NODES_OPERATION flag
    if ($ALL_NODES_OPERATION) {
        # Include all nodes when --all-nodes is specified
        push @$node_info_ref, {
            name => $node_name,
            ip => $node_ip,
            is_local => $is_local
        };
    } else {
        # Include only local node when operating on single node
        if ($is_local) {
            push @$node_info_ref, {
                name => $node_name,
                ip => $node_ip,
                is_local => $is_local
            };
        }
    }
}

# Discover cluster nodes with their IP addresses
sub acquire_target_nodes_info{
    my @node_info;  # Array of {name => 'hostname', ip => 'ip', is_local => 0|1} hashes

    # Get local node information
    my ($local_node_short, $local_ips_ref, $cluster_name) = get_local_node_info();

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
                    my $ip = $node_data->{ip} || $node_name;
                    add_node_if_applicable(\@node_info, $node_name, $ip, $local_node_short, $local_ips_ref);
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
                    add_node_if_applicable(\@node_info, $node_name, $node_name, $local_node_short, $local_ips_ref);
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
                    add_node_if_applicable(\@node_info, $name, $name, $local_node_short, $local_ips_ref);
                }
            }
        }
        return @node_info if @node_info;
    }

    # If no cluster detection methods worked:
    #   standalone Proxmox node
    #   cluster tools unavailable
    #   not part of a cluster
    # add local node as the only installation target
    if (@node_info == 0) {
        add_node_if_applicable(\@node_info, $local_node_short, $local_ips_ref->[0],
                               $local_node_short, $local_ips_ref);
    }

    return @node_info;
}

sub get_node_display_name {
    my $ip = shift;

    # Get all nodes with local/remote info
    my @nodes = acquire_target_nodes_info();
    for my $node (@nodes) {
        if ($node->{ip} eq $ip) {
            return $node->{name} eq $ip ? $ip : "$node->{name} ($ip)";
        }
    }

    # Fallback to just IP
    return $ip;
}


sub print_operation_nodes {
    my ($operation_text, $nodes_ref) = @_;

    say "";
    say $operation_text;
    for my $node (@$nodes_ref) {
        my $display_name;
        if ($node->{is_local}) {
            $display_name = $node->{name};
            if ($node->{ip} ne $node->{name}) {
                $display_name = "$node->{name} ($node->{ip})";
            }
            $display_name .= " [LOCAL]";
        } else {
            $display_name = $node->{name};
            if ($node->{ip} ne $node->{name}) {
                $display_name = "$node->{name} ($node->{ip})";
            }
        }
        say "  $display_name";
    }
    say "";
}

sub get_local_node_info {
    # Get local node name
    my $local_node_short;
    if (defined &PVE::INotify::nodename) {
        $local_node_short = PVE::INotify::nodename();
    } else {
        # Fallback to hostname command using run_cmd
        my $hostname_collector = create_output_collector();
        if (run_cmd("hostname", "-s", {
            outfunc => $hostname_collector->{collector},
            errfunc => sub {} 
        })) {
            my @hostname_lines = $hostname_collector->{get_lines}();
            $local_node_short = $hostname_lines[0] if @hostname_lines;
        }

        # Try regular hostname if -s failed
        unless ($local_node_short) {
            my $hostname_collector2 = create_output_collector();
            if (run_cmd("hostname", { 
                outfunc => $hostname_collector2->{collector}, 
                errfunc => sub {} 
            })) {
                my @hostname_lines = $hostname_collector2->{get_lines}();
                $local_node_short = $hostname_lines[0] if @hostname_lines;
            }
        }

        if ($local_node_short) {
            chomp $local_node_short;
            $local_node_short =~ s/\..*//;  # Remove domain part
        }
    }

    # Get local IP addresses using run_cmd
    my @local_ips;
    my $ip_collector = create_output_collector();
    if (run_cmd("ip", "addr", "show", {
        outfunc => $ip_collector->{collector},
        errfunc => sub {}
    })) {
        my @ip_lines = $ip_collector->{get_lines}();

        # Track current interface to exclude loopback
        my $current_interface = '';

        # Process each line to find inet addresses
        for my $line (@ip_lines) {
            # Match interface line: "1: lo: <LOOPBACK..." or "2: eth0: <BROADCAST..."
            if ($line =~ /^\d+:\s+(\S+):/) {
                $current_interface = $1;
            }

            # Look for lines like: "inet 192.168.1.1/24 brd ..."
            # Skip if current interface is loopback (lo)
            if ($line =~ /^\s*inet\s+(\S+)/ && $current_interface ne 'lo') {
                my $inet_addr = $1;
                # Extract IP part before the slash
                if ($inet_addr =~ /^([^\/]+)/) {
                    push @local_ips, $1;
                }
            }
        }
    }

    # Add standard local addresses
    push @local_ips, '127.0.0.1', 'localhost';

    # Get cluster name using run_cmd
    my $cluster_name;
    if (need_cmd("pvecm", 1)) {
        my $pvecm_collector = create_output_collector();
        if (run_cmd("pvecm", "status", { 
            outfunc => $pvecm_collector->{collector}, 
            errfunc => sub {} 
        })) {
            my @pvecm_lines = $pvecm_collector->{get_lines}();
            for my $line (@pvecm_lines) {
                if ($line =~ /Name:\s*(\S+)/) {
                    $cluster_name = $1;
                    last;
                }
            }
        }
    }
    $cluster_name = $cluster_name || "proxmox-cluster";

    return ($local_node_short, \@local_ips, $cluster_name);
}

sub main {
    # Check prerequisites
    need_cmd("apt-get");
    need_cmd("awk");
    need_cmd("sed");
    need_cmd("grep");
    need_cmd("sha256sum", 1);

    if ($ALL_NODES_OPERATION) {
        need_cmd("ssh");
        need_cmd("scp");
    }

    # Detect Proxmox (optional check)
    if (!need_cmd("pveversion", 1)) {
        say "Warning: 'pveversion' not found. Proceeding anyway (Debian-based install assumed).";
    }

    # Get local node information
    my ($local_node_short, $local_ips_ref, $cluster_name) = get_local_node_info();
    my @local_ips = @$local_ips_ref;

    # Main operation logic - separated by install/remove
    my $total_successful = 0;
    my @failed_nodes;

    if ($REMOVE_PLUGIN) {
        # REMOVAL OPERATIONS

        say "Identifying nodes belonging to cluster $cluster_name";
        my @nodes = acquire_target_nodes_info();

        if (@nodes) {
            # Show confirmation for ALL operations (sorted alphabetically)
            my @sorted_nodes = sort { $a->{name} cmp $b->{name} } @nodes;
            print_operation_nodes("Plugin will be removed from the following nodes:", \@sorted_nodes);

            unless ($ASSUME_YES) {
                my $confirm = simple_readline("Continue? (y/n): ");
                unless ($confirm && $confirm =~ /^y$/i) {
                    say "Operation cancelled.";
                    return 0;
                }
            }
            say "";

            # Perform operations on all nodes (in sorted order)
            for my $node (@sorted_nodes) {
                my $success;
                if ($node->{is_local}) {
                    # Local removal
                    $success = remove_node(1, $node->{ip}, $node->{name});
                } else {
                    # Remote removal
                    $success = remove_node(0, $node->{ip}, $node->{name});
                }

                if ($success) {
                    $total_successful++;
                } else {
                    push @failed_nodes, $node->{ip};
                }
            }
        } else {
                say "None nodes identified for operation";
                say "";
        }

    } else {
        # INSTALLATION OPERATIONS

        # Fetch release metadata and download package
        my ($TAG, $DEB_URL, $expected_sha256, $SHA_URL) = fetch_release_metadata($CHANNEL, $PINNED_TAG);
        unless ($TAG) {
            return 0;  # fetch_release_metadata already printed error
        }

        # Download package
        $DEB_PATH = download_package($DEB_URL, $TMPDIR);
        unless ($DEB_PATH) {
            return 0;  # download_package already printed error
        }

        # Verify package checksum
        unless (verify_package_checksum($DEB_PATH, $expected_sha256, $SHA_URL, $DEB_URL)) {
            return 0;  # verify_package_checksum already printed error
        }
        say "Identifying nodes belonging to cluster $cluster_name";
        my @nodes = acquire_target_nodes_info();

        if (@nodes) {
            # Show confirmation for ALL operations (sorted alphabetically)
            my @sorted_nodes = sort { $a->{name} cmp $b->{name} } @nodes;
            print_operation_nodes("Plugin $TAG will be installed on the following nodes:", \@sorted_nodes);

            unless ($ASSUME_YES) {
                my $confirm = simple_readline("Continue? (y/n): ");
                unless ($confirm && $confirm =~ /^y$/i) {
                    say "Operation cancelled.";
                    return 0;
                }
            }
            say "";

            # Perform operations on all nodes (in sorted order)
            for my $node (@sorted_nodes) {
                my $success;

                $success = install_node($node->{is_local}, $node->{ip}, $node->{name});

                if ($success) {
                    $total_successful++;
                } else {
                    push @failed_nodes, $node->{ip};
                }
            }
        } else {
            say "None nodes identified for operation";
            say "";
        }
    }

    if ($REMOVE_PLUGIN) {
        my $skipped_count = scalar(@SKIPPED_NODES);
        my $failed_count = scalar(@failed_nodes);
        if ($skipped_count > 0) {
            my $actual_removed = $total_successful - $skipped_count;
            if ($failed_count > 0) {
                say "\n✗ Operations completed with failures: Plugin removed from $actual_removed node(s), skipped $skipped_count node(s) (not installed), failed on $failed_count node(s)";
            } else {
                say "\n✓ All operations complete: Plugin removed from $actual_removed node(s), skipped $skipped_count node(s) (not installed)";
            }
        } else {
            if ($failed_count > 0) {
                say "\n✗ Operations completed with failures: Plugin removed from $total_successful node(s), failed on $failed_count node(s)";
            } else {
                say "\n✓ All operations complete: Plugin removed from $total_successful node(s)";
            }
        }
        if ($failed_count > 0) {
            say "Failed nodes: " . join(", ", @failed_nodes);
        }
    } else {
        my $failed_count = scalar(@failed_nodes);
        if ($failed_count > 0) {
            say "\n✗ Operations completed with failures: Plugin installed on $total_successful node(s), failed on $failed_count node(s)";
            say "Failed nodes: " . join(", ", @failed_nodes);
        } else {
            say "\n✓ All operations complete: Plugin installed on $total_successful node(s)";
        }
        print "\nCheck introduction to configuration guide at https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start#configuration\n";
    }

    if (@WARNING_NODES) {
        say "\n⚠ Warnings encountered on " . scalar(@WARNING_NODES) . " node(s):";
        for my $warning (@WARNING_NODES) {
            my ($node, $msg) = split(': ', $warning, 2);
            $msg =~ s/JOVIANDSS_WARNING:\s*//;
            chomp $msg;
            say "  - $node: $msg";
        }
    }

    # Return success only if no failures occurred
    my $failed_count = scalar(@failed_nodes);
    return $failed_count == 0 ? 1 : 0;
}

# Run the main function and exit with its return code
exit(main() ? 0 : 1);
