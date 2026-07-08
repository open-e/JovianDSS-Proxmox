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
import random
import re
import string
import hashlib
import time

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

        self.VERSION = "0.11.6"

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
        deleted = False
        last_err = None
        max_attempts = 3

        for attempt in range(max_attempts):
            try:
                vol = self.ra.get_lun(vname)
            except jexc.JDSSResourceNotFoundException:
                LOG.debug('unable to get volume %s info, '
                          'assume it was already deleted', vname)
                return

            try:
                self.ra.delete_lun(vname,
                                   force_umount=False,
                                   recursively_children=recursive)
                deleted = True
                break

            except jexc.JDSSResourceIsBusyException as jerr:
                LOG.debug('unable to conduct direct volume %s deletion', vname)
                if not recursive:
                    raise
                deleted = True
                break

            except jexc.JDSSResourceNotFoundException:
                LOG.debug('volume %s does not exist, it was already '
                          'deleted', vname)
                return

            except jexc.JDSSCfgParserException as jerr:
                LOG.warning('iSCSI config cleanup failed for volume %s '
                            '(stale target reference), retry %d/%d: %s',
                            vname, attempt + 1, max_attempts, jerr)
                last_err = jerr
                time.sleep(1)

        if not deleted:
            raise last_err

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
                                        force_umount=False)

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
    def _delete_volume(self, vname, cascade=False, detach_target=True,
                       target_name=None):
        """_delete_volume delete routine containing delete logic

        :param str vname: physical volume id
        :param bool cascade: flag for cascade volume deletion
            with its snapshots
        :param bool delete_target: indicate ifwe have to check for target
            related to given volume
        :param str target_name: optional target group name hint (e.g. 'vm-999')

        :return: None
        """
        LOG.debug("Deleting %s", vname)
        # TODO: consider more optimal method for identification
        # if volume is assigned to any target

        if detach_target:
            try:
                self._detach_volume(vname, target_name=target_name)
            except jexc.JDSSException as jerr:
                LOG.warning('Could not detach volume %s from target: %s',
                            vname, jerr)

        try:
            # First we try to delete lun, if it has no snapshots deletion will
            # succeed
            self._delete_vol_with_source_snap( vname, recursive=cascade)

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

    def delete_volume(self, volume_name, cascade=False, print_and_exit=False,
                      target_name=None):
        """Delete volume

        :param volume: volume reference
        :param cascade: remove snapshots of a volume as well
        :param target_name: optional target group name hint (e.g. 'vm-999').
            When provided, the detach scan is limited to targets belonging
            to this group instead of scanning the entire pool.
        """
        vname = jcom.vname(volume_name)

        LOG.debug('deleting volume %s', vname)

        if print_and_exit:
            LOG.debug("Print only deletion")
            return self._list_resources_to_delete(vname, cascade=True)

        if not self.ra.is_lun(vname):
            raise jexc.JDSSVolumeNotFoundException(volume=volume_name)

        return self._delete_volume(vname, cascade=cascade,
                                   target_name=target_name)

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
            try:
                self.ra.create_snapshot(ovname, sname)
            except jexc.JDSSSnapshotExistsException as seerr:
                try:
                    if jcom.is_volume(sname):
                        self.ra.delete_snapshot(ovname,
                                                sname,
                                                recursively_children=False,
                                                force_umount=False)
                        self.ra.create_snapshot(ovname, sname)
                    else:
                        raise seerr
                except jexc.JDSSException as jerrd:
                    LOG.warning("Because of %s physical snapshot %s of volume"
                                " %s have to be removed manually",
                                jerrd,
                                sname,
                                ovname)
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
                # Remove the snapshot backing the failed clone, but ONLY the
                # intermediate one this call created (volume-named,
                # jcom.is_volume). A real snapshot name here means the
                # exists-already warn path above proceeded over a
                # pre-existing user snapshot — deleting that would destroy
                # actual snapshot data (review F-15 + maintainer amendment).
                if create_snapshot and jcom.is_volume(sname):
                    try:
                        self.ra.delete_snapshot(ovname,
                                                sname,
                                                recursively_children=True,
                                                force_umount=False)
                    except jexc.JDSSException as jerrd:
                        LOG.warning("Because of %s snapshot %s of volume "
                                    "%s has to be removed manually",
                                    jerrd, sname, ovname)
                raise jerr
        except jexc.JDSSException as jerr:
            # This is a garbage collecting section responsible for cleaning
            # all the mess of request failed
            # Same intermediate-only rule as above: never delete a
            # pre-existing user snapshot. sname is what the create call at
            # the top of this method actually made (equal to cvname for the
            # current create_snapshot caller).
            if create_snapshot and jcom.is_volume(sname):
                try:
                    self.ra.delete_snapshot(ovname,
                                            sname,
                                            recursively_children=True,
                                            force_umount=False)
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
            (tname, lun_id, volume_attached_flag, new_target_flag,
             acq_scsi_id) = tvld

            if new_target_flag:
                # TODO: hendle case when volume is already assigned to target
                # we have to conduct search over all targets and then
                # ensure target volume
                return self._create_target_volume_lun(tname,
                                                      scname,
                                                      lun_id,
                                                      provider_auth)

            return self._ensure_target_volume_lun(
                tname, scname, lun_id, provider_auth,
                volume_attached=volume_attached_flag,
                new_target=new_target_flag,
                scsi_id=acq_scsi_id)

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

        tvld = self._acquire_taget_volume_lun(target_prefix,
                                              target_name,
                                              vname,
                                              current=True)
        (tname, lun_id, volume_attached_flag, new_target_flag, _) = tvld
        if ((tname is not None) and (volume_attached_flag is True)):
            try:
                self._detach_target_volume(tname, vname)
            except jexc.JDSSException as jerr:
                LOG.warning(jerr)

        if random.randint(1, 100) == 7:
            self._delete_zombie_targets(target_prefix, target_name)

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
                                              scname,
                                              current=True)
        (tname, lun_id, volume_attached_flag, new_target_flag, _) = tvld

        try:
            if (volume_attached_flag or (new_target_flag is False)):
                if tname is not None:
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
                    self.ra.delete_snapshot(vname, sname, force_umount=False)
                except jexc.JDSSSnapshotNotFoundException:
                    LOG.debug('Snapshot %s not found', sname)
                    return
            else:
                self._delete_volume(cvname, cascade=True)
        if jcom.is_volume(pname):
            try:
                self.ra.delete_snapshot(vname, sname, force_umount=False)
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
                          direct_mode=False,
                          current=False):
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
                                              vname,
                                              current=current)

        (tname, lun_id, volume_attached_flag, new_target_flag, scsi_id) = tvld

        if tname is None:
            return None

        if new_target_flag or (volume_attached_flag is False):
            return None

        conforming_vips = self._get_conforming_vips()

        volume_info = dict()
        volume_info['vips'] = list(conforming_vips.values())
        volume_info['target'] = tname
        volume_info['lun'] = lun_id
        volume_info['scsi_id'] = scsi_id
        return volume_info

    def _detach_volume(self, vname, target_name=None):
        """detach volume from target it is attached to

        Will go through targets, find one that volume is attached to
        and detach it from it. If volume is the last one attached to
        a particular target it will remove that target.

        When target_name is provided the scan is limited to targets
        belonging to that group (e.g. 'vm-999'), avoiding a full
        pool-wide scan.  Falls back to the full scan when no hint is
        given or when no matching target is found with the hint.

        :param str vname: physical volume id
        :param str target_name: optional target group name hint (e.g. 'vm-999')
            when provided, only targets matching this name are scanned
        """
        LOG.debug("detach volume %s (target_name hint: %s)", vname, target_name)

        all_targets = self.ra.get_targets()

        # Build a filtered candidate list when we have a group hint so we
        # avoid iterating over every target in the pool (~60+ REST calls).
        candidates = all_targets
        if target_name is not None:
            tprefix = self.jovian_target_prefix
            tname = tprefix + target_name
            if tprefix[-1] != ':':
                tname = tprefix + ':' + target_name
            target_re = re.compile(fr'^{re.escape(tname)}-\d+$')
            candidates = [t for t in all_targets
                          if target_re.match(t['name'])]
            LOG.debug("Filtered detach scan to %d/%d targets matching %s",
                      len(candidates), len(all_targets), tname)

        for t in [target['name'] for target in candidates]:
            try:
                luns = self.ra.get_target_luns(t)
            except jexc.JDSSResourceNotFoundException:
                # Target disappeared between get_targets() and get_target_luns()
                # (concurrent deletion). Skip it.
                LOG.debug("Target %s vanished during detach scan, skipping", t)
                continue
            for lun in luns:
                if 'name' in lun and lun['name'] == vname:
                    if len(luns) == 1:
                        self.ra.detach_target_vol(t, vname)
                        for i in range(3):
                            try:
                                self.ra.delete_target(t)
                            except jexc.JDSSResourceNotFoundException:
                                return
                            except Exception:
                                pass

                            try:
                                self.ra.get_target(t)
                            except jexc.JDSSResourceNotFoundException:
                                return

                    else:
                        self.ra.detach_target_vol(t, vname)
                    return

    def _delete_zombie_targets(self, target_prefix, target_name):
        """Delete any empty or orphaned targets for a given target group.

        Handles two classes of zombie targets:
        - Empty targets: all LUNs were detached (interrupted delete_target
          REST call leaves SCST device handlers that block future deletes).
        - Orphaned-LUN targets: one or more LUNs reference ZFS volumes that
          no longer exist (e.g., aborted restore left a partial volume behind).
          These LUNs are detached first; if the target becomes empty it is
          then deleted.

        :param str target_prefix: IQN prefix
        :param str target_name: target group name (e.g. 'vm-101')
        """
        tname = target_prefix + target_name
        if target_prefix[-1] != ':':
            tname = target_prefix + ':' + target_name

        target_re = re.compile(fr'^{re.escape(tname)}-(?P<id>\d+)$')

        try:
            tlist = self.list_targets()
        except jexc.JDSSException as jerr:
            LOG.warning("Could not list targets to check for zombies: %s", jerr)
            return

        for target in tlist:
            if not target_re.match(target):
                continue
            try:
                luns = self.ra.get_target_luns(target)

                # Detach any LUNs whose backing ZFS volume no longer exists.
                for lun in luns:
                    lun_name = lun.get('name')
                    if lun_name and not self.ra.is_lun(lun_name):
                        LOG.warning("Detaching orphaned LUN %s from target %s"
                                    " (volume no longer exists)",
                                    lun_name, target)
                        try:
                            self.ra.detach_target_vol(target, lun_name)
                        except jexc.JDSSException as jerr:
                            LOG.warning("Could not detach orphaned LUN %s "
                                        "from target %s: %s",
                                        lun_name, target, jerr)

                # Re-fetch after potential orphan cleanup.
                luns = self.ra.get_target_luns(target)
                if len(luns) == 0:
                    LOG.warning("Deleting zombie empty target %s", target)
                    self.ra.delete_target(target)
            except jexc.JDSSResourceNotFoundException:
                pass
            except jexc.JDSSException as jerr:
                LOG.warning("Could not delete zombie target %s: %s",
                            target, jerr)

    def _detach_target_volume(self, tname, vname, check_in_use=False,
                              detach_only=False):
        """detach_target_volume

        Will go through all target, find one that volume is attached to
        and detach it from it
        If target have onlyvolume is a last one attached to particular target
        it will remove target

        :param str vname: physical volume id
        :param bool check_in_use: when True, refuse to touch the target if it
              has active iSCSI sessions. Detaching a volume (and deleting the
              target once its last lun is gone) drops the device from under a
              live initiator, on this or any other node — get_target_sessions
              reports sessions cluster-wide, so this catches remote users the
              host-local lun records cannot see. Raises JDSSTargetInUseException
              (carrying the target and the initiator addresses) instead.
        :param bool detach_only: when True, only detach the volume and never
              delete the target, even if it is now empty. Used when the caller
              is about to re-attach the volume to this same target at a
              different lun — deleting it would make that re-attach fail.
        """
        LOG.debug("detach target %s volume %s", tname, vname)

        if check_in_use:
            try:
                sessions = self.ra.get_target_sessions(tname)
            except jexc.JDSSResourceNotFoundException:
                # No such target means nothing is connected to it.
                sessions = []
            if sessions:
                addresses = sorted({s['ip'] for s in sessions
                                    if s.get('ip')})
                raise jexc.JDSSTargetInUseException(tname, addresses)

        try:
            self.ra.detach_target_vol(tname, vname)
        except jexc.JDSSResourceNotFoundException:
            pass

        if detach_only:
            return

        luns = self.ra.get_target_luns(tname)

        if len(luns) == 0:
            try:
                self.ra.delete_target(tname)
            except jexc.JDSSResourceNotFoundException:
                pass

    def _ensure_target_volume_lun(self, tname, vname, lid, provider_auth,
                                  ro=False, volume_attached=False,
                                  new_target=False, scsi_id=None):
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
        # target_data will be needed later to confirm vip addresses
        try:
            target_data = self.ra.get_target(tname)
        except jexc.JDSSResourceNotFoundException:
            clean_and_recrete = True

        if clean_and_recrete:
            # A volume that is busy (attached elsewhere) is now resolved
            # inside _attach_target_volume_lun (the single attach chokepoint):
            # it relocates from another target in this pool, reuses an
            # existing attachment on this target, or raises on a live session
            # / cross-pool clash. No detach-and-reattach dance is needed here.
            return self._create_target_volume_lun(tname,
                                                  vname,
                                                  lid,
                                                  provider_auth)

        volume_publication_info['target'] = tname

        # Ensure vips are set
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

        if not scsi_id:
            try:
                lun_info = self.ra.get_target_lun(tname, vname)
                scsi_id = lun_info['scsi_id']
            except jexc.JDSSResourceNotFoundException:
                # Busy (volume attached elsewhere, or a prior request that
                # already attached it here) is resolved inside
                # _attach_target_volume_lun, so it no longer surfaces here.
                lun_data = self._attach_target_volume_lun(tname, vname, lid)
                if lun_data:
                    scsi_id = lun_data['scsi_id']
                if not scsi_id:
                    try:
                        lun_info = self.ra.get_target_lun(tname, vname)
                        scsi_id = lun_info['scsi_id']
                    except jexc.JDSSException:
                        LOG.warning("Unable to retrieve scsi_id for %s "
                                    "on target %s", vname, tname)

        if not scsi_id:
            raise jexc.JDSSException(
                "Unable to acquire scsi_id for volume %(vol)s "
                "on target %(target)s" % {'vol': vname, 'target': tname})
        volume_publication_info['scsi_id'] = scsi_id
        volume_publication_info['lun'] = lid

        if provider_auth is not None:

            (__, auth_username, auth_secret) = provider_auth.split()
            volume_publication_info['username'] = auth_username
            volume_publication_info['password'] = auth_secret

            chap_cred = {"name": auth_username,
                         "password": auth_secret}

            try:
                users = self.ra.get_target_user(tname)
                if not (len(users) == 1 and
                        users[0]['name'] == chap_cred['name']):
                    for user in users:
                        self.ra.delete_target_user(tname, user['name'])
                    self._set_target_credentials(tname, chap_cred)
            except jexc.JDSSException:
                raise

            if not target_data.get('incoming_users_active', False):
                self.ra.set_target_incoming_users_active(tname, True)
        else:
            if target_data.get('incoming_users_active', False):
                self.ra.set_target_incoming_users_active(tname, False)
            try:
                users = self.ra.get_target_user(tname)
                for user in users:
                    self.ra.delete_target_user(tname, user['name'])
            except jexc.JDSSResourceNotFoundException:
                pass

        return volume_publication_info

    def _acquire_taget_volume_lun(self, target_prefix, target_name, vname,
                                  luns_per_target=8, current=False):
        """Get target name and lun number for given volume.

        Returns a 5-tuple:
        (<target_name>, <lun_id>, <volume_attached>, <new_target>, <scsi_id>)

        <target_name>    str  - target to use
        <lun_id>         int  - lun slot to use
        <volume_attached> bool - True if volume is already attached at the
                                 returned target/lun; False means the slot
                                 is free and volume should be attached there
        <new_target>     bool - True if target does not exist yet and should
                                 be created before attaching
        <scsi_id>        str|None - scsi_id when volume_attached is True
        """
        tname = target_prefix + target_name
        if target_prefix[-1] != ':':
            tname = target_prefix + ':' + target_name

        # Fast path: ask the array directly which target+lun carries this
        # volume.  Filters by pool so results from other pools are ignored.
        # This also handles the case where the volume was attached under a
        # different target_prefix (supersedes the old TODO comment).
        for entry in self.ra.get_target_by_lun_name(vname):
            if entry.get('pool') != self._pool:
                continue

            target = None
            lun_id = None
            scsi_id = None

            if 'iscsi_target' in entry:
                target = entry['iscsi_target']['name']

            if 'lun' in entry:
                lun_id = entry['lun']['lun']
                scsi_id = entry['lun']['scsi_id']

            if target is None:
                raise jexc.JDSSException(
                    "get_target_by_lun_name returned incomplete data "
                    "for volume %(vol)s, missing target name" % {
                        'vol': vname})

            if lun_id is None or not scsi_id:
                lun_info = self.ra.get_target_lun(target, vname)
                lun_id = lun_info['lun'] if lun_info else None
                scsi_id = lun_info.get('scsi_id') if lun_info else None

            # The volume is attached. If it sits on a target that does NOT
            # comply with the requested target_prefix (tname is built from it
            # above) - e.g. the prefix was changed in the storage config -
            # re-home it under the new prefix, but only when it is safe:
            #   * a read-only lookup (current=True) never mutates: report it;
            #   * a target with live iSCSI sessions is left in place and
            #     returned as-is (re-homing would drop the device from under
            #     an active initiator - the same busy check the detach guard
            #     uses);
            #   * otherwise detach it here so the not-attached path below
            #     re-publishes it under the new prefix.
            expected_target_re = re.compile(
                fr'^{re.escape(tname)}-(?P<id>\d+)$')
            if (not current) and (not expected_target_re.match(target)):
                try:
                    sessions = self.ra.get_target_sessions(target)
                except jexc.JDSSResourceNotFoundException:
                    sessions = []
                if sessions:
                    LOG.info("Volume %s is on target %s which does not match "
                             "the configured target_prefix, but it has active "
                             "sessions - keeping it in place", vname, target)
                    return (target, lun_id, True, False, scsi_id)
                LOG.info("Volume %s is on target %s which does not match the "
                         "configured target_prefix and is idle - detaching to "
                         "re-home it under the new prefix", vname, target)
                self._detach_target_volume(target, vname)
                break

            LOG.debug("Volume %s already attached: target %s lun %s",
                      vname, target, lun_id)
            return (target, lun_id, True, False, scsi_id)

        if current:
            return (None, None, False, None, None)

        # Volume is not attached — find a free lun slot in an existing
        # related target, scanning in sorted order.
        tlist = self.list_targets()
        # re.escape is load-bearing (review S-04): IQN prefixes are
        # dot-heavy, and an unescaped '.' matches any character — a
        # foreign/legacy target differing only at dot positions would be
        # classified as one of ours and could receive the new LUN. The
        # sibling matchers already escape.
        target_re = re.compile(fr'^{re.escape(tname)}-(?P<id>\d+)$')

        related_targets = []
        related_targets_indexes = []
        for target in tlist:
            m = target_re.match(target)
            if m is not None:
                related_targets.append(target)
                related_targets_indexes.append(m.group('id'))
                LOG.debug("Related target %s with index %s",
                          target, m.group('id'))

        related_targets.sort()
        for target in related_targets:
            try:
                luns = self.ra.get_target_luns(target)
            except jexc.JDSSResourceNotFoundException:
                LOG.debug("Target %s vanished during scan, skipping", target)
                continue
            taken_luns = [int(lun['lun']) for lun in luns]
            LOG.debug("Target %s has %d luns occupied: %s",
                      target, len(taken_luns), str(taken_luns))
            if len(taken_luns) >= luns_per_target:
                continue
            for i in range(luns_per_target):
                if i not in taken_luns:
                    LOG.debug("Found empty lun at target %s lun %d",
                              target, i)
                    return (target, i, False, False, None)

        # No existing target has a free slot — pick the lowest unused index
        # and signal the caller to create a new target.
        existing_indexes = {int(idx) for idx in related_targets_indexes}
        for i in range(len(existing_indexes) + 1):
            if i not in existing_indexes:
                tcandidate = '-'.join([tname, str(i)])
                try:
                    self.ra.get_target(tcandidate)
                except jexc.JDSSResourceNotFoundException:
                    return (tcandidate, 0, False, True, None)
        return ('-'.join([tname, '0']), 0, False, True, None)

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

        max_retries = 5
        for attempt in range(max_retries):
            try:
                # target volume lun descriptor of form
                # (<target_name>, <lun_id>, <volume attached>, <new target>, <scsi_id>)
                tvld = self._acquire_taget_volume_lun(
                    target_prefix,
                    target_name,
                    vname,
                    luns_per_target=luns_per_target)
                (tname, lun_id, volume_attached_flag, new_target_flag, acq_scsi_id) = tvld

                if new_target_flag:
                    return self._create_target_volume_lun(tname,
                                                          vname,
                                                          lun_id,
                                                          provider_auth)

                return self._ensure_target_volume_lun(tname,
                                                      vname,
                                                      lun_id,
                                                      provider_auth)

            except jexc.JDSSException as err:
                if 'CfgParserError' not in str(err):
                    raise
                if attempt >= max_retries - 1:
                    LOG.error("Target volume ensure failed after %d attempts "
                              "due to concurrent config update: %s",
                              max_retries, err)
                    raise
                delay = 2 + attempt + random.uniform(0, 2)
                LOG.warning("JovianDSS config parser error during target "
                            "setup (concurrent operation), retrying in %.1fs "
                            "(attempt %d/%d): %s",
                            delay, attempt + 1, max_retries - 1, err)
                time.sleep(delay)

    def _get_conforming_vips(self):
        """get vips that conforms configuration requirments

        This function calculated vip names that should be assigned to iscsi
        target associated with specific pool on the basis of given config
        restrictions

        Method will raise JDSSVIPNotFoundException if no fitting vip was found
        :return: dictionary of vip name as key and ip as value
        """

        iscsi_addresses=[]

        if len(self.jovian_iscsi_vip_addresses) == 0:
            iscsi_addresses.extend(self.jovian_hosts)
        else:
            iscsi_addresses.extend(self.jovian_iscsi_vip_addresses)

        retries = 3
        for attempt in range(retries):
            try:
                conforming_vips=dict()
                vip_data=self.ra.get_pool_vips()

                for vip in vip_data:
                    if vip['address'] in iscsi_addresses:
                        conforming_vips[vip['name']]=vip['address']

                if len(conforming_vips) > 0:
                    return conforming_vips

                reason = ("no match for %s" %
                          ','.join(iscsi_addresses))
            except jexc.JDSSException as err:
                reason = str(err)

            if attempt < retries - 1:
                LOG.warning("VIP lookup failed: %s "
                            "(attempt %d/%d, retrying in %ds)",
                            reason,
                            attempt + 1, retries,
                            (attempt + 1) * 2)
                time.sleep((attempt + 1) * 2)

        raise jexc.JDSSVIPNotFoundException(iscsi_addresses)

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

        volume_publication_info = dict()
        conforming_vips = self._get_conforming_vips()
        volume_publication_info['vips'] = list(conforming_vips.values())
        # Create target
        try:
            self.ra.create_target(target_name,
                                  list(conforming_vips.keys()),
                                  use_chap=(provider_auth is not None))
        except jexc.JDSSResourceExistsException:
            # Target may have been created by a prior timed-out request.
            LOG.info("Target %s already exists, proceeding with "
                     "volume attachment", target_name)
        volume_publication_info['target'] = target_name
        try:
            # Attach volume
            lun_data = self._attach_target_volume_lun(target_name, vid, lid)
            scsi_id = lun_data.get('scsi_id') if lun_data else None
            if not scsi_id:
                lun_info = self.ra.get_target_lun(target_name, vid)
                scsi_id = lun_info.get('scsi_id') if lun_info else None
            if not scsi_id:
                raise jexc.JDSSException(
                    "Unable to acquire scsi_id for volume %(vol)s "
                    "on target %(target)s" % {
                        'vol': vid, 'target': target_name})
            volume_publication_info['scsi_id'] = scsi_id
        except Exception as err:
            raise err
            # TODO: finish this

        volume_publication_info['lun'] = lid
        # Set credentials
        if provider_auth is not None:
            (__, auth_username, auth_secret) = provider_auth.split()
            volume_publication_info['username'] = auth_username
            volume_publication_info['password'] = auth_secret
            chap_cred={"name": auth_username,
                         "password": auth_secret}

            self._set_target_credentials(target_name, chap_cred)

        return volume_publication_info

    def _list_targets(self):
        """List targets
        """
        targets = []
        i = 0
        # First we list all volume snapshots page by page
        try:
            while True:
                tpage = self.ra.get_targets_page(i)

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

    def get_target(self, target_name):
        """Return target data dict for target_name.

        :raises JDSSResourceNotFoundException: if target does not exist
        """
        return self.ra.get_target(target_name)

    def get_target_sessions(self, target_name):
        """Return list of active iSCSI sessions for target_name.

        :raises JDSSResourceNotFoundException: if target does not exist
        """
        return self.ra.get_target_sessions(target_name)

    def delete_target(self, target_name):
        """Delete an iSCSI target by IQN.

        :raises JDSSResourceNotFoundException: if target does not exist
        """
        self.ra.delete_target(target_name)

    def update_target(self, target_name, provider_auth=None):
        """Update CHAP credentials on an existing named iSCSI target.

        Unlike _ensure_target_volume_lun, always replaces credentials
        regardless of username match so that password-only rotation takes
        effect immediately.

        :param str target_name: full iSCSI target IQN
        :param str provider_auth: 'CHAP <user> <pass>' to set/replace
                                  credentials; None to disable CHAP
        :raises JDSSResourceNotFoundException: if target does not exist
        """
        target_data = self.ra.get_target(target_name)

        if provider_auth is not None:
            (__, auth_username, auth_secret) = provider_auth.split()
            chap_cred = {"name": auth_username, "password": auth_secret}

            try:
                users = self.ra.get_target_user(target_name)
            except jexc.JDSSResourceNotFoundException:
                users = []
            for user in users:
                self.ra.delete_target_user(target_name, user['name'])
            self.ra.create_target_user(target_name, chap_cred)

            if not target_data.get('incoming_users_active', False):
                self.ra.set_target_incoming_users_active(target_name, True)
        else:
            if target_data.get('incoming_users_active', False):
                self.ra.set_target_incoming_users_active(target_name, False)
            try:
                users = self.ra.get_target_user(target_name)
                for user in users:
                    self.ra.delete_target_user(target_name, user['name'])
            except jexc.JDSSResourceNotFoundException:
                pass

    def list_target_luns(self, target):
        luns = self.ra.get_target_luns(target)

        return luns

    def _attach_target_volume_lun(self, target_name, vname, lun):
        """Attach volume to target at the given lun, resolving conflicts.

        A busy attach ("volume already used") is the single point where the
        volume being attached somewhere else surfaces. It is resolved at the
        top of the NEXT loop pass — never inside the except handler, which
        only flags the condition — honouring three cases:
          - the volume is already on target_name (perhaps a different lun):
            it is published here already, so its existing lun is returned and
            nothing is moved;
          - it is on a different target in THIS pool: that target is detached
            (guarded — never a target with live iSCSI sessions, which raises
            JDSSTargetInUseException) and the attach is retried;
          - a target of the SAME NAME lives in a DIFFERENT pool: the driver
            must not touch another pool, so JDSSTargetPoolConflictException is
            raised for the operator to resolve.
        A transient busy (REST processing another op, volume not actually
        attached) is paced and retried.

        :param target_name: name of target
        :param vname: volume physical id
        :param lun: lun number that given vname will be attached to target_name
        """
        max_attempts = 4
        resolve_busy = False
        for attempt in range(max_attempts):

            # Resolve the previous pass's busy here, OUTSIDE the except
            # handler (the except only sets the flag).
            if resolve_busy:
                resolve_busy = False

                # Find where the volume is attached IN OUR POOL. The first
                # our-pool match is kept as target_data; a SECOND one means
                # the volume is on several targets at once - a corrupted state
                # we refuse to guess at, so the loop never breaks early.
                target_data = None
                for entry in self.ra.get_target_by_lun_name(vname):
                    entry_pool = entry.get('pool')
                    entry_target = entry.get('iscsi_target', {}).get('name')
                    if entry_pool != self._pool:
                        # Different pool, same target name: a naming clash we
                        # must never detach across.
                        if entry_target == target_name:
                            raise jexc.JDSSTargetPoolConflictException(
                                target_name, entry_pool)
                        continue
                    if target_data is not None:
                        raise jexc.JDSSException(
                            "Volume %(vol)s is attached to more than one "
                            "target in pool %(pool)s (%(t1)s and %(t2)s); a "
                            "volume must live on a single target - refusing "
                            "to relocate it in this corrupted state" % {
                                'vol': vname,
                                'pool': self._pool,
                                't1': target_data.get(
                                    'iscsi_target', {}).get('name'),
                                't2': entry_target})
                    target_data = entry

                if target_data is not None:
                    current_target = \
                        target_data.get('iscsi_target', {}).get('name')
                    current_lun = target_data.get('lun', {}).get('lun')

                    if current_target is None or current_lun is None:
                        # The array reported an attachment but without the
                        # fields we need to act on it. Do not guess - go on to
                        # the next attempt.
                        LOG.warning("Volume %s has an incomplete attachment "
                                    "record %s, retrying", vname, target_data)
                        time.sleep(1 + attempt * 2)
                        continue

                    if current_target == target_name:
                        # Already on the target we want.
                        if (lun is None) or (current_lun == lun):
                            # And at the lun we want (or no lun was asked
                            # for): use the existing attachment as it is.
                            LOG.info("Volume %s already attached to target %s "
                                     "lun %s, using existing attachment",
                                     vname, target_name, current_lun)
                            return self.ra.get_target_lun(target_name, vname)
                        # Right target but wrong lun: relocate to the
                        # requested lun, keeping the target for the re-attach.
                        LOG.info("Volume %s on target %s at lun %s, moving it "
                                 "to lun %s",
                                 vname, target_name, current_lun, lun)
                        detach_only = True
                    else:
                        # On a different target: relocate to the one we want,
                        # removing that target if it becomes empty.
                        LOG.info("Volume %s attached to target %s, relocating "
                                 "to %s", vname, current_target, target_name)
                        detach_only = False

                    # Detach where the volume actually is (refuses if that
                    # target has live sessions), then let the attach below
                    # place it on target_name at the wanted lun.
                    self._detach_target_volume(current_target, vname,
                                               check_in_use=True,
                                               detach_only=detach_only)
                else:
                    # Not attached after all (transient busy / freed): pace
                    # the retry; the attach below runs again.
                    time.sleep(1 + attempt * 2)

            try:
                return self.ra.attach_target_vol(target_name, vname,
                                                 lun_id=lun)
            except jexc.JDSSResourceIsBusyException:
                resolve_busy = True
                continue
            except jexc.JDSSException as jerr:
                LOG.warning("Unable to attach volume %s to target %s lun %s "
                            "because of %s.", vname, target_name, lun, jerr)
                raise jerr

        LOG.warning("Volume %s still busy after %d attempts to attach to "
                    "target %s", vname, max_attempts, target_name)
        raise jexc.JDSSResourceIsBusyException(vname)

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
                 'volume_name': jcom.idname(d['volume_name']),
                 'creation': d.get('properties', {}).get('creation')}
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

    def _find_share_by_real_path(self, real_path):
        """Return the first share whose real_path matches, or None.

        :param str real_path: full export path, e.g. /Pools/Pool-0/dataset
        :return: raw share dict from the API, or None if not found
        """
        try:
            shares = self._list_all_pages(self.ra.get_shares_page)
            for share in shares:
                if share.get('real_path') == real_path:
                    return share
        except Exception:
            LOG.debug('Unable to list shares while searching for %s',
                      real_path)
        return None

    def publish_nas_snapshot(self, dataset_name, snapshot_name,
                             proxmox_volume=None,
                             nas_volume_direct_mode=False,
                             inherit_from_path=None):
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
        # Read NFS properties from the main dataset share so the snapshot
        # share is created with the same configuration.
        # allow_write_ip is intentionally not copied — snapshots are read-only.
        nfs_props = {
            'insecure_connections': False,
            'synchronous_data_record': True,
            'insecure_lock_requests': False,
            'all_squash': False,
            'no_root_squash': False,
            'allow_access_ip': None,
        }
        if inherit_from_path:
            main_share = self._find_share_by_real_path(inherit_from_path)
            if main_share and 'nfs' in main_share:
                nfs = main_share['nfs']
                for key in nfs_props:
                    if key in nfs:
                        nfs_props[key] = nfs[key]
            else:
                LOG.debug(
                    'No share found with real_path %s,'
                    ' using defaults', inherit_from_path)

        # Create NFS share for the clone with same properties as main share
        path = "{}/{}".format(self._pool, sname)
        try:
            self.ra.create_share(sname, path,
                                 active=True,
                                 proto='nfs',
                                 **nfs_props)
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

        After deleting the share, polls get_share up to 10 times (1 s apart)
        to confirm the share has been fully removed before attempting clone
        deletion — NFS may hold references briefly after DELETE returns.

        delete_nas_clone is retried up to 10 times (2 s apart) in case the
        clone is temporarily busy (e.g. NFS client still has open handles).

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

        # Confirm share is gone before touching the clone — the NFS server
        # may keep the share object alive for a short time after deletion,
        # causing the subsequent clone delete to be rejected as busy.
        for attempt in range(10):
            try:
                self.ra.get_share(sname)
                LOG.debug('share %s still present after deletion, waiting'
                          ' (attempt %d/10)', sname, attempt + 1)
                time.sleep(1)
            except jexc.JDSSResourceNotFoundException:
                LOG.debug('share %s confirmed removed', sname)
                break
        else:
            LOG.warning('share %s still reported present after 10 attempts,'
                        ' proceeding with clone deletion anyway', sname)

        # Delete clone, retrying if it is temporarily busy (NFS client may
        # still hold file handles open right after the share disappears).
        for attempt in range(10):
            try:
                self.ra.delete_nas_clone(dname, sname, sname)
                break
            except jexc.JDSSResourceNotFoundException:
                break
            except jexc.JDSSException:
                if attempt < 9:
                    LOG.debug('clone %s busy or error on deletion attempt'
                              ' %d/10, retrying in 2 s', sname, attempt + 1)
                    time.sleep(2)
                else:
                    LOG.warning('clone %s could not be deleted after 10'
                                ' attempts, giving up', sname)

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

    def rename_volume(self, volume_name, new_volume_name, idempotent=None):
        LOG.debug("Rename volume %s to %s",
                  volume_name,
                  new_volume_name)

        vname = jcom.vname(volume_name)
        nvname = jcom.vname(new_volume_name)
        prop = {'name': nvname}

        new_volume_info = None
        old_volume_info = None
        last_err = None
        for i in range(3):
            if idempotent is not None:
                for i in range(3):
                    try:
                        # new volume
                        vd = {'id': new_volume_name}
                        new_volume_info = self.get_volume(vd)
                    except (jexc.JDSSVolumeNotFoundException,
                            jexc.JDSSResourceNotFoundException):
                        # New volume is not present: nothing to be
                        # idempotent about - proceed to the plain rename
                        # below. Both not-found flavors listed explicitly:
                        # get_volume raises the parent
                        # JDSSResourceNotFoundException (review F-03 - the
                        # child alone never matched it).
                        break
                    except jexc.JDSSException as err:
                        last_err = err
                        time.sleep(1)
                        continue

                    if new_volume_info is not None:
                        nvsi = None

                        if (('scsi_id' in new_volume_info) and
                                (new_volume_info['scsi_id'] is not None)):
                            nvsi = ''.join(['{:x}'.format(ord(c))
                                   for c in new_volume_info['scsi_id']])
                        elif (('san_scsi_id' in new_volume_info) and
                                (new_volume_info['san_scsi_id'] is not None)):
                            nvsi = ''.join(['{:x}'.format(ord(c))
                                   for c in new_volume_info['san_scsi_id'][:16]])


                        if str(nvsi).lower() == str(idempotent).lower():
                            return
                        else:
                            LOG.error(("Idempotent renaming is impossible since %(new_vol)s "
                                       "scsi id %(new_vol_scsi)s differ from source volume %(old_vol)s "
                                       "scsi id %(old_vol_scsi)s"),
                                      {'new_vol': new_volume_name,
                                       'new_vol_scsi': nvsi,
                                       'old_vol': volume_name,
                                       'old_vol_scsi': idempotent})
                            raise Exception(("Idempotent renaming is impossible since %(new_vol)s "
                                       "scsi id %(new_vol_scsi)s differ from source volume %(old_vol)s "
                                       "scsi id %(old_vol_scsi)s") %
                                      {'new_vol': new_volume_name,
                                       'new_vol_scsi': nvsi,
                                       'old_vol': volume_name,
                                       'old_vol_scsi': idempotent})
                    break

            try:
                # original volume
                vd = {'id': volume_name}
                old_volume_info = self.get_volume(vd)
            except (jexc.JDSSVolumeNotFoundException,
                    jexc.JDSSResourceNotFoundException) as err:
                # Source volume is missing - possibly listing lag right
                # after another operation, so retry briefly; if it stays
                # missing, the not-found itself is the error the caller
                # must see (review F-03: this must never end as exit 0).
                last_err = err
                time.sleep(1)
                continue
            except jexc.JDSSException as err:
                last_err = err
                time.sleep(1)
                continue

            if idempotent is not None:

                ovsi = None

                if (('scsi_id' in old_volume_info) and
                        (old_volume_info['scsi_id'] is not None)):
                    ovsi = ''.join(['{:x}'.format(ord(c))
                                   for c in old_volume_info['scsi_id']])
                elif (('san_scsi_id' in old_volume_info) and
                        (old_volume_info['san_scsi_id'] is not None)):
                    ovsi = ''.join(['{:x}'.format(ord(c))
                                   for c in old_volume_info['san_scsi_id'][:16]])

                if str(ovsi).lower() == str(idempotent).lower():
                    try:
                        self.ra.modify_lun(vname, prop)
                    except jexc.JDSSCfgParserException as jcperr:
                        LOG.debug("Internal config handling error: %s",
                                  str(jcperr))
                        pass
                    except jexc.JDSSException as err:
                        emsg = ("Failed to rename volume %(vol)s "
                                "to %(new_name)s") % {
                            'vol': vname,
                            'new_name': nvname}
                        raise Exception(emsg) from err
                else:
                    LOG.error(("Idempotent renaming is impossible since "
                               "requested idempotent scsi id "
                               "%(idempotent_scsi)s differ from "
                               "current volume %(cur_vol)s"
                               "scsi id %(cur_vol_scsi)s"),
                              {
                               'idempotent_scsi': idempotent,
                               'cur_vol': volume_name,
                               'cur_vol_scsi': ovsi})
                    raise Exception(("Idempotent renaming is impossible since "
                                     "requested idempotent"
                                     "scsi id %(idempotent_scsi)s differ from "
                                     "current volume %(cur_vol)s "
                                     "scsi id %(cur_vol_scsi)s") %
                                    {'idempotent_scsi': idempotent,
                                     'cur_vol': volume_name,
                                     'cur_vol_scsi': ovsi})
            # Idempotent is None
            else:
                try:
                    self.ra.modify_lun(vname, prop)
                except jexc.JDSSCfgParserException as jcperr:
                    LOG.debug("Internal config handling error: %s",
                              str(jcperr))
                    pass
                except jexc.JDSSException as err:
                    emsg = ("Failed to rename volume %(vol)s "
                            "to %(new_name)s") % {
                        'vol': vname,
                        'new_name': nvname}
                    raise Exception(emsg) from err

            rename_confirmed = False
            for i in range(51):
                new_vol = self.ra.is_lun(nvname)
                if new_vol is True:
                    rename_confirmed = True
                    break
                LOG.debug("Volume %s renaming have not completed",
                          str(nvname))
                time.sleep(1)

            if rename_confirmed:
                return
            else:
                LOG.error("Unable to confirm sucessfull volume renaming %(vol)s",
                          {"vol": volume_name})
                raise Exception('Failed to confirm renaming of %s to %s' %
                                (volume_name, new_volume_name))

        # Every attempt failed at the probe stage: the rename was never
        # issued. Never fall through to an implicit success (review F-03 -
        # exit 0 here made Proxmox write configs pointing at nonexistent
        # disks).
        if last_err is not None:
            raise last_err
        raise Exception('Failed to rename volume %s to %s: '
                        'source volume unavailable' %
                        (volume_name, new_volume_name))


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
                #LOG.debug("Page: %s", str(spage))

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

    def _list_volume_snapshots(self, ovolume_name, vname, all=False):
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
                                                               clone,
                                                               all=all))
                    continue
            if all:
                snap['volume_name'] = vname
                out.append(snap)

        return out

    def _list_nas_volume_snapshots(self, ovolume_name, vname, all=False):
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
                    props = r.get('properties', {})
                    ret.append({'name': jcom.sid_from_sname(r['name']),
                                'guid': props.get('guid'),
                                'creation': props.get('creation')})

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
                                       force_umount=False,
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

    def _update_pool_stats(self):
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
        pool_id = 'unknown'
        if 'id' in pool_stats:
            pool_id = pool_stats['id']

        pool_name = self.get_pool_name()

        if 'name' in pool_stats:
            pool_name = pool_stats['name']

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
            'multiattach': False,
            'id': pool_id,
            'pool_name': pool_name
        }

        LOG.debug('Total capacity: %d, '
                  'Free %d.',
                  self._stats['total_capacity_gb'],
                  self._stats['free_capacity_gb'])

    def get_pool_stats(self):
        """Return information about pool capacity

        return (pool_name, pool_id, total_gb, free_gb)
        """
        self._update_pool_stats()

        return (self._stats['pool_name'],
                self._stats['id'],
                self._stats['total_capacity_gb'],
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

        When force_snapshots is True and only snapshots (no clones) block the
        rollback, snapshot_rollback REST call is issued directly — the
        JovianDSS API deletes all newer snapshot dependencies atomically
        before restoring the volume.  The logical names of the blocker
        snapshots are returned so the caller can perform any necessary
        housekeeping (e.g. removing Proxmox VM snapshot config entries).
        If clone blockers are present the rollback is refused even in force
        mode, because the REST API cannot delete clones automatically.

        :param volume_name: logical volume id
        :param snapshot_name: logical snapshot id that belongs to volume_name
        :param force_snapshots: when True allow rollback past snapshot blockers

        :return: list of logical snapshot names that were deleted (may be empty)
        """

        vname = jcom.vname(volume_name)
        sname = jcom.sname(snapshot_name, None)

        if force_snapshots:
            # List blockers upfront — needed for two things:
            #   1. clone check: REST rollback cannot delete clones automatically
            #   2. return blocker names to caller for Proxmox config cleanup
            deplist = self._list_snapshot_rollback_dependency(vname, sname)

            if len(deplist['clones']) > 0:
                LOG.debug("forced rolling back volume %s to snapshot %s is"
                          " blocked by %d clone(s)",
                          jcom.idname(vname), jcom.idname(sname),
                          len(deplist['clones']))
                raise jexc.JDSSRollbackIsBlocked(
                    volume_name, snapshot_name,
                    deplist['snapshots'], deplist['clones'],
                    len(deplist['snapshots']), len(deplist['clones']))

            # No clone blockers — snapshot_rollback REST call deletes all
            # newer snapshot dependencies atomically and restores the volume.
            LOG.info("rolling back volume %(vol)s to snapshot %(snap)s"
                     " (deleting %(n)d snapshot blocker(s))",
                     {'vol': jcom.idname(vname), 'snap': jcom.idname(sname),
                      'n': len(deplist['snapshots'])})
            self.ra.snapshot_rollback(vname, sname)
            return deplist['snapshots']

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
                return []
            else:
                LOG.debug("rolling back is blocked by resources %s",
                          dependency)

        deplist = self._list_snapshot_rollback_dependency(vname, sname)

        raise jexc.JDSSRollbackIsBlocked(volume_name,
                                         snapshot_name,
                                         deplist['snapshots'],
                                         deplist['clones'],
                                         dependency.get('snapshots', 0),
                                         dependency.get('clones', 0))

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
