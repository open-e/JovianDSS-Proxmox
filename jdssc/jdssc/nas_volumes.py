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
        
        self.vsa = {'create': self.create,
                    'list': self.list}
        self.va = {
                   'delete': self.delete,
                   'get': self.get}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss
      
        if 'volumes-action' in self.args:
            self.vsa[self.args.pop('volumes-action')]()
        elif 'volume-action' in self.args:
            self.va[self.args.pop('volume-action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Volume")
 
        if args[0] in self.vsa:
            parsers = parser.add_subparsers(dest='volumes-action')

            create = parsers.add_parser('create')
            create.add_argument('volume_name', type=str, help='New nas volume name')

            listp = parsers.add_parser('list')
        else:
            parser.add_argument('volume_name', help='Volume name')
            parsers = parser.add_subparsers(dest='volume-action')

            get = parsers.add_parser('get')
            get.add_argument('-s', dest='volume_size', action='store_true', default=False, help='Print volume size')

            delete = parsers.add_parser('delete')
            delete.add_argument('-c', '--cascade', dest='cascade',
                                action='store_true',
                                default=False,
                                help='Remove snapshots along side with volume')
 
        return parser.parse_known_args(args)

    def create(self):

        volume = {'name': self.args['volume_name']}

        self.jdss.ra.create_nas_volume(volume)

    def clone(self):

        block_size = self.args['block_size']
        volume_name = self.args['volume_name']
    
        volume = {'id': self.args['clone_name'],
                  'size': self.args['volume_size']}
        
        if self.args['snapshot_name']:
            snapshot = snapshots.Snapshot.get_snapshot(
                self.args['volume_name'],
                self.args['snapshot_name'])

            self.jdss.create_volume_from_snapshot(volume, snapshot)

            return 

        src_vref = {'id': self.args['volume_name']}
        self.jdss.create_cloned_volume(volume, src_vref)
 
    def get(self):

        volume_name = self.args['volume_name']

        volume = {'id': volume_name}
        
        d = self.jdss.get_volume(volume)

        if self.args['volume_size']:
            print(d['size'])
