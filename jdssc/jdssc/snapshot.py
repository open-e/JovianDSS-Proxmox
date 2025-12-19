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
import time

import jdssc.rollback as cli_rollback

from jdssc.jovian_common import exception as jexc

"""Snapshot related commands."""

LOG = logging.getLogger(__name__)


class Snapshot():
    def __init__(self, args, uargs, jdss):

        self.sa = {'delete': self.delete,
                   'get': self.get,
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
        parsers.add_parser('rollback')
        get = parsers.add_parser('get')

        get.add_argument('-d',
                         dest='direct_mode',
                         action='store_true',
                         default=False,
                         help='Use real volume name')

        get_print = get.add_mutually_exclusive_group(required=True)

        get_print.add_argument('-i',
                               '--scsi-id',
                               dest='scsi_id',
                               action='store_true',
                               default=False,
                               help='Print volume scsi id')
        get_print.add_argument('-n',
                               '--san-scsi-id',
                               dest='san_scsi_id',
                               action='store_true',
                               default=False,
                               help='Print volume san scsi id')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.snapshot_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def delete(self):

        try:
            if self.args['target_prefix']:
                self.jdss.set_target_prefix(self.args['target_prefix'])
            self.jdss.delete_snapshot(self.args['volume_name'],
                                      self.args['snapshot_name'])
        except jexc.JDSSSnapshotIsBusyException:
            exit(1)

    def rollback(self):

        cli_rollback.Rollback(self.args, self.uargs, self.jdss)

    def get(self):
        volume_name = self.args['volume_name']
        snapshot_name = self.args['snapshot_name']

        d = dict()

        try:
            if (self.args['scsi_id'] or
                    self.args['san_scsi_id']):

                for i in range(3):
                    d = self.jdss.get_snapshot(volume_name,
                                               snapshot_name,
                                               export=True,
                                               direct_mode=self.args['direct_mode'])

                    if self.args['scsi_id']:
                        if 'scsi_id' not in d:
                            time.sleep(1)
                            continue

                    if self.args['san_scsi_id']:
                        if 'san_scsi_id' not in d:
                            time.sleep(1)
                            continue
                    break

            else:
                d = self.jdss.get_snapshot(volume_name,
                                           snapshot_name,
                                           export=False,
                                           direct_mode=self.args['direct_mode'])

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

        if self.args['scsi_id']:
            if 'scsi_id' in d:
                print(''.join(['{:x}'.format(ord(c))
                               for c in d['scsi_id']]))
            else:
                if 'san_scsi_id' in d:
                    print(''.join(['{:x}'.format(ord(c))
                                   for c in d['san_scsi_id'][:16]]))
                else:
                    LOG.error(("Unable to acquire scsi id for "
                               "snapshot %(snapshot)s"
                               "of volume %(volume)s") %
                              {'volume': volume_name,
                               'snapshot': snapshot_name})
                    exit(1)

        if self.args['san_scsi_id']:
            if 'san_scsi_id' in d:
                print(''.join(
                    ['{:x}'.format(ord(c)) for c in d['san_scsi_id']]
                ))
            else:
                LOG.error(("Unable to acquire san scsi id for "
                           "snapshot %(snapshot)s"
                           "of volume %(volume)s") %
                          {'volume': volume_name,
                           'snapshot': snapshot_name})
                exit(1)

    def clone(self):
        pass
