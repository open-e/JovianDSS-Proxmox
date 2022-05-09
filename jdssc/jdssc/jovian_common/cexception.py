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
    """Unknown error"""
    def __init__(self, reason=''):
        self.message = ("%(reason)s" % {"reason": reason})


class VolumeDriverException(JDSSException):
    """Unknown communication error"""

    message = ("JDSS REST request %(request)s faild: %(reason)s.")


class VolumeBackendAPIException(JDSSException):
    """Volume Backend API Esxeption"""

    def __init__(self, message):
        self.message = message

class VolumeIsBusy(JDSSException):
    """Volume is busy"""

    def __init__(self, message):
        self.message = message

class InvalidConfigurationValue(JDSSException):
    """Connection with host failed"""
    
    def __init__(self, value='', option=''):
        message = ("JDSS invalid configuration, Option: %(opt)s should not have value: %(val)s."
                        % {'opt': option, 'val': value})

class VolumeNotFound(JDSSException):
    """Volume does not exist"""
    
    def __init__(self, volume_id=''):
        message = ("JDSS volume with id %(vol)s not found." % {'vol': volume_id})

