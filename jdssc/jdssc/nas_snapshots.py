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
import logging
import sys


from jdssc.jovian_common import exception as jexc


"""NAS snapshots related commands."""

LOG = logging.getLogger(__name__)


class NASSnapshots():
    def __init__(self, args, uargs, jdss):

        self.ssa = {'create': self.create,
                    'list': self.list}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        if 'nas_snapshots_action' in self.args:
            self.ssa[self.args.pop('nas_snapshots_action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="NASSnapshots")

        parsers = parser.add_subparsers(dest='nas_snapshots_action')

        create = parsers.add_parser('create')
        create.add_argument('snapshot_name',
                            type=str,
                            help='New snapshot name')
        create.add_argument('--ignoreexists',
                            dest='ignoreexists',
                            action='store_true',
                            default=False,
                            help='Do not fail if snapshot with such '
                                 'name exists')

        list = parsers.add_parser('list')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.nas_snapshots_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def create(self):

        try:
            self.jdss.create_nas_snapshot(
                self.args['snapshot_name'],
                self.args['nas_volume_name'])
        except jexc.JDSSSnapshotExistsException as exists:
            if self.args['ignoreexists']:
                return
            LOG.error(exists)
            exit(1)
        except jexc.JDSSException as err:
            LOG.error(err)
            exit(1)

    def list(self):

        dataset = self.args['nas_volume_name']

        data = self.jdss.list_nas_snapshots(dataset)
        for s in data:
            line = "{}".format(s['name'])
            line += "\n"
            sys.stdout.write(line)
