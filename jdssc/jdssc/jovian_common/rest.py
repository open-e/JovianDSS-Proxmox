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


"""REST cmd interoperation class for Open-E JovianDSS driver."""
import re

import logging

from jdssc.jovian_common import exception as jexc
from jdssc.jovian_common import rest_proxy
from jdssc.jovian_common.stub import _

from jdssc.jovian_common import jdss_common as jcom

LOG = logging.getLogger(__name__)


class JovianRESTAPI(object):
    """Jovian REST API"""

    def __init__(self, config):

        self.pool = config.get('jovian_pool', 'Pool-0')
        self.rproxy = rest_proxy.JovianDSSRESTProxy(config)

        self.resource_dne_msg = (
            re.compile(r'^Zfs resource: .* not found in this collection\.$'))

        self.resource_has_clones_msg = (
            re.compile(r'^In order to delete a zvol, you must delete all of '
                       'its clones first.$'))
        self.resource_has_clones_class = (
            re.compile(r'^opene.storage.zfs.ZfsOeError$'))

        self.resource_has_clones2_class = (
            re.compile(r'^opene.storage.zfs.zfs.ZfsOeError$'))

        self.resource_has_snapshots_msg = (
            re.compile(r"^cannot destroy '.*/.*': volume has children\nuse "
                       r"'-r' to destroy the following datasets:\n.*"))
        self.resource_has_snapshots_class = (
            re.compile(r'^zfslib.wrap.zfs.ZfsCmdError$'))

        self.class_zfsresourceerror = (
            re.compile(r'^zfslib.zfsapi.resources.ZfsResourceError$'))

        self.class_item_conflict_error = (
            re.compile(r'^opene.exceptions.ItemConflictError$'))

        self.message_volume_already_used = (
            re.compile(r'^Volume .* is already used.$'))

        self.resource_already_exists_msg = (
            re.compile(r"^Resource .* already exists.$"))

        self.dataset_exists_msg = (
            re.compile(r"^cannot create '.*': dataset already exists$"))

        self.no_space_left = (
            re.compile(r"^New zvol size\(\d+\) exceeds available space on pool"
                       r" .+\(\d+\).$"))

    def _general_error(self, url, resp):
        reason = "Request %s failure" % url
        LOG.debug("error resp %s", resp)
        if 'error' in resp:

            eclass = resp['error'].get('class', 'Unknown')
            code = resp['error'].get('code', 'Unknown')
            msg = resp['error'].get('message', 'Unknown')

            reason = _("Request to %(url)s failed with code: %(code)s "
                       "of type:%(eclass)s reason:%(message)s")
            reason = (reason % {'url': url,
                                'code': code,
                                'eclass': eclass,
                                'message': msg})
        raise jexc.JDSSException(reason=reason)

    def get_active_host(self):
        """Return address of currently used host."""
        return self.rproxy.get_active_host()

    def is_pool_exists(self):
        """is_pool_exists.

        GET
        /pools/<string:poolname>

        :param pool_name:
        :return: Bool
        """
        req = ""
        LOG.debug("check pool")

        resp = self.rproxy.pool_request('GET', req)

        if resp["code"] == 200 and not resp["error"]:
            return True

        return False

    def get_iface_info(self):
        """get_iface_info

        GET
        /network/interfaces
        :return list of internet ifaces
        """
        req = '/network/interfaces'

        LOG.debug("get network interfaces")

        resp = self.rproxy.request('GET', req)
        if (resp['error'] is None) and (resp['code'] == 200):
            return resp['data']
        self._general_error(req, resp)

    def get_luns(self):
        """get_all_pool_volumes.

        GET
        /pools/<string:poolname>/volumes
        :param pool_name
        :return list of all pool volumes
        """
        req = '/volumes'

        LOG.debug("get all volumes")
        resp = self.rproxy.pool_request('GET', req)

        if resp['error'] is None and resp['code'] == 200:
            return resp['data']
        self._general_error(req, resp)

    def create_lun(self, volume_name, volume_size, sparse=False,
                   block_size=None):
        """create_volume.

        POST
        .../volumes

        :param volume_name:
        :param volume_size:
        :param sparse: thin or thick volume flag
        :param block_size: size of block
        :return:
        """
        volume_size_str = str(volume_size)
        jbody = {
            'name': volume_name,
            'size': volume_size_str,
            'sparse': sparse
        }
        if block_size:
            jbody['blocksize'] = block_size

        req = '/volumes'

        LOG.info("create volume %(vol)s of size %(size)s%(sparse)s",
                 {'vol': jcom.idname(volume_name),
                  'size': volume_size_str,
                  'sparse': ' that is sparse' if sparse else ''})

        resp = self.rproxy.pool_request('POST', req, json_data=jbody)

        if not resp["error"] and resp["code"] in (200, 201):
            return

        if "error" in resp and resp["error"] is not None:
            if "errno" in resp['error']:
                if resp["error"]["errno"] == str(5):
                    self._general_error(req, resp)
            if "message" in resp["error"]:
                if self.no_space_left.match(resp["error"]["message"]):
                    raise jexc.JDSSResourceExhausted
                if self.resource_already_exists_msg.match(
                        resp["error"]["message"]):
                    raise jexc.JDSSVolumeExistsException(volume_name)
        self._general_error(req, resp)

    def extend_lun(self, volume_name, volume_size):
        """create_volume.

        PUT /volumes/<string:volume_name>
        """
        req = '/volumes/' + volume_name
        volume_size_str = str(volume_size)
        jbody = {
            'size': volume_size_str
        }

        LOG.info("extend volume %(volume)s to %(size)s",
                 {"volume": jcom.idname(volume_name),
                  "size": volume_size_str})
        resp = self.rproxy.pool_request('PUT', req, json_data=jbody)

        if not resp["error"] and resp["code"] == 201:
            return

        if resp["error"]:
            raise jexc.JDSSRESTException(req,
                                         _('Failed to extend volume %s' %
                                           volume_name))

        self._general_error(req, resp)

    def is_lun(self, volume_name):
        """is_lun.

        GET /volumes/<string:volumename>
        Returns True if volume exists. Uses GET request.
        :param pool_name:
        :param volume_name:
        :return:
        """
        req = '/volumes/' + volume_name

        LOG.debug("check volume %s", volume_name)
        ret = self.rproxy.pool_request('GET', req)

        if not ret["error"] and ret["code"] == 200:
            return True
        return False

    def get_lun(self, volume_name):
        """get_lun

        GET /volumes/<volume_name>
        :param volume_name: zvol id
        :return: volume dict
            {
                "origin": null,
                "referenced": "65536",
                "primarycache": "all",
                "logbias": "latency",
                "creation": "1432730973",
                "sync": "always",
                "is_clone": false,
                "dedup": "off",
                "used": "1076101120",
                "full_name": "Pool-0/v1",
                "type": "volume",
                "written": "65536",
                "usedbyrefreservation": "1076035584",
                "compression": "lz4",
                "usedbysnapshots": "0",
                "copies": "1",
                "compressratio": "1.00x",
                "readonly": "off",
                "mlslabel": "none",
                "secondarycache": "all",
                "available": "976123452576",
                "resource_name": "Pool-0/v1",
                "volblocksize": "131072",
                "refcompressratio": "1.00x",
                "snapdev": "hidden",
                "volsize": "1073741824",
                "reservation": "0",
                "usedbychildren": "0",
                "usedbydataset": "65536",
                "name": "v1",
                "checksum": "on",
                "refreservation": "1076101120"
            }
        """
        req = '/volumes/' + volume_name

        LOG.debug("get volume %s info", volume_name)
        resp = self.rproxy.pool_request('GET', req)

        if not resp['error'] and resp['code'] == 200:
            return resp['data']

        if resp['error']:
            if 'message' in resp['error']:
                if self.resource_dne_msg.match(resp['error']['message']):
                    raise jexc.JDSSResourceNotFoundException(res=volume_name)

        self._general_error(req, resp)

    def modify_lun(self, volume_name, prop=None):
        """Update volume properties

        :param volume_name: volume name
        :param prop: dictionary
            {
                <property>: <value>
            }
        """

        req = '/volumes/' + volume_name

        LOG.info("update volume %(vol)s properties %(prop)s",
                 {'vol': jcom.idname(volume_name),
                  'prop': str(prop)})
        resp = self.rproxy.pool_request('PUT', req, json_data=prop)

        if resp["code"] in (200, 201, 204):
            LOG.debug("volume %s updated", volume_name)
            return

        if resp["code"] == 500:
            if resp["error"] is not None:
                if resp["error"]["errno"] == 1:
                    raise jexc.JDSSResourceNotFoundException(
                        res=volume_name)

        self._general_error(req, resp)

    def make_readonly_lun(self, volume_name):
        """Set volume into read only mode

        :param: volume_name: volume name
        """
        prop = {"property_name": "readonly", "property_value": "on"}

        self.modify_property_lun(volume_name, prop)

    def modify_property_lun(self, volume_name, prop=None):
        """Change volume properties

        :param volume_name: volume name
        :param prop: dictionary of volume properties in format
                { "property_name": "<name of property>",
                  "property_value":"<value of a property>"}
        """

        req = '/volumes/%s/properties' % volume_name

        LOG.info("set volume %(vol)s propertie %(prop)s to %(value)s",
                 {'vol': jcom.idname(volume_name),
                  'prop': str(prop['property_name']),
                  'value': str(prop['property_value'])})
        resp = self.rproxy.pool_request('PUT', req, json_data=prop)

        if resp["code"] in (200, 201, 204):
            LOG.debug(
                "volume %s properties updated", volume_name)
            return

        if resp["code"] == 500:
            if resp["error"] is not None:
                if resp["error"]["errno"] == 1:
                    raise jexc.JDSSResourceNotFoundException(
                        res=volume_name)
        self._general_error(req, resp)

    def delete_lun(self, volume_name,
                   recursively_children=False,
                   force_umount=False):
        """delete_volume.

        DELETE /volumes/<string:volumename>
        :param volume_name:
        :return:
        """
        jbody = {}
        if recursively_children:
            jbody['recursively_children'] = True

        if force_umount:
            jbody['force_umount'] = True

        req = '/volumes/' + volume_name
        LOG.info(("delete volume: %(vol)s"
                  " recursively" if recursively_children else ""
                  " with unmounting" if force_umount else ""),
                 {'vol': jcom.idname(volume_name)})

        if len(jbody) > 0:
            resp = self.rproxy.pool_request('DELETE', req, json_data=jbody)
        else:
            resp = self.rproxy.pool_request('DELETE', req)

        if resp["code"] == 204:
            LOG.debug(
                "volume %s deleted", volume_name)
            return

        # Handle DNE case
        if resp["code"] == 500:
            if 'message' in resp['error']:
                if self.resource_dne_msg.match(resp['error']['message']):
                    LOG.debug("volume %s do not exists, delition success",
                              volume_name)
                    return

        # Handle volume busy
        if resp["code"] == 500 and resp["error"]:
            if 'message' in resp['error'] and \
               'class' in resp['error']:
                if (self.resource_has_clones_msg.match(
                        resp['error']['message']) and
                   (self.resource_has_clones_class.match(
                        resp['error']['class']) or
                   self.resource_has_clones2_class.match(
                        resp['error']['class']))):
                    LOG.warning("volume %s is busy", volume_name)
                    raise jexc.JDSSResourceIsBusyException(res=volume_name)
                if (self.resource_has_snapshots_msg.match(
                        resp['error']['message']) and
                   self.resource_has_snapshots_class.match(
                        resp['error']['class'])):
                    LOG.warning("volume %s is busy", volume_name)
                    raise jexc.JDSSResourceIsBusyException(res=volume_name)
        if 'error' in resp and resp["error"] is not None:
            if 'message' in resp['error'] and \
               'class' in resp['error']:
                if (self.resource_has_clones_msg.match(
                        resp['error']['message']) and
                   (self.resource_has_clones_class.match(
                        resp['error']['class']) or
                   self.resource_has_clones2_class.match(
                        resp['error']['class']))):
                    LOG.warning("volume %s is busy", volume_name)
                    raise jexc.JDSSResourceIsBusyException(res=volume_name)

        self._general_error(req, resp)

    def is_target(self, target_name):
        """is_target.

        GET /san/iscsi/targets/ target_name
        :param target_name:
        :return: Bool
        """
        req = '/san/iscsi/targets/' + target_name

        LOG.debug("check if targe %s exists", target_name)
        resp = self.rproxy.pool_request('GET', req)

        if resp["error"] or resp["code"] not in (200, 201):
            return False

        if "name" in resp["data"]:
            if resp["data"]["name"] == target_name:
                LOG.debug(
                    "target %s exists", target_name)
                return True

        return False

    def create_target(self,
                      target_name,
                      use_chap=True,
                      allow_ip=None,
                      deny_ip=None):
        """create_target.

        POST /san/iscsi/targets
        :param target_name:
        :param chap_cred:
        :param allow_ip:
        "allow_ip": [
                "192.168.2.30/0",
                "192.168.3.45"
            ],

        :return:
        """
        req = '/san/iscsi/targets'

        jdata = {"name": target_name, "active": True}

        jdata["incoming_users_active"] = use_chap

        if allow_ip:
            jdata["allow_ip"] = allow_ip

        if deny_ip:
            jdata["deny_ip"] = deny_ip

        LOG.info("create iSCSI target: %(target)s",
                 {'target': target_name})

        resp = self.rproxy.pool_request('POST', req, json_data=jdata)

        if not resp["error"] and resp["code"] == 201:
            return

        if resp["code"] == 409:
            raise jexc.JDSSResourceExistsException(res=target_name)

        self._general_error(req, resp)

    def delete_target(self, target_name):
        """delete_target.

        DELETE /san/iscsi/targets/<target_name>
        :param pool_name:
        :param target_name:
        :return:
        """
        req = '/san/iscsi/targets/' + target_name

        LOG.info("delete iSCSI target: %(target)s",
                 {'target': target_name})

        resp = self.rproxy.pool_request('DELETE', req)

        if resp["code"] in (200, 201, 204):
            LOG.debug(
                "target %s deleted", target_name)
            return

        not_found_err = "opene.exceptions.ItemNotFoundError"
        if (resp["code"] == 404) or \
                (resp["error"]["class"] == not_found_err):
            raise jexc.JDSSResourceNotFoundException(res=target_name)

        self._general_error(req, resp)

    def create_target_user(self, target_name, chap_cred):
        """Set CHAP credentials for accees specific target.

        POST
        /san/iscsi/targets/<target_name>/incoming-users

        :param target_name:
        :param chap_cred:
        {
            "name": "target_user",
            "password": "3e21ewqdsacxz" --- 12 chars min
        }
        :return:
        """
        req = "/san/iscsi/targets/%s/incoming-users" % target_name

        LOG.debug("add credentails to target %s", target_name)

        resp = self.rproxy.pool_request('POST', req, json_data=chap_cred)

        if not resp["error"] and resp["code"] in (200, 201, 204):
            return

        if resp['code'] == 404:
            raise jexc.JDSSResourceNotFoundException(res=target_name)

        self._general_error(req, resp)

    def get_targets(self):
        """get_all_pool_volumes.

        GET
        /san/iscsi/targets

        :return list of all iscsi targets related to pool
        """
        req = "/san/iscsi/targets"

        LOG.debug("get all targets")
        resp = self.rproxy.pool_request('GET', req)

        if resp['error'] is None and resp['code'] == 200:
            return resp['data']
        self._general_error(req, resp)

    def get_target_luns(self, target_name):
        """Get list of luns attached to target

        GET
        /san/iscsi/targets/<target_name>/luns

        :param target_name:
        """
        req = "/san/iscsi/targets/%s/luns" % target_name

        LOG.debug("get target %s luns", target_name)

        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            return resp['data']

        if resp['code'] == 404:
            raise jexc.JDSSResourceNotFoundException(res=target_name)

        self._general_error(req, resp)

    def get_target_user(self, target_name):
        """Get name of CHAP user for accessing target

        GET
        /san/iscsi/targets/<target_name>/incoming-users

        :param target_name:
        """
        req = "/san/iscsi/targets/%s/incoming-users" % target_name

        LOG.debug("get chap cred for target %s", target_name)

        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            return resp['data']

        if resp['code'] == 404:
            raise jexc.JDSSResourceNotFoundException(res=target_name)

        self._general_error(req, resp)

    def delete_target_user(self, target_name, user_name):
        """Delete CHAP user for target

        DELETE
        /san/iscsi/targets/<target_name>/incoming-users/<user_name>

        :param target_name: target name
        :param user_name: user name
        """
        req = '/san/iscsi/targets/%(target)s/incoming-users/%(user)s' % {
            'target': target_name,
            'user': user_name}

        LOG.debug("remove credentails from target %s", target_name)

        resp = self.rproxy.pool_request('DELETE', req)

        if resp["error"] is None and resp["code"] == 204:
            return

        if resp['code'] == 404:
            raise jexc.JDSSResourceNotFoundException(res=target_name)

        self._general_error(req, resp)

    def is_target_lun(self, target_name, lun_name):
        """is_target_lun.

        GET /san/iscsi/targets/<target_name>/luns/<lun_name>
        :param pool_name:
        :param target_name:
        :param lun_name:
        :return: Bool
        """
        req = '/san/iscsi/targets/%(tar)s/luns/%(lun)s' % {
            'tar': target_name,
            'lun': lun_name}

        LOG.debug("check if volume %(vol)s is associated with %(tar)s",
                  {'vol': lun_name,
                   'tar': target_name})
        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            LOG.debug("volume %(vol)s is associated with %(tar)s",
                      {'vol': lun_name,
                       'tar': target_name})
            return True

        if resp['code'] == 404:
            LOG.debug("volume %(vol)s is not associated with %(tar)s",
                      {'vol': lun_name,
                       'tar': target_name})
            return False

        self._general_error(req, resp)

    def attach_target_vol(self, target_name, lun_name,
                          lun_id=0,
                          mode=None):
        """attach_target_vol.

        POST /san/iscsi/targets/<target_name>/luns
        :param target_name: name of the target
        :param lun_name: phisical volume name to be attached
        :param lun_id: id that would be assigned to volume
        :param mode: one of "wt", "wb" or "ro"
        :return:
        """
        req = '/san/iscsi/targets/%s/luns' % target_name

        jbody = {"name": lun_name, "lun": lun_id}
        if mode is not None:
            if mode in ['wt', 'wb', 'ro']:
                jbody['mode'] = mode
            else:
                raise jexc.JDSSException(
                    _("Incoret mode for target %s" % mode))
        LOG.debug("atach volume %(vol)s to target %(tar)s",
                  {'vol': lun_name,
                   'tar': target_name})

        resp = self.rproxy.pool_request('POST', req, json_data=jbody)

        if not resp["error"] and resp["code"] == 201:
            return

        if resp["error"]:
            if ('class' in resp["error"] and
                    self.class_item_conflict_error.match(
                        resp['error']['class']) and
                    'message' in resp["error"] and
                    self.message_volume_already_used.match(
                        resp['error']['message'])):
                raise jexc.JDSSResourceIsBusyException(lun_name)

        if "message" in resp["error"]:
            if self.no_space_left.match(resp["error"]["message"]):
                raise jexc.JDSSResourceExhausted

        if resp['code'] == 409:
            raise jexc.JDSSResourceExistsException(res=lun_name)

        if resp['code'] == 404:
            raise jexc.JDSSResourceNotFoundException(res=target_name)

            self._general_error(req, resp)

    def detach_target_vol(self, target_name, lun_name):
        """detach_target_vol.

        DELETE /san/iscsi/targets/<target_name>/luns/
        <lun_name>
        :param target_name:
        :param lun_name:
        :return:
        """
        req = '/san/iscsi/targets/%(tar)s/luns/%(lun)s' % {
            'tar': target_name,
            'lun': lun_name}

        LOG.debug("detach volume %(vol)s from target %(tar)s",
                  {'vol': lun_name,
                   'tar': target_name})

        resp = self.rproxy.pool_request('DELETE', req)

        if resp["code"] in (200, 201, 204):
            return

        if resp['code'] == 404:
            raise jexc.JDSSResourceNotFoundException(res=lun_name)

        self._general_error(req, resp)

    def create_snapshot(self, volume_name, snapshot_name):
        """create_snapshot.

        POST /pools/<string:poolname>/volumes/<string:volumename>/snapshots
        :param pool_name:
        :param volume_name: source volume
        :param snapshot_name: snapshot name
        :return:
        """
        req = '/volumes/%s/snapshots' % volume_name

        jbody = {
            'snapshot_name': snapshot_name
        }

        LOG.info("create snapshot %(snap)s for volume %(vol)s",
                 {'snap': jcom.idname(snapshot_name),
                  'vol': jcom.idname(volume_name)})

        resp = self.rproxy.pool_request('POST', req, json_data=jbody)

        if not resp["error"] and resp["code"] in (200, 201, 204):
            return

        if resp["code"] == 500:
            if resp["error"]:
                if resp["error"]["errno"] == 5:
                    raise jexc.JDSSSnapshotExistsException(
                        snapshot_name, volume_name)
                if resp["error"]["errno"] == 1:
                    raise jexc.JDSSVolumeNotFoundException(
                        volume=volume_name)

        self._general_error(req, resp)

    def create_volume_from_snapshot(self, volume_name, snapshot_name,
                                    original_vol_name, **options):
        """create_volume_from_snapshot.

        POST /volumes/<string:volumename>/clone
        :param volume_name: volume that is going to be created
        :param snapshot_name: slice of original volume
        :param original_vol_name: sample copy
        :return:
        """
        req = '/volumes/%s/clone' % original_vol_name

        jbody = {
            'name': volume_name,
            'snapshot': snapshot_name,
            'sparse': False,
        }

        if 'sparse' in options:
            jbody['sparse'] = options['sparse']

        if 'readonly' in options:
            jbody['readonly'] = options['readonly']

        LOG.info("create volume %(vol)s from snapshot %(snap)s",
                 {'vol': jcom.idname(volume_name),
                  'snap': jcom.idname(snapshot_name)})

        resp = self.rproxy.pool_request('POST', req, json_data=jbody)

        if not resp["error"] and resp["code"] in (200, 201, 204):
            return

        if resp["code"] == 500:
            if resp["error"]:
                if (resp["error"]["errno"] == 100 and
                        ('message' in resp["error"])):
                    if self.dataset_exists_msg.match(resp['error']['message']):
                        raise jexc.JDSSVolumeExistsException(volume_name)
                if resp["error"]["errno"] == 1:
                    raise jexc.JDSSResourceNotFoundException(
                        res="%(vol)s@%(snap)s" % {'vol': original_vol_name,
                                                  'snap': snapshot_name})
            if "message" in resp["error"]:
                if self.no_space_left.match(resp["error"]["message"]):
                    raise jexc.JDSSResourceExhausted

        self._general_error(req, resp)

    def delete_snapshot(self,
                        volume_name,
                        snapshot_name,
                        recursively_children=False,
                        force_umount=False):
        """delete_snapshot.

        DELETE /volumes/<string:volumename>/snapshots/
            <string:snapshotname>
        :param volume_name: volume that snapshot belongs to
        :param snapshot_name: snapshot name
        :param recursively_children: boolean indicating if zfs should
            recursively destroy all children of resource, in case of snapshot
            remove all snapshots in descendant file system (default false).
        :param recursively_dependents: boolean indicating if zfs should
            recursively destroy all dependents, including cloned file systems
            outside the target hierarchy (default false).
        :param force_umount: boolean indicating if volume should be forced to
            umount (defualt false).
        :return:
        """

        req = '/volumes/%(vol)s/snapshots/%(snap)s' % {
            'vol': volume_name,
            'snap': snapshot_name}

        jbody = {}
        if recursively_children:
            jbody['recursively_children'] = True

        if force_umount:
            jbody['force_umount'] = True

        LOG.info(("delete snapshot: %(snap) for volume: %(vol)s"
                  " recursively" if recursively_children else ""
                  " with unmounting" if force_umount else ""),
                 {'vol': jcom.idname(volume_name),
                  'snap': jcom.idname(snapshot_name)})

        resp = self.rproxy.pool_request('DELETE', req, json_data=jbody)

        if resp["code"] in (200, 201, 204):
            LOG.debug("snapshot %s deleted", snapshot_name)
            return

        if resp["code"] == 500:
            if resp["error"]:
                if resp["error"]["errno"] == 1000:
                    raise jexc.JDSSSnapshotIsBusyException(
                        snapshot=snapshot_name)
            if 'message' in resp['error']:
                if self.resource_dne_msg.match(resp['error']['message']):
                    raise jexc.JDSSResourceNotFoundException(snapshot_name)
        self._general_error(req, resp)

    def get_snapshot(self, volume_name, snapshot_name):

        req = (('/volumes/%(vol)s/snapshots/%(snap)s') %
               {'vol': volume_name, 'snap': snapshot_name})

        LOG.debug("get snapshots for volume %s ", volume_name)

        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            return resp["data"]

        if resp['code'] == 500:
            if 'message' in resp['error']:
                if self.resource_dne_msg.match(resp['error']['message']):
                    raise jexc.JDSSResourceNotFoundException(volume_name)

        self._general_error(req, resp)

    def get_snapshots(self, volume_name):
        """get_snapshots.

        GET
        /volumes/<string:volumename>/
            snapshots

        :param volume_name: that snapshot belongs to
        :return:
        {
            "data":
            [
                {
                    "referenced": "65536",
                    "name": "MySnapshot",
                    "defer_destroy": "off",
                    "userrefs": "0",
                    "primarycache": "all",
                    "type": "snapshot",
                    "creation": "2015-5-27 16:8:35",
                    "refcompressratio": "1.00x",
                    "compressratio": "1.00x",
                    "written": "65536",
                    "used": "0",
                    "clones": "",
                    "mlslabel": "none",
                    "secondarycache": "all"
                }
            ],
            "error": null
        }
        """
        req = '/volumes/%s/snapshots' % volume_name

        LOG.debug("get snapshots for volume %s ", volume_name)

        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            return resp["data"]["entries"]

        if resp['code'] == 500:
            if 'message' in resp['error']:
                if self.resource_dne_msg.match(resp['error']['message']):
                    raise jexc.JDSSResourceNotFoundException(volume_name)

        self._general_error(req, resp)

    def get_snapshots_page(self, page_id):
        """get_snapshots_page

        GET
        /volumes/snapshots?page=<int:page_id>

        :param page_id: page number
        :return:
        {
            "data":
            [
                {"results": 1,
                 "entries": [
                     ]}
                {
                    "referenced": "65536",
                    "name": "MySnapshot",
                    "defer_destroy": "off",
                    "userrefs": "0",
                    "primarycache": "all",
                    "type": "snapshot",
                    "creation": "2015-5-27 16:8:35",
                    "refcompressratio": "1.00x",
                    "compressratio": "1.00x",
                    "written": "65536",
                    "used": "0",
                    "clones": "",
                    "mlslabel": "none",
                    "secondarycache": "all"
                }
            ],
            "error": null
        }
        """
        req = '/volumes/snapshots?page=%s' % str(page_id)

        LOG.debug("get page %d of all snapshots", page_id)

        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            return resp["data"]["entries"]

        self._general_error(req, resp)

    def get_volume_snapshots_page(self, vname, page_id):
        """get_snapshots_page

        GET
        /volumes/snapshots?page=<int:page_id>

        :param page_id: page number
        :return:
        {
            "data":
            [
                {"results": 1,
                 "entries": [
                     ]}
                {
                    "referenced": "65536",
                    "name": "MySnapshot",
                    "defer_destroy": "off",
                    "userrefs": "0",
                    "primarycache": "all",
                    "type": "snapshot",
                    "creation": "2015-5-27 16:8:35",
                    "refcompressratio": "1.00x",
                    "compressratio": "1.00x",
                    "written": "65536",
                    "used": "0",
                    "clones": "",
                    "mlslabel": "none",
                    "secondarycache": "all"
                }
            ],
            "error": null
        }
        """
        req = (('/volumes/%(vname)s/snapshots?page=%(page)s') %
               {'vname': vname, 'page': str(page_id)})

        LOG.debug("get page %d of volume %s snapshots", page_id, vname)

        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            return resp["data"]["entries"]

        self._general_error(req, resp)

    def get_pool_stats(self):
        """get_pool_stats.

        GET /pools/<string:poolname>
        :param pool_name:
        :return:
        {
          "data": {
            "available": "24433164288",
            "status": 24,
            "name": "Pool-0",
            "scan": {
              "errors": 0,
              "repaired": "0",
              "start_time": 1463476815,
              "state": "finished",
              "end_time": 1463476820,
              "type": "scrub"
            },
            "iostats": {
              "read": "0",
              "write": "0",
              "chksum": "0"
            },
            "vdevs": [
              {
                "name": "scsi-SSCST_BIOoWKF6TM0qafySQBUd1bb392e",
                "iostats": {
                  "read": "0",
                  "write": "0",
                  "chksum": "0"
                },
                "disks": [
                  {
                    "led": "off",
                    "name": "sdb",
                    "iostats": {
                      "read": "0",
                      "write": "0",
                      "chksum": "0"
                    },
                    "health": "ONLINE",
                    "sn": "d1bb392e",
                    "path": "pci-0000:04:00.0-scsi-0:0:0:0",
                    "model": "oWKF6TM0qafySQBU",
                    "id": "scsi-SSCST_BIOoWKF6TM0qafySQBUd1bb392e",
                    "size": 30064771072
                  }
                ],
                "health": "ONLINE",
                "vdev_replacings": [],
                "vdev_spares": [],
                "type": ""
              }
            ],
            "health": "ONLINE",
            "operation": "none",
            "id": "11612982948930769833",
            "size": "29796335616"
          },
          "error": null
        }
        """
        req = ""
        LOG.debug("Get pool %s fsprops", self.pool)

        resp = self.rproxy.pool_request('GET', req)
        if not resp["error"] and resp["code"] == 200:
            return resp["data"]

        self._general_error(req, resp)

    def get_snapshot_rollback(self, volume_name, snapshot_name):
        """get snapshot rollback fetches number of resources affected by
        volume rollback to specific snapshot

        GET /volumes/<volume_name>/snapshots/<snapshot_name>/rollback

        :param str volume_name: volume that is going to be reverted
        :param str snapshot_name: snapshot of a volume above

        :return: { 'clones': int, 'snapshots': int }
        """
        req = (('/volumes/%(vname)s/snapshots/%(sname)s/rollback') %
               {'vname': volume_name, 'sname': snapshot_name})

        LOG.info(("check rollback dependency count for volume %(vol)s"
                 " to snapshot %(snap)s"),
                 {'vol': jcom.idname(volume_name),
                  'snap': jcom.idname(snapshot_name)})

        resp = self.rproxy.pool_request('GET', req)

        if not resp["error"] and resp["code"] == 200:
            return resp["data"]

        if resp["code"] == 500:
            if resp["error"]:
                if resp["error"]["errno"] == 1:
                    raise jexc.JDSSResourceNotFoundException(
                        res="%(vol)s@%(snap)s" % {'vol': volume_name,
                                                  'snap': snapshot_name})

        self._general_error(req, resp)

    def snapshot_rollback(self, volume_name, snapshot_name):
        """snapshot rollback rollbacks volume to its snapshot

        POST /volumes/<volume_name>/snapshots/<snapshot_name>/rollback
        :param volume_name: volume that is going to be restored
        :param snapshot_name: snapshot of a volume above
        :return:
        """
        req = (('/volumes/%(vname)s/snapshots/%(sname)s/rollback') %
               {'vname': volume_name, 'sname': snapshot_name})

        LOG.info("rollback volume %(vol)s to snapshot %(snap)s",
                 {'vol': jcom.idname(volume_name),
                  'snap': jcom.idname(snapshot_name)})

        resp = self.rproxy.pool_request('POST', req)

        if resp["code"] in (200, 201, 204):
            LOG.debug("volume %s been rolled back to snapshot %s",
                      volume_name,
                      snapshot_name)
            return

        self._general_error(req, resp)
