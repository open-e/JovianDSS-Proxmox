import pytest
from unittest.mock import MagicMock

from jdssc.jovian_common.driver import JovianDSSDriver
from jdssc.jovian_common import exception as jexc


PREFIX = "iqn.2025-01.com.open-e:"
GROUP  = "pool-0-target"
TBASE  = PREFIX + GROUP
POOL   = "Pool-0"
VOL    = "v_vm-100-disk-0"
SCSI   = "95545635e1780899"


@pytest.fixture
def driver():
    d = JovianDSSDriver({"jovian_pool": POOL, "san_hosts": []})
    d.ra = MagicMock()
    return d


def _global_lun_entry(target, lun_id, scsi_id=SCSI, pool=POOL):
    """Build a get_target_by_lun_name response entry."""
    return {
        "lun": {"lun": lun_id, "name": VOL, "scsi_id": scsi_id},
        "iscsi_target": {"name": target, "active": True},
        "pool": pool,
    }


def _target_lun(name, lun_id):
    """Build a get_target_luns list entry."""
    return {"name": name, "lun": lun_id}


def _set_not_attached(driver):
    driver.ra.get_target_by_lun_name.return_value = []


def _set_no_targets(driver):
    driver.ra.get_targets.return_value = []


class TestAcquireTargetVolumeLun:

    # ------------------------------------------------------------------
    # Fast path: volume already attached (get_target_by_lun_name hit)
    # ------------------------------------------------------------------

    def test_volume_already_attached_returns_target_and_lun(self, driver):
        target = TBASE + "-0"
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(target, 3),
        ]

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (target, 3, True, False, SCSI)

    def test_volume_attached_scsi_id_passed_through(self, driver):
        target = TBASE + "-0"
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(target, 0, scsi_id="aabbccddeeff0011"),
        ]

        _, _, _, _, scsi_id = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert scsi_id == "aabbccddeeff0011"

    def test_volume_attached_entry_for_wrong_pool_is_ignored(self, driver):
        target = TBASE + "-0"
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(target, 0, pool="Pool-99"),
        ]
        driver.ra.get_targets.return_value = []
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=TBASE + "-0",
        )

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result[2] is False   # volume_attached must be False
        assert result[3] is True    # new_target: fell through to create path

    def test_volume_attached_first_matching_pool_entry_wins(self, driver):
        t0, t1 = TBASE + "-0", TBASE + "-1"
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(t0, 0, pool="Pool-99"),   # wrong pool
            _global_lun_entry(t1, 2, pool=POOL),         # correct pool
        ]

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (t1, 2, True, False, SCSI)

    def test_missing_scsi_id_fetched_via_get_target_lun(self, driver):
        target = TBASE + "-0"
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(target, 0, scsi_id=None),
        ]
        driver.ra.get_target_lun.return_value = {"lun": 0, "scsi_id": SCSI}

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        driver.ra.get_target_lun.assert_called_once_with(target, VOL)
        assert result == (target, 0, True, False, SCSI)

    def test_scsi_id_present_no_extra_request_made(self, driver):
        target = TBASE + "-0"
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(target, 0, scsi_id=SCSI),
        ]

        driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        driver.ra.get_target_lun.assert_not_called()

    def test_get_target_lun_failure_propagates(self, driver):
        target = TBASE + "-0"
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(target, 0, scsi_id=None),
        ]
        driver.ra.get_target_lun.side_effect = (
            jexc.JDSSResourceNotFoundException(res=VOL)
        )

        with pytest.raises(jexc.JDSSResourceNotFoundException):
            driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

    def test_missing_target_name_raises(self, driver):
        driver.ra.get_target_by_lun_name.return_value = [
            {"pool": POOL, "lun": {"lun": 0, "scsi_id": SCSI}},
        ]

        with pytest.raises(jexc.JDSSException):
            driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

    # ------------------------------------------------------------------
    # Fast path: attached target does not comply with the target_prefix
    # ------------------------------------------------------------------

    STALE = "iqn.2020-01.com.open-e:pool-0-target-0"   # a different prefix

    def test_stale_prefix_idle_detaches_and_rehomes(self, driver):
        # Attached on a target that does NOT match the requested prefix and
        # has no sessions -> detach and fall through to the create path.
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(self.STALE, 3),
        ]
        driver.ra.get_target_sessions.return_value = []          # idle
        driver._detach_target_volume = MagicMock()
        driver.list_targets = MagicMock(return_value=[])         # no new target
        driver.ra.get_target.side_effect = \
            jexc.JDSSResourceNotFoundException(res=TBASE + "-0")

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        driver._detach_target_volume.assert_called_once_with(self.STALE, VOL)
        assert result[2] is False      # volume_attached: detached
        assert result[3] is True       # new_target: re-publish under new prefix

    def test_stale_prefix_in_use_keeps_current(self, driver):
        # Same stale target but WITH sessions -> leave it, return it as-is.
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(self.STALE, 3),
        ]
        driver.ra.get_target_sessions.return_value = [
            {"ip": "10.0.0.5", "initiator_name": "iqn.x"}]
        driver._detach_target_volume = MagicMock()

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (self.STALE, 3, True, False, SCSI)
        driver._detach_target_volume.assert_not_called()

    def test_stale_prefix_current_query_does_not_mutate(self, driver):
        # current=True is a read-only lookup: report the stale target, never
        # check sessions or detach.
        driver.ra.get_target_by_lun_name.return_value = [
            _global_lun_entry(self.STALE, 3),
        ]
        driver._detach_target_volume = MagicMock()

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL,
                                                  current=True)

        assert result == (self.STALE, 3, True, False, SCSI)
        driver._detach_target_volume.assert_not_called()
        driver.ra.get_target_sessions.assert_not_called()

    # ------------------------------------------------------------------
    # Slow path: volume not attached, free slot in existing target
    # ------------------------------------------------------------------

    def test_free_slot_in_only_target_returned(self, driver):
        target = TBASE + "-0"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": target}]
        driver.ra.get_target_luns.return_value = [_target_lun("v_other", 0)]

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (target, 1, False, False, None)

    def test_first_free_lun_is_zero_when_target_is_empty(self, driver):
        target = TBASE + "-0"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": target}]
        driver.ra.get_target_luns.return_value = []

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (target, 0, False, False, None)

    def test_first_gap_in_lun_ids_is_chosen(self, driver):
        target = TBASE + "-0"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": target}]
        # luns 0 and 2 are taken; slot 1 is the first gap
        driver.ra.get_target_luns.return_value = [
            _target_lun("v_disk-a", 0),
            _target_lun("v_disk-b", 2),
        ]

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (target, 1, False, False, None)

    def test_full_target_skipped_free_slot_in_second_target_used(self, driver):
        t0, t1 = TBASE + "-0", TBASE + "-1"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": t0}, {"name": t1}]
        driver.ra.get_target_luns.side_effect = [
            [_target_lun(f"v_disk-{i}", i) for i in range(8)],  # t0 full
            [_target_lun("v_disk-x", 0)],                        # t1 has room
        ]

        result = driver._acquire_taget_volume_lun(
            PREFIX, GROUP, VOL, luns_per_target=8,
        )

        assert result == (t1, 1, False, False, None)

    def test_target_vanishing_during_scan_is_skipped(self, driver):
        t0, t1 = TBASE + "-0", TBASE + "-1"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": t0}, {"name": t1}]
        driver.ra.get_target_luns.side_effect = [
            jexc.JDSSResourceNotFoundException(res=t0),
            [_target_lun("v_disk-x", 0)],
        ]

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (t1, 1, False, False, None)

    def test_unrelated_targets_not_scanned_for_luns(self, driver):
        unrelated = "iqn.2025-01.com.other:different-0"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": unrelated}]
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=TBASE + "-0",
        )

        driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        driver.ra.get_target_luns.assert_not_called()

    # ------------------------------------------------------------------
    # New-target path: no existing target has a free slot
    # ------------------------------------------------------------------

    def test_no_targets_at_all_returns_new_target_index_0(self, driver):
        _set_not_attached(driver)
        _set_no_targets(driver)
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=TBASE + "-0",
        )

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert result == (TBASE + "-0", 0, False, True, None)

    def test_all_targets_full_returns_next_available_index(self, driver):
        target = TBASE + "-0"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": target}]
        driver.ra.get_target_luns.return_value = [
            _target_lun(f"v_disk-{i}", i) for i in range(8)
        ]
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=TBASE + "-1",
        )

        result = driver._acquire_taget_volume_lun(
            PREFIX, GROUP, VOL, luns_per_target=8,
        )

        assert result == (TBASE + "-1", 0, False, True, None)

    def test_index_gap_in_existing_targets_is_filled(self, driver):
        # Targets 0 and 2 exist and are full; index 1 should be chosen.
        t0, t2 = TBASE + "-0", TBASE + "-2"
        _set_not_attached(driver)
        driver.ra.get_targets.return_value = [{"name": t0}, {"name": t2}]
        driver.ra.get_target_luns.return_value = [
            _target_lun(f"v_disk-{i}", i) for i in range(8)
        ]
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=TBASE + "-1",
        )

        result = driver._acquire_taget_volume_lun(
            PREFIX, GROUP, VOL, luns_per_target=8,
        )

        assert result == (TBASE + "-1", 0, False, True, None)

    # ------------------------------------------------------------------
    # Target prefix handling
    # ------------------------------------------------------------------

    def test_prefix_without_colon_gets_colon_inserted(self, driver):
        prefix = "iqn.2025-01.com.open-e"
        expected_base = prefix + ":" + GROUP
        _set_not_attached(driver)
        _set_no_targets(driver)
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=expected_base + "-0",
        )

        result = driver._acquire_taget_volume_lun(prefix, GROUP, VOL)

        assert result[0] == expected_base + "-0"

    def test_prefix_with_colon_produces_no_double_colon(self, driver):
        _set_not_attached(driver)
        _set_no_targets(driver)
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=TBASE + "-0",
        )

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert "::" not in result[0]

    # ------------------------------------------------------------------
    # Return value shape
    # ------------------------------------------------------------------

    def test_result_is_always_five_tuple(self, driver):
        _set_not_attached(driver)
        _set_no_targets(driver)
        driver.ra.get_target.side_effect = jexc.JDSSResourceNotFoundException(
            res=TBASE + "-0",
        )

        result = driver._acquire_taget_volume_lun(PREFIX, GROUP, VOL)

        assert len(result) == 5


TARGET0 = TBASE + "-0"
LUN_INFO = {"lun": 0, "scsi_id": SCSI}


def _setup_ensure(driver):
    """Minimal mocks for _ensure_target_volume_lun happy path."""
    driver.ra.get_target.return_value = {}
    driver._get_conforming_vips = MagicMock(return_value={})
    driver.ra.get_target_user.return_value = []


class TestEnsureTargetVolumeLun:

    def test_lun_already_attached_scsi_id_returned(self, driver):
        _setup_ensure(driver)
        driver.ra.get_target_lun.return_value = LUN_INFO

        result = driver._ensure_target_volume_lun(TARGET0, VOL, 0, None)

        assert result['scsi_id'] == SCSI
        assert result['lun'] == 0

    def test_lun_not_attached_attach_provides_scsi_id(self, driver):
        _setup_ensure(driver)
        driver.ra.get_target_lun.side_effect = (
            jexc.JDSSResourceNotFoundException(res=VOL)
        )
        driver._attach_target_volume_lun = MagicMock(
            return_value={"scsi_id": SCSI}
        )

        result = driver._ensure_target_volume_lun(TARGET0, VOL, 0, None)

        assert result['scsi_id'] == SCSI

    def test_lun_not_attached_attach_no_scsi_id_fallback_get(self, driver):
        _setup_ensure(driver)
        driver.ra.get_target_lun.side_effect = [
            jexc.JDSSResourceNotFoundException(res=VOL),
            LUN_INFO,
        ]
        driver._attach_target_volume_lun = MagicMock(return_value=None)

        result = driver._ensure_target_volume_lun(TARGET0, VOL, 0, None)

        assert result['scsi_id'] == SCSI

    def test_all_scsi_id_paths_fail_raises(self, driver):
        _setup_ensure(driver)
        driver.ra.get_target_lun.side_effect = [
            jexc.JDSSResourceNotFoundException(res=VOL),
            jexc.JDSSException("unavailable"),
        ]
        driver._attach_target_volume_lun = MagicMock(return_value=None)

        with pytest.raises(jexc.JDSSException):
            driver._ensure_target_volume_lun(TARGET0, VOL, 0, None)

    def test_busy_lun_still_absent_reraises(self, driver):
        _setup_ensure(driver)
        driver.ra.get_target_lun.side_effect = [
            jexc.JDSSResourceNotFoundException(res=VOL),
            jexc.JDSSResourceNotFoundException(res=VOL),
        ]
        driver._attach_target_volume_lun = MagicMock(
            side_effect=jexc.JDSSResourceIsBusyException(res=VOL)
        )

        with pytest.raises(jexc.JDSSResourceIsBusyException):
            driver._ensure_target_volume_lun(TARGET0, VOL, 0, None)


def _setup_create(driver):
    """Minimal mocks for _create_target_volume_lun happy path."""
    driver._get_conforming_vips = MagicMock(return_value={})
    driver._attach_target_volume_lun = MagicMock(
        return_value={"scsi_id": SCSI}
    )
    driver._set_target_credentials = MagicMock()


class TestCreateTargetVolumeLun:

    def test_attach_provides_scsi_id(self, driver):
        _setup_create(driver)

        result = driver._create_target_volume_lun(TARGET0, VOL, 0, None)

        assert result['scsi_id'] == SCSI
        assert result['lun'] == 0

    def test_attach_no_scsi_id_fallback_get_target_lun(self, driver):
        _setup_create(driver)
        driver._attach_target_volume_lun = MagicMock(return_value=None)
        driver.ra.get_target_lun.return_value = LUN_INFO

        result = driver._create_target_volume_lun(TARGET0, VOL, 0, None)

        assert result['scsi_id'] == SCSI

    def test_all_scsi_id_paths_fail_raises(self, driver):
        _setup_create(driver)
        driver._attach_target_volume_lun = MagicMock(return_value=None)
        driver.ra.get_target_lun.return_value = {"lun": 0, "scsi_id": None}

        with pytest.raises(jexc.JDSSException):
            driver._create_target_volume_lun(TARGET0, VOL, 0, None)


class TestRenameVolume:
    """rename_volume exit contract (review F-03): every path must end in an
    explicit success or a raise - a probe failure must never fall off the
    retry loop as an implicit (exit-0) success."""

    def _quiet_sleep(self, monkeypatch):
        monkeypatch.setattr("jdssc.jovian_common.driver.time.sleep",
                            lambda s: None)

    def test_probe_failure_raises_instead_of_silent_success(
            self, driver, monkeypatch):
        self._quiet_sleep(monkeypatch)
        driver.get_volume = MagicMock(
            side_effect=jexc.JDSSException("REST blip"))

        with pytest.raises(jexc.JDSSException):
            driver.rename_volume("vm-100-disk-0", "base-100-disk-0")

        driver.ra.modify_lun.assert_not_called()

    def test_missing_source_raises_not_found(self, driver, monkeypatch):
        self._quiet_sleep(monkeypatch)
        driver.get_volume = MagicMock(
            side_effect=jexc.JDSSResourceNotFoundException(
                res="vm-100-disk-0"))

        with pytest.raises(jexc.JDSSResourceNotFoundException):
            driver.rename_volume("vm-100-disk-0", "base-100-disk-0")

        driver.ra.modify_lun.assert_not_called()

    def test_idempotent_match_short_circuits(self, driver, monkeypatch):
        self._quiet_sleep(monkeypatch)
        # hex-join of 'abc' is '616263' - the idempotent comparison value
        driver.get_volume = MagicMock(return_value={"scsi_id": "abc"})

        result = driver.rename_volume("vm-100-disk-0", "base-100-disk-0",
                                      idempotent="616263")

        assert result is None
        driver.get_volume.assert_called_once()
        driver.ra.modify_lun.assert_not_called()


class TestDetachTargetVolumeInUse:
    """_detach_target_volume(check_in_use=True) session guard (C2-02)."""

    TGT = TBASE + "-0"

    def _session(self, ip):
        return {"target_name": self.TGT, "cid": "1", "ip": ip,
                "sid": "42", "initiator_name": "iqn.init:node"}

    def test_active_sessions_raise_in_use_and_skip_detach(self, driver):
        driver.ra.get_target_sessions.return_value = [
            self._session("10.0.0.7"), self._session("10.0.0.8")]

        with pytest.raises(jexc.JDSSTargetInUseException) as ei:
            driver._detach_target_volume(self.TGT, VOL, check_in_use=True)

        # Never touched the target when it is in use.
        driver.ra.detach_target_vol.assert_not_called()
        driver.ra.delete_target.assert_not_called()
        # Exception carries the target and the initiator addresses (sorted).
        assert ei.value.target == self.TGT
        assert ei.value.addresses == ["10.0.0.7", "10.0.0.8"]
        assert self.TGT in ei.value.message
        assert "10.0.0.7" in ei.value.message

    def test_no_sessions_detaches_normally(self, driver):
        driver.ra.get_target_sessions.return_value = []
        driver.ra.get_target_luns.return_value = []

        driver._detach_target_volume(self.TGT, VOL, check_in_use=True)

        driver.ra.detach_target_vol.assert_called_once_with(self.TGT, VOL)
        # Last lun gone -> target removed.
        driver.ra.delete_target.assert_called_once_with(self.TGT)

    def test_missing_target_is_not_in_use(self, driver):
        # A target that does not exist has no sessions holding it.
        driver.ra.get_target_sessions.side_effect = \
            jexc.JDSSResourceNotFoundException(res=self.TGT)
        driver.ra.get_target_luns.return_value = []

        driver._detach_target_volume(self.TGT, VOL, check_in_use=True)

        driver.ra.detach_target_vol.assert_called_once_with(self.TGT, VOL)

    def test_default_skips_session_check(self, driver):
        # Without the flag the guard must not query sessions at all.
        driver.ra.get_target_luns.return_value = [_target_lun(VOL, 0)]

        driver._detach_target_volume(self.TGT, VOL)

        driver.ra.get_target_sessions.assert_not_called()
        driver.ra.detach_target_vol.assert_called_once_with(self.TGT, VOL)

    def test_detach_only_keeps_target_even_when_empty(self, driver):
        # detach_only must never delete the target (the caller re-attaches).
        driver.ra.get_target_luns.return_value = []

        driver._detach_target_volume(self.TGT, VOL, detach_only=True)

        driver.ra.detach_target_vol.assert_called_once_with(self.TGT, VOL)
        driver.ra.get_target_luns.assert_not_called()
        driver.ra.delete_target.assert_not_called()


class TestAttachTargetVolumeLunBusy:
    """_attach_target_volume_lun resolves a busy ('volume already used')
    attach at the single attach chokepoint (C2-02)."""

    OTHER = TBASE + "-1"

    @pytest.fixture(autouse=True)
    def _quiet_sleep(self, monkeypatch):
        monkeypatch.setattr("time.sleep", lambda *_a, **_k: None)

    def _entry(self, target, pool=POOL):
        return {"iscsi_target": {"name": target},
                "lun": {"lun": 0, "scsi_id": SCSI}, "pool": pool}

    def test_case2_already_on_target_returns_existing_no_detach(self, driver):
        # busy, then found already on the SAME target -> return its lun,
        # never move it.
        driver.ra.attach_target_vol.side_effect = \
            jexc.JDSSResourceIsBusyException(res=VOL)
        driver.ra.get_target_by_lun_name.return_value = [self._entry(TARGET0)]
        driver.ra.get_target_lun.return_value = {"scsi_id": SCSI, "lun": 0}
        driver._detach_target_volume = MagicMock()

        result = driver._attach_target_volume_lun(TARGET0, VOL, 0)

        assert result["scsi_id"] == SCSI
        driver._detach_target_volume.assert_not_called()

    def test_case2_right_target_wrong_lun_relocates(self, driver):
        # On the desired target but at a DIFFERENT lun than requested ->
        # detach where it is and re-attach at the requested lun.
        driver.ra.attach_target_vol.side_effect = [
            jexc.JDSSResourceIsBusyException(res=VOL),
            {"scsi_id": SCSI},
        ]
        # _entry() reports the volume on TARGET0 at lun 0; we ask for lun 3.
        driver.ra.get_target_by_lun_name.return_value = [self._entry(TARGET0)]
        driver.ra.get_target_sessions.return_value = []
        driver.ra.get_target_luns.return_value = []

        result = driver._attach_target_volume_lun(TARGET0, VOL, 3)

        assert result["scsi_id"] == SCSI
        driver.ra.detach_target_vol.assert_called_once_with(TARGET0, VOL)
        # Same-target lun move must NOT delete the target (detach_only).
        driver.ra.delete_target.assert_not_called()

    def test_incomplete_attachment_record_retries(self, driver):
        # The array reports an attachment missing iscsi_target/lun -> do not
        # act on it, retry on the next attempt (then attach succeeds).
        driver.ra.attach_target_vol.side_effect = [
            jexc.JDSSResourceIsBusyException(res=VOL),
            {"scsi_id": SCSI},
        ]
        driver.ra.get_target_by_lun_name.return_value = [
            {"pool": POOL, "lun": {"lun": 0}}]        # no iscsi_target
        driver._detach_target_volume = MagicMock()

        result = driver._attach_target_volume_lun(TARGET0, VOL, 0)

        assert result["scsi_id"] == SCSI
        driver._detach_target_volume.assert_not_called()

    def test_case1_other_target_same_pool_detaches_then_reattaches(self, driver):
        # busy, volume on ANOTHER target in our pool, no sessions -> detach
        # there and retry attach.
        driver.ra.attach_target_vol.side_effect = [
            jexc.JDSSResourceIsBusyException(res=VOL),
            {"scsi_id": SCSI},
        ]
        driver.ra.get_target_by_lun_name.return_value = [self._entry(self.OTHER)]
        driver.ra.get_target_sessions.return_value = []       # not in use
        driver.ra.get_target_luns.return_value = []

        result = driver._attach_target_volume_lun(TARGET0, VOL, 0)

        assert result["scsi_id"] == SCSI
        driver.ra.detach_target_vol.assert_called_once_with(self.OTHER, VOL)

    def test_case1_other_target_in_use_raises_no_detach(self, driver):
        # volume on another target WITH live sessions -> refuse.
        driver.ra.attach_target_vol.side_effect = \
            jexc.JDSSResourceIsBusyException(res=VOL)
        driver.ra.get_target_by_lun_name.return_value = [self._entry(self.OTHER)]
        driver.ra.get_target_sessions.return_value = [
            {"ip": "10.0.0.9", "initiator_name": "iqn.x"}]

        with pytest.raises(jexc.JDSSTargetInUseException):
            driver._attach_target_volume_lun(TARGET0, VOL, 0)
        driver.ra.detach_target_vol.assert_not_called()

    def test_cross_pool_same_target_name_raises_no_detach(self, driver):
        # a same-named target owned by a DIFFERENT pool -> never cross pools.
        driver.ra.attach_target_vol.side_effect = \
            jexc.JDSSResourceIsBusyException(res=VOL)
        driver.ra.get_target_by_lun_name.return_value = [
            self._entry(TARGET0, pool="Other-Pool")]

        with pytest.raises(jexc.JDSSTargetPoolConflictException):
            driver._attach_target_volume_lun(TARGET0, VOL, 0)
        driver.ra.detach_target_vol.assert_not_called()

    def test_transient_busy_not_attached_retries_then_succeeds(self, driver):
        # busy but not attached anywhere -> pace and retry, then succeed.
        driver.ra.attach_target_vol.side_effect = [
            jexc.JDSSResourceIsBusyException(res=VOL),
            {"scsi_id": SCSI},
        ]
        driver.ra.get_target_by_lun_name.return_value = []    # not attached

        result = driver._attach_target_volume_lun(TARGET0, VOL, 0)

        assert result["scsi_id"] == SCSI

    def test_multiple_attachments_same_pool_raises(self, driver):
        # Volume reported on two targets in our pool -> corrupted state,
        # refuse rather than pick one.
        driver.ra.attach_target_vol.side_effect = \
            jexc.JDSSResourceIsBusyException(res=VOL)
        driver.ra.get_target_by_lun_name.return_value = [
            self._entry(TARGET0), self._entry(self.OTHER)]

        with pytest.raises(jexc.JDSSException) as ei:
            driver._attach_target_volume_lun(TARGET0, VOL, 0)
        assert "single target" in str(ei.value)
        driver.ra.detach_target_vol.assert_not_called()

    def test_persistent_busy_exhausts_and_raises(self, driver):
        # always busy, never resolvable -> raise busy after max attempts.
        driver.ra.attach_target_vol.side_effect = \
            jexc.JDSSResourceIsBusyException(res=VOL)
        driver.ra.get_target_by_lun_name.return_value = []

        with pytest.raises(jexc.JDSSResourceIsBusyException):
            driver._attach_target_volume_lun(TARGET0, VOL, 0)
