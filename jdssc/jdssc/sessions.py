#    Copyright (c) 2026 Open-E, Inc.
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

"""Target session related commands."""

LOG = logging.getLogger(__name__)


class Sessions():
    def __init__(self, args, uargs, jdss):

        self.sa = {'list': self.list}

        self.args = args
        args, uargs = self.__parse(uargs)
        self.args.update(vars(args))
        self.uargs = uargs
        self.jdss = jdss

        if 'sessions_action' in self.args:
            self.sa[self.args.pop('sessions_action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Sessions")

        parsers = parser.add_subparsers(dest='sessions_action')

        parsers.add_parser('list')

        kargs, ukargs = parser.parse_known_args(args)

        if kargs.sessions_action is None:
            parser.print_help()
            sys.exit(1)

        return kargs, ukargs

    def list(self):

        target_name = self.args['target_name']

        try:
            data = self.jdss.get_target_sessions(target_name)
        except jexc.JDSSResourceNotFoundException:
            LOG.error("Target %s not found", target_name)
            sys.exit(1)
        except jexc.JDSSException as jerr:
            LOG.error(jerr.message)
            sys.exit(1)

        # One record per SESSION (sid): a multipath initiator appears once
        # per portal it logged into, and reconnects can repeat an ip under
        # a new sid — group by initiator, dedupe ips (order preserved).
        by_initiator = {}
        for s in data:
            ips = by_initiator.setdefault(s['initiator_name'], [])
            if s['ip'] not in ips:
                ips.append(s['ip'])
        for initiator, ips in by_initiator.items():
            print("{} {}".format(initiator, ','.join(ips)))
