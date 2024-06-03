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
import re
import sys

import jdssc.snapshots as snapshots

"""Target related commands."""


class Targets():
    def __init__(self, args, uargs, jdss):

        self.ta = {'delete': self.delete,
                   'get': self.get}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss

        if 'target_action' in self.args:
            self.va[self.args.pop('target_action')]()
        else:
            sys.exit(1)

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Target")

        parser.add_argument('target_name', help='Target name')
        parsers = parser.add_subparsers(dest='target_action')

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
        get.add_argument('--snapshot', dest='volume_snapshot',
                         default=None,
                         help='Get target based on snapshot')

        return parser.parse_known_args(args)
