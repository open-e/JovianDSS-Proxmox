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


class JDSSException(Exception):
    """General JovianDSS error"""

    def __init__(self, reason):
        self.message = "%(reason)s" % {'reason': reason}
        super().__init__(self.message)


class JDSSRESTException(JDSSException):
    """Unknown communication error"""

    message = ("JDSS REST request %(request)s faild: %(reason)s.")


class JDSSRESTProxyException(JDSSException):
    """Connection with host failed"""

    message = ("JDSS connection with %(host)s failed: %(reason)s.")


class JDSSResourceNotFoundException(JDSSException):
    """Resource does not exist"""

    def __init__(self, res):
        self.message = "JDSS resource %(res)s DNE." % {'res': res}
        super().__init__(self.message)


class JDSSVolumeNotFoundException(JDSSResourceNotFoundException):
    """Volume does not exist"""

    def __init__(self, volume):
        self.message = "volume %(volume)s" % {'volume': volume}
        super().__init__(self.message)


class JDSSSnapshotNotFoundException(JDSSResourceNotFoundException):
    """Snapshot does not exist"""

    def __init__(self, snapshot):
        self.message = "snapshot %(snapshot)s" % {'snapshot': snapshot}
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
        self.message = ("JDSS volume %(volume)s already exists.")
        super().__init__(self.message)


class JDSSResourceIsBusyException(JDSSException):
    """Resource have dependents"""

    def __init__(self, res):
        self.message = ("JDSS resource %(res)s is busy." % {'res': res})
        super().__init__(self.message)


class JDSSSnapshotIsBusyException(JDSSResourceIsBusyException):
    """Snapshot have dependent clones"""

    message = ("snapshot %(snapshot)s")


class JDSSOSException(JDSSException):
    """Storage internal system error"""

    message = ("JDSS internal system error %(message)s.")
