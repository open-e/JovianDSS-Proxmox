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
import hashlib
import logging
import sys

from jdssc.jovian_common import exception as jexc

"""NAS snapshot related commands."""

LOG = logging.getLogger(__name__)


class NASSnapshot():
    def __init__(self, args, uargs, jdss):

        self.sa = {'delete': self.delete,
                   'get': self.get,
                   'clones': self.clones}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        self.sa[self.args.pop('nas_snapshot_action')]()

    @staticmethod
    def get_snapshot(dataset_name, snapshot_name):

        name_bytes = bytes(dataset_name + snapshot_name, 'ascii')
        name_uuid = hashlib.md5(name_bytes).hexdigest()
        snapshot = {'id': "{}-{}".format(name_uuid, snapshot_name),
                    'dataset_id': dataset_name,
                    'dataset_name': dataset_name}

        return snapshot

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="NASSnapshot")

        parser.add_argument('snapshot_name', help='Snapshot name')
        parsers = parser.add_subparsers(dest='nas_snapshot_action')

        delete = parsers.add_parser('delete')

        get = parsers.add_parser('get')

        clones = parsers.add_parser('clones')
        clones_action = clones.add_subparsers(dest='clones_action')

        clones_create = clones_action.add_parser('create')
        clones_create.add_argument('clone_name',
                                   type=str,
                                   help='Clone name')
        clones_create.add_argument('--compression',
                                   dest='compression',
                                   type=str,
                                   default=None,
                                   help='Compression algorithm')
        clones_create.add_argument('--copies',
                                   dest='copies',
                                   type=int,
                                   default=None,
                                   help='Number of copies (1-3)')
        clones_create.add_argument('--dedup',
                                   dest='dedup',
                                   type=str,
                                   default=None,
                                   help='Deduplication setting')

        clones_delete = clones_action.add_parser('delete')
        clones_delete.add_argument('clone_name',
                                   type=str,
                                   help='Clone name')

        clones_list = clones_action.add_parser('list')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.nas_snapshot_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def delete(self):

        try:
            self.jdss.delete_nas_snapshot(
                self.args['nas_volume_name'],
                self.args['snapshot_name'])
        except jexc.JDSSSnapshotIsBusyException:
            exit(1)

    def get(self):
        dataset_name = self.args['nas_volume_name']
        snapshot_name = self.args['snapshot_name']

        try:
            d = self.jdss.get_nas_snapshot(dataset_name,
                                           snapshot_name)
            # Print snapshot information
            for key, value in d.items():
                print(f"{key}: {value}")

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

    def clones(self):
        dataset_name = self.args['nas_volume_name']
        snapshot_name = self.args['snapshot_name']

        if self.args.get('clones_action') == 'create':
            # Create clone
            clone_name = self.args['clone_name']
            options = {}

            if self.args.get('compression'):
                options['compression'] = self.args['compression']
            if self.args.get('copies'):
                options['copies'] = self.args['copies']
            if self.args.get('dedup'):
                options['dedup'] = self.args['dedup']

            try:
                self.jdss.create_nas_clone(
                    dataset_name,
                    snapshot_name,
                    clone_name,
                    **options)
                LOG.info("Clone %s created successfully", clone_name)
            except jexc.JDSSException as err:
                LOG.error(err)
                exit(1)

        elif self.args.get('clones_action') == 'delete':
            # Delete clone
            clone_name = self.args['clone_name']

            try:
                self.jdss.delete_nas_clone(
                    dataset_name,
                    snapshot_name,
                    clone_name)
                LOG.info("Clone %s deleted successfully", clone_name)
            except jexc.JDSSException as err:
                LOG.error(err)
                exit(1)

        elif self.args.get('clones_action') == 'list':
            # List clones
            try:
                clones = self.jdss.list_nas_clones(
                    dataset_name,
                    snapshot_name)
                for clone in clones:
                    if isinstance(clone, dict) and 'name' in clone:
                        print(clone['name'])
                    else:
                        print(clone)
            except jexc.JDSSException as err:
                LOG.error(err)
                exit(1)
        else:
            LOG.error("Invalid clones action")
            exit(1)
