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
import sys

from jdssc.jovian_common import driver
import jdssc.cifs as cifs
import jdssc.nas_volumes as nas_volumes
import jdssc.volumes as volumes
import jdssc.volume as volume
import jdssc.targets as targets

"""Pool related commands."""


class Pools():
    def __init__(self, args, uargs, jdss):

        self.pa = {'cifs': self.cifs,
                   'get': self.get,
                   'ip': self.ip,
                   'nas_volumes': self.nas_volumes,
                   'targets': self.targets,
                   'volume': self.volume,
                   'volumes': self.volumes}

        self.args = args

        argst = self.__parse(uargs)

        self.args.update(vars(argst[0]))
        self.uargs = argst[1]
        self.jdss = jdss

        if self.args['pool_name']:
            self.jdss.configuration['jovian_pool'] = self.args['pool_name']
            self.jdss = driver.JovianDSSDriver(self.jdss.configuration)

        if 'pool_action' in self.args and args['pool_action'] is not None:
            self.pa[self.args.pop('pool_action')]()

    def __parse(self, args):

        parser = argparse.ArgumentParser(prog="Pool")

        parser.add_argument('pool_name', help='Pool name')
        parsers = parser.add_subparsers(dest='pool_action')
        parsers.add_parser('get', add_help=False)
        parsers.add_parser('ip', add_help=False)
        parsers.add_parser('cifs', add_help=False)
        parsers.add_parser('nas_volumes', add_help=False)
        parsers.add_parser('targets', add_help=False)
        parsers.add_parser('volume', add_help=False)
        parsers.add_parser('volumes', add_help=False)

        return parser.parse_known_args(args)

    def cifs(self):
        cifs.CIFS(self.args, self.uargs, self.jdss)

    def get(self):
        (total_gb, free_gb) = self.jdss.get_volume_stats()
        line = "{total} {free} {used}\n".format(
            total=total_gb, free=free_gb, used=total_gb-free_gb)
        sys.stdout.write(line)

    def ip(self):
        for i in self.jdss.jovian_hosts:
            line = ("%s\n" % i)
            sys.stdout.write(line)

    def nas_volumes(self):
        nas_volumes.NASVolumes(self.args, self.uargs, self.jdss)

    def volume(self):
        volume.Volume(self.args, self.uargs, self.jdss)

    def volumes(self):
        volumes.Volumes(self.args, self.uargs, self.jdss)

    def targets(self):
        targets.Targets(self.args, self.uargs, self.jdss)
