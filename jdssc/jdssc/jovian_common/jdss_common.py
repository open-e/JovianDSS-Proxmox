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

from datetime import datetime
import base64
import logging
import re

from jdssc.jovian_common import cexception as exception

import uuid
allowedPattern = re.compile(r"^[-\w]+$")

LOG = logging.getLogger(__name__)


def JBase32ToStr(bname):
    return base64.b32decode(bname.replace("-", "=") .encode()).decode()


def JBase32FromStr(name):
    return base64.b32encode(name.encode()).decode().replace("=", "-")


def is_volume(name):
    """Return True if volume"""

    return name.startswith("v_") or name.startswith("vb_")


def is_snapshot(name):
    """Return True if volume"""

    if name.startswith("s_"):
        return True

    if name.startswith("se_"):
        return True

    return False


def idname(name):
    """Extract id from physical volume name"""

    if name.startswith('v_'):
        return name[2:]

    if name.startswith('t_'):
        return name[2:]

    if name.startswith('te_'):
        ns = name.split("_")
        "_".join(ns[1:-1])

    if name.startswith('s'):
        return sname_to_id(name)[0]

    if name.startswith('vb_'):
        return JBase32ToStr(name[3:])

    # LOG.warn("Unable to identify name type %s", name)
    return name


def vname(name):
    """Convert id into volume name"""

    if name.startswith("v_"):
        return name

    if name.startswith("vb_"):
        return name

    if name.startswith('s_'):
        msg = 'Attempt to use snapshot %s as a volume' % name
        raise Exception(msg)

    if name.startswith('t_'):
        msg = 'Attempt to use deleted object %s as a volume' % name
        raise Exception(msg)

    if allowedPattern.match(name):
        return "v_" + name

    return "vb_" + JBase32FromStr(name)


def sname_to_id(sname):

    spl = sname.split('_')

    if spl[0] == 's':
        return ('_'.join(spl[1:]), None)

    if spl[0] == 'se':
        sid = '_'.join(spl[1:-1])
        vid = JBase32ToStr(spl[-1:][0])
        return sid, vid

    if spl[0] == 'sb' and len(spl) == 3:
        sid = JBase32ToStr(spl[1])
        vid = JBase32ToStr(spl[2])
        return sid, vid

    if spl[0] == 'autosnap':
        return ('_'.join(spl[1:]), None)

    msg = "Incorrect snapshot name %s" % sname
    raise Exception(msg)


def sid_from_sname(name):
    return sname_to_id(name)[0]


def vid_from_sname(name):
    return sname_to_id(name)[1]


def sname(sid, vid):
    """Convert id into snapshot name

    :param: vid: volume id
    :param: sid: snapshot id
    """
    # out = ""
    # e for extendent
    # b for based

    out = 's_%(sid)s' % {'sid': sid}

    if not allowedPattern.match(sid):
        out = 'sb_%(sid)s' % {'sid': JBase32FromStr(sid)}
    if vid is not None and len(vid) > 0:
        out += '_%(vid)s' % {'vid': JBase32FromStr(vid)}
    return out


def sname_from_snap(snapshot_struct):
    return snapshot_struct['name']


def is_hidden(name):
    """Check if object is active or no"""

    if len(name) < 2:
        return False
    if name.startswith('t_'):
        return True
    return False


def origin_snapshot(vol):
    """Extracts original physical snapshot name from volume dict"""
    if 'origin' in vol and vol['origin'] is not None:
        return vol['origin'].split("@")[1]
    return None


def origin_volume(vol):
    """Extracts original physical volume name from volume dict"""

    if 'origin' in vol and vol['origin'] is not None:
        return vol['origin'].split("@")[0].split("/")[1]
    return None


def snapshot_clones(snap):
    """Return list of clones associated with snapshot or return empty list"""
    out = []
    clones = []
    if 'clones' not in snap:
        return out
    else:
        clones = snap['clones'].split(',')

    for clone in clones:
        out.append(clone.split('/')[1])
    return out


def hidden(name):
    """Get hidden version of a name"""

    if len(name) < 2:
        raise exception.VolumeDriverException("Incorrect volume name")

    if name[:2] == 'v_' or name[:2] == 's_':
        return 't_' + name[2:] + '_' + uuid.uuid4().hex
    if name[:3] == 'se_' or name[:3] == 'sb_' or name[:3] == 'vb_':
        return 't_' + name[:3] + '_' + uuid.uuid4().hex
    return 't_' + name + '_' + uuid.uuid4().hex


def get_newest_snapshot_name(snapshots):
    newest_date = None
    sname = None
    for snap in snapshots:
        current_date = datetime.strptime(snap['creation'], "%Y-%m-%d %H:%M:%S")
        if newest_date is None or current_date > newest_date:
            newest_date = current_date
            sname = snap['name']
    return sname


def dependency_error(msg, dl):
    LOG.error(msg)
    while len(dl) > 0:
        msg = ', '.join(dl[:10])
        dl = dl[10:]
        LOG.error(msg)
