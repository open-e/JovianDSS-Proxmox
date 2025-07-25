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

"""Targets related commands."""

LOG = logging.getLogger(__name__)


class Targets():
    def __init__(self, args, uargs, jdss):

        self.tsa = {'create': self.create,
                    'get': self.get,
                    'delete': self.delete,
                    'list': self.list}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))

        self.uargs = uargs
        self.jdss = jdss

        if 'targets_action' in self.args:
            self.tsa[self.args.pop('targets_action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Target")

        parsers = parser.add_subparsers(dest='targets_action')

        create = parsers.add_parser('create')
        create.add_argument('-v',
                            required=True,
                            dest='volume_name',
                            type=str,
                            help='New volume name')
        create.add_argument('--host', action='store_true',
                            default=False,
                            help='Print host address')
        create.add_argument('--lun', action='store_true',
                            default=False,
                            help='Print lun')
        create.add_argument('--target-prefix',
                            dest='target_prefix',
                            default=None,
                            required=True,
                            help='''
                            Pattern for target name prefix.
                            User can specify plain text or template
                            in python strftime format.
                            ''')
        create.add_argument('--target-group-name',
                            dest='target_group_name',
                            required=True,
                            default=None,
                            help='''
                            Target name.
                            It will be added to target prefix"
                            ''')
        create.add_argument('--snapshot',
                            dest='snapshot_name', default=None,
                            help='Create target based on snapshot')

        create.add_argument('--luns-per-target',
                            dest='luns_per_target',
                            type=int,
                            default=8,
                            help='''Maximal number of luns that can be
                            assigned to single target
                            ''')

        create.add_argument('-d',
                            dest='direct_mode',
                            action='store_true',
                            default=False,
                            help='Use real volume name')

        delete = parsers.add_parser('delete')
        delete.add_argument('--target-prefix',
                            dest='target_prefix',
                            required=True,
                            help='''
                            Pattern for target name prefix.
                            User can specify plain text or template
                            in python strftime format.
                            Default is "iqn.2025-04.iscsi:"
                            ''')
        delete.add_argument('--target-group-name',
                            dest='target_group_name',
                            required=True,
                            default=None,
                            help='''
                            Target name.
                            It will be added to target prefix"
                            ''')
        delete.add_argument('-v',
                            required=True,
                            dest='volume_name',
                            type=str,
                            help='New volume name')
        delete.add_argument('--snapshot', dest='snapshot_name',
                            default=None,
                            help='Delete target based on snapshot')
        delete.add_argument('-d',
                            dest='direct_mode',
                            action='store_true',
                            default=False,
                            help='Use real volume name')

        get = parsers.add_parser('get')
        get.add_argument('--target-prefix',
                         dest='target_prefix',
                         default=None,
                         help='''
                         Pattern for target name prefix.
                         User can specify plain text or template
                         in python strftime format.
                         Default is "iqn.2025-04.iscsi:"
                         ''')
        get.add_argument('--target-group-name',
                         dest='target_group_name',
                         required=True,
                         default=None,
                         help='''
                            Target name.
                            It will be added to target prefix"
                            ''')
        get.add_argument('-v',
                         required=True,
                         dest='volume_name',
                         default=None,
                         type=str,
                         help='New volume name')
        get.add_argument('--snapshot', dest='snapshot_name',
                         # It is important to make default snapshot None
                         # as it is used later to acquire target name
                         default=None,
                         help='''Get target based on snapshot, using this flag
                                with empty string will result in usage of
                                snapshot with empty name''')
        get.add_argument('-c',
                         '--current',
                         required=False,
                         dest='current',
                         default=False,
                         action='store_true',
                         help=('Current volume target, it will search for '
                               'target that volume is attached to. '
                               'This message should help to identify target '
                               ' if user changes iscsi target prefix'))
        get.add_argument('-d',
                         dest='direct_mode',
                         action='store_true',
                         default=False,
                         help='Use real volume name')

        parsers.add_parser('list')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.targets_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def create(self):
        tinfo = None

        self.jdss.set_target_prefix(self.args['target_prefix'])

        target_prefix = self.args['target_prefix']

        target_group_name = self.args['target_group_name']

        try:
            if self.args['snapshot_name']:

                tinfo = self.jdss.create_export_snapshot(
                    target_prefix,
                    target_group_name,
                    self.args['snapshot_name'],
                    self.args['volume_name'],
                    None,
                    luns_per_target=self.args['luns_per_target'])
            else:
                tinfo = self.jdss.ensure_target_volume(
                    target_prefix,
                    target_group_name,
                    self.args['volume_name'],
                    None,
                    direct_mode=self.args['direct_mode'],
                    luns_per_target=self.args['luns_per_target'])
        except jexc.JDSSVIPNotFoundException as jerr:
            LOG.error(
                "%s. Please make sure that VIP are assigned to the Pool",
                jerr.message)
            exit(1)
        except jexc.JDSSOutdated:
            LOG.error("It looks like your version of JovianDSS do not"
                      " support VIP white listing for targets. Please update "
                      "JovianDSS to the newest version.")
            exit(1)
        except jexc.JDSSException as jgerr:
            LOG.error(jgerr.message)
            exit(1)

        out = ('%(target)s %(lun)d %(hosts)s' % {
            'target': tinfo['target'],
            'lun': tinfo['lun'],
            'hosts': ','.join(tinfo['vips'])})
        print(out)

    def delete(self):

        self.jdss.set_target_prefix(self.args['target_prefix'])

        try:
            if self.args['snapshot_name']:
                self.jdss.remove_export_snapshot(
                    self.args['target_prefix'],
                    self.args['target_group_name'],
                    self.args['snapshot_name'],
                    self.args['volume_name'])
            else:
                self.jdss.remove_export(
                    self.args['target_prefix'],
                    self.args['target_group_name'],
                    self.args['volume_name'],
                    direct_mode=self.args['direct_mode'])
        except jexc.JDSSException as jgerr:
            LOG.error(jgerr.message)
            exit(1)

    def get(self):
        if self.args['target_prefix']:
            self.jdss.set_target_prefix(self.args['target_prefix'])

        LOG.debug("Getting target for volume %s", self.args['volume_name'])

        tinfo = None

        if self.args['current']:
            LOG.debug("Getting current target")

            try:
                tinfo = self.jdss.get_volume_target(
                    self.args['target_prefix'],
                    self.args['target_group_name'],
                    self.args['volume_name'],
                    snapshot_name=self.args['snapshot_name'],
                    direct=self.args['direct_mode'])
            except jexc.JDSSTargetNotFoundException:
                return
            except jexc.JDSSException as jgerr:
                LOG.error(jgerr.message)
                exit(1)
        if tinfo is None:
            LOG.debug("volume %s is not attached to any target",
                      self.args['volume_name'])
        LOG.debug("volumes %s target info %s",
                  self.args['volume_name'],
                  tinfo)

        out = "{tname} {lun} {hosts}\n".format(tname=tinfo['target'],
                                               lun=tinfo['lun'],
                                               hosts=tinfo['vips'])
        print(out)

    def list(self):

        LOG.debug("Getting list of targets")

        targets = None

        try:
            targets = self.jdss.list_targets()
        except jexc.JDSSTargetNotFoundException:
            return
        for t in targets:
            print(t)
