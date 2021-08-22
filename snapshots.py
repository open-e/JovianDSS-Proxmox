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

"""Pool related commands."""

class Snapshots():
    def __init__(self, args, uargs, jdss):
        
        self.vsa = {'create': self.create,
                   'list': self.list}
        self.va = {'delete': self.delete,
                   'snapshots': self.snapshots}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss
       
        if 'volumes-action' in self.args:
            self.vsa[self.args.pop('volumes-action')]()
        elif 'volume-actions' in self.args:
            self.va[self.args.pop('volume-actions')]()            

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Volume")
       
        if args[0] in self.vsa:
            parsers = parser.add_subparsers(dest='volumes-action')

            create = parsers.add_parser('create')
            create.add_argument('-s', dest='volume_size', type=str, default='1G', help='New volume size in format <number><dimension>')
            create.add_argument('-b', dest='block_size', type=str, default='64K', help='Block size')
            create.add_argument('volume_name', nargs=1, type=str, help='New volume name')

            listp = parsers.add_parser('list')
            listp.add_argument('--vmid',
                               dest='vmid',
                               action='store_true',
                               default=False,
                               help='Show only volumes with VM ID')
        else:  
            parser.add_argument('volume_name', help='Volume name')
            parsers = parser.add_subparsers(dest='volume-action')
            clone = parsers.add_parser('clone')
            delete = parsers.add_parser('delete')
            delete.add_argument('volume_name', nargs=1, type=str, help='Name of volume to delete')
            properties = parsers.add_parser('properties')
            
            snapshots = parsers.add_parser('snapshots')
       
        return parser.parse_known_args(args)

    def create(self):
      
        volume_size = self.args['volume_size']
        block_size = self.args['block_size']
        volume_name = self.args['volume_name'][0]
    
        volume = {'id': volume_name,
                  'size': volume_size}
    
        self.jdss.create_volume(volume)
    
    def list(self):
        data = self.jdss.list_volumes()
        lines = []
    
        vmid_re = None
        if self.args['vmid']:
            vmid_re = re.compile(r'^vm-[0-9]+-')
    
        for v in data:
            if vmid_re:
                match = vmid_re.match(v['name'])
                if not match:
                    continue
    
                line = ("%(name)s %(vmid)s %(size)s\n" % {
                    'name': v['name'],
                    'vmid': v['name'][3:match.end()-1],
                    'size': v['size']})
                sys.stdout.write(line)
            else:
    
                line = ("%(name)s %(size)s\n" % {
                    'name': v['name'],
                    'size': v['size']})
                sys.stdout.write(line)
    
    def delete(self):
    
        volume = {'id': self.args['volume_name'][0]}
    
        self.jdss.delete_volume(volume, cascade=self.args['cascade'])
