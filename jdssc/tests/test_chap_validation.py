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

"""CHAP credential format checks against the appliance rules.

The checks live on JovianRESTAPI as static methods guarding
create_target_user, the funnel every CHAP-setting path flows through.

Name rule:     '^\\w([a-zA-Z0-9-_]*\\w)?$'
Password rule: 12-255 characters from '^[a-zA-Z0-9-_!@%()+?.:;]+$'
"""

import pytest

from jdssc.jovian_common import exception as jexc
from jdssc.jovian_common.rest import JovianRESTAPI


class TestChapUserNameCheck:

    @pytest.mark.parametrize('name', [
        'chapuser',
        'a',
        '_',
        'a-b_c9',
        '0user0',
        'user_',
    ])
    def test_valid_names(self, name):
        JovianRESTAPI._chap_user_name_check(name)

    @pytest.mark.parametrize('name', [
        '',
        '-bad',
        'bad-',
        'na me',
        'user\t',
        'юзер',
        'user!',
        None,
    ])
    def test_invalid_names(self, name):
        with pytest.raises(jexc.JDSSException):
            JovianRESTAPI._chap_user_name_check(name)


class TestChapUserPasswordCheck:

    @pytest.mark.parametrize('password', [
        'chappass1234',
        'a' * 12,
        'a' * 255,
        'A9-_!@%()+?.:;',
    ])
    def test_valid_passwords(self, password):
        JovianRESTAPI._chap_user_password_check(password)

    @pytest.mark.parametrize('password', [
        '',
        'short',
        'a' * 11,
        'a' * 256,
        'with space12',
        'with\ttab1234',
        'hashsign#1234',
        'dollars$12345',
        'парольпароль',
        None,
    ])
    def test_invalid_passwords(self, password):
        with pytest.raises(jexc.JDSSException):
            JovianRESTAPI._chap_user_password_check(password)

    def test_length_error_does_not_leak_value(self):
        with pytest.raises(jexc.JDSSException) as excinfo:
            JovianRESTAPI._chap_user_password_check('secretvalue')
        assert 'secretvalue' not in str(excinfo.value)

    def test_charset_error_does_not_leak_value(self):
        with pytest.raises(jexc.JDSSException) as excinfo:
            JovianRESTAPI._chap_user_password_check('secret value12')
        assert 'secret value12' not in str(excinfo.value)
