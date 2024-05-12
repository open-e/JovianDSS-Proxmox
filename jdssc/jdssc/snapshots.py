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

"""Snapshot related commands."""


class Snapshots():
    def __init__(self, args, uargs, jdss):

        self.ssa = {'create': self.create,
                    'list': self.list}
        self.sa = {'clone': self.clone,
                   'delete': self.delete,
                   'rollback': self.rollback}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss

        if 'snapshots-actions' in self.args:
            self.ssa[self.args.pop('snapshots-actions')]()
        elif 'snapshot-actions' in self.args:
            self.sa[self.args.pop('snapshot-actions')]()

    @staticmethod
    def get_snapshot(volume_name, snapshot_name):

        name_bytes = bytes(volume_name + snapshot_name, 'ascii')
        name_uuid = hashlib.md5(name_bytes).hexdigest()
        snapshot = {'id': "{}-{}".format(name_uuid, snapshot_name),
                    'volume_id': volume_name,
                    'volume_name': volume_name}

        return snapshot

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Volume")

        if args[0] in self.ssa:
            parsers = parser.add_subparsers(dest='snapshots-actions')

            create = parsers.add_parser('create')
            create.add_argument('snapshot_name', type=str, help='New snapshot name')

            listp = parsers.add_parser('list')
        else:
            parser.add_argument('snapshot_name', help='Snapshot name')
            parsers = parser.add_subparsers(dest='snapshot-actions')
            clone = parsers.add_parser('clone')
            delete = parsers.add_parser('delete')
            delete = parsers.add_parser('rollback')

        return parser.parse_known_args(args)

    def create(self):

        snapshot = Snapshots.get_snapshot(self.args['volume_name'],
                                          self.args['snapshot_name'])

        self.jdss.create_snapshot(snapshot)

    def list(self):

        volume = {'id': self.args['volume_name']}

        data = self.jdss.list_snapshots(volume)

        for v in data:
            name = "-".join(v['name'].split("-")[1:])
            line = "{}\n".format(name)
            sys.stdout.write(line)

    def delete(self):

        snapshot = Snapshots.get_snapshot(self.args['volume_name'],
                                          self.args['snapshot_name'])
        self.jdss.delete_snapshot(snapshot)
    
    def rollback(self):

        volume = {'id': self.args['volume_name']}
        snapshot = Snapshots.get_snapshot(self.args['volume_name'],
                                          self.args['snapshot_name'])

        self.jdss.revert_to_snapshot('', volume, snapshot)

    def clone(self):
        pass
