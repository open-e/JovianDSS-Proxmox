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

import re
import sys

"""Pool related commands."""

def volume_create(args, jdss):
  
    volume_size = args['volume_size']
    block_size = args['block_size']
    volume_name = args['volume_name'][0]

    volume = {'id': volume_name,
              'size': volume_size}

    jdss.create_volume(volume)

def volume_list(args, jdss):
    data = jdss.list_volumes()
    lines = []

    vmid_re = None
    if args['vmid']:
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

def volume_delete(args, jdss):

    volume = {'id': args['volume_name'][0]}

    jdss.delete_volume(volume, cascade=args['cascade'])

def volume(args, jdss):

    volume_sub_objects = {
        'create': volume_create,
        'list': volume_list,
        'delete': volume_delete}
    volume_sub_objects[args.pop('volume_sub_object')](args, jdss) 

def pool(args, jdss):

    pool_sub_objects = {'volume': volume}
    return pool_sub_objects[args.pop('pool_sub_object')](args, jdss)
