#    Copyright (c) 2024 Open-E, Inc.
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

import datetime
import logging
from oslo_utils import units as o_units
import math
import re
import string
import time
import hashlib

from jdssc.jovian_common import exception as jexc
# from jdssc.jovian_common import cexception as exception
from jdssc.jovian_common import jdss_common as jcom
from jdssc.jovian_common import rest
from jdssc.jovian_common.stub import _

LOG = logging.getLogger(__name__)


Size_Pattern = re.compile(r"^(\d+[GgMmKk]?)$")
Allowed_ISCSI_Symbols = re.compile(r"^[a-z\-\.\:\d]+$")


class JovianDSSDriver(object):

    def __init__(self, config):

        self.VERSION = "0.10.15"

        self.configuration = config
        self._pool = self.configuration.get('jovian_pool', 'Pool-0')
        self.jovian_iscsi_target_portal_port = self.configuration.get(
            'target_port', 3260)

        self.jovian_target_prefix = self.configuration.get(
            'target_prefix',
            'iqn.2025-04.com.open-e.cinder:')
        self.jovian_chap_pass_len = self.configuration.get(
            'chap_password_len', 12)
        self.block_size = (
            self.configuration.get('jovian_block_size', '16K'))
        self.jovian_sparse = (
            self.configuration.get('san_thin_provision', True))
        self.jovian_ignore_tpath = self.configuration.get(
            'jovian_ignore_tpath', None)
        self.jovian_hosts = self.configuration.get(
            'san_hosts', [])
        self.jovian_iscsi_vip_addresses = self.configuration.get(
            'iscsi_vip_addresses', [])
        self.jovian_nfs_vip_addresses = self.configuration.get(
            'nfs_vip_addresses', [])

        self.ra = rest.JovianRESTAPI(config)
        self.jovian_rest_port = self.ra.rproxy.port

    def set_target_prefix(self, prefix):
        self.jovian_target_prefix = prefix

    def get_pool_name(self):
        return self._pool

    def rest_config_is_ok(self):
        """Check config correctness by checking pool availability"""

        return self.ra.is_pool_exists()

    def get_active_ifaces(self):
        """Return list of ip addresses for iSCSI connection"""

        return self.jovian_hosts

    def create_volume(self, volume_id, volume_size, sparse=None,
                      block_size=None,
                      direct_mode=False):
        """Create a volume.

        :param str volume_id: volume id
        :param int volume_size: size in Gi
        :param bool sparse: thin or thick volume flag (default thin)
        :param int block_size: size of block (default None)

        :return: None
        """
        vname = jcom.vname(volume_id)
        if direct_mode:
            vname = volume_id

        if sparse is None:
            sparse = self.jovian_sparse

        LOG.debug(("Create volume:%(name)s with size:%(size)s "
                   "sparse is %(sparse)s"),
                  {'name': volume_id,
                   'size': volume_size,
                   'sparse': sparse})

        self.ra.create_lun(vname,
                           volume_size,
                           sparse=sparse,
                           block_size=block_size)
        return

    def create_nas_volume(self, volume_id, volume_quota,
                          reservation=None,
                          direct_mode=False):
        """Create a nas volume.

        :param str volume_id: nas volume id
        :param int volume_quota: size in Gi
        :param bool sparse: thin or thick volume flag (default thin)
        :param int block_size: size of block (default None)
        :param bool direct_mode: indicates that volume id should be used
                                for name without any changes

        :return: None
        """
        vname = jcom.vname(volume_id)
        if direct_mode:
            vname = volume_id

        LOG.debug(("Create nas volume:%(name)s with quota:%(size)s "
                   "direct mode is %(direct)s and reservation:%(reserv)s "),
                  {'name': volume_id,
                   'size': volume_quota,
                   'reserv': reservation,
                   'direct': direct_mode})

        self.ra.create_nas_volume(vname,
                                  volume_quota,
                                  reservation=reservation)
        return

    def _promote_newest_delete(self, vname, snapshots=None, cascade=False):
        '''Promotes and delete volume

        This function deletes volume.
        It will promote volume if needed before deletion.

        :param str vname: physical volume id
        :param list snapshots: snapshot data list (default None)

        :return: None
        '''

        if snapshots is None:
            try:
                snapshots = self.ra.get_snapshots(vname)
            except jexc.JDSSResourceNotFoundException:
                LOG.debug('volume %s do not exists, it was already '
                          'deleted', vname)
                return

        bsnaps = self._list_busy_snapshots(vname, snapshots)

        if len(bsnaps) != 0:

            promote_target = None

            sname = jcom.get_newest_snapshot_name(bsnaps)

            for snap in bsnaps:
                if snap['name'] == sname:
                    cvnames = self._list_snapshot_clones_names(vname,
                                                               snap['name'])
                    for cvname in cvnames:
                        if jcom.is_volume(cvname):
                            promote_target = cvname
                        if jcom.is_snapshot(cvname):
                            self._promote_newest_delete(cvname,
                                                        cascade=True)
                        if jcom.is_hidden(cvname):
                            try:
                                self._promote_newest_delete(cvname,
                                                            cascade=cascade)
                            except jexc.JDSSResourceIsBusyException:
                                continue
                    break
            if promote_target is not None:
                self.ra.promote(vname, sname, promote_target)

            self._promote_newest_delete(vname, cascade=cascade)

        self._delete_vol_with_source_snap(vname, recursive=cascade)

    def _delete_vol_with_source_snap(self, vname, recursive=False):
        '''Delete volume and its source snapshot if required

        This function deletes volume.
        If volume is a clone it will check its source snapshot if
        one is originates from volume to delete.

        :param str vname: physical volume id
        :param bool recursive: recursive flag (default False)

        :return: None
        '''
        vol = None

        try:
            vol = self.ra.get_lun(vname)
        except jexc.JDSSResourceNotFoundException:
            LOG.debug('unable to get volume %s info, '
                      'assume it was already deleted', vname)
            return
        try:
            self.ra.delete_lun(vname,
                               force_umount=True,
                               recursively_children=recursive)
        except jexc.JDSSResourceNotFoundException:
            LOG.debug('volume %s do not exists, it was already '
                      'deleted', vname)
            return

        if vol is not None and \
                'origin' in vol and \
                vol['origin'] is not None:
            if jcom.is_volume(jcom.origin_snapshot(vol)) or \
                    jcom.is_hidden(jcom.origin_snapshot(vol)) or \
                    (jcom.vid_from_sname(jcom.origin_snapshot(vol)) ==
                     jcom.idname(vname)):
                self.ra.delete_snapshot(jcom.origin_volume(vol),
                                        jcom.origin_snapshot(vol),
                                        recursively_children=True,
                                        force_umount=True)

    def _clean_garbage_resources(self, vname, snapshots=None):
        '''Removes resources that is not related to volume

        Goes through volume snapshots and it clones to identify one
        that is clearly not related to vname volume and therefore
        have to be deleted.

        :param str vname: physical volume id
        :param list snapshots: list of snapshot info dictionaries

        :return: updated list of snapshots
        '''

        if snapshots is None:
            try:
                snapshots = self.ra.get_snapshots(vname)
            except jexc.JDSSResourceNotFoundException:
                LOG.debug('volume %s do not exists, it was already '
                          'deleted', vname)
                return
        update = False
        for snap in snapshots:
            if jcom.is_volume(jcom.sname_from_snap(snap)):
                cvnames = self._list_snapshot_clones_names(vname, snap['name'])
                if len(cvnames) == 0:
                    self._delete_snapshot(vname, jcom.sname_from_snap(snap))
                    update = True
            if jcom.is_snapshot(jcom.sname_from_snap(snap)):
                cvnames = self._list_snapshot_clones_names(vname, snap['name'])
                for cvname in cvnames:
                    if jcom.is_hidden(cvname):
                        self._promote_newest_delete(cvname, cascade=False)
                        update = True
                    if jcom.is_snapshot(cvname):
                        if jcom.idname(vname) != jcom.vid_from_sname(cvname):
                            self._promote_newest_delete(cvname, cascade=True)
                            update = True
        if update:
            snapshots = self.ra.get_snapshots(vname)
        return snapshots

    def _list_snapshot_clones_names(self, vname, sname):
        """Lists all snapshot clones

        :return: list of clone names related to given snapshot
        """

        clist = list()

        clones = self.ra.get_snapshot_clones(vname, sname)
        for c in clones:
            clist.append(c['name'])

        return clist

    def _list_nas_snapshot_clones_names(self, vname, sname):
        """Lists all snapshot clones

        :return: list of clone names related to given snapshot
        """

        clist = list()

        clones = self.ra.get_nas_snapshot_clones(vname, sname)
        for c in clones:
            clist.append(c['name'])

        return clist

    def _list_busy_snapshots(self, vname, snapshots,
                             exclude_dedicated_volumes=False,
                             exclude_dedicated_snapshots=False) -> list:
        """List all volume snapshots with clones

        Goes through provided list of snapshots.
        If additional parameters are given, will filter list of snapshots
        accordingly.

        Keyword arguments:
        :param str vname: zvol id
        :param list snapshots: list of snapshots data dicts
        :param bool exclude_dedicated_volumes: list snapshots that has clones
                                        (default False)

        :return: filtered list of snapshot data dicts
        :rtype: list
        """

        out = []
        for snap in snapshots:
            LOG.debug("Checking snapshot %(snap)s for clones", {"snap": snap})

            clones = self._list_snapshot_clones_names(vname, snap['name'])
            add = False

            for clone in clones:
                LOG.debug("Found clone %(clone)s", {'clone': clone})
                if exclude_dedicated_volumes and jcom.is_volume(clone):
                    continue
                if (exclude_dedicated_snapshots and
                        jcom.is_snapshot(clone)):
                    continue
                add = True
            if add:
                out.append(snap)

        return out

    def _clean_volume_snapshots_mount_points(self, vname, snapshots):
        """_clean_volume_snapshots_mount_point

        :param str vname: physical volume id
        :param list snapshots: list of volume snapshots

        :return: None
        """
        LOG.debug("Cleaning volume snapshot mount points")
        for s in snapshots:
            LOG.debug("%s", s['name'])

        for snap in snapshots:
            clones = self._list_snapshot_clones_names(vname, snap['name'])
            for cname in [c for c in clones if jcom.is_snapshot(c)]:
                # self._remove_target_volume(jcom.idname(cname), cname)
                LOG.debug("Delete snapshot mount point %s", cname)
                self._delete_volume(cname, cascade=True)

    def _volume_busy_error(self, vname, snapshots):

        cnames = []

        for s in snapshots:
            cnames.extend(self._list_snapshot_clones_names(vname, s['name']))

        volume_names = [jcom.idname(vn) for vn in cnames]
        msg = (("Volume %(volume_name)s is busy, delete dependent "
                "volumes first:")
               % {'volume_name': jcom.idname(vname)})
        jcom.dependency_error(msg, volume_names)

        raise jexc.JDSSResourceIsBusyException(vname)

    # TODO: rethink delete volume
    # it is used in many places, yet concept of 'garbage' has changed
    # since last time. So instead of deleting hidden volumes
    # we should only remove them if they have no snapshots
    def _delete_volume(self, vname, cascade=False, detach_target=True):
        """_delete_volume delete routine containing delete logic

        :param str vname: physical volume id
        :param bool cascade: flag for cascade volume deletion
            with its snapshots
        :param bool delete_target: indicate ifwe have to check for target
            related to given volume

        :return: None
        """
        LOG.debug("Deleting %s", vname)
        # TODO: consider more optimal method for identification
        # if volume is assigned to any target

        if detach_target:
            try:
                self._detach_volume(vname)
            except jexc.JDSSResourceNotFoundException:
                LOG.debug('target for volume %s does not exist', vname)

        try:
            # First we try to delete lun, if it has no snapshots deletion will
            # succeed
            self.ra.delete_lun(vname,
                               force_umount=True,
                               recursively_children=cascade)
        except jexc.JDSSResourceIsBusyException as jerr:
            LOG.debug('unable to conduct direct volume %s deletion', vname)
            if cascade is False:
                raise jerr

        except jexc.JDSSResourceNotFoundException:
            LOG.debug('volume %s do not exists, it was already '
                      'deleted', vname)
            return
        except jexc.JDSSRESTException as jerr:
            LOG.debug(
                "Unable to delete physical volume %(volume)s "
                "with error %(err)s.", {
                    "volume": vname,
                    "err": jerr})
        else:
            LOG.debug('in place deletion suceeded')
            return

        def vsnap_filter(snap):
            if jcom.is_snapshot(snap['name']):
                return True
            return False

        snapshots = []
        try:
            snapshots = self._list_all_volume_snapshots(vname, None)
        except jexc.JDSSResourceNotFoundException:
            LOG.debug('volume %s do not exists, it was already '
                      'deleted', vname)
            return

        bsnaps = self._list_busy_snapshots(vname,
                                           snapshots,
                                           exclude_dedicated_snapshots=True)
        # TODO: make sure that in case there are volume clones and snapshots
        # mount points, we show user only clones as dependency
        if len(bsnaps) > 0:
            cnames = []
            for s in snapshots:
                cnames.extend(
                    self._list_snapshot_clones_names(vname, s['name']))
            volume_names = [jcom.idname(vn) for vn in cnames]
            raise jexc.JDSSResourceVolumeIsBusyException(jcom.idname(vname),
                                                         volume_names)

        LOG.debug("All snapshots len %d %s", len(snapshots), str(snapshots))
        self._clean_volume_snapshots_mount_points(vname, snapshots)

        self._delete_volume(vname, cascade=cascade)

    def delete_volume(self, volume_name, cascade=False, print_and_exit=False):
        """Delete volume

        :param volume: volume reference
        :param cascade: remove snapshots of a volume as well
        """
        vname = jcom.vname(volume_name)

        LOG.debug('deleting volume %s', vname)

        if print_and_exit:
            LOG.debug("Print only deletion")
            return self._list_resources_to_delete(vname, cascade=True)
        else:
            return self._delete_volume(vname, cascade=cascade)

    def _delete_nas_volume(self, vname, cascade=False, detach_target=True):
        """_delete_volume delete routine containing delete logic

        :param str vname: physical volume id
        :param bool cascade: flag for cascade volume deletion
            with its snapshots
        :param bool delete_target: indicate ifwe have to check for target
            related to given volume

        :return: None
        """
        LOG.debug("Deleting %s", vname)

        self.ra.delete_nas_volume(vname)

    def delete_nas_volume(self, volume_name,
                          direct_mode=False,
                          print_and_exit=False):
        """Delete nas volume

        :param volume: volume reference
        :param cascade: remove snapshots of a volume as well
        """

        vname = jcom.vname(volume_name)

        if direct_mode:
            vname = volume_name

        LOG.info('deleting nas volume %s', vname)

        self._delete_nas_volume(vname, cascade=True)

    def _list_resources_to_delete(self, vname, cascade=False):
        ret = []
        snapshots = []
        try:
            snapshots = self._list_all_volume_snapshots(vname, None)
        except jexc.JDSSResourceNotFoundException:
            LOG.debug('volume %s do not exists, it was already '
                      'deleted', vname)
            return

        bsnaps = self._list_busy_snapshots(vname,
                                           snapshots,
                                           exclude_dedicated_volumes=True)
        LOG.debug("Busy snaps to delete %s", str(bsnaps))

        for snap in bsnaps:
            clones = self._list_snapshot_clones_names(vname, snap['name'])
            ret.extend([jcom.idname(c) for c in clones if jcom.is_snapshot(c)])
        LOG.debug("Snaps to delete %s", str(ret))
        return ret

    def _clone_object(self, cvname, sname, ovname,
                      sparse=None,
                      create_snapshot=False,
                      readonly=False):
        """Creates a clone of specified object

        Will create snapshot if it is not provided

        :param str cvname: clone volume name
        :param str sname: snapshot name
        :param str ovname: original volume name
        :param bool sparse: sparse property of new volume
        :param bool create_snapshot:
        """
        LOG.debug('cloning %(ovname)s to %(coname)s', {
            "ovname": ovname,
            "coname": cvname})

        if sparse is None:
            sparse = self.jovian_sparse

        if create_snapshot:
            self.ra.create_snapshot(ovname, sname)
        try:
            self.ra.create_volume_from_snapshot(
                cvname,
                sname,
                ovname,
                sparse=sparse,
                readonly=readonly)
        except jexc.JDSSVolumeExistsException as jerr:
            if jcom.is_snapshot(cvname):
                LOG.debug(("Got Volume Exists exception, but do nothing as"
                           "%s is a snapshot"), cvname)
            else:
                raise jerr
        except jexc.JDSSException as jerr:
            # This is a garbage collecting section responsible for cleaning
            # all the mess of request failed
            if create_snapshot:
                try:
                    self.ra.delete_snapshot(ovname,
                                            cvname,
                                            recursively_children=True,
                                            force_umount=True)
                except jexc.JDSSException as jerrd:
                    LOG.warning("Because of %s physical snapshot %s of volume"
                                " %s have to be removed manually",
                                jerrd,
                                sname,
                                ovname)

            raise jerr

    def resize_volume(self, volume_name, new_size, direct_mode=False):
        """Extend an existing volume.

        :param str volume_name: volume id
        :param int new_size: volume new size in Gi
        """
        LOG.debug("Extend volume:%(name)s to size:%(size)s",
                  {'name': volume_name, 'size': new_size})

        vname = jcom.vname(volume_name)

        if direct_mode:
            vname = volume_name
        self.ra.extend_lun(vname, new_size)

    def create_cloned_volume(self,
                             clone_name,
                             volume_name,
                             size,
                             snapshot_name=None,
                             sparse=None):
        """Create a clone of the specified volume.

        :param str clone_name: new volume id
        :param volume_name: original volume id
        :param int size: size in Gi
        :param str snapshot_name: openstack snapshot id to use for cloning
        :param bool sparse: sparse flag
        """
        cvname = jcom.vname(clone_name)

        ovname = jcom.vname(volume_name)

        LOG.debug('clone volume %(id)s to %(id_clone)s', {
            "id": volume_name,
            "id_clone": clone_name})

        if snapshot_name:
            sname = jcom.sname(snapshot_name, None)

            pname = self._find_snapshot_parent(ovname, sname)
            if pname is None:
                raise jexc.JDSSSnapshotNotFoundException(snapshot_name)

            # TODO: make sure that sparsity of the volume depends on config
            self._clone_object(cvname, sname, pname,
                               create_snapshot=False,
                               sparse=sparse,
                               readonly=jcom.is_snapshot(cvname))
        else:
            sname = jcom.vname(clone_name)
            self._clone_object(cvname, sname, ovname,
                               create_snapshot=True,
                               sparse=sparse,
                               readonly=jcom.is_snapshot(cvname))

        if sparse is None:
            sparse = self.jovian_sparse

        self._set_provisioning_thin(cvname, sparse)

        size = str(size)

        try:
            if Size_Pattern.match(size):
                if len(size) > 1:
                    self.resize_volume(clone_name, size)

        except jexc.JDSSException as jerr:
            # If volume can't be set to a proper size make sure to clean it
            # before failing
            try:
                self.delete_volume(clone_name, cascade=False)
            except jexc.JDSSException as jerrex:
                LOG.warning("Error %s during cleaning failed volume %s",
                            jerrex, volume_name)
                raise jerr from jerrex

    def create_snapshot(self, snapshot_name, volume_name):
        """Create snapshot of existing volume.

        :param str snapshot_name: new snapshot id
        :param str volume_name: original volume id
        """
        LOG.debug('create snapshot %(snap)s for volume %(vol)s', {
            'snap': snapshot_name,
            'vol': volume_name})

        vname = jcom.vname(volume_name)
        sname = jcom.sname(snapshot_name, None)

        snaps = self._list_volume_snapshots(volume_name, vname)

        for snap in snaps:
            if snap['name'] == sname:
                LOG.error("Snapshot %(snapshot)s exists at volume %(volume)s",
                          {"snapshot": sname,
                           "volume": snap['volume_name']})
                raise jexc.JDSSSnapshotExistsException(snapshot_name,
                                                       volume_name)
        self.ra.create_snapshot(vname, sname)

    def create_export_snapshot(self,
                               target_prefix,
                               target_name,
                               snapshot_name,
                               volume_name,
                               provider_auth,
                               luns_per_target=8):
        """Creates iscsi resources needed to start using snapshot

        :param str snapshot_name: openstack snapshot id
        :param str volume_name: openstack volume id
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        :param int luns_per_target: maximum number of luns that should be
                assigned to single iscsi taregt
        """

        luns_per_target = int(luns_per_target)
        sname = jcom.sname(snapshot_name, None)
        ovname = jcom.vname(volume_name)
        scname = jcom.sname(snapshot_name, volume_name)
        try:
            self._clone_object(scname, sname, ovname,
                               sparse=True,
                               create_snapshot=False,
                               readonly=True)

        except jexc.JDSSVolumeExistsException:
            LOG.debug(("Got Volume Exists exception, but do nothing as"
                       "%(snap)s is a snapshot"),
                      {'snap': scname})

        try:
            tvld = self._acquire_taget_volume_lun(
                    target_prefix,
                    target_name,
                    scname,
                    luns_per_target=luns_per_target)
            (tname, lun_id, volume_attached_flag, new_target_flag) = tvld

            if new_target_flag:
                # TODO: hendle case when volume is already assigned to target
                # we have to conduct search over all targets and then
                # ensure target volume
                return self._create_target_volume_lun(tname,
                                                      scname,
                                                      lun_id,
                                                      provider_auth)

            return self._ensure_target_volume_lun(tname,
                                                  scname,
                                                  lun_id,
                                                  provider_auth)

        except Exception as err:
            self._delete_volume(scname, cascade=True)
            raise err

    def remove_export(self, target_prefix, target_name, volume_name,
                      direct_mode=False):
        """Remove iscsi target created to make volume attachable

        :param str volume_name: openstack volume id
        """
        LOG.debug('Remove export for volume %(vol)s', {
                'vol': volume_name})

        vname = jcom.vname(volume_name)

        if direct_mode:
            vname = volume_name

        if not self.ra.is_lun(vname):
            LOG.warning(("Abandon detaching as volume %(volume)s does not "
                        "exist"),
                        {'volume': volume_name})
            return

        tvld = self._acquire_taget_volume_lun(target_prefix,
                                              target_name,
                                              vname)
        (tname, lun_id, volume_attached_flag, new_target_flag) = tvld

        if (volume_attached_flag or (new_target_flag is True)):
            try:
                self._detach_target_volume(tname, vname)
            except jexc.JDSSException as jerr:
                LOG.warning(jerr)

    def remove_export_snapshot(self,
                               target_prefix,
                               target_name,
                               snapshot_name,
                               volume_name,
                               direct_mode=False):
        """Remove tmp vol and iscsi target created to make snap attachable

        :param str snapshot_name: openstack snapshot id
        :param str volume_name: openstack volume id
        :param bool direct_mode: use actual disk name as volume id
        """
        LOG.debug('Remove export for volume %(vol)s snapshot %(snap)s', {
                'vol': volume_name,
                'snap': snapshot_name})

        scname = jcom.sname(snapshot_name, volume_name)

        if direct_mode:
            scname = snapshot_name

        if not self.ra.is_lun(scname):
            LOG.warning(("Abandon detaching of volume %(volume)s "
                        "snapshot %(snapshot)s as it does not exist"),
                        {'volume': volume_name,
                         'snapshot': snapshot_name})
            return

        tvld = self._acquire_taget_volume_lun(target_prefix,
                                              target_name,
                                              scname)
        (tname, lun_id, volume_attached_flag, new_target_flag) = tvld

        try:
            if (volume_attached_flag or (new_target_flag is False)):
                self._detach_target_volume(tname, scname)
        except jexc.JDSSException as jerr:
            self._delete_volume(scname, cascade=True)
            raise jerr

        # We do not do target detachment here because it was done before
        self._delete_volume(scname, cascade=True, detach_target=False)

    def _delete_snapshot(self, vname, sname):
        """Delete snapshot

        This method will delete snapshot mount point and snapshot if possible

        :param str vname: zvol name
        :param dict snap: snapshot info dictionary

        :return: None
        """

        pname = self._find_snapshot_parent(vname, sname)
        snapshot = dict()
        if pname is not None:
            try:
                snapshot = self.ra.get_snapshot(pname, sname)
            except jexc.JDSSResourceNotFoundException:
                LOG.debug('snapshot %s do not exists, it was already '
                          'deleted', sname)
                return
        else:
            LOG.debug('snapshot %s do not exists, it was already '
                      'deleted', sname)
            return

        clones = self._list_snapshot_clones_names(vname, sname)
        if len(clones) > 0:

            for cvname in clones:
                if jcom.is_hidden(cvname):
                    dsnaps = self._list_all_volume_snapshots(cvname, None)

                    if len(dsnaps) > 0:
                        msg = ("Snapshot is busy, delete dependent snapshots "
                               "first")
                        dsnames = [jcom.sid_from_sname(
                            s['name']) for s in dsnaps]
                        jcom.dependency_error(msg, dsnames)

                        raise jexc.JDSSSnapshotIsBusyException(
                            jcom.sid_from_sname(sname))
                    else:
                        self._delete_volume(cvname, cascade=False)

                if jcom.is_volume(cvname):
                    msg = ("Snapshot is busy, delete dependent clone "
                           "first")
                    dcnames = [jcom.idname(cvname)]
                    jcom.dependency_error(msg, dcnames)

                    raise jexc.JDSSSnapshotIsBusyException(
                        jcom.sid_from_sname(sname))

                if jcom.is_snapshot(cvname):
                    self._delete_volume(cvname, cascade=False)

        if jcom.is_hidden(pname):
            psnaps = self.ra.get_volume_snapshots_page(pname, 0)
            if len(psnaps) > 1:
                try:
                    self.ra.delete_snapshot(vname, sname, force_umount=True)
                except jexc.JDSSSnapshotNotFoundException:
                    LOG.debug('Snapshot %s not found', sname)
                    return
            else:
                self._delete_volume(cvname, cascade=True)
        if jcom.is_volume(pname):
            try:
                self.ra.delete_snapshot(vname, sname, force_umount=True)
            except jexc.JDSSSnapshotNotFoundException:
                LOG.debug('Snapshot %s not found', sname)
                return

    def delete_snapshot(self, volume_name, snapshot_name):
        """Delete snapshot of existing volume.

        :param str volume_name: volume id
        :param str snapshot_name: snapshot id
        """
        vname = jcom.vname(volume_name)
        sname = jcom.sname(snapshot_name, None)

        try:
            self._delete_snapshot(vname, sname)
        except jexc.JDSSResourceNotFoundException:
            self._delete_snapshot(vname, jcom.sname(snapshot_name,
                                                    volume_name))

    def get_volume_target(self,
                          target_prefix,
                          target_name,
                          volume_name,
                          snapshot_name=None,
                          direct_mode=False):
        """Get volume target
        Find target that the volume is attached to

        :param str volume_name: name of volume
        :param str direct: flag that indicates that volume name
            should not be changed

        :return: dictionary containing information regarding volume
                propagation through iscsi
                dict will contain:
                    target str: name of target
                    lun int: lun id that given volume is attached to
                    vips list(ip str: string of ip address)
                dict might contain:
                    username str: CHAP user name for authentication
                    password srt: CHAP password for authentication
        """
        vname = jcom.vname(volume_name)

        if snapshot_name:
            vname = jcom.sname(snapshot_name, volume_name)

        if direct_mode:
            vname = volume_name

        if not self.ra.is_lun(vname):
            raise jexc.JDSSVolumeNotFoundException(vname)

        tvld = self._acquire_taget_volume_lun(target_prefix,
                                              target_name,
                                              vname)

        (tname, lun_id, volume_attached_flag, new_target_flag) = tvld

        if new_target_flag or (volume_attached_flag is False):
            return None

        conforming_vips = self._get_conforming_vips()

        volume_info = dict()
        volume_info['vips'] = list(conforming_vips.values())
        volume_info['target'] = tname
        volume_info['lun'] = lun_id

    def _detach_volume(self, vname):
        """detach volume from target it is attached to

        Will go through all target, find one that volume is attached to
        and detach it from it
        If volume is a last one attached to particular target
        it will remove target

        :param str vname: physical volume id
        """
        LOG.debug("detach volume %s", vname)

        targets = self.ra.get_targets()
        for t in [target['name'] for target in targets]:
            luns = self.ra.get_target_luns(t)
            for lun in luns:
                if 'name' in lun and lun['name'] == vname:
                    if len(luns) == 1:
                        self.ra.delete_target(t)
                    else:
                        self.ra.detach_target_vol(t, vname)
                    return

    def _detach_target_volume(self, tname, vname):
        """detach_target_volume

        Will go through all target, find one that volume is attached to
        and detach it from it
        If target have onlyvolume is a last one attached to particular target
        it will remove target

        :param str vname: physical volume id
        """
        LOG.debug("detach target %s volume %s", tname, vname)

        try:
            self.ra.detach_target_vol(tname, vname)
        except jexc.JDSSResourceNotFoundException:
            pass

        luns = self.ra.get_target_luns(tname)

        if len(luns) == 0:
            try:
                self.ra.delete_target(tname)
            except jexc.JDSSResourceNotFoundException:
                pass

    def _ensure_target_volume_lun(self, tname, vname, lid, provider_auth,
                                  ro=False):
        """Checks if target configured properly and volume is attached to it
            at given lun

            If volume is 'busy' and attached to a different target it will
            detach volume from previous target and assign it to the one
            that is provided

        :param str target_id: target id that would be used for target naming
        :param str vname: physical volume id
        :param int lid: lun id
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        :return: dictionary containing information regarding volume
                propagation through iscsi
                dict will contain:
                    target str: name of target
                    lun int: lun id that given volume is attached to
                    vips list(ip str: string of ip address)
                dict might contain:
                    username str: CHAP user name for authentication
                    password srt: CHAP password for authentication
        """
        LOG.debug("ensure volume %s assigned to target %s with lun %s",
                  vname, tname, lid)

        if not provider_auth:
            LOG.debug("ensuring target %s for volume %s with no auth",
                      tname, vname)
        target_data = None
        clean_and_recrete = False

        volume_publication_info = dict()

        # first we check if given target exists
        # if not we do not need to run complex checks and
        # and can create it from ground up
        try:
            target_data = self.ra.get_target(tname)
        except jexc.JDSSResourceNotFoundException:
            clean_and_recrete = True

        if clean_and_recrete:
            try:
                # TODO: update this
                return self._create_target_volume_lun(tname,
                                                      vname,
                                                      lid,
                                                      provider_auth)
            except jexc.JDSSResourceIsBusyException:
                LOG.debug("looks like volume %s belogns to other target",
                          vname)
                # this only happens if volume is attached somewhere and it
                # not related to target spoecified in the reques
                # there fore we detach and try to reattach
                self._detach_target_volume(tname, vname)

            return self._create_target_volume_lun(tname,
                                                  tname,
                                                  lid,
                                                  provider_auth)
        volume_publication_info['target'] = tname

        # Here expected vips is a set of vip by name
        expected_vips = self._get_conforming_vips()
        if (('vip_allowed_portals' in target_data) and
                (set(target_data['vip_allowed_portals']['assigned_vips']) ==
                 set(expected_vips.keys()))):
            pass
        else:
            self.ra.set_target_assigned_vips(tname,
                                             list(expected_vips.keys()))

        volume_publication_info['vips'] = list(expected_vips.values())
        if not self.ra.is_target_lun(tname, vname, lid):
            self._attach_target_volume_lun(tname, vname, lid)

        volume_publication_info['lun'] = lid

        if provider_auth is not None:

            (__, auth_username, auth_secret) = provider_auth.split()
            volume_publication_info['username'] = auth_username
            volume_publication_info['password'] = auth_secret

            chap_cred = {"name": auth_username,
                         "password": auth_secret}

            try:
                users = self.ra.get_target_user(tname)
                if len(users) == 1:
                    if users[0]['name'] == chap_cred['name']:
                        return volume_publication_info
                    self.ra.delete_target_user(
                        tname,
                        users[0]['name'])
                for user in users:
                    self.ra.delete_target_user(
                        tname,
                        user['name'])
                self._set_target_credentials(tname, chap_cred)

            except jexc.JDSSException as jerr:
                self.ra.delete_target(tname)
                raise jerr

        return volume_publication_info

    def _acquire_taget_volume_lun(self, target_prefix, target_name, vname,
                                  luns_per_target=8):
        """Get target name and lun number for given volume

        This function acts as replacement for _get_target_name function
        because with new logic of target name generation we cannot
        know in advance name of a target for a given volume we have
        make requests to check existing targets

        It returns tuple:
        (<target_name>, <lun_id>, <volume attached>,<new target>)

        <target_name> is a str of a target shat should be used
        <lun id> is a int if a lun that should be used
        <volume attached> is a bool of indicating that given volume
            already attached and <taget name> and <lun id> depicting
            target and lun that are used to attach volume
            if given flag is false then volume is not attached and
            lun number indicates where volume can be attached to
        <new target> is a bool that is set to True if and only if
            target <target_name> do not exists and it is recommended to create
            one and attache volume to lun with ID specified at <lun_id>

        :return: (<target_name>, <lun_id>, <volume attached>,<new target>)
        """
        tname = target_prefix + target_name
        if target_prefix[-1] != ':':
            tname = target_prefix + ':' + target_name

        tlist = self.list_targets()
        target_re = re.compile(fr'^{tname}-(?P<id>\d+)$')

        related_targets = []
        related_targets_indexes = []

        for target in tlist:
            m = target_re.match(target)
            if m is not None:
                related_targets.append(target)
                related_targets_indexes.append(m.group('id'))
                LOG.debug("Related target %s with index %s",
                          target,
                          m.group('id'))

        # We found list of targets that might be related to
        # same volume group that volume of interest
        candidate_lun = None
        if related_targets is not None:
            related_targets.sort()
        for target in related_targets:
            luns = self.ra.get_target_luns(target)
            taken_luns = []
            # For each target we check if it has volume of interest
            # already attached
            for lun in luns:
                if lun['name'] == vname:
                    return (target, lun['lun'], True, False)
                taken_luns.append(int(lun['lun']))
            if candidate_lun is None:
                LOG.debug("Target %s has %d luns occupied: %s",
                          target, len(taken_luns), str(taken_luns))
                if len(taken_luns) >= luns_per_target:
                    continue
                for i in range(luns_per_target):
                    if i not in taken_luns:
                        LOG.debug("Found empty lun at target %s lun %d",
                                  target, i)
                        candidate_lun = (target, i)
                        break
        # TODO: search over all targets, as target prefix might change

        if candidate_lun is not None:
            return (candidate_lun[0], candidate_lun[1], False, False)

        for i in range(len(related_targets_indexes) + 1):
            if i not in related_targets_indexes:
                tcandidate = '-'.join([tname, str(i)])
                try:
                    self.ra.get_target(tcandidate)
                except jexc.JDSSResourceNotFoundException:
                    return (tcandidate, 0, False, True)
        return ('-'.join([tname, '0']), 0, False, True)

    def ensure_target_volume(self,
                             target_prefix,
                             target_name,
                             volume_name,
                             provider_auth,
                             direct_mode=False,
                             luns_per_target=8):
        """Ensures that given volume is attached to specific target

        This function checkes if volume is attached to given target.
        If it is not, it will attach volume to target and return its lun number
        If it is already attached it will return lun number of the volume

        Target name assigned to storage is a concatination of:
        target_prefix
        target_name
        suffix_number

        suffix_number is needed to distinguish among targets with same
        prefix+name for cases when too many volumes are assigned to
        too many pairs of prefix+name

        :return: dict with keys:
                    target str: target name
                    lun int: lun id
                    vips list(ip str): list of ips that should be used to
                        attach given target
        """
        LOG.debug(("ensure volume %(volume)s is assigned to target "
                   "with prefix %(prefix)s "
                   "group name %(group)s "
                   "luns per target %(lpt)s"), {
                        'prefix': target_prefix,
                        'group': target_name,
                        'volume': volume_name,
                        'lpt': luns_per_target})
        vname = jcom.vname(volume_name)
        luns_per_target = int(luns_per_target)

        if direct_mode:
            vname = volume_name

        if not self.ra.is_lun(vname):
            raise jexc.JDSSVolumeNotFoundException(vname)

        # target volume lune descriptor of form
        # (<target_name>, <lun_id>, <volume attached>,<new target>)
        tvld = self._acquire_taget_volume_lun(target_prefix,
                                              target_name,
                                              vname,
                                              luns_per_target=luns_per_target)
        (tname, lun_id, volume_attached_flag, new_target_flag) = tvld

        if new_target_flag:
            return self._create_target_volume_lun(tname,
                                                  vname,
                                                  lun_id,
                                                  provider_auth)

        return self._ensure_target_volume_lun(tname,
                                              vname,
                                              lun_id,
                                              provider_auth)

    def _get_conforming_vips(self):
        """get vips that conforms configuration requirments

        This function calculated vip names that should be assigned to iscsi
        target associated with specific pool on the basis of given config
        restrictions

        Method will raise JDSSVIPNotFoundException if no fitting vip was found
        :return: dictionary of vip name as key and ip as value
        """

        conforming_vips=dict()
        iscsi_addresses=[]

        if len(self.jovian_iscsi_vip_addresses) == 0:
            iscsi_addresses.extend(self.jovian_hosts)
        else:
            iscsi_addresses.extend(self.jovian_iscsi_vip_addresses)

        vip_data=self.ra.get_pool_vips()

        for vip in vip_data:
            if vip['address'] in iscsi_addresses:
                conforming_vips[vip['name']]=vip['address']

        if len(conforming_vips) == 0:
            raise jexc.JDSSVIPNotFoundException(iscsi_addresses)

        return conforming_vips

    def _create_target_volume_lun(self, target_name, vid, lid, provider_auth):
        """Creates target and attach volume to it

        :param target_name: name of a target to create
        :param vid: physical volume id, might identify snapshot mount
        :param lid: lun that vid will be assigned at target_name
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        :return: dictionary containing information regarding volume
                propagation through iscsi
                dict will contain:
                    target str: name of target
                    lun int: lun id that given volume is attached to
                    vips list(ip str: string of ip address)
                dict might contain:
                    username str: CHAP user name for authentication
                    password srt: CHAP password for authentication
        """
        LOG.debug("create target %s and assigne volume %s to lun %s",
                  target_name, vid, lid)

        volume_publication_info=dict()
        conforming_vips=self._get_conforming_vips()
        volume_publication_info['vips']=list(conforming_vips.values())
        # Create target
        self.ra.create_target(target_name,
                              list(conforming_vips.keys()),
                              use_chap=(provider_auth is not None))
        volume_publication_info['target']=target_name
        try:
            # Attach volume
            self._attach_target_volume_lun(target_name, vid, lid)
        except Exception as err:
            raise err
            # TODO: finish this

        volume_publication_info['lun']=lid
        # Set credentials
        if provider_auth is not None:
            (__, auth_username, auth_secret)=provider_auth.split()
            volume_publication_info['username']=auth_username
            volume_publication_info['password']=auth_secret
            chap_cred={"name": auth_username,
                         "password": auth_secret}

            self._set_target_credentials(target_name, chap_cred)

        return volume_publication_info

    def _list_targets(self):
        """List targets
        """
        targets=[]
        i=0
        # First we list all volume snapshots page by page
        try:
            while True:
                tpage=self.ra.get_targets_page(i)

                if len(tpage) > 0:
                    LOG.debug("Page: %s", str(tpage))

                    targets.extend(tpage)
                    i += 1
                else:
                    break

        except jexc.JDSSException as ex:
            LOG.error("List targets error. Because %(err)s",
                      {"err": ex})

        return targets

    def list_targets(self):
        targets_data=self.ra.get_targets()
        # TODO: switch to target listing with pages once
        # it is supported with jovian
        # self._list_targets()
        target_names=[]
        for t in targets_data:
            target_names.append(t['name'])

        return target_names

    def list_target_luns(self, target):
        luns = self.ra.get_target_luns(target)

        return luns

    def _attach_target_volume_lun(self, target_name, vname, lun):
        """Attach target to volume and handles exceptions

        Attempts to set attach volume to specific target.
        :param target_name: name of target
        :param vname: volume physical id
        :param lun: lun number that given vname will be attached to target_name
        """
        try:
            self.ra.attach_target_vol(target_name, vname, lun_id=lun)
        except jexc.JDSSException as jerr:
            msg=(f"Unable to attach volume {vname} to "
                   f"target {target_name} lun {lun} "
                   f"because of {jerr}.")
            LOG.warning(msg)
            raise jerr

    def _set_target_credentials(self, target_name, cred):
        """Set CHAP configuration for target and handle exceptions

        Attempts to set CHAP credentials for specific target.
        In case of failure will remove target.
        :param target_name: name of target
        :param cred: CHAP user name and password
        """
        try:
            self.ra.create_target_user(target_name, cred)

        except jexc.JDSSException as jerr:
            try:
                self.ra.delete_target(target_name)
            except jexc.JDSSException:
                pass

            err_msg = (('Unable to create user %(user)s '
                        'for target %(target)s '
                        'because of %(error)s.') % {
                            'target': target_name,
                            'user': cred['name'],
                            'error': jerr})

            LOG.error(err_msg)
            raise jexc.JDSSException(_(err_msg))

    def list_volumes(self):
        """List volumes related to this pool.

        :return: list of volumes
        """

        ret = []
        data = []
        try:
            data = self._list_all_pages(self.ra.get_volumes_page)
        except jexc.JDSSCommunicationFailure as jerr:
            raise jerr

        except jexc.JDSSException as ex:
            LOG.error("List volume error. Because %(err)s",
                      {"err": ex})
            raise Exception(('Failed to list volumes %s.') % ex.message)

        LOG.debug(data)
        for r in data:
            try:

                if not jcom.is_volume(r['name']):
                    continue

                vdata = {'name': jcom.idname(r['name']),
                         'size': r['volsize'],
                         'creation': r['creation']}

                if 'san:volume_id' in r:
                    vdata['san_scsi_id'] = r['san:volume_id']

                if 'default_scsi_id' in r:
                    vdata['scsi_id'] = r['default_scsi_id']

                ret.append(vdata)

            except Exception:
                pass
        return ret

    def get_volume(self, volume, direct_mode=False):
        """Get volume information.

        :return: volume id, san id, size
        """
        name = None

        if direct_mode:
            name = volume['id']
        else:
            name = jcom.vname(volume['id'])
        data = self.ra.get_lun(name)

        if (not direct_mode) and (not jcom.is_volume(name)):
            return dict()

        ret = {'name': name,
               'size': data['volsize']}

        if 'san:volume_id' in data:
            ret['san_scsi_id'] = data['san:volume_id']

        if 'default_scsi_id' in data:
            ret['scsi_id'] = data['default_scsi_id']

        return ret

    def get_nas_volume(self, nas_volume_name, direct_mode=False):
        """Get nas volume information.

        :return: volume id, size
        """
        name = None

        if direct_mode:
            name = nas_volume_name
        else:
            name = jcom.vname(nas_volume_name)
        data = self.ra.get_nas_volume(name)

        ret = {'name': name,
               'quota': data['quota']}

        return ret

    def list_nas_volumes(self):
        """List all NAS volumes (datasets) in the pool.

        :return: list of NAS volumes
        """
        LOG.debug('list all nas volumes')

        data = self.ra.get_nas_volumes()

        return data

    def create_nas_snapshot(self, snapshot_name, dataset_name,
                            nas_volume_direct_mode=False,
                            proxmox_volume=None,
                            ignoreexists=False):
        """Create snapshot of existing NAS volume (dataset).

        :param str snapshot_name: new snapshot name
        :param str dataset_name: dataset name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        """
        LOG.debug(('create snapshot %(snap)s for NAS volume %(vol)s '
                   'direct mode %(mode)s proxmox volume %(pvol)s'), {
            'snap': snapshot_name,
            'vol': dataset_name,
            'mode': str(nas_volume_direct_mode),
            'pvol': proxmox_volume})

        dname = jcom.vname(dataset_name)

        if nas_volume_direct_mode:
            dname = dataset_name

        sname = jcom.sname(snapshot_name, dataset_name,
                           proxmox_volume=proxmox_volume)

        try:
            self.ra.create_nas_snapshot(dname, sname)
        except jexc.JDSSSnapshotExistsException as err:
            if ignoreexists:
                pass
            else:
                raise err

    def _delete_nas_snapshot(self, vname, sname):
        """Delete snapshot

        This method will delete snapshot mount point and snapshot if possible

        :param str vname: zvol name
        :param dict snap: snapshot info dictionary

        :return: None
        """

        clones = []

        try:
            clones = self._list_nas_snapshot_clones_names(vname, sname)
        except jexc.JDSSSnapshotNotFoundException:
            LOG.debug('Snapshot %s not found', sname)
            pass
        except jexc.JDSSResourceNotFoundException:
            LOG.debug(('Resource related to nas-volume %s snapshot %s'
                       'not found'), vname, sname)
            pass

        if len(clones) > 0:
            for cvname in clones:
                if jcom.is_snapshot(cvname):
                    self._delete_nas_volume(cvname, cascade=False)

        try:
            self.ra.delete_nas_snapshot(vname, sname)
        except jexc.JDSSSnapshotNotFoundException:
            LOG.debug('Snapshot %s not found', sname)
            pass
        except jexc.JDSSResourceNotFoundException:
            LOG.debug(('Resource related to nas-volume %s snapshot %s'
                       'not found'), vname, sname)
            pass


    def delete_nas_snapshot(self, dataset_name, snapshot_name,
                            nas_volume_direct_mode=False,
                            proxmox_volume=None):
        """Delete snapshot of existing NAS volume (dataset).

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        """
        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        sname = jcom.sname(snapshot_name, dataset_name,
                           proxmox_volume=proxmox_volume)

        self._delete_nas_snapshot(dname, sname)

    def list_nas_snapshots(self, dataset_name, nas_volume_direct_mode=False,
                           proxmox_volume=None):
        """List snapshots for NAS volume (dataset).

        :param str dataset_name: dataset name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        :param str proxmox_volume: name of proxmox volume
        :return: list of snapshots
        """
        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        try:
            data = self._list_nas_volume_snapshots(dname, dname)
        except jexc.JDSSException as ex:
            LOG.error("List NAS snapshots error. Because %(err)s",
                      {"err": ex})
            raise

        out = []
        for d in data:
            r = {'snapshot_name': jcom.idname(d['name']),
                 'volume_name': jcom.idname(d['volume_name'])}
            if proxmox_volume:
                if proxmox_volume == jcom.proxid_from_sname(d['name']):
                    out.append(r)
            else:
                out.append(r)
        return out

    def get_nas_snapshot(self, dataset_name, snapshot_name,
                         nas_volume_direct_mode=False,
                         proxmox_volume=None):
        """Get NAS snapshot information.

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        :return: snapshot data
        """
        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        sname = jcom.sname(snapshot_name, dataset_name,
                           proxmox_volume=proxmox_volume)

        data = self.ra.get_nas_snapshot(dname, sname)
        return data

    def create_nas_clone(self, dataset_name, snapshot_name, clone_name,
                         nas_volume_direct_mode=False, **options):
        """Create clone from NAS snapshot.

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param str clone_name: clone name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        :param options: optional ZFS properties
        :return: clone data
        """
        LOG.debug('create clone %(clone)s from snapshot %(snap)s '
                  'of NAS volume %(vol)s', {
            'clone': clone_name,
            'snap': snapshot_name,
            'vol': dataset_name})

        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        sname = jcom.sname(snapshot_name, dataset_name)
        cname = clone_name

        return self.ra.create_nas_clone(dname, sname, cname, **options)

    def delete_nas_clone(self, dataset_name, snapshot_name, clone_name,
                         nas_volume_direct_mode=False):
        """Delete NAS clone.

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param str clone_name: clone name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        """
        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        sname = jcom.sname(snapshot_name, None)
        cname = clone_name

        self.ra.delete_nas_clone(dname, sname, cname)

    def list_nas_clones(self, dataset_name, snapshot_name,
                        nas_volume_direct_mode=False):
        """List clones for NAS snapshot.

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        :return: list of clones
        """
        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        sname = jcom.sname(snapshot_name, dataset_name)

        try:
            data = self.ra.get_nas_clones(dname, sname)
        except jexc.JDSSException as ex:
            LOG.error("List NAS clones error. Because %(err)s",
                      {"err": ex})
            raise

        return data

    def get_nas_snapshot_publish_name(self, dataset_name, snapshot_name,
                                      proxmox_volume=None,
                                      nas_volume_direct_mode=False):
        """Get the clone name that would be used for publishing a snapshot.

        Returns the clone dataset name without actually creating the clone.
        This is useful for determining mount paths.

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        :return: clone dataset name (properly formatted with se_ prefix)
        """
        # Generate clone name using sname with dataset reference
        # This creates the se_ prefixed name with base32 encoding
        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        clone_name = jcom.sname(snapshot_name, dataset_name)
        return clone_name

    def publish_nas_snapshot(self, dataset_name, snapshot_name,
                             proxmox_volume=None,
                             nas_volume_direct_mode=False):
        """Publish NAS snapshot by creating clone and NFS share.

        Creates a snapshot export clone with proper se_ naming and
        creates an NFS share for it, making it accessible for mounting.

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        :return: clone dataset name (properly formatted with se_ prefix)
        """
        LOG.debug('publish snapshot %(snap)s from NAS volume %(vol)s', {
            'snap': snapshot_name,
            'vol': dataset_name})

        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        sname = jcom.sname(snapshot_name, dataset_name,
                           proxmox_volume=proxmox_volume)
        # Generate clone name using sname with dataset reference
        # This creates the se_ prefixed name with base32 encoding
        #clone_name = jcom.sname(snapshot_name, dataset_name,
        #                         proxmox_volume=proxmox_volume)

        #self.ra.get_nas_snapshot_clone(dname, sname, clone_name)
        # Create clone from snapshot
        try:
            self.ra.create_nas_clone(dname, sname, sname)
        except jexc.JDSSResourceExistsException:
            pass
        # Create NFS share for the clone
        path = "{}/{}".format(self._pool, sname)
        try:
            self.ra.create_share(sname, path,
                                 active=True,
                                 proto='nfs',
                                 insecure_connections=False,
                                 synchronous_data_record=True)
        except jexc.JDSSResourceExistsException:
            pass

        LOG.debug('published snapshot as clone %(clone)s', {
            'clone': sname})

        for i in range(3):
            try:
                share_data = self.ra.get_share(sname)
                if "real_path" in share_data:
                    return share_data['real_path']
                else:
                    time.sleep(1)
                    continue
            except Exception:
                time.sleep(1)
                continue

        self.ra.delete_share(sname)
        self.ra.delete_nas_clone(dname, sname, sname)
        raise jexc.JDSSException("Unable to create share %(share)s",
                                 {'share': sname})

    def unpublish_nas_snapshot(self, dataset_name, snapshot_name,
                               proxmox_volume=None,
                               nas_volume_direct_mode=False):
        """Unpublish NAS snapshot by deleting clone and NFS share.

        Removes the NFS share and deletes the snapshot export clone,
        cleaning up resources created by publish_nas_snapshot.

        :param str dataset_name: dataset name
        :param str snapshot_name: snapshot name
        :param bool nas_volume_direct_mode: use dataset name without
                                            transformation
        """
        LOG.debug('unpublish snapshot %(snap)s from NAS volume %(vol)s', {
            'snap': snapshot_name,
            'vol': dataset_name})

        if nas_volume_direct_mode:
            dname = dataset_name
        else:
            dname = jcom.vname(dataset_name)
        sname = jcom.sname(snapshot_name, dataset_name,
                           proxmox_volume=proxmox_volume)

        # Delete NFS share
        try:
            self.ra.delete_share(sname)
        except jexc.JDSSResourceNotFoundException:
            pass

        # Delete clone
        try:
            self.ra.delete_nas_clone(dname, sname, sname)
        except jexc.JDSSResourceNotFoundException:
            pass

        LOG.debug('unpublished snapshot clone %(clone)s', {
            'clone': sname})

    def get_snapshot(self, volume_name, snapshot_name,
                     export=False, direct_mode=False):
        """Get volume information.

        :return: volume id, san id, size
        """

        if direct_mode:
            vname = volume_name
            sname = snapshot_name
        else:
            if export:
                sname = jcom.sname(snapshot_name, volume_name)
                data = self.ra.get_lun(sname)
            else:
                vname = jcom.vname(volume_name)
                sname = jcom.sname(snapshot_name)
                data = self.ra.get_snapshot(vname, sname)

        ret = dict()

        if 'san:volume_id' in data:
            ret['san_scsi_id'] = data['san:volume_id']
        if 'default_scsi_id' in data:
            ret['scsi_id'] = data['default_scsi_id']
        return ret

    def _set_provisioning_thin(self, vname, thinp):

        provisioning = 'thin' if thinp else 'thick'

        LOG.info("Setting volume %s provisioning %s",
                 jcom.idname(vname),
                 provisioning)

        prop = {'provisioning': provisioning}
        try:
            self.ra.modify_lun(vname, prop=prop)
        except jexc.JDSSException as err:
            emsg = (("Failed to set volume %(vol)s provisioning "
                     "%(ptype)s") % {
                'vol': jcom.idname(vname),
                'ptype': provisioning})
            raise Exception(emsg) from err

    def rename_volume(self, volume_name, new_volume_name):
        LOG.debug("Rename volume %s to %s",
                  volume_name,
                  new_volume_name)

        vname = jcom.vname(volume_name)
        nvname = jcom.vname(new_volume_name)
        prop = {'name': nvname}
        try:
            self.ra.modify_lun(vname, prop)
        except jexc.JDSSException as err:
            emsg="Failed to rename volume %(vol)s to %(new_name)s" % {
                'vol': vname,
                'new_name': nvname}
            raise Exception(emsg) from err

    def _list_all_snapshots(self, f=None):
        resp = []
        i = 0
        while True:
            spage = self.ra.get_snapshots_page(i)

            if len(spage) > 0:
                LOG.debug("Page: %s", str(spage))

                if f is not None:
                    resp.extend(filter(f, spage))
                else:
                    resp.extend(spage)
                i += 1
            else:
                break

        return resp

    def _list_all_pages(self, resource_getter, f=None):
        resp=[]
        i=0
        while True:
            spage=resource_getter(i)

            if len(spage) > 0:
                LOG.debug("Page: %s", str(spage))

                if f is not None:
                    resp.extend(filter(f, spage))
                else:
                    resp.extend(spage)
                i += 1
            else:
                break

        return resp

    # Expand this function with remove hidden volume if that volume
    # have not snapshots
    def _list_all_volume_snapshots(self, vname, f=None):

        snaps = []

        i = 0
        LOG.debug("Listing all volume snapshots: %s", vname)

        while True:
            spage = []
            try:
                spage = self.ra.get_volume_snapshots_page(vname, i)
            except jexc.JDSSResourceNotFoundException:
                return snaps

            LOG.debug("spage %s", str(spage))
            if len(spage) > 0:

                if f is not None:
                    snaps.extend(filter(f, spage))
                else:
                    snaps.extend(spage)
                i += 1
            else:
                break

        return snaps

    def _list_volume_snapshots(self, ovolume_name, vname):
        """List volume snapshots

        :return: list of volume related snapshots
        """
        out = []
        snapshots = []
        i = 0
        # First we list all volume snapshots page by page
        try:
            while True:
                spage = self.ra.get_volume_snapshots_page(vname, i)

                if len(spage) > 0:
                    LOG.debug("Page: %s", str(spage))

                    snapshots.extend(spage)
                    i += 1
                else:
                    break

        except jexc.JDSSException as ex:
            LOG.error("List snapshots error. Because %(err)s",
                      {"err": ex})

        # Each snapshot we check
        for snap in snapshots:
            # if that is a linked clone one we might not
            # want to list it for specific volume
            if jcom.is_volume(snap['name']):
                if all:
                    snap['volume_name'] = vname
                    out.append(snap)
                else:
                    LOG.warning("Linked clone present among volumes")
                continue

            if jcom.is_snapshot(snap['name']):
                vid = jcom.vid_from_sname(snap['name'])
                if vid is None or vid == ovolume_name:
                    # That is used in create_snapshot function
                    # to provide detailed
                    # info in case volume already have snapshot
                    snap['volume_name'] = vname

                    out.append(snap)
                    for clone in self._list_snapshot_clones_names(vname,
                                                                  snap['name']):

                        LOG.debug(
                            "List volume recursion step for list_volume_snapshots")
                        out.extend(self._list_volume_snapshots(ovolume_name,
                                                               clone))
                    continue
            if all:
                snap['volume_name'] = vname
                out.append(snap)

        return out

    def _list_nas_volume_snapshots(self, ovolume_name, vname):
        """List volume snapshots

        :return: list of volume related snapshots
        """
        out = []
        snapshots = []
        i = 0
        # First we list all volume snapshots page by page
        try:
            while True:
                spage = self.ra.get_nas_volume_snapshots_page(vname, i)

                if len(spage) > 0:
                    LOG.debug("Page: %s", str(spage))

                    snapshots.extend(spage)
                    i += 1
                else:
                    break

        except jexc.JDSSException as ex:
            LOG.error("List snapshots error. Because %(err)s",
                      {"err": ex})

        # Each snapshot we check
        for snap in snapshots:
            # if that is a linked clone one we might not
            # want to list it for specific volume
            if jcom.is_volume(snap['name']):
                if all:
                    snap['volume_name'] = vname
                    out.append(snap)
                else:
                    LOG.warning("Linked clone present among volumes")
                continue

            if jcom.is_snapshot(snap['name']):
                vid = jcom.vid_from_sname(snap['name'])
                if vid is None or vid == ovolume_name:
                    # That is used in create_snapshot function
                    # to provide detailed
                    # info in case volume already have snapshot
                    snap['volume_name'] = vname

                    out.append(snap)
                    continue
            if all:
                snap['volume_name'] = vname
                out.append(snap)

        return out

    def list_snapshots(self, volume_name):
        """List snapshots related to this volume.

        :return: list of volumes
        """

        ret = []
        vname = jcom.vname(volume_name)
        try:
            data = self._list_volume_snapshots(volume_name, vname)
            # data = self.ra.get_snapshots(vname)

        except jexc.JDSSException as ex:
            LOG.error("List snapshots error. Because %(err)s",
                      {"err": ex})
            raise Exception(('Failed to list snapshots %s.') % volume_name)

        for r in data:
            try:
                LOG.debug("physical volume %s snap volume %s snap name %s",
                          volume_name,
                          jcom.vid_from_sname(r['name']),
                          r['name'])

                vid = jcom.vid_from_sname(r['name'])
                if vid == volume_name or vid is None:
                    ret.append({'name': jcom.sid_from_sname(r['name'])})

            except Exception:
                continue
        return ret

    def _promote_volume(self, cname):
        """Promote volume.

        Takes clone_name and promotes it until it hits not hidden volume
        """

        cvolume=self.ra.get_lun(cname)

        ovname=jcom.origin_volume(cvolume)

        if ovname is not None and len(ovname) > 0:

            if jcom.is_hidden(ovname):

                self.ra.promote(ovname,
                                jcom.origin_snapshot(cvolume),
                                cname)
                try:
                    self.ra.delete_lun(ovname,
                                       force_umount=True,
                                       recursively_children=False)
                except jexc.JDSSResourceIsBusyException:
                    LOG.debug('unable to delete volume %s, it is busy',
                              ovname)
                except jexc.JDSSResourceNotFoundException:
                    LOG.debug('Hidden volume %s not found', ovname)
                except jexc.JDSSException as jerr:
                    LOG.error(
                        "Unable to continue volume %(volume)s promotion,"
                        "because of inability to conduct garbage cleaning "
                        "on volume %(hvolume)s with error %(err)s.", {
                            "volume": cname,
                            "hvolume": ovname,
                            "err": jerr})
                return self._promote_volume(cname)

        return

    def _find_snapshot_parent(self, vname, sname):

        out=[]
        snapshots=[]
        i=0
        try:
            while True:
                spage=self.ra.get_volume_snapshots_page(vname, i)

                if len(spage) > 0:
                    LOG.debug("Page: %s", str(spage))

                    snapshots.extend(spage)
                    i += 1
                else:
                    break

        except jexc.JDSSException as ex:
            LOG.error("List snapshots error. Because %(err)s",
                      {"err": ex})

        for snap in snapshots:
            if snap['name'] == sname:
                return vname
            if jcom.is_volume(snap['name']):
                LOG.warning("Linked clone present among volumes")
                continue

            for clone in self._list_snapshot_clones_names(vname, snap['name']):
                out = self._find_snapshot_parent(clone, sname)
                if out is not None:
                    return out
        return None

    def _update_volume_stats(self):
        """Retrieve stats info."""
        LOG.debug('Updating volume stats')

        pool_stats = self.ra.get_pool_stats()
        total_capacity = math.floor(int(pool_stats["size"]) / o_units.Gi)
        free_capacity = math.floor(int(pool_stats["available"]) / o_units.Gi)

        reserved_percentage = (
            self.configuration.get('reserved_percentage', 0))

        if total_capacity is None:
            total_capacity = 'unknown'
        if free_capacity is None:
            free_capacity = 'unknown'

        location_info = '%(driver)s:%(host)s:%(volume)s' % {
            'driver': self.__class__.__name__,
            'host': self.ra.get_active_host()[0],
            'volume': self._pool
        }

        self._stats = {
            'vendor_name': 'Open-E',
            'driver_version': self.VERSION,
            'storage_protocol': 'iSCSI',
            'total_capacity_gb': total_capacity,
            'free_capacity_gb': free_capacity,
            'reserved_percentage': int(reserved_percentage),
            'volume_backend_name': self.backend_name,
            'QoS_support': False,
            'location_info': location_info,
            'multiattach': True
        }

        LOG.debug('Total capacity: %d, '
                  'Free %d.',
                  self._stats['total_capacity_gb'],
                  self._stats['free_capacity_gb'])

    def get_volume_stats(self):
        """Return information about pool capacity

        return (total_gb, free_gb)
        """
        self._update_volume_stats()

        return (self._stats['total_capacity_gb'],
                self._stats['free_capacity_gb'])

    def _list_snapshot_rollback_dependency(self, vname, sname):
        """List snapshot rollback dependency return list of resource that
            would be affected by rollback

        List that is returned is not exact full list and should not be used
        to make decision of rollback is possible

        :param vname: physical volume id
        :param sname: physical snapshot id that belongs to vname

        :return: { 'snapshots': [<list of snapshots preventing rollback>],
                   'clones':    [<list of clones preventing rollback>]}
        """
        rsnap = {}

        try:
            rsnap = self.ra.get_snapshot(vname, sname)
        except jexc.JDSSResourceNotFoundException as nferr:
            LOG.debug('Volume %s snapshot %s not found',
                      jcom.idname(vname), jcom.idname(sname))
            raise nferr
        except jexc.JDSSException as jerr:
            LOG.error(
                "Unable to get volume %(volume)s snapshot %(snapshot)s "
                "information %(err)s.", {
                    "volume": vname,
                    "snapshot": sname,
                    "err": jerr})
            raise jerr

        dformat = "%Y-%m-%d %H:%M:%S"
        rdate = None
        if (('creation' in rsnap) and
            (type(rsnap['creation']) is str) and
                (len(rsnap['creation']) > 0)):
            rdate = datetime.datetime.strptime(rsnap['creation'], dformat)
            LOG.debug('Rollback date of snapshot %s is %s',
                      sname, str(rdate))

        def filter_older_snapshots(snap):

            if snap['name'] == sname:
                return False

            if ('properties' in snap):
                sp = snap['properties']
                if (('creation' in sp) and
                        isinstance(sp['creation'], int)):
                    ts_dt = datetime.datetime.fromtimestamp(
                                sp['creation'])
                    if rdate is not None:
                        if ts_dt >= rdate:
                            return True
                        else:
                            return False
                    else:
                        return True
                else:
                    return True
            else:
                raise jexc.JDSSException(
                    "Unable to identify snapshot properties")

        snapshots = self._list_all_volume_snapshots(
            vname, filter_older_snapshots)

        snapshot_names = [jcom.idname(s['name']) for s in snapshots]
        clone_names = []
        for s in snapshots:
            snap_clones = self._list_snapshot_clones_names(vname, s['name'])
            clone_names.extend([jcom.idname(c)
                                for c in snap_clones])

        out = {'snapshots': snapshot_names,
               'clones': clone_names}
        return out

    def rollback_check(self, volume_name, snapshot_name):
        """Rollback check if volume can be rolled back to specific snapshot

        It checks if other snapshots or clones depend on snapshot sname
        If rollback can be commited sucessfully function returns empty list
        If rollback cause deletion of resources, function will raise exception

        :param vname: physical volume id
        :param sname: physical snapshot id that belongs to vname

        :return: { 'snapshots': [<list of snapshots preventing rollback>],
                   'clones':    [<list of clones preventing rollback>]}
        """
        vname = jcom.vname(volume_name)
        sname = jcom.sname(snapshot_name, None)
        dependency = {}
        try:
            dependency = self.ra.get_snapshot_rollback(vname, sname)
        except jexc.JDSSResourceNotFoundException as nferr:
            LOG.debug('Volumes %s snapshot %s not found', vname, sname)
            raise nferr
        except jexc.JDSSException as jerr:
            LOG.error(
                "Unable to continue volume %(volume)s rollback to "
                "snapshot %(snapshot)s because of inability to check snapshot "
                "rollback information %(err)s.", {
                    "volume": jcom.idname(vname),
                    "snapshot": jcom.idname(sname),
                    "err": jerr})
            raise jerr

        if (len(dependency) > 0 and
            "snapshots" in dependency and
                "clones" in dependency):
            if (dependency["snapshots"] == 0 and
                    dependency["clones"] == 0):
                return None
            else:
                LOG.debug("rolling back is blocked by resources %s",
                          str(dependency))
        out = self._list_snapshot_rollback_dependency(vname, sname)

        if len(out['snapshots']) == 0 and dependency['snapshots'] > 0:
            out['snapshots'] = ["Unknown"]

        if len(out['clones']) == 0 and dependency['clones'] > 0:
            out['clones'] = ["Unknown"]

        return out

    def rollback(self, volume_name, snapshot_name, force_snapshots=False):
        """Rollback volume to specific snapshot

        This function operates around ZFS rollback.
        It checks if other snapshots or clones depend on snapshot sname
        And commits rollback if no dependecy is found.
        In other case it raises ResourceIsBusy exception.

        :param vname: physical volume id
        :param sname: physical snapshot id that belongs to vname

        :return: None
        """

        vname = jcom.vname(volume_name)
        sname = jcom.sname(snapshot_name, None)

        dependency = {}
        try:
            dependency = self.ra.get_snapshot_rollback(vname, sname)
        except jexc.JDSSResourceNotFoundException as nferr:
            LOG.debug('Volumes %s snapshot %s not found', vname, sname)
            raise nferr
        except jexc.JDSSException as jerr:
            LOG.error(
                "Unable to continue volume %(volume)s rollback to "
                "snapshot %(snapshot)s because of inability to check snapshot "
                "rollback information %(err)s.", {
                    "volume": jcom.idname(vname),
                    "snapshot": jcom.idname(sname),
                    "err": jerr})
            raise jerr

        if (len(dependency) > 0 and
                "snapshots" in dependency and
                "clones" in dependency):
            if (dependency["snapshots"] == 0 and
                    dependency["clones"] == 0):
                LOG.info(("rolling back volume %(vol)s to snapshot "
                          "%(snap)s"),
                         {'vol': jcom.idname(vname),
                          'snap': jcom.idname(sname)})
                self.ra.snapshot_rollback(vname, sname)
                LOG.info(("rolling back volume %(vol)s to snapshot "
                          "%(snap)s done"),
                         {'vol': jcom.idname(vname),
                          'snap': jcom.idname(sname)})
                return
            elif (force_snapshots):
                if dependency['clones'] == 0:
                    self.ra.snapshot_rollback(vname, sname)
                    return
                else:
                    LOG.debug("forced rolling back is blocked by %s clones",
                              dependency['clones'])
            else:
                LOG.debug("rolling back is blocked by resources %s",
                          dependency)

        deplist = self._list_snapshot_rollback_dependency(vname, sname)

        raise jexc.JDSSRollbackIsBlocked(volume_name,
                                         snapshot_name,
                                         deplist['snapshots'],
                                         deplist['clones'],
                                         dependency['snapshots'],
                                         dependency['clones'])

    @property
    def backend_name(self):
        """Return backend name."""
        backend_name = None
        if self.configuration:
            backend_name = self.configuration.get('volume_backend_name',
                                                  'Open-EJovianDSS')
        if not backend_name:
            backend_name = self.__class__.__name__
        return backend_name

    def create_share(self, share_name, quota_size,
                     reservation=None,
                     direct_mode=False):

        sharename = share_name if direct_mode else jcom.vname(share_name)
        # create nas / ensure nas volume is present
        # TODO: rework it so that there will be only one place of
        # sharename generation
        try:
            self.create_nas_volume(share_name, quota_size,
                                   reservation=reservation,
                                   direct_mode=direct_mode)
        except jexc.JDSSDatasetExistsException:
            LOG.debug("Looks like nas volume %s already exists", share_name)

        path = "{}/{}".format(self._pool, sharename)

        self.ra.create_share(sharename, path,
                             active=True,
                             proto='nfs',
                             insecure_connections=False,
                             synchronous_data_record=True)

    def delete_share(self, share_name, direct_mode=False):
        sharename = share_name if direct_mode else jcom.vname(share_name)

        self.ra.delete_share(sharename)

        self.delete_nas_volume(share_name, direct_mode=False)

    def list_shares(self):
        """List shares

        :return: list of volumes
        """

        ret = []
        try:
            data = self._list_all_pages(self.ra.get_shares_page)

        except jexc.JDSSException as ex:
            LOG.error("List shares error. Because %(err)s",
                      {"err": ex})
            raise Exception(('Failed to list shares %s.') % ex)

        for r in data:
            try:

                LOG.debug(r['name'])
                if not jcom.is_volume(r['name']):
                    continue

                sdata = {'name': jcom.idname(r['name']),
                         'path': r['path']}

                if 'nfs' in r:
                    sdata['proto']='nfs'
                    sdata['proto_data']=r['nfs']

                ret.append(sdata)

            except Exception:
                pass
        return ret

    def resize_share(self, share_name, new_size, direct_mode=False):
        """Extend an existing volume.

        :param str volume_name: volume id
        :param int new_size: volume new size in Gi
        """
        LOG.debug("Extend share: %(name)s to size:%(size)s",
                  {'name': share_name, 'size': new_size})

        shname=jcom.vname(share_name)

        if direct_mode:
            shname=share_name
        self.ra.extend_nas_volume(shname, new_size)
