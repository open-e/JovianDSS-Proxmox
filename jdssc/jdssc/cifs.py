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
from jdssc.jovian_common import exception as jexc

"""NAS volumes related commands."""

class CIFS():
    def __init__(self, args, uargs, jdss):
        
        self.nva = {
                   'ensure': self.ensure,
                   'extend': self.extend,
                   'delete': self.delete}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss
      
        self.nva[self.args.pop('cifs-action')]()

    def __parse(self, args):

        cifs_parser = argparse.ArgumentParser(prog="CIFS volume manager")

        cifs_parser.add_argument('cifs_share_name', type=str, help='Name of CIFS share')
        
        parser = cifs_parser.add_subparsers(dest='cifs-action')

        ensure = parser.add_parser('ensure')
        ensure.add_argument('-s', '--size', dest='cifs_size', default="10G", help='Size of CIFS share')
        ensure.add_argument('-u', '--user', required=True, dest='cifs_user', help='Use specific user name for this share')
        ensure.add_argument('-p', '--password', required=True, dest='cifs_password', help='Use specific password for user')
        ensure.add_argument('-n', '--nasname', required=True, dest='cifs_nas_name', help='Use specific name for nas volume')

        extend = parser.add_parser('extend')
        extend.add_argument('cifs_share_name', type=str, help='Name of CIFS share')
        extend.add_argument('-s', '--size', dest='cifs_size', default="10G", help='New size of CIFS share')
 
        delete = parser.add_parser('delete')
        delete.add_argument('cifs_share_name', help='CIFS share to delete')

        return cifs_parser.parse_known_args(args)

    def ensure(self):

        # Make shure nas-volume exist
        try:
            self.jdss.ra.get_nas_volume(self.args['cifs_nas_name'])
        except jexc.JDSSResourceNotFoundException:
            self.jdss.ra.create_nas_volume(self.args['cifs_nas_name'])
        except Exception as err:
            raise err

        # Make sure user exists
        user = None
        try:
            user = self.jdss.ra.get_user(self.args['cifs_user'])
        except jexc.JDSSResourceNotFoundException:
            self.jdss.ra.create_user(self.args['cifs_user'], self.args['cifs_password'])
        except Exception as err:
            raise err

        if user:
            self.jdss.ra.set_user_pass(self.args['cifs_user'], self.args['cifs_password'])

        # Create share
        try:
            self.jdss.ra.get_share(self.args['cifs_share_name'])
        except jexc.JDSSResourceNotFoundException:
            self.jdss.ra.create_share(self.args['cifs_nas_name'],
                                      self.args['cifs_share_name'])
        except Exception as err:
            raise err

        # Ensure share have specific size

        # Set share user
        users = None
        try:
            users = self.jdss.ra.get_share_users(self.args['cifs_share_name'])
        except Exception as err:
            raise err
        
        user_names = [ n['name'] for n in users['entries'] ] 
        
        if self.args['cifs_user'] in user_names:
            return
       
        if len(user_names) > 0:
            self.jdss.ra.delete_share_user(self.args['cifs_share_name'], user_names)

        self.jdss.ra.set_share_user(self.args['cifs_share_name'], self.args['cifs_user'])
 
    def get(self):

        volume_name = self.args['volume_name']

        volume = {'id': volume_name}
 
        d = self.jdss.get_volume(volume)

        if self.args['volume_size']:
            print(d['size'])

    def extend(self):
        pass

    def delete(self):

        self.jdss.ra.delete_nas_volume(self.args['nas_volume_name'])
