#    Copyright (c) 2026 Open-E, Inc.
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

"""Shared CLI helpers in jdssc.cli_common.

is_natural_number (1, 2, 3, ...) and is_whole_number (0, 1, 2, ...) are the
argparse types behind the five --rest-* options. Four take a count or a
timeout and use the natural form; the delay takes the whole form, because 0
legitimately means 'retry without sleeping'. They are the only thing standing
between a mistyped value and a jdssc process that misbehaves rather than
refusing to start, so the cases below are about what they must reject:

  * a negative attempt count reaches retry_call, which treats it as infinite
    and re-sends without pause - a hang at full CPU, not an error;
  * a zero cycle count sends nothing at all and reports a communication
    failure indistinguishable from an unreachable appliance;
  * a zero connect or read timeout cannot be satisfied by a request that
    necessarily takes time.

The plugin path is already guarded by 'minimum => 1' in the storage schema.
These options are the unguarded route around it: a direct CLI run, or the -c
YAML config channel.
"""

import argparse

import pytest

from jdssc.cli_common import cli_common as ccom


class TestIsNaturalNumberAccepts:

    def test_returns_the_parsed_value(self):
        assert ccom.is_natural_number('17') == 17

    def test_returns_an_int_not_a_string(self):
        """argparse hands the result straight to the config dict, which is
        later compared and arithmetic-ed on."""
        assert isinstance(ccom.is_natural_number('17'), int)

    def test_accepts_one_the_smallest_natural_number(self):
        assert ccom.is_natural_number('1') == 1

    def test_accepts_an_int_as_well_as_a_string(self):
        """argparse passes strings, but the helper is also callable directly."""
        assert ccom.is_natural_number(9) == 9

    def test_accepts_surrounding_whitespace(self):
        assert ccom.is_natural_number(' 4 ') == 4

    def test_accepts_a_large_value(self):
        assert ccom.is_natural_number('86400') == 86400


class TestIsNaturalNumberRejects:

    def test_rejects_zero(self):
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_natural_number('0')

    def test_rejects_negative(self):
        """The regression that matters: retry_call treats a negative attempt
        count as infinite and spins without sleeping."""
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_natural_number('-1')

    def test_rejects_a_non_numeric_string(self):
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_natural_number('abc')

    def test_rejects_an_empty_string(self):
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_natural_number('')

    def test_rejects_none(self):
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_natural_number(None)

    def test_rejects_a_fractional_value(self):
        """'2.5' seconds is a plausible thing to type and int() will not take
        it; the failure must be the argparse one, not a bare ValueError."""
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_natural_number('2.5')


class TestIsNaturalNumberErrorType:

    def test_raises_argument_type_error_not_jdss_exception(self):
        """argparse only renders ArgumentTypeError as 'jdssc: error: argument
        --x: ...'. Any other exception escapes as a traceback, which is what
        the rest of cli_common's *_check helpers would produce."""
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_natural_number('-1')

    def test_message_names_the_offending_value(self):
        with pytest.raises(argparse.ArgumentTypeError) as excinfo:
            ccom.is_natural_number('abc')
        assert 'abc' in str(excinfo.value)

    def test_message_names_the_expected_kind(self):
        with pytest.raises(argparse.ArgumentTypeError) as excinfo:
            ccom.is_natural_number('0')
        assert 'natural number' in str(excinfo.value)


class TestIsWholeNumberAllowsZero:
    """The delay option is the one knob where 0 is legal - it means retry
    without sleeping - which is exactly why it takes the whole form."""

    def test_accepts_zero(self):
        assert ccom.is_whole_number('0') == 0

    def test_still_rejects_negative(self):
        with pytest.raises(argparse.ArgumentTypeError):
            ccom.is_whole_number('-1')

    def test_still_accepts_positive(self):
        assert ccom.is_whole_number('3') == 3

    def test_message_names_the_offending_value(self):
        with pytest.raises(argparse.ArgumentTypeError) as excinfo:
            ccom.is_whole_number('-5')
        assert '-5' in str(excinfo.value)


class TestArgparseIntegration:
    """The helper is only useful if argparse actually rejects through it, so
    these drive a parser rather than the function."""

    def parser(self):
        p = argparse.ArgumentParser(prog='jdssc-test')
        p.add_argument('--attempts', type=ccom.is_natural_number)
        p.add_argument('--delay', type=ccom.is_whole_number)
        return p

    def test_valid_value_parses(self):
        assert self.parser().parse_args(['--attempts', '4']).attempts == 4

    def test_zero_delay_parses(self):
        assert self.parser().parse_args(['--delay', '0']).delay == 0

    def test_negative_attempts_exits_two(self):
        """argparse exits 2 on a bad argument; anything else means the error
        escaped as an exception instead."""
        with pytest.raises(SystemExit) as excinfo:
            self.parser().parse_args(['--attempts', '-1'])
        assert excinfo.value.code == 2

    def test_zero_attempts_exits_two(self):
        with pytest.raises(SystemExit) as excinfo:
            self.parser().parse_args(['--attempts', '0'])
        assert excinfo.value.code == 2

    def test_negative_delay_exits_two(self):
        with pytest.raises(SystemExit) as excinfo:
            self.parser().parse_args(['--delay', '-1'])
        assert excinfo.value.code == 2
