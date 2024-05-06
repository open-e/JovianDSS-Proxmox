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

import base64
import re

allowed = re.compile(r"^[-\w]+$")


def is_volume(name):
    """Return True if volume"""

    return name.startswith("v_") or name.startswith("vb_")


def is_snapshot(name):
    """Return True if volume"""

    return name.startswith("s_")


def idname(name):
    """Convert id into name"""

    if name.startswith(('s_', 'v_', 't_')):
        return name[2:]

    if name.startswith('vb_'):
        return base64.b32decode(name[3:].encode())

    raise Exception("Bad volume name %s" % name)


def vname(name):
    """Convert id into volume name"""

    if name.startswith("v_"):
        return name

    if name.startswith("vb_"):
        return name

    if name.startswith('s_'):
        msg = 'Attempt to use snapshot %s as a volume' % name
        raise Exception(message=msg)

    if name.startswith('t_'):
        msg = 'Attempt to use deleted object %s as a volume' % name
        raise Exception(message=msg)

    if allowed.match(name):
        return name

    return "vb_" + base64.b32encode(name).decode()


def sname(name):
    """Convert id into snapshot name"""

    if name.startswith('s_'):
        return name

    if name.startswith('v_'):
        msg = ('Attempt to use volume %s as a snapshot') % name
        raise Exception(message=msg)

    if name.startswith('t_'):
        msg = ('Attempt to use deleted object %s as a snapshot') % name
        raise Exception(message=msg)

    return 's_' + name


def is_hidden(name):
    """Check if object is active or no"""

    if len(name) < 2:
        return False
    if name.startswith('t_'):
        return True
    return False


def origin_snapshot(origin_str):
    """Extracts original phisical snapshot name from origin record"""

    return origin_str.split("@")[1]


def origin_volume(origin_str):
    """Extracts original phisical volume name from origin record"""

    return origin_str.split("@")[0].split("/")[1]


def full_name_volume(name):
    """Get volume id from full_name"""

    return name.split('/')[1]


def hidden(name):
    """Get hidden version of a name"""

    if len(name) < 2:
        pass

    if name[:2] == 'v_' or name[:2] == 's_':
        return 't_' + name[2:]

    if name[3:] == 'vb_':
        return 't_' + name[3:]

    return 't_' + name
