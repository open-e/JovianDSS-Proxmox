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

"""Sensitive-file channel: loader, CHAP checks and password resolution.

Part 1 of docs/design/0008-sensitive-data-transfer-control.md: credentials
reach jdssc through the per-storage password file passed as
--sensitive-file, never on argv. The loader and the CHAP format checks live
in cli_common (shared by bin/jdssc and the CLI modules); each CLI module
resolves the value into a local of its own.

The hard rule the resolution must keep: the resolved secret goes into a
local and never back into args - the args dict is dumped to the debug log.
"""

import pytest

from jdssc.cli_common import cli_common as ccom
from jdssc.jovian_common import exception as jexc

import jdssc.target as target
import jdssc.targets as targets


def _write(tmp_path, content):
    path = tmp_path / "store.pw"
    path.write_text(content)
    return str(path)


# --------------------------------------------------------------------------
# loader
# --------------------------------------------------------------------------

def test_loader_parses_key_value(tmp_path):
    path = _write(tmp_path,
                  "chap_user_password chappass12345\n"
                  "user_password restpass\n")
    assert ccom.load_sensitive_file(path) == {
        "chap_user_password": "chappass12345",
        "user_password": "restpass"}


def test_loader_skips_blank_and_comment_lines(tmp_path):
    path = _write(tmp_path, "\n# comment line\nuser_password restpass\n")
    assert ccom.load_sensitive_file(path) == {"user_password": "restpass"}


def test_loader_keeps_values_containing_spaces(tmp_path):
    # partition(' ') splits on the FIRST space, so the value survives intact.
    path = _write(tmp_path, "user_password pass with spaces\n")
    assert ccom.load_sensitive_file(path) == {
        "user_password": "pass with spaces"}


def test_loader_missing_file_is_empty():
    # Unreadable file must not raise: the caller reports the missing
    # credential, and bin/jdssc logs the underlying OSError.
    assert ccom.load_sensitive_file("/nonexistent/store.pw") == {}


def test_loader_no_path_is_empty():
    assert ccom.load_sensitive_file(None) == {}


# --------------------------------------------------------------------------
# CHAP format checks (cli_common copies of the appliance rules)
# --------------------------------------------------------------------------

@pytest.mark.parametrize("name", ["chapuser", "ok_1", "a", "A-b_C9"])
def test_chap_user_name_accepted(name):
    ccom.chap_user_name_check(name)


@pytest.mark.parametrize("name", ["bad-", "-bad", "with space", "", None])
def test_chap_user_name_refused(name):
    with pytest.raises(jexc.JDSSException):
        ccom.chap_user_name_check(name)


@pytest.mark.parametrize("password", ["chappass12345", "a" * 255,
                                      "p@ss-w0rd_ok!"])
def test_chap_password_accepted(password):
    ccom.chap_user_password_check(password)


@pytest.mark.parametrize("password", ["short", "a" * 256, "with space12",
                                      "tab\there123", None])
def test_chap_password_refused(password):
    with pytest.raises(jexc.JDSSException):
        ccom.chap_user_password_check(password)


def test_chap_check_errors_never_leak_the_password():
    secret = "sup3rsecret!" * 30       # too long -> refused
    with pytest.raises(jexc.JDSSException) as err:
        ccom.chap_user_password_check(secret)
    assert secret not in str(err.value)


# --------------------------------------------------------------------------
# resolution into a local
# --------------------------------------------------------------------------

def test_resolve_flag_wins(tmp_path):
    path = _write(tmp_path, "chap_user_password filepass12345\n")
    args = {"chap_user": "chapuser",
            "chap_password": "flagpass12345",
            "sensitive_file": path}
    assert targets._resolve_chap_password(args) == "flagpass12345"


def test_resolve_falls_back_to_file(tmp_path):
    path = _write(tmp_path, "chap_user_password filepass12345\n")
    args = {"chap_user": "chapuser",
            "chap_password": None,
            "sensitive_file": path}
    assert targets._resolve_chap_password(args) == "filepass12345"


def test_resolve_needs_chap_user():
    # Without --chap-user there is no CHAP request to resolve for.
    args = {"chap_user": None,
            "chap_password": None,
            "sensitive_file": "/nonexistent/store.pw"}
    assert targets._resolve_chap_password(args) is None


def test_resolution_never_writes_back_into_args(tmp_path):
    # Risk 4 of the design: self.args is dumped to the debug log, so the
    # resolved secret must stay in a local and args must stay untouched.
    path = _write(tmp_path, "chap_user_password filepass12345\n")
    args = {"chap_user": "chapuser",
            "chap_password": None,
            "sensitive_file": path}
    before = dict(args)
    targets._resolve_chap_password(args)
    assert args == before
    assert args["chap_password"] is None


def test_target_module_resolves_identically(tmp_path):
    # target.py carries its own copy of the resolver; behaviour must match
    # targets.py, including leaving args untouched.
    path = _write(tmp_path, "chap_user_password filepass12345\n")
    args = {"chap_user": "chapuser",
            "chap_password": None,
            "sensitive_file": path}
    assert target._resolve_chap_password(args) == "filepass12345"
    assert args["chap_password"] is None
