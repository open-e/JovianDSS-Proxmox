from setuptools import setup

setup(
  name='OpenEJovianDSSProxmoxCLI',
  version='0.6.1',
  author='Andrei Perepiolkin',
  author_email='andrei.perepiolkin@open-e.com',
  packages=['package_name', 'package_name.test'],
  scripts=['bin/jdssc'],
  url='https://github.com/open-e/JovianDSS-Proxmox',
  license='LICENSE.txt',
  description='An assistant tool for Proxmox plugin',
  long_description=open('README.txt').read(),
  install_requires=[
      "Django >= 1.1.1",
      "pytest",
  ],)
