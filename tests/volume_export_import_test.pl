#!/usr/bin/perl
# Functional tests for the iSCSI plugin's offline-migration surface:
# volume_export_formats / volume_import_formats (what PVE is offered) and
# volume_export / volume_import (the raw+size stream path used by
# storage_migrate and the cross-cluster 'disk-import' tunnel command).
#
# The regression that motivated this file: PVE composes the import target
# volname as "$vmid/$name.$format" for any storage declaring a `path`
# property (PVE::Storage, $volname_for_storage), and the plugin used to feed
# that directory-style name straight into parse_volname, which rejected it —
# every import into JovianDSS storage died with "unable to parse joviandss
# volume name '103/vm-103-disk-0.raw'".  The volname-reduction cases below
# pin that fix down.
#
# The other contract worth pinning is failure cleanup: a partially imported
# volume must never survive a failed import, and a failed export must not
# leave the volume attached — while a cleanup step that itself fails must
# surface loudly rather than be swallowed.
#
# Self-contained: PVE modules, String::Util and JSON are stubbed; the
# plugin's own locking/allocation/activation internals are swapped for
# recording doubles, so no cluster, no JovianDSS appliance and no root are
# needed.  Runs anywhere perl does.  From the repo root:
#
#     perl tests/volume_export_import_test.pl
#
# Scope: orchestration AND the byte-moving path — the cooperative copy loop
# runs for real against temp files, so stream contents, bounded reads and
# premature-EOF handling are verified here.  Only blockdev sizing and the
# real iSCSI device path still need the live drive (see .claude/skills/verify).

use strict;
use warnings;

use File::Temp ();
use FindBin ();
use lib "$FindBin::Bin/..";

BEGIN {
    $INC{'String/Util.pm'}        = __FILE__;
    $INC{'PVE/INotify.pm'}        = __FILE__;
    $INC{'PVE/Tools.pm'}          = __FILE__;
    $INC{'PVE/Cluster.pm'}        = __FILE__;
    $INC{'PVE/Storage.pm'}        = __FILE__;
    $INC{'PVE/Storage/Plugin.pm'} = __FILE__;
    $INC{'JSON.pm'}               = __FILE__;
}
{
    # Imported but unused on the paths under test.
    package String::Util;
    sub import { }
}
{
    package PVE::INotify;
    sub import   { }
    sub nodename { 'testnode' }
}
{
    package PVE::Cluster;
    sub import { }
}
{
    package PVE::Tools;
    # The plugin binds run_command at compile time, so the exported sub must
    # stay a stable trampoline; tests swap the body via $RUN_COMMAND.
    our $RUN_COMMAND = sub { 0 };
    our $IPV4RE      = qr/\d+\.\d+\.\d+\.\d+/;
    our $IPV6RE      = qr/[0-9a-fA-F:]+/;

    sub run_command       { return $RUN_COMMAND->(@_) }
    sub file_set_contents { }
    sub run_with_timeout  { my ( $t, $code, @a ) = @_; return $code->(@a) }

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::run_command"}       = \&run_command;
        *{"${caller}::file_set_contents"} = \&file_set_contents;
        ${"${caller}::IPV4RE"}            = $IPV4RE;
        ${"${caller}::IPV6RE"}            = $IPV6RE;
    }
}
{
    package JSON;
    use JSON::PP ();
    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::decode_json"} = \&JSON::PP::decode_json;
        *{"${caller}::from_json"}   = \&JSON::PP::decode_json;
        *{"${caller}::to_json"}     = \&JSON::PP::encode_json;
    }
}
{
    package PVE::Storage;
    use constant APIVER    => 12;
    use constant APIAGE    => 3;
    sub import { }
}
{
    package PVE::Storage::Plugin;
    sub import { }

    # Stream header helpers: the real ones sys{write,read} a little-endian
    # u64 size.  Tests record what the plugin writes and dictate what it
    # reads.
    our @HEADERS_WRITTEN;
    our $HEADER_SIZE = 0;

    sub write_common_header {
        my ( $fh, $size ) = @_;
        push @HEADERS_WRITTEN, $size;
        return;
    }
    sub read_common_header { return $HEADER_SIZE }
}

# The plugin lives at the repo root but declares a PVE::Storage::Custom::
# package, so it is loaded by path rather than by module name.
BEGIN { require "$FindBin::Bin/../OpenEJovianDSSPlugin.pm"; }

my $PLUGIN = 'PVE::Storage::Custom::OpenEJovianDSSPlugin';

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

my ( $tests, $failures ) = ( 0, 0 );

sub ok {
    my ( $cond, $name ) = @_;
    $tests++;
    if ($cond) {
        print "ok ${tests} - ${name}\n";
    } else {
        $failures++;
        print "NOT OK ${tests} - ${name}\n";
    }
    return $cond;
}

sub is {
    my ( $got, $want, $name ) = @_;
    $got  = '<undef>' if !defined $got;
    $want = '<undef>' if !defined $want;
    my $cond = ( $got eq $want );
    ok( $cond, $name ) or print "    got:  '${got}'\n    want: '${want}'\n";
    return $cond;
}

sub is_deeply_list {
    my ( $got, $want, $name ) = @_;
    my $g = join( ',', map { defined $_ ? $_ : '<undef>' } @$got );
    my $w = join( ',', map { defined $_ ? $_ : '<undef>' } @$want );
    return is( $g, $w, $name );
}

sub like {
    my ( $got, $re, $name ) = @_;
    $got = '<undef>' if !defined $got;
    my $cond = ( $got =~ $re );
    ok( $cond, $name ) or print "    got:   '${got}'\n    match: ${re}\n";
    return $cond;
}

# ---------------------------------------------------------------------------
# Doubles for the plugin internals the export/import paths call
# ---------------------------------------------------------------------------
#
# @CALLS records every internal step in order, so the tests can assert both
# that a step ran and where it ran relative to the others (cleanup ordering
# is a large part of what is under test).

our @CALLS;
our %BEHAVIOUR;      # step name => coderef | 'die:<message>'
our $DEVICE_PATH;    # what _path() resolves to — a real temp file, so the
                     # cooperative copy loop moves actual bytes in the tests

sub reset_state {
    @CALLS                                   = ();
    %BEHAVIOUR                               = ();
    @PVE::Storage::Plugin::HEADERS_WRITTEN   = ();
    $PVE::Storage::Plugin::HEADER_SIZE       = 0;
    $PVE::Tools::RUN_COMMAND                 = sub { 0 };
    ( undef, $DEVICE_PATH ) = File::Temp::tempfile( UNLINK => 1 );
}

sub device_write {
    my ($data) = @_;
    open( my $f, '>', $DEVICE_PATH ) or die "device_write: $!\n";
    binmode $f;
    print {$f} $data;
    close $f;
}

sub device_read {
    open( my $f, '<', $DEVICE_PATH ) or die "device_read: $!\n";
    binmode $f;
    local $/;
    my $data = <$f>;
    close $f;
    return $data // '';
}

sub step_names { return map { $_->{step} } @CALLS }

sub calls_named {
    my ($step) = @_;
    return grep { $_->{step} eq $step } @CALLS;
}

# Record a step, then apply whatever behaviour the test configured for it.
# The step key is deliberately 'step', not 'name': alloc records a 'name'
# argument of its own.
sub record {
    my ( $step, %args ) = @_;
    push @CALLS, { %args, step => $step };
    my $behaviour = $BEHAVIOUR{$step};
    return if !defined $behaviour;
    if ( ref $behaviour eq 'CODE' ) {
        return $behaviour->(%args);
    }
    if ( $behaviour =~ /^die:(.*)$/s ) {
        die "$1\n";
    }
    return $behaviour;
}

{
    no warnings 'redefine';
    no strict 'refs';

    # ctx: the export/import paths only ever read storeid out of it.
    *{"${PLUGIN}::new_ctx"} = sub {
        my ( $scfg, $storeid ) = @_;
        return { scfg => $scfg, storeid => $storeid, reqid => 'test' };
    };
    *{"${PLUGIN}::debugmsg"}       = sub { };
    *{"OpenEJovianDSS::Common::debugmsg"} = sub { };
    *{"${PLUGIN}::safe_var_print"} = sub {
        my ( $label, $value ) = @_;
        return defined $value ? "${label} ${value}" : '';
    };

    # Per-step locking lives inside these wrappers (shared with every other
    # plugin method), so the doubles replace the wrappers themselves; the
    # export/import top level must hold no lock of its own.
    *{"${PLUGIN}::_activate_volume_lock"} = sub {
        my ( $class, $ctx, $volname, $snapname, $cache ) = @_;
        return record( 'activate', volname => $volname, snapname => $snapname );
    };
    *{"${PLUGIN}::_deactivate_volume_lock"} = sub {
        my ( $class, $ctx, $volname, $snapname, $cache, $hints ) = @_;
        return record( 'deactivate', volname => $volname, snapname => $snapname );
    };
    *{"${PLUGIN}::_alloc_image_lock"} = sub {
        my ( $class, $ctx, $vmid, $fmt, $name, $size ) = @_;
        return record( 'alloc', vmid => $vmid, fmt => $fmt, name => $name, size => $size );
    };
    *{"${PLUGIN}::_free_image_lock"} = sub {
        my ( $class, $ctx, $volname, $isBase, $format ) = @_;
        return record( 'free', volname => $volname );
    };
    *{"${PLUGIN}::_path"} = sub {
        my ( $class, $ctx, $volname, $snapname ) = @_;
        record( 'path', volname => $volname, snapname => $snapname );
        return [ $DEVICE_PATH, 990001, 'images' ];
    };

    # The copy loop's cooperation point; recorded so the cadence tests can
    # see it.  Flow tests never reach the default 10 s interval.
    *{"OpenEJovianDSS::Lock::refresh_locks"} = sub { record('refresh') };

    # jdssc round-trips are outside this suite's scope; the size query used
    # by volume_size_info answers a fixed volume size.
    *{"${PLUGIN}::joviandss_cmd"} = sub { return "1073741824\n"; };
}

# run_command double: answers blockdev --getsize64 through outfunc and
# emulates GNU dd faithfully enough for the slice loop — byte-addressed
# skip/seek, count in bytes, short read at stream EOF, and the trailing
# "N bytes ... copied" stderr line the loop parses.
sub install_run_command {
    my (%opt) = @_;
    my $size = exists $opt{size} ? $opt{size} : '1073741824';
    $PVE::Tools::RUN_COMMAND = sub {
        my ( $cmd, %params ) = @_;
        if ( $cmd->[0] =~ m!blockdev$! ) {
            record( 'blockdev', cmd => $cmd );
            $params{outfunc}->($size) if $params{outfunc} && defined $size;
            return 0;
        }
        if ( $cmd->[0] eq 'dd' ) {
            record( 'dd', cmd => $cmd, params => \%params );
            my %arg =
              map { m/^([a-z]+)=(.*)$/ ? ( $1 => $2 ) : () } @{$cmd}[ 1 .. $#$cmd ];
            my $data = '';
            if ( defined $arg{if} ) {    # device -> stream
                open( my $in, '<', $arg{if} )
                  or die "dd: failed to open '$arg{if}': $!\n";
                binmode $in;
                sysread( $in, $data, -s $arg{if} );
                close $in;
                $params{output} =~ m/^>&(\d+)$/ or die "dd emu: bad output\n";
                open( my $out, '>&', $1 ) or die "dd emu dup: $!\n";
                syswrite( $out, $data );
                close $out;
            }
            else {                       # stream -> device: read to EOF
                open( my $out, '+<', $arg{of} )
                  or die "dd: failed to open '$arg{of}': No such file or directory\n";
                binmode $out;
                $params{input} =~ m/^<&(\d+)$/ or die "dd emu: bad input\n";
                open( my $in, '<&', $1 ) or die "dd emu dup: $!\n";
                while ( ( my $r = sysread( $in, my $b, 65536 ) ) ) {
                    die "dd emu read: $!\n" if !defined $r;
                    $data .= $b;
                }
                close $in;
                syswrite( $out, $data );
                close $out;
            }
            my $n = length($data);
            $params{errfunc}->("${n} bytes (${n} B) copied, 0.0 s, 1.0 MB/s")
              if $params{errfunc};
            return 0;
        }
        return record( 'run_command', cmd => $cmd );
    };
}

my $SCFG = {
    pool_name => 'Pool-0',
    path      => '/mnt/pve/jdss-test',
    content   => { images => 1 },
};

sub scratch_fh {
    my $buffer = '';
    open( my $fh, '+>', \$buffer ) or die "cannot open in-memory fh: $!\n";
    return $fh;
}

# Stream handles must be real files: the cooperative copy uses sysread/
# syswrite, which bypass PerlIO and fail with EBADF on in-memory scalar
# handles (production always hands real fds — sockets or a dup'd stdout).
sub stream_in {
    my ($data) = @_;
    my ( $fh, $path ) = File::Temp::tempfile( UNLINK => 1 );
    binmode $fh;
    print {$fh} $data;
    close $fh;
    open( my $in, '<', $path ) or die "stream_in: $!\n";
    binmode $in;
    return $in;
}

sub stream_out {
    my ( $fh, $path ) = File::Temp::tempfile( UNLINK => 1 );
    binmode $fh;
    return ( $fh, $path );
}

sub slurp {
    my ($path) = @_;
    open( my $f, '<', $path ) or die "slurp: $!\n";
    binmode $f;
    local $/;
    my $data = <$f>;
    close $f;
    return $data // '';
}

# ---------------------------------------------------------------------------
# volume_export_formats / volume_import_formats
# ---------------------------------------------------------------------------
# A raw stream carries exactly one point-in-time state.  Offering raw+size
# for a request that needs snapshot history would make PVE start a transfer
# that silently loses the snapshots, so both functions must return the empty
# list there and let PVE report "no matching import/export format".

print "# volume_export_formats / volume_import_formats\n";

for my $spec (
    [ 'export', 'volume_export_formats' ],
    [ 'import', 'volume_import_formats' ],
  )
{
    my ( $label, $method ) = @$spec;

    my @plain = $PLUGIN->$method( $SCFG, 'jdss', 'vm-100-disk-0', undef, undef, 0 );
    is_deeply_list( \@plain, ['raw+size'], "${label}_formats: plain volume offers raw+size" );

    my @snap = $PLUGIN->$method( $SCFG, 'jdss', 'vm-100-disk-0', 'snap1', undef, 0 );
    is_deeply_list( \@snap, ['raw+size'],
        "${label}_formats: a single named snapshot is still one raw state" );

    my @hist = $PLUGIN->$method( $SCFG, 'jdss', 'vm-100-disk-0', undef, undef, 1 );
    is_deeply_list( \@hist, [], "${label}_formats: with_snapshots offers nothing" );

    my @incr = $PLUGIN->$method( $SCFG, 'jdss', 'vm-100-disk-0', 'snap2', 'snap1', 0 );
    is_deeply_list( \@incr, [], "${label}_formats: incremental (base_snapshot) offers nothing" );
}

# Format negotiation with the PVE-composed directory-style volname — the
# exact call PVE core makes on the import side before an offline migration
# (volume_import_start): must answer raw+size, not die in parse_volname.
{
    my @f = $PLUGIN->volume_import_formats( $SCFG, 'jdss',
        '990001/vm-990001-disk-0.raw', undef, undef, 0 );
    is_deeply_list( \@f, ['raw+size'],
        'import_formats: PVE-composed volname negotiates raw+size' );

    my @e = $PLUGIN->volume_export_formats( $SCFG, 'jdss',
        '990001/vm-990001-disk-0.raw', undef, undef, 0 );
    is_deeply_list( \@e, ['raw+size'],
        'export_formats: PVE-composed volname negotiates raw+size' );
}

# ---------------------------------------------------------------------------
# volume_export
# ---------------------------------------------------------------------------

print "# volume_export\n";

# Refusals happen before any storage is touched: a rejected request must not
# have activated anything.
{
    reset_state();
    install_run_command();
    eval {
        $PLUGIN->volume_export( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'zfs', undef, undef, 0 );
    };
    like( $@, qr/format 'zfs' not available/, 'export: unknown stream format is refused' );
    is( scalar(@CALLS), 0, 'export: refused format touches no storage' );
}

{
    reset_state();
    install_run_command();
    eval {
        $PLUGIN->volume_export( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 1 );
    };
    like( $@, qr/cannot export volume snapshot history/,
        'export: with_snapshots is refused' );
    is( scalar(@CALLS), 0, 'export: refused history request touches no storage' );
}

{
    reset_state();
    install_run_command();
    eval {
        $PLUGIN->volume_export( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', 'snap2', 'snap1', 0 );
    };
    like( $@, qr/cannot export volume snapshot history/,
        'export: incremental stream is refused' );
}

# Happy path: the copy loop must move the device's exact bytes into the
# stream, after a header carrying the exact device size.
{
    reset_state();
    my $payload = pack( 'C*', map { $_ % 251 } 1 .. 8192 );
    device_write($payload);
    install_run_command( size => length($payload) );
    my ( $stream, $streampath ) = stream_out();
    $PLUGIN->volume_export( $SCFG, 'jdss', $stream, 'vm-100-disk-0',
        'raw+size', undef, undef, 0 );

    is_deeply_list( [ step_names() ],
        [ 'activate', 'path', 'blockdev', 'dd', 'deactivate' ],
        'export: one unlocked dd run between the locked steps' );

    my ($dd) = calls_named('dd');
    ok( !defined( $dd->{params}->{timeout} ),
        'export: the copy has no timeout — transfer duration is unbounded' );
    ok( ( grep { $_ eq 'status=progress' } @{ $dd->{cmd} } ),
        'export: dd reports progress, upstream style' );

    is( $PVE::Storage::Plugin::HEADERS_WRITTEN[0], length($payload),
        'export: stream header carries the device size' );
    ok( slurp($streampath) eq $payload, 'export: the stream carries the device bytes' );
}

# Snapshot export: activation publishes a clone, so every step must carry the
# snapshot name through — a dropped snapname would silently export live data
# in place of the requested point in time.
{
    reset_state();
    device_write( 'S' x 8 );
    install_run_command( size => 8 );
    my ( $stream, undef ) = stream_out();
    $PLUGIN->volume_export( $SCFG, 'jdss', $stream, 'vm-100-disk-0',
        'raw+size', 'snap1', undef, 0 );

    my ($activate) = calls_named('activate');
    my ($path)     = calls_named('path');
    my ($deact)    = calls_named('deactivate');
    is( $activate->{snapname}, 'snap1', 'export: activation receives the snapshot' );
    is( $path->{snapname},     'snap1', 'export: path resolves the snapshot clone' );
    is( $deact->{snapname},    'snap1', 'export: deactivation releases the snapshot' );
}

# A size that cannot be determined must abort before writing a header — a
# raw+size stream with a wrong size is unusable at the far end.  The device
# answer (blockdev) is primary and the jdssc size query is the fallback, so
# the abort requires BOTH to fail.
{
    reset_state();
    install_run_command( size => undef );
    no strict 'refs';
    no warnings 'redefine';
    local *{"${PLUGIN}::joviandss_cmd"} = sub { return "unknown\n"; };
    eval {
        $PLUGIN->volume_export( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 0 );
    };
    like( $@, qr/unable to determine size/, 'export: unreadable size aborts' );
    is( scalar( @PVE::Storage::Plugin::HEADERS_WRITTEN ),
        0, 'export: no header is written when the size is unknown' );
    is( scalar( calls_named('deactivate') ),
        1, 'export: the volume is deactivated after a size failure' );
}

# A garbage device answer alone must NOT abort: the size falls back to the
# jdssc query (the global double answers 1073741824) and the export runs.
{
    reset_state();
    my $payload = 'F' x 16;
    device_write($payload);
    install_run_command( size => 'not-a-number' );
    my ( $stream, $streampath ) = stream_out();
    $PLUGIN->volume_export( $SCFG, 'jdss', $stream, 'vm-100-disk-0',
        'raw+size', undef, undef, 0 );
    is( $PVE::Storage::Plugin::HEADERS_WRITTEN[0], '1073741824',
        'export: non-numeric device size falls back to the jdssc size' );
    ok( slurp($streampath) eq $payload,
        'export: the fallback-sized stream still carries the device bytes' );
}

# Copy failure (device cannot be opened): the volume must not stay attached,
# and the original error — not the cleanup's outcome — is what the caller sees.
{
    reset_state();
    install_run_command();
    $DEVICE_PATH = '/nonexistent-joviandss-test/dev0';
    eval {
        $PLUGIN->volume_export( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 0 );
    };
    like( $@, qr/failed to open/, 'export: copy failure propagates' );
    is( scalar( calls_named('deactivate') ),
        1, 'export: the volume is deactivated after a copy failure' );
}

# A cleanup step that fails must be loud: silently swallowing it would leave
# the volume attached with nothing in the caller's output to say so.
{
    reset_state();
    install_run_command( size => 0 );
    $BEHAVIOUR{deactivate} = 'die:volume is busy';
    my ( $stream, undef ) = stream_out();
    eval {
        $PLUGIN->volume_export( $SCFG, 'jdss', $stream, 'vm-100-disk-0',
            'raw+size', undef, undef, 0 );
    };
    like( $@, qr/volume is busy/, 'export: a failing deactivation is reported' );
}

# ---------------------------------------------------------------------------
# volume_import
# ---------------------------------------------------------------------------

print "# volume_import\n";

{
    reset_state();
    install_run_command();
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'zfs', undef, undef, 0, 0 );
    };
    like( $@, qr/format 'zfs' not available/, 'import: unknown stream format is refused' );
    is( scalar(@CALLS), 0, 'import: refused format allocates nothing' );
}

{
    reset_state();
    install_run_command();
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 1, 0 );
    };
    like( $@, qr/cannot import volumes together with their snapshots/,
        'import: with_snapshots is refused' );
}

# THE regression: PVE hands the plugin a directory-style volname because the
# storage declares `path`.  It must be reduced to a plain JovianDSS name
# rather than rejected by parse_volname.
{
    reset_state();
    install_run_command();
    $PVE::Storage::Plugin::HEADER_SIZE = 16;
    # eval-guarded: the regression this pins down manifests as a die out of
    # parse_volname, which would otherwise abort the whole run here.
    my $volid = eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', stream_in( 'J' x 16 ),
            '990001/vm-990001-disk-0.raw', 'raw+size', undef, undef, 0, 0 );
    };
    is( $@, '', 'import: PVE-composed "vmid/name.raw" volname is accepted' );

    my ($alloc) = calls_named('alloc');
    is( $alloc ? $alloc->{name} : undef, 'vm-990001-disk-0.raw',
        'import: the requested file name is preserved verbatim, suffix included' );

    # The reduction lives in parse_volname itself (the plugin's single
    # name-interpretation point), so every entry point accepts the form.
    my ( $pv_type, $pv_name, $pv_vmid ) =
      PVE::Storage::Custom::OpenEJovianDSSPlugin->parse_volname('990001/vm-990001-disk-0.raw');
    is( $pv_type, 'images',           'parse_volname: composed name classifies as images' );
    is( $pv_name, 'vm-990001-disk-0.raw', 'parse_volname: only the directory component is dropped' );
    is( $pv_vmid, 990001,             'parse_volname: vmid extracted from the name' );

    # The .raw strip is tied to the directory form: a plain volname ending
    # in .raw is a literal volume name and must survive untouched.
    my ( undef, $raw_name ) =
      PVE::Storage::Custom::OpenEJovianDSSPlugin->parse_volname('vm-990001-disk-0.raw');
    is( $raw_name, 'vm-990001-disk-0.raw',
        'parse_volname: plain name ending in .raw is not aliased' );

    my ( undef, $noext_name ) =
      PVE::Storage::Custom::OpenEJovianDSSPlugin->parse_volname('990001/vm-990001-disk-7');
    is( $noext_name, 'vm-990001-disk-7',
        'parse_volname: directory form without suffix still reduces' );
    is( $alloc ? $alloc->{vmid} : undef, 990001,
        'import: vmid is taken from the parsed name' );
    is( $volid, 'jdss:vm-990001-disk-0.raw',
        'import: the volid carries the name exactly as requested' );
}

{
    reset_state();
    install_run_command();
    my $volid = eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', stream_in(''),
            'vm-990001-disk-0', 'raw+size', undef, undef, 0, 0 );
    };
    is( $@, '', 'import: a plain volname is accepted' );
    my ($alloc) = calls_named('alloc');
    is( $alloc ? $alloc->{name} : undef, 'vm-990001-disk-0',
        'import: a plain volname is used as-is' );
    is( $volid, 'jdss:vm-990001-disk-0', 'import: plain volname returns the same volid' );
}

# A volume requested under a .raw-suffixed name keeps the suffix end to end:
# the suffix is part of the requested name, not a decoration to normalize
# away, so the allocated volume and the returned volid carry it verbatim.
{
    reset_state();
    install_run_command();
    $PVE::Storage::Plugin::HEADER_SIZE = 16;
    my $volid = eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', stream_in( 'R' x 16 ),
            'vm-990001-disk-2.raw', 'raw+size', undef, undef, 0, 0 );
    };
    is( $@, '', 'import: a plain .raw-suffixed volname is accepted' );
    my ($alloc) = calls_named('alloc');
    is( $alloc ? $alloc->{name} : undef, 'vm-990001-disk-2.raw',
        'import: the .raw suffix is kept in the allocated name' );
    is( $volid, 'jdss:vm-990001-disk-2.raw',
        'import: the .raw suffix is kept in the returned volid' );
}

# Only image volumes live as zvols; other content types have no device to
# stream into and must be refused before anything is allocated.
{
    reset_state();
    install_run_command();
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', scratch_fh(),
            'iso/debian-12.iso', 'raw+size', undef, undef, 0, 0 );
    };
    like( $@, qr/cannot import volume type 'iso'/, 'import: non-image content is refused' );
    is( scalar( calls_named('alloc') ), 0, 'import: refused content allocates nothing' );
}

# The stream header is in bytes, allocation is in KiB: a partial trailing KiB
# must round up, or the imported volume is short and the copy overruns it.
{
    my @cases = (
        [ 1048576, 1024, 'exact MiB size' ],
        [ 1024,    1,    'exactly one KiB' ],
        [ 1025,    2,    'one byte over a KiB rounds up' ],
        [ 1,       1,    'a single byte still needs one KiB' ],
    );
    for my $case (@cases) {
        my ( $bytes, $want_kib, $label ) = @$case;
        reset_state();
        install_run_command();
        $PVE::Storage::Plugin::HEADER_SIZE = $bytes;
        $PLUGIN->volume_import( $SCFG, 'jdss', stream_in( 'x' x $bytes ),
            'vm-100-disk-0', 'raw+size', undef, undef, 0, 0 );
        my ($alloc) = calls_named('alloc');
        is( $alloc->{size}, $want_kib, "import: ${label} allocates ${want_kib} KiB" );
    }
}

# Happy path ordering: allocate, attach, copy, detach — and emphatically no
# free_image, which would delete the volume that was just imported.  The
# device must end up holding exactly the streamed bytes.
{
    reset_state();
    install_run_command();
    my $payload = pack( 'C*', map { ( $_ * 7 ) % 256 } 1 .. 4096 );
    $PVE::Storage::Plugin::HEADER_SIZE = length($payload);
    $PLUGIN->volume_import( $SCFG, 'jdss', stream_in($payload), 'vm-100-disk-0',
        'raw+size', undef, undef, 0, 0 );

    is_deeply_list( [ step_names() ],
        [ 'alloc', 'activate', 'path', 'dd', 'deactivate' ],
        'import: one unlocked dd run between the locked steps' );
    is( scalar( calls_named('free') ), 0, 'import: a successful import frees nothing' );
    ok( device_read() eq $payload, 'import: the device holds exactly the streamed bytes' );

    my ($dd) = calls_named('dd');
    ok( ( grep { $_ eq 'conv=sparse,notrunc,fsync' } @{ $dd->{cmd} } ),
        'import: dd skips zero blocks to keep thin volumes thin' );
    ok( !( grep { m/^count=/ } @{ $dd->{cmd} } ),
        'import: the stream is read to EOF, upstream style — no byte bound' );
}

# Name collision without allow_rename: the caller asked for a specific name,
# so the failure must surface rather than land somewhere unexpected.
{
    reset_state();
    install_run_command();
    $BEHAVIOUR{alloc} = 'die:volume vm-100-disk-0 already exists';
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 0, 0 );
    };
    like( $@, qr/already exists/, 'import: name collision fails without allow_rename' );
    is( scalar( calls_named('alloc') ), 1, 'import: no retry without allow_rename' );
}

# With allow_rename PVE explicitly permits a different name: retry with an
# auto-selected one and report the name actually used.
{
    reset_state();
    install_run_command();
    my $attempt = 0;
    $BEHAVIOUR{alloc} = sub {
        my (%args) = @_;
        $attempt++;
        die "volume already exists\n" if $attempt == 1;
        return 'vm-100-disk-7';
    };
    my @warnings;
    local $SIG{__WARN__} = sub { push @warnings, @_; };
    my $volid = $PLUGIN->volume_import( $SCFG, 'jdss', stream_in(''), 'vm-100-disk-0',
        'raw+size', undef, undef, 0, 1 );
    like( $warnings[0], qr/already exists - importing with a different name/,
        'import: renaming leaves an operator-visible breadcrumb (upstream style)' );

    my @allocs = calls_named('alloc');
    is( scalar(@allocs), 2, 'import: allow_rename retries the allocation' );
    is( $allocs[1]->{name}, undef,
        'import: the retry asks the plugin to pick a free name' );
    is( $volid, 'jdss:vm-100-disk-7', 'import: the volid reports the renamed volume' );

    my ($activate) = calls_named('activate');
    is( $activate->{volname}, 'vm-100-disk-7',
        'import: the renamed volume is the one attached' );
}

# allow_rename covers name collisions only — any other allocation failure
# (out of space, unreachable appliance) must not be retried under a new name.
{
    reset_state();
    install_run_command();
    $BEHAVIOUR{alloc} = 'die:pool Pool-0 is out of space';
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 0, 1 );
    };
    like( $@, qr/out of space/, 'import: a non-collision alloc failure is not retried' );
    is( scalar( calls_named('alloc') ), 1, 'import: no retry for unrelated alloc errors' );
}

# Failure after allocation must not leave a half-imported volume behind:
# whatever was created is removed, and the original error is what surfaces.
{
    reset_state();
    install_run_command();
    $BEHAVIOUR{activate} = 'die:no path to target';
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 0, 0 );
    };
    like( $@, qr/no path to target/, 'import: attach failure propagates' );
    is_deeply_list( [ step_names() ], [ 'alloc', 'activate', 'free' ],
        'import: an unattachable volume is freed, not left behind' );
}

{
    reset_state();
    install_run_command();
    $DEVICE_PATH = '/nonexistent-joviandss-test/dev0';
    $PVE::Storage::Plugin::HEADER_SIZE = 16;
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', stream_in( 'x' x 16 ), 'vm-100-disk-0',
            'raw+size', undef, undef, 0, 0 );
    };
    like( $@, qr/failed to open/, 'import: copy failure propagates' );
    is_deeply_list( [ step_names() ],
        [ 'alloc', 'activate', 'path', 'dd', 'deactivate' ],
        'import: a failed copy detaches the volume; the partial volume is kept' );
}

# EOF semantics (adopted from the upstream implementation): the stream is
# read until the sender closes it.  The header communicates the size for
# allocation; the copy itself is not byte-bounded, so a short stream imports
# short and succeeds — exactly as PVE::Storage::Plugin behaves.
{
    reset_state();
    install_run_command();
    $PVE::Storage::Plugin::HEADER_SIZE = 2048;
    my $volid = $PLUGIN->volume_import( $SCFG, 'jdss', stream_in( 'y' x 1024 ),
        'vm-100-disk-0', 'raw+size', undef, undef, 0, 0 );
    is( $volid, 'jdss:vm-100-disk-0',
        'import: a short stream imports to EOF and succeeds (upstream semantics)' );
    ok( device_read() eq ( 'y' x 1024 ),
        'import: the device holds what the stream delivered' );
}

# As on the export side, a failing cleanup step must be reported rather than
# swallowed — a volume that could not be detached or freed is a leak the
# operator needs to hear about.
{
    reset_state();
    install_run_command();
    $DEVICE_PATH           = '/nonexistent-joviandss-test/dev0';
    $PVE::Storage::Plugin::HEADER_SIZE = 16;
    $BEHAVIOUR{deactivate} = 'die:device is busy';
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', stream_in( 'x' x 16 ), 'vm-100-disk-0',
            'raw+size', undef, undef, 0, 0 );
    };
    like( $@, qr/device is busy/, 'import: a failing detach during cleanup is reported' );
}

{
    reset_state();
    install_run_command();
    $BEHAVIOUR{deactivate} = 'die:device is busy';
    eval {
        $PLUGIN->volume_import( $SCFG, 'jdss', scratch_fh(), 'vm-100-disk-0',
            'raw+size', undef, undef, 0, 0 );
    };
    like( $@, qr/device is busy/,
        'import: a failing detach on the success path is reported' );
}

# ---------------------------------------------------------------------------
# data_copy directly
# ---------------------------------------------------------------------------
# A single unlocked dd run per direction, upstream-style: stream read/written
# to EOF, progress on the export side only, bs from the data_copy_bs
# property.

print "# data_copy\n";

{
    reset_state();
    install_run_command();
    my $data = 'z' x ( 2 * 1024 * 1024 + 512 * 1024 );
    OpenEJovianDSS::Common::data_copy(
        { scfg => {} }, stream_in($data), $DEVICE_PATH );

    ok( device_read() eq $data, 'data_copy: destination matches source' );
    is( scalar( calls_named('dd') ), 1, 'data_copy: a single dd run moves everything' );
    is( scalar( calls_named('refresh') ), 0,
        'data_copy: no lock refreshes — the copy holds no lock' );
}

{
    reset_state();
    install_run_command();
    OpenEJovianDSS::Common::data_copy(
        { scfg => { data_copy_bs => '1M' } }, stream_in( 'w' x 8 ), $DEVICE_PATH );
    my ($dd) = calls_named('dd');
    ok( ( grep { $_ eq 'bs=1M' } @{ $dd->{cmd} } ),
        'data_copy: data_copy_bs reaches dd' );
}

{
    reset_state();
    install_run_command();
    eval {
        OpenEJovianDSS::Common::data_copy(
            { scfg => { data_copy_bs => '; rm -rf /' } },
            stream_in( 'w' x 8 ), $DEVICE_PATH );
    };
    like( $@, qr/invalid data_copy_bs/, 'data_copy: malformed bs is refused' );
    is( scalar( calls_named('dd') ), 0, 'data_copy: malformed bs never reaches dd' );
}

{
    reset_state();
    device_write( 'E' x 4096 );
    install_run_command();
    my ( $stream, $streampath ) = stream_out();
    OpenEJovianDSS::Common::data_copy( { scfg => {} }, $DEVICE_PATH, $stream );
    ok( slurp($streampath) eq ( 'E' x 4096 ),
        'data_copy: export direction streams the device bytes' );
    my ($dd) = calls_named('dd');
    ok( ( grep { $_ eq 'status=progress' } @{ $dd->{cmd} } ),
        'data_copy: export dd reports progress, upstream style' );
}

# ---------------------------------------------------------------------------
# volume_size_info list contract
# ---------------------------------------------------------------------------
# PVE consumes volume_size_info in list context as ($size, $format, $used,
# $parent) — e.g. QemuMigrate derives the snapshots flag from $format. A
# scalar-only return leaves $format undef there (the "uninitialized value
# in pattern match at QemuMigrate.pm" warning per disk).

print "# volume_size_info\n";

{
    my @info = $PLUGIN->volume_size_info( $SCFG, 'jdss', 'vm-990001-disk-0' );
    is( $info[0], 1073741824, 'volume_size_info: size in list context' );
    is( $info[1], 'raw',      'volume_size_info: format is raw, never undef' );
    ok( defined $info[2],     'volume_size_info: used is defined' );

    ok( !defined $info[3], 'volume_size_info: plain volume has no parent' );

    my @clone_info = $PLUGIN->volume_size_info( $SCFG, 'jdss',
        'base-990001-disk-0/vm-990001-disk-1' );
    is( $clone_info[3], 'base-990001-disk-0',
        'volume_size_info: linked-clone volname reports its base as parent' );

    my $size = $PLUGIN->volume_size_info( $SCFG, 'jdss', 'vm-990001-disk-0' ) + 0;
    is( $size, 1073741824, 'volume_size_info: scalar context returns the size' );
}

# ---------------------------------------------------------------------------

print "\n1..${tests}\n";
if ($failures) {
    print "FAILED ${failures}/${tests}\n";
    exit 1;
}
print "PASSED ${tests}/${tests}\n";
exit 0;
