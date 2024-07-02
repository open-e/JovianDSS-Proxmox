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
import logging
import sys


"""Targets related commands."""

LOG = logging.getLogger(__name__)


class Targets():
    def __init__(self, args, uargs, jdss):

        self.tsa = {'create': self.create,
                    'get': self.get,
                    'delete': self.delete}

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
        create.add_argument('--snapshot',
                            dest='snapshot_name', default=None,
                            help='Create target based on snapshot')
        create.add_argument('-d',
                            dest='direct_mode',
                            action='store_true',
                            default=False,
                            help='Use real volume name')

        delete = parsers.add_parser('delete')
        delete.add_argument('-v',
                            required=True,
                            dest='volume_name',
                            type=str,
                            help='New volume name')
        delete.add_argument('--snapshot', dest='snapshot_name',
                            default=None,
                            help='Delete target based on snapshot')

        get = parsers.add_parser('get')
        get.add_argument('--path', dest='path_format', action='store_true',
                         default=False,
                         help='Print in path format')
        get.add_argument('--host', action='store_true',
                         default=False,
                         help='Print host address')
        get.add_argument('--lun', action='store_true',
                         default=False,
                         help='Print lun')
        get.add_argument('--snapshot', dest='snapshot_name',
                         default=None,
                         help='Get target based on snapshot')
        get.add_argument('-v',
                         required=True,
                         dest='volume_name',
                         default=None,
                         type=str,
                         help='New volume name')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.targets_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def create(self):
        provider_location = None

        if self.args['snapshot_name']:

            self.jdss.create_export_snapshot(
                    self.args['snapshot_name'],
                    self.args['volume_name'],
                    None)
            provider_location = self.jdss.get_provider_location(
                    self.args['snapshot_name'])

        else:
            self.jdss.ensure_export(
                    self.args['volume_name'],
                    None,
                    direct_mode=self.args['direct_mode'])
            provider_location = self.jdss.get_provider_location(
                    self.args['volume_name'])
        out = ''
        if self.args['host']:
            out += ' ' + ':'.join(provider_location.split()[0].split(':')[:-1])
        if self.args['lun']:
            out += ' ' + provider_location.split()[2]
        out = provider_location.split()[1] + out
        print(out)

    def delete(self):

        if self.args['snapshot_name']:
            self.jdss.remove_export_snapshot(self.args['snapshot_name'],
                                             self.args['volume_name'])
        else:
            self.jdss.remove_export(self.args['volume_name'])

    def get(self):

        LOG.debug("Getting target for volume %s", self.args['volume_name'])
        provider_location = None
        if self.args['snapshot_name']:
            provider_location = self.jdss.get_provider_location(
                    self.args['snapshot_name'])
        elif self.args['volume_name']:
            provider_location = self.jdss.get_provider_location(
                    self.args['volume_name'])
        else:
            sys.exit(1)

        pvs = provider_location.split()
        ip = ''.join(pvs[0].split(':')[:-1])
        target_port = pvs[0].split(':')[-1].split(',')[0]
        target = pvs[1]
        lun = pvs[2]
        if self.args['path_format']:
            out = "ip-{ip}:{port}-iscsi-{target}-lun-{lun}".format(
                    ip=ip,
                    port=target_port,
                    target=target,
                    lun=lun)
            out = [chr(ord(c)) for c in out]
            print(''.join(out))
            return

        out = ''
        if self.args['host']:
            out += ' ' + ':'.join(provider_location.split()[0].split(':')[:-1])
        if self.args['lun']:
            out += ' ' + lun
        out = provider_location.split()[1] + out

        print(out)
