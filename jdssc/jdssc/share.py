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

"""Share related commands."""


class Share():
    def __init__(self, args, uargs, jdss):

        self.share_action = {'delete': self.delete,
                             'get': self.get,
                             'resize': self.resize}

        self.args = args
        args, uargs = self.__parse(uargs)

        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        action = args.share_action
        if ((action is not None) and
                (len(action) > 0) and
                (action in self.share_action)):
            self.share_action[action]()
        else:
            sys.exit(1)

    def __parse(self, args):

        share_parser = argparse.ArgumentParser(prog="Share")

        share_parser.add_argument('share_name', help='Volume name')

        parsers = share_parser.add_subparsers(dest='share_action')

        delete = parsers.add_parser('delete')
        delete.add_argument('-d',
                            dest='direct_mode',
                            action='store_true',
                            default=False,
                            help='Print actual share names')
        get = parsers.add_parser('get')
        get.add_argument('-d',
                         dest='direct_mode',
                         action='store_true',
                         default=False,
                         help='Use exact volume name')
        get.add_argument('-s',
                         dest='share_size',
                         action='store_true',
                         default=False,
                         help='Print share quota size')
        get.add_argument('-G',
                         dest='share_gigabyte_size',
                         action='store_true',
                         default=False,
                         help='Print share size in gigabytes')

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

        kargs, ukargs = share_parser.parse_known_args(args)

        if kargs.share_action is None:
            share_parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def get(self):

        try:
            d = self.jdss.get_nas_volume(self.args['share_name'],
                                         direct_mode=self.args['direct_mode'])

        except jexc.JDSSException as err:
            LOG.error(err.message)
            exit(1)

        if self.args['share_size']:
            if self.args['share_gigabyte_size']:
                print(int(int(d['quota'])/(1024*1024*1024)))
            else:
                print(d['quota'])

    def delete(self):

        try:
            self.jdss.delete_share(self.args['share_name'],
                                   direct=self.args['share_name'])
        except jexc.JDSSResourceNotFoundException:
            LOG.debug(("NAS volume $s do not exists, "
                      "treat deletion as complete."),
                      self.args['share_name'])

    def resize(self):

        share_name = self.args['share_name']

        size = self.args['new_size']

        if self.args['add_size']:
            d = self.jdss.get_share(share_name,
                                    direct_mode=self.args['direct_mode'])
            size += int(d['size'])

        self.jdss.resize_share(share_name, size,
                               direct_mode=self.args['direct_mode'])
