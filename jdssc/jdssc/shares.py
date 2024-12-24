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
                (action in self.shares_action)):
            self.shares_action[action]()
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
        listp.add_argument('-d',
                           dest='direct_mode',
                           action='store_true',
                           default=False,
                           help='Print actual share names')
        listp.add_argument('-p',
                           dest='path',
                           action='store_true',
                           default=False,
                           help='Print share path')

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

        except jexc.JDSSVolumeExistsException:
            LOG.error(("Please pick another name for Share/Dataset as given "
                       "one %s is occupied by existing Volume"), name)
            exit(2)

        except jexc.JDSSResourceExhausted:
            LOG.error("No space left on the storage")
            exit(1)

        except jexc.JDSSPoolNotFoundException:
            LOG.error(("Unable to create NFS share %(share)s because pool "
                       "%(pool)s not found.") %
                      {'pool': self.jdss.get_pool_name(),
                       'share': name})
            exit(1)

        except jexc.JDSSCommunicationFailure as jerr:
            LOG.error(("Unable to communicate with JovianDSS over given "
                       "interfaces %(interfaces)s. "
                       "Please make sure that addresses are correct and "
                       "REST API is enabled for JovianDSS") %
                      {'interfaces': ', '.join(jerr.interfaces)})
            exit(1)

    def list(self):
        data = self.jdss.list_shares()
        LOG.debug(data)
        for v in data:

            line = ("%(name)s %(path)s\n" % {
                'name': v['name'],
                'path': v['path']})
            sys.stdout.write(line)
