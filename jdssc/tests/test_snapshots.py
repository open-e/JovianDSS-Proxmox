import time

import pytest
from unittest.mock import MagicMock

from jdssc.jovian_common.driver import JovianDSSDriver
from jdssc.jovian_common import exception as jexc
from jdssc.jovian_common.jdss_common import time_to_epoch


POOL = "Pool-0"
VOL = "vm-100-disk-0"
SNAP_RAW = "s_pvesnap"  # snapshot name as the appliance stores it
SNAP_ID = "pvesnap"  # snapshot name as jdssc reports it


@pytest.fixture
def driver():
    d = JovianDSSDriver({"jovian_pool": POOL, "san_hosts": []})
    d.ra = MagicMock()
    return d


class TestTimeToEpoch:

    def test_integer_passes_through(self):
        assert time_to_epoch(1753900000) == 1753900000

    def test_digit_string_passes_through(self):
        assert time_to_epoch("1753900000") == 1753900000

    def test_date_string_converts_to_local_epoch(self):
        expected = int(time.mktime(
            time.strptime("2015-05-27 16:08:35", "%Y-%m-%d %H:%M:%S")))
        assert time_to_epoch("2015-05-27 16:08:35") == expected

    def test_unpadded_date_equals_padded_date(self):
        # The appliance emits fields without zero padding.
        assert (time_to_epoch("2015-5-27 16:8:35")
                == time_to_epoch("2015-05-27 16:08:35"))

    def test_missing_value_is_zero(self):
        assert time_to_epoch(None) == 0

    def test_unknown_format_is_zero(self):
        assert time_to_epoch("yesterday") == 0


class TestListSnapshots:

    def _snapshot_entry(self, props=None, **top):
        entry = {"name": SNAP_RAW}
        entry.update(top)
        if props is not None:
            entry["properties"] = props
        return entry

    def test_properties_nested_attributes(self, driver):
        entry = self._snapshot_entry(
            props={"guid": "123", "creation": 1753900000,
                   "volsize": "1073741824"})
        driver.ra.get_volume_snapshots_page.side_effect = [[entry], []]

        snaps = driver.list_snapshots(VOL)

        assert snaps == [{"name": SNAP_ID, "guid": "123",
                          "creation": 1753900000,
                          "volsize": "1073741824"}]

    def test_top_level_attributes(self, driver):
        entry = self._snapshot_entry(
            guid="123", creation="2015-5-27 16:8:35")
        driver.ra.get_volume_snapshots_page.side_effect = [[entry], []]

        snaps = driver.list_snapshots(VOL)

        assert snaps == [{"name": SNAP_ID, "guid": "123",
                          "creation": time_to_epoch("2015-5-27 16:8:35")}]

    def test_volsize_not_fetched_unless_requested(self, driver):
        entry = self._snapshot_entry(
            props={"guid": "123", "creation": 1753900000})
        driver.ra.get_volume_snapshots_page.side_effect = [[entry], []]

        snaps = driver.list_snapshots(VOL)

        assert "volsize" not in snaps[0]
        driver.ra.get_snapshot.assert_not_called()

    def test_volsize_backfilled_from_snapshot_details(self, driver):
        # The v4 paged listing carries only guid and creation; volsize
        # must come from the single-snapshot resource.
        entry = self._snapshot_entry(
            props={"guid": "123", "creation": 1753900000})
        driver.ra.get_volume_snapshots_page.side_effect = [[entry], []]
        driver.ra.get_snapshot.return_value = {
            "volsize": "1073741824", "san:volume_id": "abc"}

        snaps = driver.list_snapshots(VOL, volsize=True)

        assert snaps[0]["volsize"] == "1073741824"
        driver.ra.get_snapshot.assert_called_once_with(
            "v_" + VOL, SNAP_RAW)

    def test_volsize_present_in_listing_not_refetched(self, driver):
        entry = self._snapshot_entry(
            props={"guid": "123", "creation": 1753900000,
                   "volsize": "1073741824"})
        driver.ra.get_volume_snapshots_page.side_effect = [[entry], []]

        snaps = driver.list_snapshots(VOL, volsize=True)

        assert snaps[0]["volsize"] == "1073741824"
        driver.ra.get_snapshot.assert_not_called()

    def test_volsize_of_vanished_snapshot_stays_unknown(self, driver):
        entry = self._snapshot_entry(
            props={"guid": "123", "creation": 1753900000})
        driver.ra.get_volume_snapshots_page.side_effect = [[entry], []]
        driver.ra.get_snapshot.side_effect = \
            jexc.JDSSResourceNotFoundException(SNAP_RAW)

        snaps = driver.list_snapshots(VOL, volsize=True)

        assert "volsize" not in snaps[0]

    def test_missing_volume_raises_not_found(self, driver):
        driver.ra.get_volume_snapshots_page.side_effect = \
            jexc.JDSSResourceNotFoundException("v_" + VOL)

        with pytest.raises(jexc.JDSSResourceNotFoundException):
            driver.list_snapshots(VOL)

    def test_other_rest_error_keeps_generic_failure(self, driver):
        driver.ra.get_volume_snapshots_page.side_effect = \
            jexc.JDSSException("REST unreachable")

        # A transient REST failure is (pre-existing behavior) absorbed by
        # the page loop and yields an empty listing, not an error.
        assert driver.list_snapshots(VOL) == []
