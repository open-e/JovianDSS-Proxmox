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
import hashlib
import re
import sys

"""Snapshots related commands."""


class Snapshots():
    def __init__(self, args, uargs, jdss):

        self.ssa = {'create': self.create,
                    'list': self.list}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        if 'snapshots_action' in self.args:
            self.ssa[self.args.pop('snapshots_action')]()

    #@staticmethod
    #def get_snapshot(volume_name, snapshot_name):

    #    name_bytes = bytes(volume_name + snapshot_name, 'ascii')
    #    name_uuid = hashlib.md5(name_bytes).hexdigest()
    #    snapshot = {'id': "{}-{}".format(name_uuid, snapshot_name),
    #                'volume_id': volume_name,
    #                'volume_name': volume_name}
    #    return snapshot

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Volume")

        parsers = parser.add_subparsers(dest='snapshots_action')

        create = parsers.add_parser('create')
        create.add_argument('snapshot_name',
                            type=str,
                            help='New snapshot name')

        parsers.add_parser('list')
        kargs, ukargs = parser.parse_known_args(args)

        if kargs.snapshots_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def create(self):

        self.jdss.create_snapshot(self.args['snapshot_name'],
                                  self.args['volume_name'])

    def list(self):

        volume = self.args['volume_name']

        data = self.jdss.list_snapshots(volume)
        for v in data:
            line = "{}\n".format(v['name'])
            sys.stdout.write(line)
