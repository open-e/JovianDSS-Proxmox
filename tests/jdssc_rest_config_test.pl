#!/usr/bin/perl

# Unit tests for the jdssc REST resilience knobs:
#
#   jdssc_rest_request_send_cycle_attempts          how many times jdssc
#                                                   cycles the control
#                                                   addresses for one request
#   jdssc_rest_request_send_cycle_delay             seconds slept between
#                                                   those cycles
#   jdssc_rest_send_retry_on_decode_error_attempts  attempts at a single send
#                                                   when the appliance answers
#                                                   with undecodable JSON
#   jdssc_rest_connect_timeout                      seconds to establish a TCP
#                                                   connection to one control
#                                                   address
#   jdssc_rest_read_timeout                         seconds of silence allowed
#                                                   between bytes of a
#                                                   response already arriving
#
# These values were hardcoded in jdssc's REST proxy (17 / 3 / 5, and a single
# 570 s scalar covering both timeout phases) before they became storage.cfg
# properties. The contract this suite pins:
#
#   * an entry that sets none of them keeps exactly the old behaviour, because
#     every getter falls back to its constant;
#   * a configured value is honoured, including 0 for the delay - the getter
#     must not use '||', which would silently turn 0 back into 3;
#   * the declared schema default equals the constant, so the value the API
#     advertises is the value the code uses.
#
# The end-to-end half - the properties reaching the jdssc command line - lives
# in pve-testing/testcases/iscsi-plugin/config-change/ and nfs-plugin/config-change/.

use strict;
use warnings;

use FindBin ();
use lib "$FindBin::Bin/..";

BEGIN {
    $INC{'String/Util.pm'}        = __FILE__;
    $INC{'Net/IP.pm'}             = __FILE__;
    $INC{'IO/File.pm'}            = __FILE__;
    $INC{'PVE/Network.pm'}        = __FILE__;
    $INC{'PVE/ProcFSTools.pm'}    = __FILE__;
    $INC{'PVE/INotify.pm'}        = __FILE__;
    $INC{'PVE/Tools.pm'}          = __FILE__;
    $INC{'PVE/Cluster.pm'}        = __FILE__;
    $INC{'PVE/Storage.pm'}        = __FILE__;
    $INC{'PVE/Storage/Plugin.pm'} = __FILE__;
    $INC{'PVE/Storage/DirPlugin.pm'} = __FILE__;
    $INC{'PVE/JSONSchema.pm'}     = __FILE__;
    $INC{'JSON.pm'}               = __FILE__;
}
{
    # Imported but unused on the paths under test.
    package String::Util;
    sub import { }
}
{
    # Required by the NFS plugin only; unused on the paths under test.
    package Net::IP;
    sub import { }
}
{
    package IO::File;
    sub import { }
}
{
    package PVE::Network;
    sub import { }
}
{
    package PVE::ProcFSTools;
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
    our $RUN_COMMAND = sub { die "unexpected run_command in this suite\n" };
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
    use constant APIVER => 15;
    use constant APIAGE => 6;
    sub import { }
}
{
    package PVE::Storage::Plugin;
    sub import { }
}
{
    package PVE::Storage::DirPlugin;
    sub import { }
}
{
    package PVE::JSONSchema;
    sub get_standard_option { return {} }

    sub import {
        my $caller = caller;
        no strict 'refs';
        *{"${caller}::get_standard_option"} = \&get_standard_option;
    }
}

BEGIN { require "$FindBin::Bin/../OpenEJovianDSSPlugin.pm"; }
BEGIN { require "$FindBin::Bin/../OpenEJovianDSSNFSPlugin.pm"; }

my $PLUGIN     = 'PVE::Storage::Custom::OpenEJovianDSSPlugin';
my $NFS_PLUGIN = 'PVE::Storage::Custom::OpenEJovianDSSNFSPlugin';
my $STOREID = 'teststore';

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------

my ( $tests, $failures ) = ( 0, 0 );

sub ok {
    my ( $cond, $desc ) = @_;
    $tests++;
    if ($cond) {
        print "ok $tests - $desc\n";
        return 1;
    }
    $failures++;
    print "NOT OK $tests - $desc\n";
    return 0;
}

sub is {
    my ( $got, $want, $desc ) = @_;
    if ( !ok( ( $got // '(undef)' ) eq ( $want // '(undef)' ), $desc ) ) {
        print "    got:      " . ( $got  // '(undef)' ) . "\n";
        print "    expected: " . ( $want // '(undef)' ) . "\n";
    }
}

sub ctx_for {
    my ($extra) = @_;
    my $scfg = {
        pool_name         => 'Pool-0',
        user_name         => 'admin',
        control_addresses => '127.0.0.1',
        %{ $extra // {} },
    };
    return OpenEJovianDSS::Common::new_ctx( $scfg, $STOREID );
}

# The values the knobs had while they were hardcoded in the REST proxy. Written
# as literals on purpose: comparing the getter against its own constant would
# pass even if both drifted together.
my $HARDCODED_CYCLE_ATTEMPTS = 17;
my $HARDCODED_CYCLE_DELAY    = 3;
my $HARDCODED_SEND_ATTEMPTS  = 5;

# The two request timeouts. 570 was the value the REST proxy passed to
# requests as a single scalar, covering both phases; the connect half is now
# bounded separately at 5 s so an unreachable control address is abandoned
# fast enough for the next one to be tried inside jdssc_timeout.
my $HARDCODED_CONNECT_TIMEOUT = 5;
my $HARDCODED_READ_TIMEOUT    = 570;

# ---------------------------------------------------------------------------
# Defaults: an entry that configures nothing behaves exactly as before.
# ---------------------------------------------------------------------------
{
    my $ctx = ctx_for();

    is( OpenEJovianDSS::Common::get_jdssc_rest_request_send_cycle_attempts($ctx),
        $HARDCODED_CYCLE_ATTEMPTS,
        'default: request send cycle attempts falls back to the hardcoded 17' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_request_send_cycle_delay($ctx),
        $HARDCODED_CYCLE_DELAY,
        'default: request send cycle delay falls back to the hardcoded 3' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_send_retry_on_decode_error_attempts($ctx),
        $HARDCODED_SEND_ATTEMPTS,
        'default: send retry-on-decode-error attempts falls back to the hardcoded 5' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_connect_timeout($ctx),
        $HARDCODED_CONNECT_TIMEOUT,
        'default: connect timeout falls back to 5' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_read_timeout($ctx),
        $HARDCODED_READ_TIMEOUT,
        'default: read timeout falls back to 570' );
}

# ---------------------------------------------------------------------------
# The get_default_* accessors publish the same values to the schema.
# ---------------------------------------------------------------------------
{
    is( OpenEJovianDSS::Common::get_default_jdssc_rest_request_send_cycle_attempts(),
        $HARDCODED_CYCLE_ATTEMPTS,
        'accessor: default cycle attempts is 17' );
    is( OpenEJovianDSS::Common::get_default_jdssc_rest_request_send_cycle_delay(),
        $HARDCODED_CYCLE_DELAY,
        'accessor: default cycle delay is 3' );
    is( OpenEJovianDSS::Common::get_default_jdssc_rest_send_retry_on_decode_error_attempts(),
        $HARDCODED_SEND_ATTEMPTS,
        'accessor: default send attempts is 5' );
    is( OpenEJovianDSS::Common::get_default_jdssc_rest_connect_timeout(),
        $HARDCODED_CONNECT_TIMEOUT,
        'accessor: default connect timeout is 5' );
    is( OpenEJovianDSS::Common::get_default_jdssc_rest_read_timeout(),
        $HARDCODED_READ_TIMEOUT,
        'accessor: default read timeout is 570' );
}

# ---------------------------------------------------------------------------
# Configured values are honoured.
# ---------------------------------------------------------------------------
{
    my $ctx = ctx_for( {
        jdssc_rest_request_send_cycle_attempts         => 4,
        jdssc_rest_request_send_cycle_delay            => 7,
        jdssc_rest_send_retry_on_decode_error_attempts => 9,
        jdssc_rest_connect_timeout                     => 11,
        jdssc_rest_read_timeout                        => 13,
    } );

    is( OpenEJovianDSS::Common::get_jdssc_rest_request_send_cycle_attempts($ctx),
        4, 'configured: cycle attempts is taken from storage.cfg' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_request_send_cycle_delay($ctx),
        7, 'configured: cycle delay is taken from storage.cfg' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_send_retry_on_decode_error_attempts($ctx),
        9, 'configured: send attempts is taken from storage.cfg' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_connect_timeout($ctx),
        11, 'configured: connect timeout is taken from storage.cfg' );
    is( OpenEJovianDSS::Common::get_jdssc_rest_read_timeout($ctx),
        13, 'configured: read timeout is taken from storage.cfg' );
}

# ---------------------------------------------------------------------------
# 0 is a legal delay: retry without sleeping. A '||' fallback would silently
# restore the default here, which is the whole reason the delay getter tests
# definedness instead of truth.
# ---------------------------------------------------------------------------
{
    my $ctx = ctx_for( { jdssc_rest_request_send_cycle_delay => 0 } );
    is( OpenEJovianDSS::Common::get_jdssc_rest_request_send_cycle_delay($ctx),
        0, 'zero delay survives instead of collapsing to the default' );
}

# An empty string is not a configured value - it is what an unset property
# looks like after a round trip through the config parser.
{
    my $ctx = ctx_for( { jdssc_rest_request_send_cycle_delay => '' } );
    is( OpenEJovianDSS::Common::get_jdssc_rest_request_send_cycle_delay($ctx),
        $HARDCODED_CYCLE_DELAY,
        'empty delay is treated as unset and falls back to the default' );
}

# ---------------------------------------------------------------------------
# Values arrive from storage.cfg as strings; the getters must return numbers
# so the jdssc command line never carries something like '4\n'.
# ---------------------------------------------------------------------------
{
    my $ctx = ctx_for( {
        jdssc_rest_request_send_cycle_attempts         => '4',
        jdssc_rest_send_retry_on_decode_error_attempts => '9',
    } );

    my $attempts =
      OpenEJovianDSS::Common::get_jdssc_rest_request_send_cycle_attempts($ctx);
    my $sends =
      OpenEJovianDSS::Common::get_jdssc_rest_send_retry_on_decode_error_attempts($ctx);

    ok( $attempts == 4 && $attempts eq '4',
        'string attempts value is normalised to a number' );
    ok( $sends == 9 && $sends eq '9',
        'string send-attempts value is normalised to a number' );
}

# ---------------------------------------------------------------------------
# The declared schema advertises the same defaults the getters use, so an
# operator reading `pvesm` output sees what the code will actually do.
# ---------------------------------------------------------------------------
{
    my $props = $PLUGIN->properties();

    for my $case (
        [ 'jdssc_rest_request_send_cycle_attempts',         $HARDCODED_CYCLE_ATTEMPTS,  1 ],
        [ 'jdssc_rest_request_send_cycle_delay',            $HARDCODED_CYCLE_DELAY,     0 ],
        [ 'jdssc_rest_send_retry_on_decode_error_attempts', $HARDCODED_SEND_ATTEMPTS,   1 ],
        [ 'jdssc_rest_connect_timeout',                     $HARDCODED_CONNECT_TIMEOUT, 1 ],
        [ 'jdssc_rest_read_timeout',                        $HARDCODED_READ_TIMEOUT,    1 ],
      )
    {
        my ( $name, $want_default, $want_min ) = @$case;
        my $p = $props->{$name};

        ok( defined($p), "schema: ${name} is declared" ) or next;
        is( $p->{default}, $want_default,
            "schema: ${name} advertises the getter's default" );
        is( $p->{type}, 'integer', "schema: ${name} is an integer" );
        is( $p->{minimum}, $want_min, "schema: ${name} minimum is ${want_min}" );
    }
}

# ---------------------------------------------------------------------------
# Both plugins accept the properties: the NFS plugin drives the same REST
# proxy, so the knobs must be settable on an NFS storage too.
# ---------------------------------------------------------------------------
{
    for my $plugin ( [ 'iSCSI', $PLUGIN ], [ 'NFS', $NFS_PLUGIN ] ) {
        my ( $label, $class ) = @$plugin;
        my $options = $class->options();

        for my $name (
            'jdssc_rest_request_send_cycle_attempts',
            'jdssc_rest_request_send_cycle_delay',
            'jdssc_rest_send_retry_on_decode_error_attempts',
            'jdssc_rest_connect_timeout',
            'jdssc_rest_read_timeout',
          )
        {
            ok( exists( $options->{$name} ),
                "options: the ${label} plugin accepts ${name}" )
              or next;
            ok( $options->{$name}{optional},
                "options: ${label} ${name} is optional, so existing entries stay valid" );
        }
    }
}

print "1..$tests\n";
if ($failures) {
    print "FAILED $failures/$tests\n";
    exit 1;
}
print "PASSED $tests/$tests\n";
exit 0;
