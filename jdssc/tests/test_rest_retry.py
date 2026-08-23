"""Tests for the REST resilience knobs in rest_proxy.

Two things are covered, and they need different setups:

* the *wiring* - that _send_with_retry hands retry_call the configured
  attempt count and the right exception type. conftest stubs 'retry.api'
  with a MagicMock, so these assert on how retry_call was called.
* the *semantics* - that N attempts really means N sends and that a
  recovered attempt stops the loop. A MagicMock cannot show that, so these
  import the genuine `retry` package (a declared dependency, setup.py) and
  substitute the real retry_call. They skip when it is not installed rather
  than silently asserting nothing.

The knobs are also end-to-end tested for *forwarding* in
pve-testing/testcases/{iscsi,nfs}-plugin/config-change/, and pinned on the
Perl side by tests/jdssc_rest_config_test.pl. Nothing there exercises the
retry itself - that is what this file is for.
"""

import importlib
import json
import sys
from unittest.mock import MagicMock

import pytest

from jdssc.jovian_common import rest_proxy


POOL = "Pool-0"
HOST = "192.168.0.1"


def proxy_for(**config):
    """Build a proxy with a stubbed session; config overrides the defaults."""
    cfg = {"san_hosts": [HOST], "jovian_pool": POOL}
    cfg.update(config)
    p = rest_proxy.JovianDSSRESTProxy(cfg)
    p.session = MagicMock()
    return p


def decode_error():
    return json.JSONDecodeError("Expecting value", "", 0)


@pytest.fixture
def real_retry_call(monkeypatch):
    """The genuine retry.api.retry_call, with conftest's stub set aside."""
    saved = {name: sys.modules.get(name) for name in ("retry", "retry.api")}
    for name in ("retry", "retry.api"):
        sys.modules.pop(name, None)
    try:
        module = importlib.import_module("retry.api")
        call = module.retry_call
    except ImportError:
        pytest.skip("the real 'retry' package is not installed")
    else:
        monkeypatch.setattr(rest_proxy, "retry_call", call)
        yield call
    finally:
        for name, module in saved.items():
            if module is not None:
                sys.modules[name] = module
            else:
                sys.modules.pop(name, None)


# ---------------------------------------------------------------------------
# Defaults. Written as literals: comparing a constant against itself would
# pass even if it drifted. The Perl side pins the same numbers independently
# in tests/jdssc_rest_config_test.pl - these two sets must agree, because the
# plugin always passes its own values and a direct jdssc run uses these.
# ---------------------------------------------------------------------------

class TestDefaults:

    def test_connect_timeout_default_is_5(self):
        assert rest_proxy.DEFAULT_REST_CONNECT_TIMEOUT == 5

    def test_read_timeout_default_is_570(self):
        assert rest_proxy.DEFAULT_REST_READ_TIMEOUT == 570

    def test_cycle_attempts_default_is_17(self):
        assert rest_proxy.DEFAULT_REST_REQUEST_SEND_CYCLE_ATTEMPTS == 17

    def test_cycle_delay_default_is_3(self):
        assert rest_proxy.DEFAULT_REST_REQUEST_SEND_CYCLE_DELAY == 3

    def test_decode_error_attempts_default_is_5(self):
        assert rest_proxy.DEFAULT_REST_SEND_RETRY_ON_DECODE_ERROR_ATTEMPTS == 5

    def test_unconfigured_proxy_uses_the_defaults(self):
        p = proxy_for()

        assert p.connect_timeout == 5
        assert p.read_timeout == 570
        assert p.request_send_cycle_attempts == 17
        assert p.request_send_cycle_delay == 3
        assert p.send_retry_on_decode_error_attempts == 5

    def test_configured_values_override_the_defaults(self):
        p = proxy_for(jdssc_rest_connect_timeout=2,
                      jdssc_rest_read_timeout=44,
                      jdssc_rest_request_send_cycle_attempts=4,
                      jdssc_rest_request_send_cycle_delay=0,
                      jdssc_rest_send_retry_on_decode_error_attempts=9)

        assert p.connect_timeout == 2
        assert p.read_timeout == 44
        assert p.request_send_cycle_attempts == 4
        assert p.request_send_cycle_delay == 0
        assert p.send_retry_on_decode_error_attempts == 9

    def test_zero_delay_survives(self):
        """0 means retry without sleeping and must not fall back to 3."""
        p = proxy_for(jdssc_rest_request_send_cycle_delay=0)

        assert p.request_send_cycle_delay == 0


# ---------------------------------------------------------------------------
# The two timeout phases are passed to requests as a (connect, read) tuple.
# A scalar would apply the read value to the connect phase too, which is how
# an unreachable control address used to cost ~130 s instead of 5.
# ---------------------------------------------------------------------------

class TestTimeoutsReachRequests:

    def test_send_passes_a_connect_read_tuple(self):
        p = proxy_for()
        p.session.send.return_value = MagicMock(status_code=204)

        p._send(MagicMock())

        _, kwargs = p.session.send.call_args
        assert kwargs["timeout"] == (5, 570)

    def test_configured_timeouts_are_the_ones_sent(self):
        p = proxy_for(jdssc_rest_connect_timeout=2,
                      jdssc_rest_read_timeout=44)
        p.session.send.return_value = MagicMock(status_code=204)

        p._send(MagicMock())

        _, kwargs = p.session.send.call_args
        assert kwargs["timeout"] == (2, 44)


# ---------------------------------------------------------------------------
# Wiring: _send_with_retry must hand retry_call the *configured* count and
# the exception json.loads actually raises.
# ---------------------------------------------------------------------------

class TestRetryWiring:

    def test_retry_is_bound_to_the_configured_attempt_count(self, monkeypatch):
        p = proxy_for(jdssc_rest_send_retry_on_decode_error_attempts=9)
        spy = MagicMock()
        monkeypatch.setattr(rest_proxy, "retry_call", spy)

        p._send_with_retry("prepared")

        assert spy.call_args.kwargs["tries"] == 9

    def test_retry_count_is_read_at_call_time_not_import_time(self, monkeypatch):
        """The reason this is retry_call and not an @retry decorator: a
        decorator binds its arguments when the module is imported, before any
        configuration exists."""
        spy = MagicMock()
        monkeypatch.setattr(rest_proxy, "retry_call", spy)

        proxy_for(jdssc_rest_send_retry_on_decode_error_attempts=2) \
            ._send_with_retry("prepared")
        first = spy.call_args.kwargs["tries"]
        proxy_for(jdssc_rest_send_retry_on_decode_error_attempts=7) \
            ._send_with_retry("prepared")
        second = spy.call_args.kwargs["tries"]

        assert (first, second) == (2, 7)

    def test_retry_catches_the_exception_json_loads_raises(self, monkeypatch):
        """_send parses with json.loads, which raises json.JSONDecodeError.
        Had it used response.json(), the type would be
        requests.exceptions.JSONDecodeError and this pairing would silently
        stop matching."""
        p = proxy_for()
        spy = MagicMock()
        monkeypatch.setattr(rest_proxy, "retry_call", spy)

        p._send_with_retry("prepared")

        assert spy.call_args.kwargs["exceptions"] is json.JSONDecodeError

    def test_the_retried_callable_is_send_with_the_prepared_request(
            self, monkeypatch):
        p = proxy_for()
        spy = MagicMock()
        monkeypatch.setattr(rest_proxy, "retry_call", spy)

        p._send_with_retry("prepared")

        assert spy.call_args.args[0] == p._send
        assert spy.call_args.kwargs["fargs"] == ["prepared"]


# ---------------------------------------------------------------------------
# Semantics, against the genuine retry package: N attempts means N sends.
# ---------------------------------------------------------------------------

class TestRetryBehaviour:

    def test_exhausting_the_budget_sends_exactly_that_many_times(
            self, real_retry_call, monkeypatch):
        p = proxy_for(jdssc_rest_send_retry_on_decode_error_attempts=5)
        calls = []
        monkeypatch.setattr(
            p, "_send",
            lambda pr: (calls.append(pr), (_ for _ in ()).throw(decode_error())))

        with pytest.raises(json.JSONDecodeError):
            p._send_with_retry("prepared")

        assert len(calls) == 5

    def test_a_recovered_attempt_stops_the_loop(
            self, real_retry_call, monkeypatch):
        p = proxy_for(jdssc_rest_send_retry_on_decode_error_attempts=5)
        calls = []

        def flaky(pr):
            calls.append(pr)
            if len(calls) < 3:
                raise decode_error()
            return {"code": 200}

        monkeypatch.setattr(p, "_send", flaky)

        assert p._send_with_retry("prepared") == {"code": 200}
        assert len(calls) == 3

    def test_one_attempt_disables_the_retry(
            self, real_retry_call, monkeypatch):
        """The documented meaning of 1: attempts, not additional retries."""
        p = proxy_for(jdssc_rest_send_retry_on_decode_error_attempts=1)
        calls = []
        monkeypatch.setattr(
            p, "_send",
            lambda pr: (calls.append(pr), (_ for _ in ()).throw(decode_error())))

        with pytest.raises(json.JSONDecodeError):
            p._send_with_retry("prepared")

        assert len(calls) == 1

    def test_a_non_decode_error_is_not_retried_here(
            self, real_retry_call, monkeypatch):
        """Connection failures belong to the cycle loop in request(), which
        moves to the next control address. Retrying them at this level would
        re-send to the same dead host."""
        p = proxy_for(jdssc_rest_send_retry_on_decode_error_attempts=5)
        calls = []

        def boom(pr):
            calls.append(pr)
            raise ValueError("not a decode error")

        monkeypatch.setattr(p, "_send", boom)

        with pytest.raises(ValueError):
            p._send_with_retry("prepared")

        assert len(calls) == 1
