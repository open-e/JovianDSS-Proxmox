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
import logging
import sys

import jdssc.rollback as cli_rollback

from jdssc.jovian_common import exception as jexc

"""Snapshot related commands."""

LOG = logging.getLogger(__name__)


class Snapshot():
    def __init__(self, args, uargs, jdss):

        self.sa = {'delete': self.delete,
                   'rollback': self.rollback}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        self.sa[self.args.pop('snapshot_action')]()

    @staticmethod
    def get_snapshot(volume_name, snapshot_name):

        name_bytes = bytes(volume_name + snapshot_name, 'ascii')
        name_uuid = hashlib.md5(name_bytes).hexdigest()
        snapshot = {'id': "{}-{}".format(name_uuid, snapshot_name),
                    'volume_id': volume_name,
                    'volume_name': volume_name}

        return snapshot

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Snapshot")

        parser.add_argument('snapshot_name', help='Snapshot name')
        parsers = parser.add_subparsers(dest='snapshot_action')
        parsers.add_parser('delete')
        parsers.add_parser('rollback')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.snapshot_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def delete(self):

        try:
            self.jdss.delete_snapshot(self.args['volume_name'],
                                      self.args['snapshot_name'])
        except jexc.JDSSSnapshotIsBusyException:
            exit(1)

    def rollback(self):

        cli_rollback.Rollback(self.args, self.uargs, self.jdss)

    def clone(self):
        pass
