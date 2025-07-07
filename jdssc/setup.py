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


from setuptools import setup

setup(
    name='OpenEJovianDSSProxmoxCLI',
    version='0.9.10-0',
    author='Andrei Perepiolkin',
    author_email='andrei.perepiolkin@open-e.com',
    packages=['jdssc'],
    scripts=['bin/jdssc'],
    url='https://github.com/open-e/JovianDSS-Proxmox',
    license='LICENSE.txt',
    description='An assistant tool for Proxmox plugin',
    long_description=open('README.txt').read(),
    install_requires=[
        "pytest",
        "retry",
        "pyinotify",
        "toml"
    ],)
