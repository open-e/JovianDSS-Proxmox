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

from jdssc.jovian_common import rest 

"""NAS volumes related commands."""

class NASVolumes():
    def __init__(self, args, uargs, jdss):
        
        self.nvsa = {'create': self.create}
        self.nva = {
                   'delete': self.delete,
                   'get': self.get}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss
      
        if 'nas-volumes-action' in self.args:
            self.nvsa[self.args.pop('nas-volumes-action')]()
        elif 'nas-volume-action' in self.args:
            self.nva[self.args.pop('nas-volume-action')]()

    def __parse(self, args):

        nas_volumes_parser = argparse.ArgumentParser(prog="NASVolumes")
        nas_volume_parser = argparse.ArgumentParser(prog="NASVolume")



        parsers = nas_volumes_parser.add_subparsers(dest='nas-volumes-action')

        create = parsers.add_parser('create')
        create.add_argument('nas_volume_name', type=str, help='New nas volume name')
        
        nas_volume_parser.add_argument('nas_volume_name', help='NSA volume name')
        parsers = nas_volume_parser.add_subparsers(dest='nas-volume-action')

        get = parsers.add_parser('get')
        get.add_argument('-s', dest='volume_size', action='store_true', default=False, help='Print volume size')

        delete = parsers.add_parser('delete')
        delete.add_argument('-c', '--cascade', dest='cascade',
                            action='store_true',
                            default=False,
                            help='Remove snapshots along side with volume')
 
        if len(args) == 0:
            nas_volumes_parser.print_help()
            print("\n")
            nas_volume_parser.print_help()
            exit(0)

        if args[0] in self.nvsa:
            return nas_volumes_parser.parse_known_args(args)
        else:
            return nas_volume_parser.parse_known_args(args)

    def create(self):

        self.jdss.ra.create_nas_volume(self.args['nas_volume_name'])
 
    def get(self):

        volume_name = self.args['volume_name']

        volume = {'id': volume_name}
 
        d = self.jdss.get_volume(volume)

        if self.args['volume_size']:
            print(d['size'])

    def delete(self):

        self.jdss.ra.delete_nas_volume(self.args['nas_volume_name'])
