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


class JDSSException(Exception):
    """General JovianDSS error"""

    def __init__(self, reason):
        self.message = "%(reason)s" % {'reason': reason}
        self.errcode = 1
        super().__init__(self.message)


class JDSSRESTException(JDSSException):
    """Unknown communication error"""

    def __init__(self, request, reason):
        self.errcode = 2
        msg = ("JDSS REST request %(request)s faild: %(reason)s." %
               {"request": request,
                "reason": reason})
        self.message = msg
        super().__init__(self.message)
        self.errcode = 2


class JDSSRESTProxyException(JDSSException):
    """Connection with host failed"""

    def __init__(self, host, reason):
        self.errcode = 3

        msg = ("JDSS connection with %(host)s failed: %(reason)s.",
               {"host": host,
                "reason": reason})
        self.message = msg
        super().__init__(self.message)
        self.errcode = 3


class JDSSCommunicationFailure(JDSSException):
    """Communication with host failed at all fiven IP"""

    def __init__(self, hosts, request):
        self.errcode = 4
        self.interfaces = hosts
        msg = ("None of interfaces: %(hosts)s responded to request "
               "%(request)s." % {"hosts": ', '.join(hosts),
                                 "request": request})
        self.message = msg
        super().__init__(self.message)
        self.errcode = 4


class JDSSOutdated(JDSSException):
    """Outdated"""

    def __init__(self, feature):

        msg = (("Feature %(feature)s is not supported in current version of "
               "JovianDSS") % {"feature": feature})

        self.message = msg
        super().__init__(self.message)
        self.errcode = 5


class JDSSVIPNotFoundException(JDSSException):
    """General JovianDSS error"""

    def __init__(self, vip_ips):

        self.message = "Unable to identify VIP name for ip's: %(vip_ips)s" % {
            'vip_ips': ','.join(vip_ips)}
        super().__init__(self.message)
        self.errcode = 6


class JDSSResourceNotFoundException(JDSSException):
    """Resource does not exist"""

    def __init__(self, res):

        self.message = "JDSS resource %(res)s DNE." % {'res': res}
        super().__init__(self.message)
        self.errcode = 7


class JDSSTargetNotFoundException(JDSSResourceNotFoundException):
    """Target does not exist"""

    def __init__(self, target):

        self.message = "target %(target)s" % {'target': target}
        super().__init__(self.message)
        self.errcode = 8


class JDSSVolumeNotFoundException(JDSSResourceNotFoundException):
    """Volume does not exist"""

    def __init__(self, volume):
        # ! Important ! this format is captured by perl base part of Proxmmox
        # plugin to identify if path can be returned
        # DO NOT CHANGE
        self.message = "volume %(volume)s" % {'volume': volume}
        super().__init__(self.message)


class JDSSSnapshotNotFoundException(JDSSResourceNotFoundException):
    """Snapshot does not exist"""

    def __init__(self, snapshot):
        self.message = "snapshot %(snapshot)s" % {'snapshot': snapshot}
        super().__init__(self.message)


class JDSSPoolNotFoundException(JDSSResourceNotFoundException):
    """Snapshot does not exist"""

    def __init__(self, pool):
        self.message = "pool %(pool)s" % {'pool': pool}
        super().__init__(self.message)


class JDSSResourceExistsException(JDSSException):
    """Resource with specified id exists"""

    def __init__(self, res):
        self.message = ("JDSS resource {} already exists.".format(res))
        super().__init__(self.message)


class JDSSSnapshotExistsException(JDSSResourceExistsException):
    """Snapshot with the same id exists"""

    def __init__(self, snapshot, volume):
        self.message = (("snapshot %(snapshot)s associated with "
                         "volume %(volume)s") %
                        {"snapshot": snapshot,
                         "volume": volume})
        super().__init__(self.message)


class JDSSVolumeExistsException(JDSSResourceExistsException):
    """Volume with same id exists"""

    def __init__(self, volume):
        self.message = ("volume %(volume)s" % {'volume': volume})
        super().__init__(self.message)


class JDSSDatasetExistsException(JDSSResourceExistsException):
    """Dataset with same id exists"""

    def __init__(self, dataset):
        self.message = ("dataset %(volume)s" % {'volume': dataset})
        super().__init__(self.message)


class JDSSResourceIsBusyException(JDSSException):
    """Resource have dependents"""

    def __init__(self, res):
        self.message = ("JDSS resource %(res)s is busy." % {'res': res})
        super().__init__(self.message)


class JDSSResourceVolumeIsBusyException(JDSSException):

    def __init__(self, volume, clones):
        dependents = ""
        while len(clones) > 0:
            dependents += ', '.join(clones[:10])
            dependents += '\n'
            clones = clones[10:]
        self.message = (("JDSS volume %(volume)s is busy, other volumes depend"
                         " on it:\n%(dependents)s ") %
                        {'volume': volume,
                         'dependents': dependents})
        super().__init__(self.message)


class JDSSRollbackIsBlocked(JDSSException):

    def __init__(self,
                 volume, snapshot,
                 snapshots, clones,
                 nsnapshots, nclones):
        snaps_string = ""
        while len(snapshots) > 0:
            snaps_string = ' '.join(snapshots[:10]) + "\n"
            snapshots = snapshots[10:]

        clones_string = ""
        while len(clones) > 0:
            clones_string = ' '.join(clones[:10]) + "\n"
            clones = clones[10:]

        msg = (("Unable to rollback volume %(volume_name)s to snapshot "
                "%(snapshot_name)s.\n") %
               {'volume_name': volume,
                'snapshot_name': snapshot})
        if nsnapshots > 0 or nclones > 0:
            msg += "Because "
            if nsnapshots > 0:
                msg += "%d snapshot(s) " % nsnapshots

            if nclones > 0:
                msg += "%d clone(s) " % nclones

            msg += "will be lost in process.\n"

        if len(snaps_string) > 0 or len(clones_string) > 0:
            msg += "To proceed with rollback please remove\n"
            if len(snaps_string) > 0:
                msg += "snapshots: %s\n" % snaps_string
            if len(clones_string) > 0:
                msg += "clones: %s\n" % clones_string

        self.message = msg
        super().__init__(self.message)


class JDSSSnapshotIsBusyException(JDSSResourceIsBusyException):
    """Snapshot have dependent clones"""

    def __init__(self, res):
        self.message = ("snapshot %(snapshot)s")
        super().__init__(self.message)


class JDSSOSException(JDSSException):
    """Storage internal system error"""

    def __init__(self, res):
        self.message = ("JDSS internal system error %(res)s." %
                        {'res': res})
        super().__init__(self.message)


class JDSSResourceExhausted(JDSSException):
    """No space left on the device"""

    def __init__(self):
        self.message = "JDSS Not enoung free space."
        super().__init__(self.message)
