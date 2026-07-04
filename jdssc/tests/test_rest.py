import pytest
from unittest.mock import MagicMock

from jdssc.jovian_common import rest
from jdssc.jovian_common import exception as jexc


TARGET = 'iqn.2025-01.com.open-e:pool-0-target-0'
VOL    = 'v_vm-100-disk-0'

LUN_DATA = {
    'name':             VOL,
    'block_size':       512,
    'mode':             'wt',
    'scsi_id':          '95545635e1780899',
    'lun':              0,
    'thin_provisioned': True,
}

GLOBAL_LUN_ENTRY = {
    'lun': {
        'lun':     0,
        'eui':     '3935353435363335',
        'name':    VOL,
        'scsi_id': '95545635e1780899',
    },
    'iscsi_target': {'name': TARGET, 'active': True},
    'pool': 'Pool-0',
}


def _resp_ok(data):
    return {'error': None, 'code': 200, 'data': data}


def _resp_404():
    return {'error': None, 'code': 404}


def _resp_error(code=500):
    return {
        'error': {
            'class':   'opene.storage.SomeError',
            'code':    str(code),
            'message': 'internal server error',
        },
        'code': code,
    }


@pytest.fixture
def ra():
    api = rest.JovianRESTAPI({'jovian_pool': 'Pool-0', 'san_hosts': []})
    api.rproxy = MagicMock()
    return api


class TestGetTargetLun:

    def test_returns_full_data_dict_on_200(self, ra):
        ra.rproxy.pool_request.return_value = _resp_ok(LUN_DATA)
        result = ra.get_target_lun(TARGET, VOL)
        assert result == LUN_DATA

    def test_scsi_id_present_in_result(self, ra):
        ra.rproxy.pool_request.return_value = _resp_ok(LUN_DATA)
        result = ra.get_target_lun(TARGET, VOL)
        assert result['scsi_id'] == '95545635e1780899'

    def test_raises_resource_not_found_on_404(self, ra):
        ra.rproxy.pool_request.return_value = _resp_404()
        with pytest.raises(jexc.JDSSResourceNotFoundException):
            ra.get_target_lun(TARGET, VOL)

    def test_raises_jdss_exception_on_server_error(self, ra):
        ra.rproxy.pool_request.return_value = _resp_error(500)
        with pytest.raises(jexc.JDSSException):
            ra.get_target_lun(TARGET, VOL)

    def test_uses_get_method(self, ra):
        ra.rproxy.pool_request.return_value = _resp_ok(LUN_DATA)
        ra.get_target_lun(TARGET, VOL)
        method = ra.rproxy.pool_request.call_args[0][0]
        assert method == 'GET'

    def test_url_contains_target_and_volume(self, ra):
        ra.rproxy.pool_request.return_value = _resp_ok(LUN_DATA)
        ra.get_target_lun(TARGET, VOL)
        url = ra.rproxy.pool_request.call_args[0][1]
        assert TARGET in url
        assert VOL in url

    def test_called_exactly_once(self, ra):
        ra.rproxy.pool_request.return_value = _resp_ok(LUN_DATA)
        ra.get_target_lun(TARGET, VOL)
        ra.rproxy.pool_request.assert_called_once()


class TestGetTargetByLunName:

    def test_returns_list_on_200(self, ra):
        ra.rproxy.request.return_value = _resp_ok([GLOBAL_LUN_ENTRY])
        result = ra.get_target_by_lun_name(VOL)
        assert result == [GLOBAL_LUN_ENTRY]

    def test_returns_empty_list_when_no_match(self, ra):
        ra.rproxy.request.return_value = _resp_ok([])
        result = ra.get_target_by_lun_name(VOL)
        assert result == []

    def test_result_contains_scsi_id(self, ra):
        ra.rproxy.request.return_value = _resp_ok([GLOBAL_LUN_ENTRY])
        result = ra.get_target_by_lun_name(VOL)
        assert result[0]['lun']['scsi_id'] == '95545635e1780899'

    def test_result_contains_target_name(self, ra):
        ra.rproxy.request.return_value = _resp_ok([GLOBAL_LUN_ENTRY])
        result = ra.get_target_by_lun_name(VOL)
        assert result[0]['iscsi_target']['name'] == TARGET

    def test_raises_on_server_error(self, ra):
        ra.rproxy.request.return_value = _resp_error(500)
        with pytest.raises(jexc.JDSSException):
            ra.get_target_by_lun_name(VOL)

    def test_uses_get_method(self, ra):
        ra.rproxy.request.return_value = _resp_ok([GLOBAL_LUN_ENTRY])
        ra.get_target_by_lun_name(VOL)
        method = ra.rproxy.request.call_args[0][0]
        assert method == 'GET'

    def test_url_contains_volume_name(self, ra):
        ra.rproxy.request.return_value = _resp_ok([GLOBAL_LUN_ENTRY])
        ra.get_target_by_lun_name(VOL)
        url = ra.rproxy.request.call_args[0][1]
        assert VOL in url
