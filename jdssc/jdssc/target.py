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
import logging
import sys

from jdssc.jovian_common import exception as jexc

"""Singular iSCSI target operations addressed by full IQN."""

LOG = logging.getLogger(__name__)


class Target():
    def __init__(self, args, uargs, jdss):

        self.ta = {'delete': self.delete,
                   'get': self.get,
                   'update': self.update}

        self.args = args
        argst = self.__parse(uargs)
        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss

        if 'target_action' in self.args:
            self.ta[self.args.pop('target_action')]()
        else:
            sys.exit(1)

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Target")

        parser.add_argument('target_name', help='Full iSCSI target IQN')
        parsers = parser.add_subparsers(dest='target_action')

        parsers.add_parser('get')

        parsers.add_parser('delete')

        update = parsers.add_parser('update')
        update.add_argument('--chap-user',
                            dest='chap_user',
                            default=None,
                            help='CHAP initiator username')
        update.add_argument('--chap-password',
                            dest='chap_password',
                            default=None,
                            help='CHAP initiator password')
        update.add_argument('--no-chap',
                            dest='no_chap',
                            action='store_true',
                            default=False,
                            help='Disable CHAP: clear incoming_users_active '
                                 'and remove all CHAP users from the target')

        return parser.parse_known_args(args)

    def get(self):
        target_name = self.args['target_name']
        try:
            data = self.jdss.get_target(target_name)
        except jexc.JDSSResourceNotFoundException:
            LOG.error("Target %s not found", target_name)
            sys.exit(1)
        except jexc.JDSSException as jerr:
            LOG.error(jerr.message)
            sys.exit(1)
        print(data)

    def delete(self):
        target_name = self.args['target_name']
        try:
            self.jdss.delete_target(target_name)
        except jexc.JDSSResourceNotFoundException:
            LOG.error("Target %s not found", target_name)
            sys.exit(1)
        except jexc.JDSSException as jerr:
            LOG.error(jerr.message)
            sys.exit(1)

    def update(self):
        target_name = self.args['target_name']
        no_chap    = self.args.get('no_chap', False)
        chap_user  = self.args.get('chap_user')
        chap_pass  = self.args.get('chap_password')

        if no_chap and (chap_user or chap_pass):
            LOG.error("--no-chap cannot be combined with "
                      "--chap-user or --chap-password")
            sys.exit(1)

        if not no_chap:
            if not chap_user and not chap_pass:
                LOG.error("Provide --chap-user and --chap-password to update "
                          "credentials, or --no-chap to disable CHAP")
                sys.exit(1)
            if bool(chap_user) != bool(chap_pass):
                LOG.error("--chap-user and --chap-password must be "
                          "provided together")
                sys.exit(1)

        provider_auth = (
            'CHAP {} {}'.format(chap_user, chap_pass) if not no_chap else None
        )

        try:
            self.jdss.update_target(target_name, provider_auth)
        except jexc.JDSSResourceNotFoundException:
            LOG.error("Target %s not found", target_name)
            sys.exit(1)
        except jexc.JDSSException as jerr:
            LOG.error(jerr.message)
            sys.exit(1)
