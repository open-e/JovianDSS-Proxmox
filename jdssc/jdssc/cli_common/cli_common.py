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

import logging
import re

from jdssc.jovian_common import exception as jexc

LOG = logging.getLogger(__name__)

# CHAP credential format rules of the JovianDSS appliance (REST API spec;
# duplicated from jovian_common/rest.py so the CLI can refuse malformed
# values before any driver or appliance work).
# re.ASCII pins \w to ASCII - the appliance rule is ASCII.
chapUserNamePattern = re.compile(r'^\w([a-zA-Z0-9-_]*\w)?$', re.ASCII)
chapPasswordPattern = re.compile(r'^[a-zA-Z0-9-_!@%()+?.:;]+$', re.ASCII)

CHAP_PASSWORD_MIN_LEN = 12
CHAP_PASSWORD_MAX_LEN = 255


def chap_user_name_check(name):
    """Check a CHAP user name against the JovianDSS appliance rule.

    Names must match '^\\w([a-zA-Z0-9-_]*\\w)?$'.
    Raises JDSSException on violation.
    """
    if not isinstance(name, str):
        raise jexc.JDSSException("CHAP user name is missing")

    if chapUserNamePattern.match(name) is None:
        raise jexc.JDSSException(
            "CHAP user name '%s' is invalid: only letters, digits, "
            "'-' and '_' are allowed, and it must start and end with "
            "a letter, digit or '_'" % name)


def chap_user_password_check(password):
    """Check a CHAP password against the JovianDSS appliance rule.

    Passwords must be 12 to 255 characters from
    '^[a-zA-Z0-9-_!@%()+?.:;]+$' (no whitespace).
    Raises JDSSException on violation; the password value is never
    included in the error message.
    """
    if not isinstance(password, str):
        raise jexc.JDSSException("CHAP password is missing")

    if ((len(password) < CHAP_PASSWORD_MIN_LEN) or
            (len(password) > CHAP_PASSWORD_MAX_LEN)):
        raise jexc.JDSSException(
            "CHAP password must be %d to %d characters long"
            % (CHAP_PASSWORD_MIN_LEN, CHAP_PASSWORD_MAX_LEN))

    if chapPasswordPattern.match(password) is None:
        raise jexc.JDSSException(
            "CHAP password contains unsupported characters; allowed "
            "are letters, digits and -_!@%()+?.:;")


def load_sensitive_file(path):
    """Parse the plugin sensitive file ('key value' per line) into a dict.
    """
    creds = {}
    if not path:
        return creds
    try:
        with open(path) as sf:
            for line in sf:
                line = line.strip()
                if not line or line.startswith('#'):
                    continue
                key, _, val = line.partition(' ')
                if key and val:
                    creds[key] = val
    except OSError as err:
        LOG.error("Unable to read sensitive file %s: %s", path, err)
    return creds
