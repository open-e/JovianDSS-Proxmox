#    Copyright (c) 2023 Open-E, Inc.
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
from oslo_utils import units as o_units
import math
import re

from jdssc.jovian_common import exception as jexc
# from jdssc.jovian_common import cexception as exception
from jdssc.jovian_common import jdss_common as jcom
from jdssc.jovian_common import rest
from jdssc.jovian_common.stub import _

LOG = logging.getLogger(__name__)


Size_Pattern = re.compile(r"^(\d+[GgMmKk]?)$")


class JovianDSSDriver(object):

    def __init__(self, config):

        self.VERSION = "0.9.7"

        self.configuration = config
        self._pool = self.configuration.get('jovian_pool', 'Pool-0')
        self.jovian_iscsi_target_portal_port = self.configuration.get(
            'target_port', 3260)

        self.jovian_target_prefix = self.configuration.get(
            'target_prefix',
            'iqn.2020-04.com.open-e.cinder:')
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

        self.ra = rest.JovianRESTAPI(config)

    def rest_config_is_ok(self):
        """Check config correctness by checking pool availability"""

        return self.ra.is_pool_exists()

    def get_active_ifaces(self):
        """Return list of ip addresses for iSCSI connection"""

        return self.jovian_hosts

    def get_provider_location(self, volume_name):
        """Return volume iscsiadm-formatted provider location string."""
        return '%(host)s:%(port)s,1 %(name)s 0' % {
            'host': self.ra.get_active_host(),
            'port': self.jovian_iscsi_target_portal_port,
            'name': self._get_target_name(volume_name)}

    def create_volume(self, volume_id, volume_size, sparse=False,
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

        LOG.debug("Create volume:%(name)s with size:%(size)s",
                  {'name': volume_id, 'size': volume_size})

        self.ra.create_lun(vname,
                           volume_size,
                           sparse=sparse,
                           block_size=block_size)
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
                    cvnames = jcom.snapshot_clones(snap)
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
                cvnames = jcom.snapshot_clones(snap)
                if len(cvnames) == 0:
                    self._delete_snapshot(vname, jcom.sname_from_snap(snap))
                    update = True
            if jcom.is_snapshot(jcom.sname_from_snap(snap)):
                cvnames = jcom.snapshot_clones(snap)
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
            clones = jcom.snapshot_clones(snap)
            add = False
            for cvname in clones:
                if exclude_dedicated_volumes and jcom.is_volume(cvname):
                    continue
                if exclude_dedicated_snapshots and jcom.is_snapshot(cvname):
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
            clones = jcom.snapshot_clones(snap)
            for cname in [c for c in clones if jcom.is_snapshot(c)]:
                LOG.debug("Delete snapshot mount point %s", cname)
                self._delete_volume(cname, cascade=True)

    # TODO: rethink delete volume
    # it is used in many places, yet concept of 'garbage' has changed
    # since last time. So instead of deleting hidden volumes
    # we should only remove them if they have no snapshots
    def _delete_volume(self, vname, cascade=False):
        """_delete_volume delete routine containing delete logic

        :param str vname: physical volume id
        :param bool cascade: flag for cascade volume deletion
            with its snapshots

        :return: None
        """
        LOG.debug("Deleting %s", vname)
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
            snapshots = self._list_all_volume_snapshots(vname, vsnap_filter)
        except jexc.JDSSResourceNotFoundException:
            LOG.debug('volume %s do not exists, it was already '
                      'deleted', vname)
            return

        LOG.debug(snapshots)
        exit(1)
        bsnaps = self._list_busy_snapshots(vname,
                                           snapshots,
                                           exclude_dedicated_snapshots=True)
        if len(bsnaps) > 0:
            LOG.debug("Found busy snapshots that cant be deleted, for instance %s", bsnaps[0]['name'])
            raise jexc.JDSSResourceIsBusyException(vname)

        # snaps = self._clean_garbage_resources(vname, snapshots)
        self._clean_volume_snapshots_mount_points(vname, snapshots)

        self._delete_volume(vname, cascade=False)

        # self._promote_newest_delete(vname, snapshots=snaps, cascade=cascade)

    def delete_volume(self, volume_name, cascade=False):
        """Delete volume

        :param volume: volume reference
        :param cascade: remove snapshots of a volume as well
        """
        vname = jcom.vname(volume_name)

        LOG.debug('deleting volume %s', vname)

        self._delete_volume(vname, cascade=cascade)

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
                           "%s is a snapshot"))
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
                             sparse=False):
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
            sname = jcom.sname(snapshot_name, volume_name)

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
        sname = jcom.sname(snapshot_name, volume_name)

        snaps = self._list_volume_snapshots(volume_name, vname)

        for snap in snaps:
            if snap['name'] == sname:
                LOG.error("Snapshot %(snapshot)s exists at volume %(volume)s",
                          {"snapshot": sname,
                           "volume": snap['volume_name']})
                raise jexc.JDSSSnapshotExistsException(snapshot_name,
                                                       volume_name)
        self.ra.create_snapshot(vname, sname)

    def create_export_snapshot(self, snapshot_name, volume_name,
                               provider_auth):
        """Creates iscsi resources needed to start using snapshot

        :param str snapshot_name: openstack snapshot id
        :param str volume_name: openstack volume id
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        """

        sname = jcom.sname(snapshot_name, volume_name)
        ovname = jcom.vname(volume_name)
        try:
            self._clone_object(sname, sname, ovname,
                               sparse=True,
                               create_snapshot=False,
                               readonly=True)

        except jexc.JDSSVolumeExistsException:
            LOG.debug(("Got Volume Exists exception, but do nothing as"
                       "%s is a snapshot"))

        try:
            self._ensure_target_volume(snapshot_name, sname, provider_auth,
                                       ro=True)
        except jexc.JDSSException as jerr:
            self._delete_volume(sname, cascade=True)
            raise jerr

    def remove_export(self, volume_name):
        """Remove iscsi target created to make volume attachable

        :param str volume_name: openstack volume id
        """
        vname = jcom.vname(volume_name)
        try:
            self._remove_target_volume(volume_name, vname)
        except jexc.JDSSException as jerr:
            LOG.warning(jerr)

    def remove_export_snapshot(self, snapshot_name, volume_name):
        """Remove tmp vol and iscsi target created to make snap attachable

        :param str snapshot_name: openstack snapshot id
        :param str volume_name: openstack volume id
        """

        sname = jcom.sname(snapshot_name, volume_name)

        try:
            self._remove_target_volume(snapshot_name, sname)
        except jexc.JDSSException as jerr:
            self._delete_volume(sname, cascade=True)
            raise jerr

        self._delete_volume(sname, cascade=True)

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

        clones = jcom.snapshot_clones(snapshot)

        if len(clones) > 0:

            for cvname in clones:
                if jcom.is_hidden(cvname):
                    dsnaps = self._list_all_volume_snapshots(cvname, None)
                    msg = "Snapshot is busy, delete dependent snapshots firs"
                    dsnames = [jcom.sid_from_sname(s['name']) for s in dsnaps]
                    jcom.dependency_error(msg, dsnames)

                    raise jexc.JDSSSnapshotIsBusyException(
                            jcom.sid_from_sname(sname))

                if jcom.is_snapshot(cvname):
                    self.ra.delete_lun(cvname)

        if jcom.is_hidden(pname):
            psnaps = self.ra.get_volume_snapshots_page(pname, 0)
            if len(psnaps) > 1:
                try:
                    self.ra.delete_snapshot(vname, sname, force_umount=True)
                except jexc.JDSSSnapshotNotFoundException:
                    LOG.debug('Snapshot %s not found', sname)
                    return

            self.ra.delete_lun(pname,
                               force_umount=True,
                               recursively_children=True)
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
        sname = jcom.sname(snapshot_name, volume_name)

        try:
            self._delete_snapshot(vname, sname)
        except jexc.JDSSResourceNotFoundException:
            self._delete_snapshot(vname, "s_" + snapshot_name)

    def _ensure_target_volume(self, id, vid, provider_auth, ro=False):
        """Checks if target configured properly and volume is attached to it

        :param str id: id that would be used for target naming
        :param str vname: physical volume id
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        """
        LOG.debug("ensure volume %s assigned to a proper target", id)

        target_name = self._get_target_name(id)

        if not provider_auth:
            LOG.debug("creating target for volume %s with no auth", id)

        if not self.ra.is_target(target_name):

            return self._create_target_volume(id, vid, provider_auth)

        if not self.ra.is_target_lun(target_name, vid):
            self._attach_target_volume(target_name, vid)

        if provider_auth is not None:
            (__, auth_username, auth_secret) = provider_auth.split()
            chap_cred = {"name": auth_username,
                         "password": auth_secret}

            try:
                users = self.ra.get_target_user(target_name)
                if len(users) == 1:
                    if users[0]['name'] == chap_cred['name']:
                        return
                    self.ra.delete_target_user(
                        target_name,
                        users[0]['name'])
                for user in users:
                    self.ra.delete_target_user(
                        target_name,
                        user['name'])
                self._set_target_credentials(target_name, chap_cred)

            except jexc.JDSSException as jerr:
                self.ra.delete_target(target_name)
                raise jerr

    def _get_target_name(self, volume_id):
        """Return iSCSI target name to access volume."""
        return f'{self.jovian_target_prefix}{volume_id}'

    def _get_iscsi_properties(self, volume_id, provider_auth, multipath=False):
        """Return dict according to cinder/driver.py implementation.

        :param volume_id: UUID of volume, might take snapshot UUID
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        :return:
        """
        tname = self._get_target_name(volume_id)
        iface_info = []
        if multipath:
            iface_info = self.get_active_ifaces()
            if not iface_info:
                raise jexc.JDSSRESTException(
                    _('No available interfaces '
                      'or config excludes them'))

        iscsi_properties = {}

        if multipath:
            iscsi_properties['target_iqns'] = []
            iscsi_properties['target_portals'] = []
            iscsi_properties['target_luns'] = []
            LOG.debug('tpaths %s.', iface_info)
            for iface in iface_info:
                iscsi_properties['target_iqns'].append(
                    self._get_target_name(volume_id))
                iscsi_properties['target_portals'].append(
                    iface +
                    ":" +
                    str(self.jovian_iscsi_target_portal_port))
                iscsi_properties['target_luns'].append(0)
        else:
            iscsi_properties['target_iqn'] = tname
            iscsi_properties['target_portal'] = (
                self.ra.get_active_host() +
                ":" +
                str(self.jovian_iscsi_target_portal_port))

        iscsi_properties['target_discovered'] = False

        if provider_auth:
            (auth_method, auth_username, auth_secret) = provider_auth.split()

            iscsi_properties['auth_method'] = auth_method
            iscsi_properties['auth_username'] = auth_username
            iscsi_properties['auth_password'] = auth_secret

        iscsi_properties['target_lun'] = 0
        return iscsi_properties

    def _remove_target_volume(self, id, vid):
        """_remove_target_volume

        Ensure that volume is not attached to target and target do not exists.
        """

        target_name = self._get_target_name(id)
        LOG.debug("remove export")
        LOG.debug("detach volume:%(vol)s from target:%(targ)s.", {
            'vol': id,
            'targ': target_name})

        try:
            self.ra.detach_target_vol(target_name, vid)
        except jexc.JDSSResourceNotFoundException as jerrrnf:
            LOG.debug('failed to remove resource %(t)s because of %(err)s', {
                't': target_name,
                'err': jerrrnf.args[0]})
        except jexc.JDSSException as jerr:
            LOG.warning('failed to Terminate_connection for target %(targ)s '
                        'because of: %(err)s', {'targ': target_name,
                                                'err': jerr.args[0]})
            raise jerr

        LOG.debug("delete target: %s", target_name)

        try:
            self.ra.delete_target(target_name)
        except jexc.JDSSResourceNotFoundException as jerrrnf:
            LOG.debug('failed to remove resource %(target)s because '
                      'of %(err)s',
                      {'target': target_name, 'err': jerrrnf.args[0]})

        except jexc.JDSSException as jerr:
            LOG.warning('Failed to Terminate_connection for target %(targ)s '
                        'because of: %(err)s ',
                        {'targ': target_name, 'err': jerr.args[0]})

            raise jerr

    def ensure_export(self, volume_id, provider_auth, direct_mode=False):

        vname = jcom.vname(volume_id)

        if direct_mode:
            vname = volume_id

        self._ensure_target_volume(volume_id, vname, provider_auth)

    def initialize_connection(self, volume_id, provider_auth,
                              snapshot_id=None,
                              multipath=False):
        """Ensures volume is ready for connection and return connection data

        Ensures that particular volume is ready to be used over iscsi
        with credentials provided in provider_auth
        If snapshot name is provided method will ensure that connection
        leads to read only volume object associated with particular snapshot

        :param str volume_id: Volume id string
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        :param str snapshot_id: id of snapshot that should be connected
        :param bool multipath: specifies if multipath should be used
        """

        id_of_disk_to_attach = volume_id
        vid = jcom.vname(volume_id)
        if provider_auth is None:
            raise jexc.JDSSException(_("CHAP credentials missing"))
        if snapshot_id:
            id_of_disk_to_attach = snapshot_id
            vid = jcom.sname(snapshot_id, volume_id)
        iscsi_properties = self._get_iscsi_properties(id_of_disk_to_attach,
                                                      provider_auth,
                                                      multipath=multipath)
        if snapshot_id:
            self._ensure_target_volume(id_of_disk_to_attach,
                                       vid,
                                       provider_auth,
                                       mode='ro')
        else:
            self._ensure_target_volume(id_of_disk_to_attach,
                                       vid,
                                       provider_auth)

        LOG.debug(
            "initialize_connection for physical disk %(vid)s with %(id)s",
            {'vid': vid, 'id': id_of_disk_to_attach})

        return {
            'driver_volume_type': 'iscsi',
            'data': iscsi_properties,
        }

    def _create_target_volume(self, id, vid, provider_auth):
        """Creates target and attach volume to it

        :param id: uuid of particular resource
        :param vid: physical volume id, might identify snapshot mount
        :param str provider_auth: space-separated triple
              '<auth method> <auth username> <auth password>'
        :return:
        """
        LOG.debug("create target and attach volume %s to it", vid)

        target_name = self._get_target_name(id)

        # Create target
        self.ra.create_target(target_name,
                              use_chap=(provider_auth is not None))

        # Attach volume
        self._attach_target_volume(target_name, vid)

        # Set credentials
        if provider_auth is not None:
            (__, auth_username, auth_secret) = provider_auth.split()
            chap_cred = {"name": auth_username,
                         "password": auth_secret}

            self._set_target_credentials(target_name, chap_cred)

    def _attach_target_volume(self, target_name, vname):
        """Attach target to volume and handles exceptions

        Attempts to set attach volume to specific target.
        In case of failure will remove target.
        :param target_name: name of target
        :param vname: volume physical id
        """
        try:
            self.ra.attach_target_vol(target_name, vname)
        except jexc.JDSSException as jerr:
            msg = ('Unable to attach volume {volume} to target {target} '
                   'because of {error}.')
            LOG.warning(msg, {"volume": vname,
                              "target": target_name,
                              "error": jerr})
            self.ra.delete_target(target_name)
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
        try:
            data = self.ra.get_luns()

        except jexc.JDSSException as ex:
            LOG.error("List volume error. Because %(err)s",
                      {"err": ex})
            raise Exception(('Failed to list volumes %s.') % ex)

        for r in data:
            try:

                if not jcom.is_volume(r['name']):
                    continue

                ret.append({
                    'name': jcom.idname(r['name']),
                    'id': r['san:volume_id'],
                    'size': r['volsize']})

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
               'id': data['san:volume_id'],
               'size': data['volsize']}

        return ret

    def modify_volume(self, volume_name, property, value):
        LOG.debug("Update volume %s property %s with value %s",
                  volume_name,
                  property,
                  value)
        prop = {property: value}
        try:
            self.ra.modify_lun(jcom.vname(volume_name, prop=prop))
        except jexc.JDSSException as err:
            emsg = "Failed to set volume %(vol)s property %(pname)s with value %(pval)s" % {
                              'vol': volume_name,
                              'pname': property,
                              'pval': value}
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
            emsg = "Failed to rename volume %(vol)s to %(new_name)s" % {
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

    # Expand this function with remove hidden volume if that volume
    # have not snapshots
    def _list_all_volume_snapshots(self, vname, f=None):

        snaps = []

        i = 0
        LOG.debug("Listing all volume snapshots: %s", vname)

        while True:
            spage = self.ra.get_volume_snapshots_page(vname, i)

            if len(spage) > 0:

                if f is not None:
                    snaps.extend(filter(f, spage))
                else:
                    snaps.extend(spage)
                i += 1
            else:
                break

        for snap in snaps:
            for clone in jcom.snapshot_clones(snap):
                snaps.extend(self._list_all_volume_snapshots(vname, f))

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
            # if that is a linked clone one we might not want to list it for specific volume
            if jcom.is_volume(snap['name']):
                if all:
                    snap['volume_name'] = vname
                    out.append(snap)
                else:
                    LOG.warning("Linked clone present among volumes")
                continue

            vid = jcom.vid_from_sname(snap['name'])
            if vid is None or vid == ovolume_name:
                # That is used in create_snapshot function to provide detailed
                # info in case volume already have snapshot
                snap['volume_name'] = vname

                out.append(snap)
                for clone in jcom.snapshot_clones(snap):
                    out.extend(self._list_volume_snapshots(ovolume_name,
                                                           clone))
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
                          jcom.vid_from_sname(r['name']), r['name'])

                vid = jcom.vid_from_sname(r['name'])
                if vid == volume_name or vid is None:
                    ret.append({'name': jcom.sid_from_sname(r['name'])})

            except Exception:
                continue
        return ret

    def _hide_object(self, vname):
        """Mark volume/snapshot as hidden

        :param vname: physical volume name
        """
        rename = {'name': jcom.hidden(vname)}
        try:
            self.ra.modify_lun(vname, rename)
            return rename['name']
        except jexc.JDSSException as err:
            msg = _('Failure in hidding %(object)s, err: %(error)s,'
                    ' object have to be removed manually') % {'object': vname,
                                                              'error': err}
            LOG.warning(msg)
            raise err

    def _promote_volume(self, cname):
        """Promote volume.

        Takes clone_name and promotes it until it hits not hidden volume
        """

        cvolume = self.ra.get_lun(cname)

        ovname = jcom.origin_volume(cvolume)

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
                        "on volume %(hvolume) with error %(err)s.", {
                            "volume": cname,
                            "hvolume": ovname,
                            "err": jerr})
                return self._promote_volume(cname)

        return

    def _find_snapshot_parent(self, vname, sname):

        out = []
        snapshots = []
        i = 0
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

        for snap in snapshots:
            if snap['name'] == sname:
                return vname
            if jcom.is_volume(snap['name']):
                LOG.warning("Linked clone present among volumes")
                continue

            for clone in jcom.snapshot_clones(snap):
                out = self._find_snapshot_parent(clone, sname)
                if out is not None:
                    return out
        return None

    def revert_to_snapshot(self, volume_name, snapshot_name):
        """Revert volume to snapshot.

        Note: the revert process should not change the volume's
        current size, that means if the driver shrank
        the volume during the process, it should extend the
        volume internally.
        """
        raise jexc.JDSSException("Function not supported")
        vname = jcom.vname(volume_name)
        sname = jcom.sname(snapshot_name, volume_name)
        LOG.debug('reverting %(vname)s to %(sname)s', {
            "vname": vname,
            "sname": sname})

        pname = self._find_snapshot_parent(vname, sname)
        if pname is None:
            raise jexc.JDSSSnapshotNotFoundException(snapshot_name)

        hname = self._hide_object(vname)
        if pname == vname:
            pname = hname
        # TODO: make sure that sparsity of the volume depends on config
        self._clone_object(vname, sname, pname,
                           create_snapshot=False)
        self._promote_volume(vname)
        # TODO: catch if volume is busy with snapshots
        # in this case we just ignore

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
