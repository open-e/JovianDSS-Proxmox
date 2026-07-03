import pytest
from unittest.mock import MagicMock

from jdssc.sessions import Sessions
from jdssc.jovian_common import exception as jexc


TARGET = "iqn.2025-04.proxmox.joviandss.iscsi:vm-420-0"

# The verified vm-420-0 capture (docs/design/jdssc-target-sessions.md,
# Background): three sessions, two initiators, one initiator over two portals.
CAPTURE = [
    {"target_name": TARGET, "cid": "0", "ip": "172.29.143.18",
     "sid": "4957301003d0200",
     "initiator_name": "iqn.1993-08.org.debian:01:793c225e3c37"},
    {"target_name": TARGET, "cid": "0", "ip": "172.30.143.18",
     "sid": "4977401003d0200",
     "initiator_name": "iqn.1993-08.org.debian:01:793c225e3c37"},
    {"target_name": TARGET, "cid": "0", "ip": "172.29.143.17",
     "sid": "4962100003d0200",
     "initiator_name": "iqn.1993-08.org.debian:01:f4e662329db1"},
]


def _run_list(jdss, capsys):
    Sessions({'target_name': TARGET}, ['list'], jdss)
    return capsys.readouterr().out


class TestSessionsList:

    def test_groups_by_initiator_and_joins_ips(self, capsys):
        jdss = MagicMock()
        jdss.get_target_sessions.return_value = list(CAPTURE)

        out = _run_list(jdss, capsys)

        assert out == (
            "iqn.1993-08.org.debian:01:793c225e3c37"
            " 172.29.143.18,172.30.143.18\n"
            "iqn.1993-08.org.debian:01:f4e662329db1 172.29.143.17\n"
        )
        jdss.get_target_sessions.assert_called_once_with(TARGET)

    def test_reconnect_repeating_ip_is_deduplicated(self, capsys):
        jdss = MagicMock()
        jdss.get_target_sessions.return_value = list(CAPTURE) + [
            {"target_name": TARGET, "cid": "0", "ip": "172.29.143.18",
             "sid": "ffff0000ffff000",
             "initiator_name": "iqn.1993-08.org.debian:01:793c225e3c37"},
        ]

        out = _run_list(jdss, capsys)

        assert out.splitlines()[0] == (
            "iqn.1993-08.org.debian:01:793c225e3c37"
            " 172.29.143.18,172.30.143.18")

    def test_no_sessions_prints_nothing(self, capsys):
        jdss = MagicMock()
        jdss.get_target_sessions.return_value = []

        out = _run_list(jdss, capsys)

        assert out == ""

    def test_missing_target_exits_nonzero(self, capsys):
        jdss = MagicMock()
        jdss.get_target_sessions.side_effect = \
            jexc.JDSSResourceNotFoundException(res=TARGET)

        with pytest.raises(SystemExit) as excinfo:
            _run_list(jdss, capsys)

        assert excinfo.value.code == 1

    def test_missing_action_prints_help_and_exits(self, capsys):
        jdss = MagicMock()

        with pytest.raises(SystemExit) as excinfo:
            Sessions({'target_name': TARGET}, [], jdss)

        assert excinfo.value.code == 1
        jdss.get_target_sessions.assert_not_called()
