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

import volumes
"""Pool related commands."""
        
class Pools():
    def __init__(self, args, uargs, jdss):

        #self.sa = {'create': self.create,
        #           'list': self.list}
        self.a = {'volumes': volumes.Volumes}

        self.args = args
        
        argst = self.__parse(uargs)

        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss
        
        print(self.args)
         
        if 'pool-action' in self.args:
            self.a[self.args.pop('pool-action')](self.args, self.uargs, self.jdss)

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Pool")

        parser.add_argument('pool_name', help='Pool name')
        parsers = parser.add_subparsers(dest='pool-action')
        volumes = parsers.add_parser('volumes', add_help=False)

        return parser.parse_known_args(args)

#.parse_known_args(args)

#def pool(args, uargs, jdss):
#
#    pool_sub_objects = {'volumes': volumes.Volumes}
#    return pool_sub_objects[args.pop('pool_sub_object')](args, uargs, jdss)

