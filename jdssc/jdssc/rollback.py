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


"""Snapshot rollback related commands."""

LOG = logging.getLogger(__name__)


class Rollback():
    def __init__(self, args, uargs, jdss):

        self.ssa = {'check': self.check,
                    'do': self.do}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        if 'rollback_action' in self.args:
            self.ssa[self.args.pop('rollback_action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="JDSS Volume To Snapshot Rollback",
                                         description="Executes snapshot rollback")

        parsers = parser.add_subparsers(dest='rollback_action')

        check = parsers.add_parser('check')
        do = parsers.add_parser('do')
        kargs, ukargs = parser.parse_known_args(args)

        if kargs.rollback_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def check(self):
        try:
            self.jdss.rollback_check(self.args['volume_name'], self.args['snapshot_name'])
            return
        except jexc.JDSSResourceIsBusyException as berr:
            LOG.error(berr)
            exit(1)
        except jexc.JDSSSnapshotNotFoundException as dneerr:
            LOG.error(dneerr)
            exit(1)
        except jexc.JDSSException as err:
            LOG.error(err)
            exit(1)

    def do(self):

        try:
            self.jdss.rollback(self.args['volume_name'], self.args['snapshot_name'])
            return
        except jexc.JDSSResourceIsBusyException as berr:
            LOG.error(berr)
            exit(1)
        except jexc.JDSSSnapshotNotFoundException as dneerr:
            LOG.error(dneerr)
            exit(1)
        except jexc.JDSSException as err:
            LOG.error(err)
            exit(1)

