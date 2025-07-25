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
import sys
import logging
import time

import jdssc.snapshot as snapshot
import jdssc.snapshots as snapshots
from jdssc.jovian_common import exception as jexc

"""Volume related commands."""

LOG = logging.getLogger(__name__)


_MiB = 1048576


class Volume():
    def __init__(self, args, uargs, jdss):

        self.va = {'clone': self.clone,
                   'delete': self.delete,
                   'get': self.get,
                   'snapshot': self.snapshot,
                   'snapshots': self.snapshots,
                   'rename': self.rename,
                   'resize': self.resize}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        self.va[self.args.pop('volume_action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Volume")

        parser.add_argument('volume_name', help='Volume name')
        parsers = parser.add_subparsers(dest='volume_action')

        get = parsers.add_parser('get')
        get.add_argument('-s',
                         dest='volume_size',
                         action='store_true',
                         default=False,
                         help='Print volume size')
        get.add_argument('-G',
                         dest='volume_gigabyte_size',
                         action='store_true',
                         default=False,
                         help='Print volume size in gigabytes')
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
        clone.add_argument('--size',
                           dest='clone_size',
                           type=str,
                           default='0',
                           help='New volume size in format size+[K M G]')
        clone.add_argument('-n',
                           required=True,
                           dest='clone_name',
                           type=str,
                           help='Clone volume name')

        delete = parsers.add_parser('delete')
        delete.add_argument('--target-prefix',
                            dest='target_prefix',
                            default=None,
                            help='''
                            Pattern for target name prefix.
                            User can specify plain text or template
                            in python strftime format.
                            Default is "iqn.2025-04.iscsi:"
                            ''')
        delete.add_argument('-c', '--cascade', dest='cascade',
                            action='store_true',
                            default=False,
                            help='Remove snapshots along side with volume')
        delete.add_argument('-p', '--printres', dest='print',
                            action='store_true',
                            default=False,
                            help='Print resources that would be deleted')

        rename = parsers.add_parser('rename')
        rename.add_argument('new_name', type=str, help='New volume name')

        resize = parsers.add_parser('resize')
        resize.add_argument('--add',
                            dest="add_size",
                            action="store_true",
                            default=False,
                            help='Add new size to existing volume size')
        resize.add_argument('new_size',
                            type=str,
                            help='New volume size')
        resize.add_argument('-d',
                            dest='direct_mode',
                            action='store_true',
                            default=False,
                            help='Use real volume name')

        parsers.add_parser('snapshot')

        parsers.add_parser('snapshots')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.volume_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def clone(self):

        if self.args['snapshot_name']:

            self.jdss.create_cloned_volume(
                self.args['clone_name'],
                self.args['volume_name'],
                0,
                snapshot_name=self.args['snapshot_name'],
                sparse=self.jdss.jovian_sparse)
            return
        try:
            self.jdss.create_cloned_volume(self.args['clone_name'],
                                           self.args['volume_name'],
                                           0,
                                           sparse=self.jdss.jovian_sparse)
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
            if self.args['volume_gigabyte_size']:
                print(int((int(d['size'])) / (1024*1024*1024)))

        except jexc.JDSSCommunicationFailure as jerr:
            LOG.error(("Unable to communicate with JovianDSS over given "
                       "interfaces %(interfaces)s. "
                       "Please make sure that addresses are correct and "
                       "REST API is enabled for JovianDSS") %
                      {'interfaces': ', '.join(jerr.interfaces)})
            exit(jerr.errcode)

        except jexc.JDSSException as err:
            LOG.error(err.message)
            exit(err.errcode)

    def delete(self):
        res = None
        try:
            if self.args['target_prefix']:
                self.jdss.set_target_prefix(self.args['target_prefix'])

            res = self.jdss.delete_volume(self.args['volume_name'],
                                          cascade=self.args['cascade'],
                                          print_and_exit=self.args['print'])
        except jexc.JDSSException as err:
            LOG.error(err.message)
            exit(1)

        if res is not None and len(res) > 0:
            for r in res:
                print(r)

    def snapshot(self):
        snapshot.Snapshot(self.args, self.uargs, self.jdss)

    def snapshots(self):
        snapshots.Snapshots(self.args, self.uargs, self.jdss)

    def rename(self):

        self.jdss.rename_volume(self.args['volume_name'],
                                self.args['new_name'])

    def resize(self):

        volume_name = self.args['volume_name']

        size = int(self.args['new_size'])

        if self.args['add_size']:
            volume = {'id': volume_name}

            d = self.jdss.get_volume(volume,
                                     direct_mode=self.args['direct_mode'])
            size = int(size) + int(d['size'])

        self.jdss.resize_volume(volume_name, int(size),
                                direct_mode=self.args['direct_mode'])

        for i in range(1, 10):
            volume = {'id': volume_name}
            d = self.jdss.get_volume(volume,
                                     direct_mode=self.args['direct_mode'])
            if int(d['size']) != size:
                time.sleep(1)
                continue
