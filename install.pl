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
my $APT_INSTALL = "apt-get -y --reinstall install";
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
    "help|h"        => \$help,
) or die "Error parsing options\n";

if ($help) {
    print_usage();
    exit 0;
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
  --nodes "n1,n2,..."        Install/remove on specific nodes (use IPs or hostnames)
  --user <name>              SSH user for remote operations (default: root)
  --ssh-flags "<flags>"      Extra SSH flags (default: $SSH_FLAGS)

Examples:
  # Install latest stable on this node only
  $prog

  # Install pre-release on all nodes (automatically uses cluster IPs)
  $prog --pre --all-nodes

  # Install specific tag on two nodes using IP addresses (recommended)
  $prog --version v0.9.9-3 --nodes "192.168.1.10,192.168.1.11"

  # Install using sudo (when not running as root)
  $prog --sudo

  # Remove plugin from local node only
  $prog --remove

  # Remove plugin from all cluster nodes
  $prog --remove --all-nodes

  # Remove plugin from specific nodes using sudo
  $prog --remove --nodes "192.168.1.10,192.168.1.11" --sudo

Note: For --nodes option, use IP addresses unless you have proper DNS records
or /etc/hosts entries configured for the node hostnames.
EOF
}

sub say {
    my $message = shift;
    print "==> $message\n";
}

sub run_cmd {
    my @args = @_;
    my $capture_output = 0;
    my $output_ref;
    
    # Check if last argument is a reference for output capture
    if (ref($args[-1]) eq 'SCALAR') {
        $output_ref = pop @args;
        $capture_output = 1;
    }
    
    my @cmd = @args;
    
    if ($dry_run) {
        print "[dry-run] " . join(" ", @cmd) . "\n";
        if ($capture_output) {
            $$output_ref = "[dry-run output]";
        }
        return 1;
    }
    
    # Use PVE::Tools::run_command if available (only for non-output commands)
    if (defined &PVE::Tools::run_command && !$capture_output) {
        eval {
            PVE::Tools::run_command(\@cmd);
        };
        if ($@) {
            warn "Command failed: " . join(" ", @cmd) . "\nError: $@\n";
            return 0;
        }
        return 1;
    } else {
        # Fallback to system() calls or backticks for output capture
        if ($capture_output) {
            my $cmd_str = join(" ", map { "'$_'" } @cmd);
            $$output_ref = `$cmd_str`;
            my $ret = $?;
            return $ret == 0;
        } else {
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

# Detect Proxmox
if (need_cmd("pveversion", 1)) {
    my $version = `pveversion 2>/dev/null`;
    chomp $version;
    say "Detected Proxmox VE: $version";
} else {
    say "Warning: 'pveversion' not found. Proceeding anyway (Debian-based install assumed).";
}

# Get local node name using PVE modules if available
my $local_node_short;
if (defined &PVE::INotify::nodename) {
    $local_node_short = PVE::INotify::nodename();
} else {
    # Fallback to hostname command
    $local_node_short = `hostname -s 2>/dev/null` || `hostname 2>/dev/null`;
    chomp $local_node_short;
    $local_node_short =~ s/\..*//;  # Remove domain part
}

# Only resolve and download for install operations
if (!$remove_plugin) {
    # Resolve release
    say "Resolving release (channel=$channel" . ($pinned_tag ? ", tag=$pinned_tag" : "") . ") ...";

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

    # Extract download URLs
    for my $asset (@{$rel_json->{assets}}) {
        my $url = $asset->{browser_download_url};
        if ($url =~ /\.deb$/) {
            $deb_url = $url;
        }
        if ($url =~ /(sha256sum|sha256\.txt|\.sha256)$/) {
            $sha_url = $url;
        }
    }

    die "Error: Could not locate a .deb asset in $tag\n" unless $deb_url;

    say "Selected release: $tag";
    say "Downloading: $deb_url";

    # Download .deb file
    $deb_path = "$tmpdir/plugin.deb";
    my $deb_response = $ua->get($deb_url, ':content_file' => $deb_path);
    die "Error downloading .deb file: " . $deb_response->status_line . "\n"
        unless $deb_response->is_success;

    # Download and verify checksum if available
    if ($sha_url) {
        say "Downloading checksum: $sha_url";
        my $checksum_file = "$tmpdir/checksums.txt";
        my $sha_response = $ua->get($sha_url, ':content_file' => $checksum_file);

        if ($sha_response->is_success && need_cmd("sha256sum", 1)) {
            say "Verifying checksum...";
            my $file_sum = "";
            run_cmd("sha256sum", $deb_path, \$file_sum);
            $file_sum =~ /^([a-f0-9]{64})/;
            $file_sum = $1;

            my $deb_basename = basename($deb_url);
            my $ref_sum = "";
            run_cmd("sh", "-c", "grep -E '$deb_basename' '$checksum_file' 2>/dev/null | grep -Eo '^[a-f0-9]{64}' | head -n1", \$ref_sum);
            chomp $ref_sum;

            if ($ref_sum) {
                if ($file_sum ne $ref_sum) {
                    die "Error: checksum mismatch!\n";
                } else {
                    say "Checksum OK.";
                }
            } else {
                say "Checksum file present, no matching entry; skipping strict verification.";
            }
        } else {
            say "sha256sum not found or checksum download failed; skipping checksum verification.";
        }
    } else {
        say "No checksum asset found; skipping checksum verification.";
    }

} # End of install-only logic

# Remove plugin locally
sub remove_local {
    say "Removing JovianDSS plugin locally...";
    my $sudo = maybe_sudo();
    my @cmd;
    if ($sudo) {
        @cmd = ($sudo, "apt-get", "-y", "remove", "open-e-joviandss-proxmox-plugin");
    } else {
        @cmd = ("apt-get", "-y", "remove", "open-e-joviandss-proxmox-plugin");
    }

    unless (run_cmd(@cmd)) {
        die "Error: Local removal failed\n";
    }

    if ($need_restart) {
        say "Restarting pvedaemon (local)...";
        my @restart_cmd;
        if ($sudo) {
            @restart_cmd = ($sudo, "systemctl", "restart", "pvedaemon");
        } else {
            @restart_cmd = ("systemctl", "restart", "pvedaemon");
        }
        unless (run_cmd(@restart_cmd)) {
            die "Error: Failed to restart pvedaemon locally\n";
        }
    }

    say "Local removal complete: $REPO plugin removed";
}

# Install locally
sub install_local {
    say "Installing locally with apt...";
    my $sudo = maybe_sudo();
    my @cmd;
    if ($sudo) {
        @cmd = ($sudo, split(/\s+/, $APT_INSTALL));
    } else {
        @cmd = split(/\s+/, $APT_INSTALL);
    }
    push @cmd, $deb_path;

    unless (run_cmd(@cmd)) {
        die "Error: Local installation failed\n";
    }

    if ($need_restart) {
        say "Restarting pvedaemon (local)...";
        my @restart_cmd;
        if ($sudo) {
            @restart_cmd = ($sudo, "systemctl", "restart", "pvedaemon");
        } else {
            @restart_cmd = ("systemctl", "restart", "pvedaemon");
        }
        unless (run_cmd(@restart_cmd)) {
            die "Error: Failed to restart pvedaemon locally\n";
        }
    }

    say "Local install complete: $REPO $tag";
}

# Discover cluster nodes with their IP addresses
sub discover_nodes {
    my @nodes;

    # Try .members file first to get IP addresses
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
                # Return IP addresses instead of node names for better connectivity
                for my $node_name (keys %{$data->{nodelist}}) {
                    my $node_info = $data->{nodelist}->{$node_name};
                    if ($node_info->{ip}) {
                        push @nodes, $node_info->{ip};
                    } else {
                        # Fallback to node name if no IP
                        push @nodes, $node_name;
                    }
                }
            }
        };
        return @nodes if @nodes;
    }

    # Use PVE::Cluster if available (fallback)
    if (defined &PVE::Cluster::get_members) {
        eval {
            my $members = PVE::Cluster::get_members();
            if ($members && ref($members) eq 'HASH') {
                @nodes = keys %$members;
            }
        };
        return @nodes if @nodes;
    }

    # Fallback to pvecm
    if (need_cmd("pvecm", 1)) {
        my $output = `pvecm nodes 2>/dev/null`;
        for my $line (split /\n/, $output) {
            if ($line =~ /^\s*\d+\s+\d+\s+(\S+)/) {
                my $name = $1;
                $name =~ s/\s*\(local\)\s*$//;
                $name =~ s/^\s+|\s+$//g;
                push @nodes, $name if $name;
            }
        }
    }

    return @nodes;
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

    # Display node information (IP or hostname)
    my $node_desc = $node;
    if ($node =~ /^\d+\.\d+\.\d+\.\d+$/) {
        $node_desc = "$node (IP)";
    }
    say "[$node] Removing JovianDSS plugin from remote node $node_desc ($ssh_tgt)";

    # Remove package
    say "[$node] Removing package with apt...";
    unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}apt-get -y remove open-e-joviandss-proxmox-plugin")) {
        warn "Error: Failed to remove package from node $node\n";
        return 0;
    }

    # Restart pvedaemon
    if ($need_restart) {
        say "[$node] Restarting pvedaemon...";
        unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon")) {
            warn "Error: Failed to restart pvedaemon on node $node\n";
            return 0;
        }
    }

    say "[$node] Removal completed successfully.";
    return 1;
}

sub install_remote_node {
    my $node = shift;
    my $ssh_tgt = "$ssh_user\@$node";
    my $r_sudo = remote_sudo_prefix();

    # Display node information (IP or hostname)
    my $node_desc = $node;
    if ($node =~ /^\d+\.\d+\.\d+\.\d+$/) {
        $node_desc = "$node (IP)";
    }
    say "[$node] Installing JovianDSS plugin on remote node $node_desc ($ssh_tgt)";

    # Copy package
    say "[$node] Copying package -> $REMOTE_TMP";
    unless (run_cmd("scp", split(/\s+/, $SSH_FLAGS), $deb_path, "$ssh_tgt:$REMOTE_TMP")) {
        warn "Error: Failed to copy package to node $node\n";
        return 0;
    }

    # Install package
    say "[$node] Installing package with apt...";
    unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}apt-get -y --reinstall install $REMOTE_TMP")) {
        warn "Error: Failed to install package on node $node\n";
        return 0;
    }

    # Restart pvedaemon
    if ($need_restart) {
        say "[$node] Restarting pvedaemon...";
        unless (run_cmd("ssh", split(/\s+/, $SSH_FLAGS), $ssh_tgt, "${r_sudo}systemctl restart pvedaemon")) {
            warn "Error: Failed to restart pvedaemon on node $node\n";
            return 0;
        }
    }

    say "[$node] Installation completed successfully.";
    return 1;
}

sub perform_remote_operations {
    my @targets = @_;

    return unless @targets;

    my $operation = $remove_plugin ? "removal" : "installation";
    my $verb = $remove_plugin ? "Remove" : "Install";

    say "Remote $operation targets: " . join(" ", @targets);
    my @failed_nodes;
    my $success_count = 0;
    my $skip_count = 0;

    for my $node (@targets) {
        # Skip local node - check both hostname and local IP detection
        my $is_local = 0;
        if ($local_node_short && $node eq $local_node_short) {
            $is_local = 1;
        } elsif ($node eq "127.0.0.1" || $node eq "localhost") {
            $is_local = 1;
        } else {
            # Try to detect if this IP belongs to local node
            if ($node =~ /^\d+\.\d+\.\d+\.\d+$/) {
                # Check if this IP matches our local interfaces
                my $local_ips = `ip addr show 2>/dev/null | grep 'inet ' | awk '{print \$2}' | cut -d'/' -f1`;
                if ($local_ips && $local_ips =~ /\Q$node\E/) {
                    $is_local = 1;
                }
            }
        }

        if ($is_local) {
            say "[$node] Skipping (local node handled separately).";
            $skip_count++;
            next;
        }

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
        warn "Error: Remote $operation failed on " . scalar(@failed_nodes) . " node(s): " . join(" ", @failed_nodes) . "\n";
        warn "Successfully processed: $success_count node(s)\n";
        exit 1;
    } else {
        say "Remote $operation summary: $success_count successful, $skip_count skipped, 0 failed.";
    }
}

# Main execution
if ($remove_plugin) {
    remove_local();
} else {
    # Only proceed with download and install if not removing
    # (The download/install logic above should only run for install operations)
    install_local();
}

my @remote_targets;

# Discover nodes for --all-nodes
if ($install_all_nodes) {
    my @nodes = discover_nodes();
    if (@nodes) {
        push @remote_targets, @nodes;
        say "Auto-discovered cluster nodes: " . join(" ", @nodes);
    } else {
        die <<EOF;
Error: --all-nodes specified but could not discover any cluster nodes.
This may indicate:
  - This is a single-node installation (use without --all-nodes)
  - The cluster is not properly configured
  - You need to specify nodes manually with --nodes "node1,node2,..."
EOF
    }
}

# Add manual node list
if ($node_list) {
    my @manual = parse_node_list($node_list);
    push @remote_targets, @manual;
}

# Remove duplicates and perform remote operations
if (@remote_targets) {
    my %seen;
    @remote_targets = grep { !$seen{$_}++ } @remote_targets;
    perform_remote_operations(@remote_targets);
}

if ($remove_plugin) {
    say "All done. Removed $REPO plugin.";
} else {
    say "All done. Installed $REPO $tag.";
    print <<EOF;
Next steps:
 - Configure storage following the guide:
   https://github.com/open-e/JovianDSS-Proxmox/wiki/Quick-Start#configuration
 - Verify in Datacenter -> Storage, or 'pvesh get /storage'.
EOF
}
