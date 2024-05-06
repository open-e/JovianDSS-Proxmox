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

import argparse
import re
import sys
import uuid

import jdssc.snapshots as snapshots

"""Volume related commands."""


class Volumes():
    def __init__(self, args, uargs, jdss):

        self.vsa = {'create': self.create,
                    'getfreename': self.getfreename,
                    'list': self.list}
        self.va = {'clone': self.clone,
                   'delete': self.delete,
                   'get': self.get,
                   'snapshots': self.snapshots,
                   'properties': self.properties,
                   'rename': self.rename,
                   'resize': self.resize}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss

        if 'volumes-action' in self.args:
            self.vsa[self.args.pop('volumes-action')]()
        elif 'volume-action' in self.args:
            self.va[self.args.pop('volume-action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Volume")

        if args[0] in self.vsa:
            parsers = parser.add_subparsers(dest='volumes-action')

            create = parsers.add_parser('create')
            create.add_argument('-s',
                                dest='volume_size',
                                type=str,
                                default='1G',
                                help='New volume size in format num + [K M G]')
            create.add_argument('-b',
                                dest='block_size',
                                type=str,
                                default=None,
                                help='Block size')
            create.add_argument('-d',
                                dest='direct_mode',
                                action='store_true',
                                default=False,
                                help='Use real volume name')
            create.add_argument('volume_name',
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
        else:
            parser.add_argument('volume_name', help='Volume name')
            parsers = parser.add_subparsers(dest='volume-action')

            get = parsers.add_parser('get')
            get.add_argument('-s',
                             dest='volume_size',
                             action='store_true',
                             default=False,
                             help='Print volume size')
            get.add_argument('-d',
                             dest='direct_mode',
                             action='store_true',
                             default=False,
                             help='Use real volume name')

            clone = parsers.add_parser('clone')
            clone.add_argument('--snapshot',
                               dest='snapshot_name',
                               type=str,
                               help='Use snapshot for cloning')
            # clone.add_argument('-s',
            #                    '--size',
            #                    dest='volume_size',
            #                    type=str,
            #                    default='1G',
            #                    help='New volume size in format size+[K M G]')
            # clone.add_argument('-b',
            #                    dest='block_size',
            #                    type=str,
            #                    default=None,
            #                    help='Block size')
            clone.add_argument('clone_name',
                               type=str,
                               help='Clone volume name')

            delete = parsers.add_parser('delete')
            delete.add_argument('-c', '--cascade', dest='cascade',
                                action='store_true',
                                default=False,
                                help='Remove snapshots along side with volume')

            properties = parsers.add_parser('properties')
            properties.add_argument('--name',
                                    dest='property_name',
                                    type=str,
                                    help='Volume propertie name')
            properties.add_argument('--value',
                                    dest='property_value',
                                    type=str,
                                    help='Volume propertie value')

            rename = parsers.add_parser('rename')
            rename.add_argument('new_name', type=str, help='New volume name')

            resize = parsers.add_parser('resize')
            resize.add_argument('--add',
                                dest="add_size",
                                action="store_true",
                                default=False,
                                help='Add new size to existing volume size')
            resize.add_argument('new_size',
                                type=int,
                                help='New volume size')
            resize.add_argument('-d',
                                dest='direct_mode',
                                action='store_true',
                                default=False,
                                help='Use real volume name')

            # snapshots = parsers.add_parser('snapshots')

        return parser.parse_known_args(args)

    def create(self):

        volume = {'size': self.args['volume_size'],
                  'block_size': self.args['block_size'].upper()}

        if 'volume_name' in self.args:
            volume['id'] = self.args['volume_name']
        else:
            volume['id'] = str(uuid.uuid1())

        self.jdss.create_volume(volume, direct_mode=self.args['direct_mode'])

    def clone(self):

        volume = {'id': self.args['clone_name']}

        if self.args['snapshot_name']:
            snapshot = snapshots.Snapshot.get_snapshot(
                self.args['volume_name'],
                self.args['snapshot_name'])

            self.jdss.create_volume_from_snapshot(volume, snapshot)

            return

        src_vref = {'id': self.args['volume_name']}
        self.jdss.create_cloned_volume(volume, src_vref)

    def get(self):

        volume_name = self.args['volume_name']

        volume = {'id': volume_name}

        d = self.jdss.get_volume(volume, direct_mode=self.args['direct_mode'])
        if self.args['volume_size']:
            print(d['size'])

    def getfreename(self):

        volume_prefix = None

        if 'volume_prefix' in self.args:
            volume_prefix = self.args['volume_prefix']

        present_volumes = []
        data = self.jdss.list_all_volumes()

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
        lines = []

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
                    'size': v['size']})
                sys.stdout.write(line)
            else:
                line = ("%(name)s %(size)s\n" % {
                    'name': v['name'],
                    'size': v['size']})
                sys.stdout.write(line)

    def delete(self):

        volume = {'id': self.args['volume_name']}
        self.jdss.delete_volume(volume, cascade=self.args['cascade'])

    def snapshots(self):
        snapshots.Snapshots(self.args, self.uargs, self.jdss)

    def properties(self):
        volume = {'id': self.args['volume_name']}
        new_prop = {'name': self.args['property_name'],
                    'value': self.args['property_value']}

        self.jdss.modify_volume(volume, new_prop)

    def rename(self):
        volume = {'id': self.args['volume_name']}

        self.jdss.rename_volume(volume, self.args['new_name'])

    def resize(self):

        volume_name = self.args['volume_name']

        volume = {'id': volume_name}
        size = self.args['new_size']

        if self.args['add_size']:
            d = self.jdss.get_volume(volume,
                                     direct_mode=self.args['direct_mode'])
            size += int(d['size'])

        self.jdss.extend_volume(volume, size,
                                direct_mode=self.args['direct_mode'])
