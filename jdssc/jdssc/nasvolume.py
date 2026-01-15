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

import jdssc.nas_snapshot as nas_snapshot
import jdssc.nas_snapshots as nas_snapshots

"""NAS volume related commands."""


class NASVolume():
    def __init__(self, args, uargs, jdss):

        self.nva = {
            'get': self.get,
            'snapshot': self.snapshot,
            'snapshots': self.snapshots}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss

        if 'nas-volume-action' in self.args:
            self.nva[self.args.pop('nas-volume-action')]()

    def __parse(self, args):

        nas_volume_parser = argparse.ArgumentParser(prog="NASVolume")
        nas_volume_parser.add_argument('-d', '--direct',
                                       dest='nas_volume_direct_mode',
                                       action='store_true',
                                       default=False,
                                       help='Use real nas volume name')

        nas_volume_parser.add_argument(
            'nas_volume_name', help='NAS volume name')
        parsers = nas_volume_parser.add_subparsers(dest='nas-volume-action')

        get = parsers.add_parser('get')
        get.add_argument('-d',
                         dest='nas_volume_direct_mode',
                         action='store_true',
                         default=False,
                         help='Use real volume name')
        get.add_argument('-s', dest='volume_size', action='store_true',
                         default=False, help='Print volume size')

        parsers.add_parser('snapshot', add_help=False)
        parsers.add_parser('snapshots', add_help=False)

        if len(args) == 0:
            nas_volume_parser.print_help()
            exit(0)

        return nas_volume_parser.parse_known_args(args)

    def get(self):

        volume_name = self.args['nas_volume_name']

        d = self.jdss.get_nas_volume(
            volume_name,
            direct_mode=self.args['nas_volume_direct_mode'])

        if self.args['volume_size']:
            print(d['quota'])

    def snapshot(self):
        nas_snapshot.NASSnapshot(self.args, self.uargs, self.jdss)

    def snapshots(self):
        nas_snapshots.NASSnapshots(self.args, self.uargs, self.jdss)
