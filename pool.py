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


"""Pool related commands."""

def volume_create(args, jdss):
  
    volume_size = args['volume_size']
    block_size = args['block_size']
    volume_name = args['volume_name']

    volume = {'id': volume_name,
              'size': int(volume_size)}

    jdss.create_volume(volume)

def volume_list(args, jdss):
    data = jdss.list_volumes()
    for v in data:
        print("%(name)s %(id)s %(size)s " % {
            'name': v['name'],
            'id': v['id'],
            'size': v['size']})

def volume_delete(args, jdss):

    volume = {'id': args['volume_name']}

    jdss.delete_volume(volume, cascade=args['cascade'])

def volume(args, jdss):

    volume_sub_objects = {
        'create': volume_create,
        'list': volume_list,
        'delete': volume_delete}
    volume_sub_objects[args.pop('volume_sub_object')](args, jdss) 

def pool(args, jdss):
    
    pool_sub_objects = {'volume': volume}
    pool_sub_objects[args.pop('pool_sub_object')](args, jdss)
