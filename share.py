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
import uuid
import logging

from jdssc.jovian_common import exception as jexc

LOG = logging.getLogger(__name__)

"""Shares related commands."""


class Shares():
    def __init__(self, args, uargs, jdss):

        self.shares_action = {'create': self.create,
                              'list': self.list}

        self.args = args
        args, uargs = self.__parse(uargs)

        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        action = args.shares_action
        if ((action is not None) and
                (len(action) > 0) and
                (action in self.sharesaction)):
            self.sharesaction[action]()
        else:
            sys.exit(1)

    def __parse(self, args):

        shares_parser = argparse.ArgumentParser(prog="Shares")

        parsers = shares_parser.add_subparsers(dest='shares_action')

        create = parsers.add_parser('create')
        create.add_argument('-q',
                            '--quota',
                            required=True,
                            dest='volume_quota',
                            type=str,
                            default='1G',
                            help=('New NAS volume maximum size in format num '
                                    '+ [M G T]'))
        create.add_argument('-r',
                            '--reservation',
                            required=False,
                            dest='volume_reservation',
                            default=None,
                            help=('New NAS volume maximum size in format num '
                                  '+ [M G T]'))
        create.add_argument('-d',
                            dest='direct_mode',
                            action='store_true',
                            default=False,
                            help='Use real volume name')
        create.add_argument('-n',
                            required=True,
                            dest='share_name',
                            type=str,
                            help='New nas volume name')

        listp = parsers.add_parser('list')
        listp.add_argument('--vmid',
                           dest='vmid',
                           action='store_true',
                           default=False,
                           help='Show only volumes with VM ID')

        kargs, ukargs = shares_parser.parse_known_args(args)

        if kargs.shares_action is None:
            shares_parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def create(self):
        quota = self.args['volume_quota'].upper()

        name = str(uuid.uuid1())
        if 'share_name' in self.args:
            name = self.args['share_name']

        try:
            self.jdss.create_share(
                name,
                quota,
                direct_mode=self.args['direct_mode'],
                reservation=self.args['volume_reservation'])

        except (jexc.JDSSVolumeExistsException,
                jexc.JDSSResourceExistsException):
            LOG.error("Volume %s already exists", name)

        except jexc.JDSSResourceExhausted:
            LOG.error("No space left on the storage")
            exit(1)

    def get(self):

        volume_name = self.args['volume_name']

        volume = {'id': volume_name}

        d = self.jdss.get_volume(volume)

        if self.args['volume_size']:
            print(d['size'])

    def delete(self):

        self.jdss.delete_share(self.args['share_name'])
