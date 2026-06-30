#!/usr/bin/perl
#
# check-no-wantarray.pl — CI / pre-commit gate.
#
# Enforces the project rule:
#
#   Internal helpers must NOT branch on `wantarray`. They return a *fixed shape*
#   (a single scalar, or an arrayref/hashref when several values are needed).
#   Only top-level PVE-facing methods may organize `wantarray`.
#
# Rationale: code run under PVE::Tools::lock_file is invoked in scalar context,
# so a list returned through it collapses silently; keeping context-handling in
# exactly one place (the top-level method) makes that impossible to trip over.
# See docs/design/multi-layer-lock-design.md, "Return convention".
#
# `wantarray` is therefore forbidden:
#   * anywhere in the internal-only helper modules (Common.pm / NFSCommon.pm /
#     Lock.pm), and
#   * in any sub whose name starts with `_` (an internal helper), in any file.
#
# It is allowed only in top-level (non-`_`) subs of the plugin modules
# (OpenEJovianDSSPlugin.pm / OpenEJovianDSSNFSPlugin.pm) — e.g. path().
#
# Dependency-free (no PPI / Perl::Critic): a line scan that tracks the enclosing
# sub and ignores `#` comments. Run from the repository root.
#
# Usage:
#   perl tools/check-no-wantarray.pl [FILE ...]
# With no FILE arguments it scans the default set below.
#
# Exit status: 0 = clean, 1 = violation(s) found, 2 = usage / I/O error.

use strict;
use warnings;

# Helper-only modules: EVERY sub in these must avoid wantarray.
my %WHOLE_FILE_FORBIDDEN = map { $_ => 1 } qw(
    Common.pm
    NFSCommon.pm
    Lock.pm
);

# Scanned when no files are given on the command line (paths are repo-relative).
my @DEFAULT_FILES = qw(
    OpenEJovianDSSPlugin.pm
    OpenEJovianDSSNFSPlugin.pm
    OpenEJovianDSS/Common.pm
    OpenEJovianDSS/NFSCommon.pm
    OpenEJovianDSS/Lock.pm
);

my @files = @ARGV ? @ARGV : @DEFAULT_FILES;

my $violations = 0;
my $checked    = 0;

for my $file (@files) {
    open my $fh, '<', $file or do {
        warn "check-no-wantarray: cannot open '$file': $!\n";
        exit 2;
    };
    $checked++;

    my ($basename) = $file =~ m{([^/]+)\z};
    my $whole_file_forbidden = $WHOLE_FILE_FORBIDDEN{$basename} ? 1 : 0;

    my $cur_sub;    # name of the most recent enclosing sub (flat sub layout)

    while ( my $line = <$fh> ) {
        # Drop `#` comments so a `wantarray` mentioned in prose is not flagged.
        # Anchor on start-of-line or whitespace to avoid eating `$#array`.
        ( my $code = $line ) =~ s/(?:^|\s)#.*//;

        $cur_sub = $1 if $code =~ /\bsub\s+(\w+)/;

        next unless $code =~ /\bwantarray\b/;

        my $why;
        if ($whole_file_forbidden) {
            $why = "helper module '$basename' must not use wantarray";
        }
        elsif ( defined $cur_sub && $cur_sub =~ /^_/ ) {
            $why = "internal sub '$cur_sub' must not use wantarray";
        }
        else {
            next;    # allowed: top-level sub in a plugin module
        }

        ( my $snippet = $line ) =~ s/^\s+//;
        $snippet =~ s/\s+\z//;
        printf STDERR "%s:%d: %s\n    %s\n", $file, $., $why, $snippet;
        $violations++;
    }

    close $fh;
}

if ($violations) {
    printf STDERR
        "\ncheck-no-wantarray: FAIL — %d violation(s) across %d file(s).\n",
        $violations, $checked;
    print STDERR
        "Internal helpers must return a fixed shape (scalar / arrayref / hashref);\n",
        "only top-level PVE-facing methods may organize wantarray.\n";
    exit 1;
}

printf "check-no-wantarray: OK — %d file(s) clean.\n", $checked;
exit 0;
