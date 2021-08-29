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


"""Volume related commands."""

class Targets():
    def __init__(self, args, uargs, jdss):

        self.vsa = {'create': self.create,
                    'list': self.list}
        self.va = {'delete': self.delete,
                   'get': self.get}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss

        if 'targets-action' in self.args:
            self.vsa[self.args.pop('targets-action')]()
        elif 'target-action' in self.args:
            self.va[self.args.pop('target-action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Target")

        if args[0] in self.vsa:
            parsers = parser.add_subparsers(dest='targets-action')

            create = parsers.add_parser('create')
            create.add_argument('target_name', type=str, help='New target name')
            create.add_argument('--host', action='store_true', default=False,
                                help='Print host address')
            create.add_argument('--lun', action='store_true', default=False,
                                help='Print lun')

            listp = parsers.add_parser('list')
        else:
            parser.add_argument('target_name', help='Target name')
            parsers = parser.add_subparsers(dest='target-action')

            get = parsers.add_parser('get')
            get.add_argument('--host', action='store_true', default=False,
                                help='Print host address')
            get.add_argument('--lun', action='store_true', default=False,
                                help='Print lun')
            delete = parsers.add_parser('delete')

        return parser.parse_known_args(args)

    def create(self):

        volume = {'id': self.args['target_name'],
                  'provider_auth': 'CHAP 123456 123456789012'}

        provider_location = self.jdss.create_export('', volume, '')['provider_location']
        #output = self.jdss.jovian_target_prefix + self.args['target_name'] + "\n"
        out = ''
        if self.args['host']:
            out += ' ' + ':'.join(provider_location.split()[0].split(':')[:-1])
        if self.args['lun']:
            out += ' ' + provider_location.split()[2]
        out = provider_location.split()[1] + out + '\n'
        sys.stdout.write(out)

    def list(self):
        pass

    def delete(self):
    
        volume = {'id': self.args['target_name']}

        self.jdss.remove_export('', volume)

    def get(self):

        provider_location = self.jdss.get_provider_location(self.args['target_name'])

        out = ''
        if self.args['host']:
            out += ' ' + ':'.join(provider_location.split()[0].split(':')[:-1])
        if self.args['lun']:
            out += ' ' + provider_location.split()[2]
        out = provider_location.split()[1] + out + '\n'
        sys.stdout.write(out)
