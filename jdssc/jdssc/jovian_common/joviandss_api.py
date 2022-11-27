#    Copyright (c) 2020 Open-E, Inc.
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

"""iSCSI volume driver for JovianDSS driver."""
import math
import string
import secrets

import logging
from oslo_utils import units as o_units

from jdssc.jovian_common import exception as jexc
from jdssc.jovian_common import cexception as cexc
from jdssc.jovian_common import jdss_common as jcom
from jdssc.jovian_common import rest
from jdssc.jovian_common.stub import _

LOG = logging.getLogger(__name__)

class JovianISCSIDriver(object):
    """Executes volume driver commands on Open-E JovianDSS.

    Version history:

    .. code-block:: none

        1.0.0 - Open-E JovianDSS driver with basic functionality
        1.0.1 - Added certificate support
                Added revert to snapshot support
        1.0.2 - Added multi-attach support
    """

    # ThirdPartySystems wiki page
    CI_WIKI_NAME = "Open-E_JovianDSS_CI"
    VERSION = "1.0.2"

    def __init__(self, cfg):

        self.configuration = cfg
        self._stats = None
        self.jovian_iscsi_target_portal_port = "3260"
        self.jovian_target_prefix = 'iqn.2020-04.com.open-e'
        self.jovian_chap_pass_len = 12
        self.jovian_sparse = False
        self.jovian_ignore_tpath = None
        self.jovian_hosts = None
        self._pool = 'Pool-0'
        self.ra = None

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

    def do_setup(self, context):
        """Any initialization the volume driver does while starting."""

        self._pool = self.configuration.get('jovian_pool', 'Pool-0')
        self.jovian_iscsi_target_portal_port = self.configuration.get(
            'target_port', 3260)

        self.jovian_target_prefix = self.configuration.get(
            'target_prefix',
            'iqn.2020-04.com.open-e.cinder:')
        self.jovian_chap_pass_len = self.configuration.get(
            'chap_password_len', 12)
        self.block_size = (
            self.configuration.get('jovian_block_size', '64K'))
        self.jovian_sparse = (
            self.configuration.get('thin_provision', True))
        self.jovian_ignore_tpath = self.configuration.get(
            'jovian_ignore_tpath', None)
        self.jovian_hosts = self.configuration.get(
            'rest_api_addresses', [])

        self.ra = rest.JovianRESTAPI(self.configuration)

        self.check_for_setup_error()

    def check_for_setup_error(self):
        """Check for setup error."""
        if len(self.jovian_hosts) == 0:
            msg = _("No hosts provided in configuration")
            raise cexc.VolumeDriverException(msg)

        if not self.ra.is_pool_exists():
            raise Exception(("Unable to identify pool %s") % self._pool)

        valid_bsize = ['16K', '32K', '64K', '128K', '256K', '512K', '1M']
        if self.block_size not in valid_bsize:
            raise cexc.InvalidConfigurationValue(
                value=self.block_size,
                option='jovian_block_size')

    def _get_target_name(self, volume_name):
        """Return iSCSI target name to access volume."""
        return '%s%s' % (self.jovian_target_prefix, volume_name)

    def _get_active_ifaces(self):
        """Return list of ip addreses for iSCSI connection"""

        return self.jovian_hosts

    def create_volume(self, vol_name, size):
        """Create a volume.

        :param volume: volume reference
        :return: model update dict for volume reference
        """
        LOG.debug('creating volume %s.', vol_name)



        try:
            self.ra.create_lun(vol_name,
                               size,
                               sparse=self.jovian_sparse,
                               block_size=self.block_size)

        except jexc.JDSSException as ex:
            LOG.error("Create volume error. Because %(err)s",
                      {"err": ex})
            raise Exception(('Failed to create volume %s.') % vol_name)
        
        provider_location = self._get_provider_location(vol_name)
        ret = {}

        ret['provider_location'] = provider_location

        return ret

    def list_volumes(self):
        """List all volumes related to this pool.

        :return: list of volumes
        """
        #vname = jcom.vname(volume.id)
        #LOG.debug('creating volume %s.', vname)

        #provider_location = self._get_provider_location(volume.id)
        #provider_auth = self._get_provider_auth()

        ret = []
        try:
            data = self.ra.get_luns()

        except jexc.JDSSException as ex:
            LOG.error("List volume error. Because %(err)s",
                      {"err": ex})
            raise Exception(('Failed to list volumes %s.') % ex)

        for r in data:
            try:

                ret.append({
                'name': jcom.idname(r['name']),
                'id' : r['san:volume_id'],
                'size': r['volsize']})

            except Exception as err:
                pass
        return ret

    def get_volume(self, vol_name):
        """List volumes related to this pool.

        :return: list of volumes
        """

        try:
            data = self.ra.get_lun(vol_name)

        except jexc.JDSSException as ex:
            LOG.error("Get volume error. Because %(err)s",
                      {"err": ex})
            raise Exception(('Failed to get volume %s.') % vol_name)

        if not jcom.is_volume(vol_name):
            return dict()

        ret = {'name': data['name'],
               'id' : data['san:volume_id'],
               'size': data['volsize']}

        return ret

    def delete_volume(self, vol_name):
        """Delete volume

        :param volume: volume reference
        :param cascade: remove snapshots of a volume as well
        """

        LOG.debug('deleating volume %s', vol_name)

        try:
            self.ra.delete_lun(vol_name, force_umount=True)
        except jexc.JDSSRESTException as err:
            LOG.debug(
                "Unable to delete physical volume %(volume)s "
                "with error %(err)s.", {
                    "volume": vname,
                    "err": err})

    def extend_volume(self, vol_name, new_size):
        """Extend an existing volume.

        :param volume: volume reference
        :param new_size: volume new size in GB
        """
        LOG.debug("Extend volume %s", vol_name)

        try:
            self.ra.extend_lun(vol_name, new_size)
        except jexc.JDSSException as err:
            raise Exception(
                (('Failed to extend volume %s.'), vol_name)) from err

    def get_provider_location(self, volume):
        """Get target description"""
        
        return self._get_provider_location(volume)

    def _get_provider_location(self, volume_name):
        """Return volume iscsiadm-formatted provider location string."""
        return '%(host)s:%(port)s,1 %(name)s 0' % {
            'host': self.ra.get_active_host(),
            'port': self.jovian_iscsi_target_portal_port,
            'name': self._get_target_name(volume_name)}

    def create_target(self, vol_name, t_name):
        """Create new export for zvol.

        :param volume: reference of volume to be exported
        :return: iscsiadm-formatted provider location string
        """
        LOG.debug("create export for volume: %s.", vol_name)

        self._ensure_target_volume(vol_name, t_name)

        return {'provider_location': self._get_provider_location(vol_name)}

    def ensure_target(self, vol_name, t_name):
        """Recreate parts of export if necessary.

        :param volume: reference of volume to be exported
        """
        LOG.debug("ensure export for volume: %s.", vol_name)
        self._ensure_target_volume(vol_name, t_name)

    def remove_target(self, vol_name, t_name):
        """Destroy all resources created to export zvol.

        :param volume: reference of volume to be unexported
        """
        LOG.debug("remove_export for volume: %s.", t_name)

        self._remove_target_volume(vol_name, t_name)

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

    def _create_target(self, target_name):
        """Creates target and handles exceptions

        Tryes to create target.
        :param target_name: name of target
        :param use_chap: flag for using chap
        """
        try:
            self.ra.create_target(target_name)

        except jexc.JDSSResourceExistsException as jerr:
            raise cexc.Duplicate() from jerr
        except jexc.JDSSException as ex:

            msg = (_('Unable to create target %(target)s '
                     'because of %(error)s.') % {'target': target_name,
                                                 'error': ex})
            raise cexc.VolumeBackendAPIException(msg)

    def _attach_target_volume(self, vol_name, target_name):
        """Attach target to volume and handles exceptions

        Tryes to set attach volume to specific target.
        In case of failure will remve target.
        :param target_name: name of target
        :param use_chap: flag for using chap
        """
 
        mode='wt'
        try:
            self.ra.attach_target_vol(target_name, vol_name, mode=mode)
        except jexc.JDSSException as ex:
            msg = ('Unable to attach volume to target %(target)s '
                   'because of %(error)s.')
            emsg = msg % {'target': target_name, 'error': ex.message}
            LOG.debug(msg)
            try:
                self.ra.delete_target(target_name)
            except jexc.JDSSException:
                pass
            raise cexc.VolumeBackendAPIException(_(emsg))

    def _ensure_target_volume(self, vol_name, target_name):
        """Checks if target configured properly and volume is attached to it

        param: volume: volume structure
        """
        LOG.debug("ensure volume %s assigned to a proper target", vol_name)

        if not self.ra.is_target(target_name):
            self._create_target(target_name)

        if not self.ra.is_target_lun(target_name, vol_name):
            self._attach_target_volume(target_name, vol_name)

    def _remove_target_volume(self, volume, isSnapshot=False):
        """_remove_target_volume

        Ensure that volume is not attached to target and target do not exists.
        """
        target_name = self.jovian_target_prefix + volume['id']
        LOG.debug("remove target")
        LOG.debug("detach volume:%(vol)s from target:%(targ)s.", {
            'vol': volume,
            'targ': target_name})
        
        vname = None
        if isSnapshot:
            vname = jcom.sname(volume['id'])
        else:
            vname = jcom.vname(volume['id'])

        try:
            self.ra.detach_target_vol(target_name, vname)

        except jexc.JDSSResourceNotFoundException as ex:
            LOG.debug('failed to remove resource %(t)s because of %(err)s', {
                't': target_name,
                'err': ex.message})
        except jexc.JDSSException as ex:
            LOG.debug('failed to Terminate_connection for target %(targ)s'
                      'because of: %(err)s', {
                          'targ': target_name,
                          'err': ex.message})
            raise cexc.VolumeBackendAPIException(ex)

        LOG.debug("delete target: %s", target_name)

        try:
            self.ra.delete_target(target_name)
        except jexc.JDSSResourceNotFoundException as ex:
            LOG.debug('failed to remove resource %(target)s because '
                      'of %(err)s', {'target': target_name,
                                     'err': ex.message})

        except jexc.JDSSException as ex:
            LOG.debug('Failed to Terminate_connection for target %(targ)s'
                      'because of: %(err)s', {
                          'targ': target_name,
                          'err': ex.message})

            raise cexc.VolumeBackendAPIException(ex)

    def _get_iscsi_properties(self, volume, connector):
        """Return dict according to cinder/driver.py implementation.

        :param volume:
        :return:
        """
        tname = self.jovian_target_prefix + volume.id
        iface_info = []
        multipath = connector.get('multipath', False)
        if multipath:
            iface_info = self._get_active_ifaces()
            if not iface_info:
                raise cexc.InvalidConfigurationValue(
                    _('No available interfaces '
                      'or config excludes them'))

        iscsi_properties = dict()

        if multipath:
            iscsi_properties['target_iqns'] = []
            iscsi_properties['target_portals'] = []
            iscsi_properties['target_luns'] = []
            LOG.debug('tpaths %s.', iface_info)
            for iface in iface_info:
                iscsi_properties['target_iqns'].append(
                    self.jovian_target_prefix +
                    volume.id)
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

        auth = volume.provider_auth
        if auth:
            (auth_method, auth_username, auth_secret) = auth.split()

            iscsi_properties['auth_method'] = auth_method
            iscsi_properties['auth_username'] = auth_username
            iscsi_properties['auth_password'] = auth_secret

        iscsi_properties['target_lun'] = 0
        return iscsi_properties
