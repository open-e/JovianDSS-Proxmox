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

import argparse
import re
import sys
import uuid
import logging

import jdssc.snapshots as snapshots
from jdssc.jovian_common import exception as jexc

"""Volume related commands."""

LOG = logging.getLogger(__name__)

block_size_options = ['4K', '8K', '16K', '32K', '64K', '128K', '256K', '512K',
                      '1M']

_MiB = 1048576


class Volumes():
    def __init__(self, args, uargs, jdss):

        self.vsa = {'create': self.create,
                    'getfreename': self.getfreename,
                    'list': self.list}

        self.args = args
        args, uargs = self.__parse(uargs)

        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        action = args.volumes_action
        if action is not None and len(action) > 0 and action in self.vsa:
            self.vsa[action]()
        else:
            sys.exit(1)

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Volume")

        parsers = parser.add_subparsers(dest='volumes_action')

        create = parsers.add_parser('create')
        create.add_argument('-s',
                            '--size',
                            required=True,
                            dest='volume_size',
                            type=str,
                            default='1G',
                            help='New volume size in format num + [M G T]')
        create.add_argument('-b',
                            dest='block_size',
                            type=str,
                            default=None,
                            choices=block_size_options,
                            help=('Block size of new volume, default is 16K'))
        create.add_argument('-d',
                            dest='direct_mode',
                            action='store_true',
                            default=False,
                            help='Use real volume name')
        create.add_argument('-n',
                            required=True,
                            dest='volume_name',
                            type=str,
                            help='New volume name')

        freename = parsers.add_parser('getfreename')
        freename.add_argument('--prefix',
                              required=True,
                              dest='volume_prefix',
                              help='Prefix for the new volume')

        listp = parsers.add_parser('list')
        listp.add_argument('--vmid',
                           dest='vmid',
                           action='store_true',
                           default=False,
                           help='Show only volumes with VM ID')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.volumes_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def create(self):
        size = self.args['volume_size']

        # Size here is a string of format 1G 1M and etc

        block_size = self.args['block_size']

        if block_size is not None and block_size.upper() in block_size_options:
            block_size = block_size.upper()
        elif (self.jdss.block_size is not None and
              self.jdss.block_size.upper() in block_size_options):
            block_size = self.jdss.block_size.upper()
        else:
            block_size = '16K'

        name = str(uuid.uuid1())
        if 'volume_name' in self.args:
            name = self.args['volume_name']

        try:
            self.jdss.create_volume(name, size,
                                    direct_mode=self.args['direct_mode'],
                                    block_size=block_size)
        except jexc.JDSSDatasetExistsException:
            LOG.error(("Please pick another name for volume as given one %s is"
                       " occupied by existing Share/Dataset"), name)
            exit(1)
        except (jexc.JDSSVolumeExistsException,
                jexc.JDSSResourceExistsException):
            LOG.error("Volume %s already exists", name)
            exit(1)

        except jexc.JDSSResourceExhausted:
            LOG.error("No space left on the storage")
            exit(1)

        except jexc.JDSSCommunicationFailure as jerr:
            LOG.error(("Unable to communicate with JovianDSS over given "
                       "interfaces %(interfaces)s. "
                       "Please make sure that addresses are correct and "
                       "REST API is enabled for JovianDSS") %
                      {'interfaces': ', '.join(jerr.interfaces)})
            exit(1)

    def clone(self):

        volume = {'id': self.args['clone_name']}

        try:

            if self.args['snapshot_name']:
                snapshot = snapshots.Snapshot.get_snapshot(
                    self.args['volume_name'],
                    self.args['snapshot_name'])

                self.jdss.create_volume_from_snapshot(volume, snapshot)

                return

            src_vref = {'id': self.args['volume_name']}
            self.jdss.create_cloned_volume(volume, src_vref)

        except jexc.JDSSResourceExhausted:
            LOG.error("No space left on the storage")
            exit(1)

    def get(self):

        volume_name = self.args['volume_name']

        volume = {'id': volume_name}

        try:
            d = self.jdss.get_volume(volume,
                                     direct_mode=self.args['direct_mode'])
            if self.args['volume_size']:
                print(int(d['size']))
        except jexc.JDSSCommunicationFailure as jerr:
            LOG.error(("Unable to communicate with JovianDSS over given "
                       "interfaces %(interfaces)s. "
                       "Please make sure that addresses are correct and "
                       "REST API is enabled for JovianDSS") %
                      {'interfaces': ', '.join(jerr.interfaces)})
            exit(1)

    def getfreename(self):

        volume_prefix = None

        if 'volume_prefix' in self.args:
            volume_prefix = self.args['volume_prefix']

        present_volumes = []
        data = self.jdss.list_volumes()

        for v in data:
            if v['name'].startswith(volume_prefix):
                present_volumes.append(v['name'])
                continue

        for i in range(0, sys.maxsize):
            nname = volume_prefix + str(i)
            if nname not in present_volumes:
                print(nname)
                return
        raise Exception("Unable to find free volume name")

    def list(self):
        data = self.jdss.list_volumes()

        vmid_re = None
        if self.args['vmid']:
            vmid_re = re.compile(r'^(vm|base)-[0-9]+-')

        for v in data:

            if vmid_re:
                match = vmid_re.match(v['name'])
                if not match:
                    continue

                vmid = v['name'][0:match.end()].split('-')[1]
                line = ("%(name)s %(vmid)s %(size)s\n" % {
                    'name': v['name'],
                    'vmid': vmid,
                    'size': int(v['size'])})
                sys.stdout.write(line)
            else:
                line = ("%(name)s %(size)s\n" % {
                    'name': v['name'],
                    'size': int(v['size'])})
                sys.stdout.write(line)
