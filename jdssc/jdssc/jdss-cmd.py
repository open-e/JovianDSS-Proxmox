#!/usr/bin/python3

import argparse
import re

from jovian_common import rest_proxy

CONFIG = {
    'jovian_rest_protocol': 'https',
    'san_hosts': ['172.16.0.220'],
    'san_api_port': 82,
    'jovian_recovery_delay': 40,
    'jovian_pool': 'Pool-2',
    'san_login': 'admin',
    'san_password': 'admin',
    'jovian_target_prefix': 'iqn.2020-04.com.open-e.cinder:',
}

def get_config(args):
    cfg = {
        'jovian_rest_protocol': 'https',
        'san_hosts': [args.ip],
        'san_api_port': args.port,
        'jovian_recovery_delay': 40,
        'jovian_pool': args.pool,
        'san_login': args.username,
        'san_password': args.password,
        'jovian_target_prefix': 'iqn.2020-04.com.open-e.cinder:',
    }
    return cfg

class JovianRESTAPI(object):
    """Jovian REST API proxy."""

    def __init__(self, config):

        self.target_p = config.get('jovian_target_prefix',
            'iqn.2020-04.com.open-e.cinder:')
        self.pool = config.get('jovian_pool')
        self.rproxy = rest_proxy.JovianRESTProxy(config)

        self.resource_dne_msg = (
            re.compile(r'^Zfs resource: .* not found in this collection\.$'))

    def get_luns(self):
        """get_all_pool_volumes.

        GET
        /pools/<string:poolname>/volumes
        :param pool_name
        :return list of all pool volumes
        """
        req = '/volumes'

        resp = self.rproxy.pool_request('GET', req)

        if resp['error'] is None and resp['code'] == 200:
            return resp['data']
        raise jexc.JDSSRESTException(resp['error']['message'])

    def delete_lun(self, volume_name,
                   recursively_children=False,
                   recursively_dependents=False,
                   force_umount=False):
        """delete_volume.

        DELETE /volumes/<string:volumename>
        :param volume_name:
        :return:
        """
        jbody = {}
        if recursively_children is True:
            jbody['recursively_children'] = True

        if recursively_dependents is True:
            jbody['recursively_dependents'] = True

        if force_umount is True:
            jbody['force_umount'] = True

        req = '/volumes/' + volume_name

        if len(jbody) > 0:
            resp = self.rproxy.pool_request('DELETE', req, json_data=jbody)
        else:
            resp = self.rproxy.pool_request('DELETE', req)

        if resp["code"] == 204:
            return

        # Handle DNE case
        if resp["code"] == 500:
            if 'message' in resp['error']:
                if self.resource_dne_msg.match(resp['error']['message']):
                    return

        # Handle volume busy
        if resp["code"] == 500 and resp["error"] is not None:
            if resp["error"]["errno"] == 1000:
                raise exception.VolumeIsBusy(volume_name=volume_name)

        raise jexc.JDSSRESTException('Failed to delete volume.')

    def get_users(self):
        """get_users.

        GET
        /users
        :param pool_name
        :return list of all pool volumes
        """
        req = '/users'

        resp = self.rproxy.request('GET', req)

        if resp['error'] is None and resp['code'] == 200:
            return resp['data']
        raise jexc.JDSSRESTException(resp['error']['message'])

    def create_user(self, user, password):
        req = '/users'

        json_data = {"name": user, "password": password, "backend_name": "LDAP"}
        resp = self.rproxy.request('POST', req, json_data=json_data)

        if resp['code'] == 201:
            return resp['data']
        #print(resp['error'])

    def delete_user(self, user):
        req = '/users/' + user

        resp = self.rproxy.request('DELETE', req)

        if resp['code'] != 204:
            print(resp['error'])

    def set_share_user(self, share, user):
        req = '/shares/{}/users'.format(share)

        json_data = [{'name': user, 'readonly': False}]
        resp = self.rproxy.request('PUT', req, json_data=json_data)

        if resp['code'] != 201:
            raise Exception()
        return resp['data']

    def get_share_user(self, user, share):
        req = '/shares/{}/users'.format(share)

        resp = self.rproxy.request('GET', req)

        if resp['code'] != 200:
            raise Exception()
            
        return resp['data']
        #print(resp['error'])

    def create_share(self, pool, path, name):
        req = '/shares'

        json_data = {"path": "{}/{}/{}".format(pool, path, name),
                     "name": name,
                     "smb": {"enabled": True, 
                             "visible": True,
                             "access_mode": "user"}}
        resp = self.rproxy.request('POST', req, json_data=json_data)

        if resp['code'] != 201:
            print(resp)
            raise Exception()

    def delete_share(self, share):
        req = '/shares/' + share

        resp = self.rproxy.request('DELETE', req)

        if resp['code'] != 204:
            print(resp['error'])

    def get_share(self, name):
        req = '/shares/{}'.format(name)

        resp = self.rproxy.request('GET', req)

        if resp['code'] != 200:
            raise Exception()
        return redp['data']

def get_users():
    print("getting users")
    rapi = JovianRESTAPI(CONFIG)
    users = rapi.get_users()['entries']
    for user in users:
        print(user['name']) 
    
def generate_test_shares(a, b):
    rapi = JovianRESTAPI(CONFIG)

    for j in range(a, b):
        share = "user_{}".format(str(j))
        rapi.create_share("win_perf_test", share)
        rapi.set_share_user(share, share)

def share_action(args):
    cfg  = get_config(args)
    rapi = JovianRESTAPI(cfg)

    shares = ["".join([args.template, str(i)]) for i in range(args.first, args.last + 1)]

    if args.create:
        for share in shares:
            rapi.create_share(args.pool, args.path, share)
            rapi.set_share_user(share, share)
            print('Create share: {}'.format(share)) 
    if args.delete:
        for share in shares:
            rapi.delete_share(share)
            print('Delete share: {}'.format(share))

def user_action(args):
    cfg  = get_config(args)
    rapi = JovianRESTAPI(cfg)

    users = ["".join([args.template, str(i)]) for i in range(args.first, args.last + 1)]
    if args.create:
        for user in users:
            rapi.create_user(user, user)
            print('Creating user: {}'.format(user))
    if args.delete:
        for user in users:
            rapi.delete_user(user)
            print('Delete users: {}'.format(user))

def __get_arguments():
    parser = argparse.ArgumentParser(description='Arguments')

    subparsers = parser.add_subparsers(required=True, dest='cmd')

    parser.add_argument('-i','--ip', dest='ip', type=str,
                        action='store',
                        default='10.0.0.27',
                        help='IP or FQDN of JovianDSS')

    parser.add_argument('-p','--port', dest='port', type=int,
                        action='store',
                        default=82,
                        help='REST port for JovianDSS')

    parser.add_argument('-u', '--user', dest='username', type=str,
                        action='store',
                        default='admin',
                        help='Jovian user name')

    parser.add_argument('-s', '--password', dest='password', type=str,
                        action='store',
                        default='admin',
                        help='Jovian user password')



    #parser.add_argument('-d', dest='debug', type=str,
    #                    action='store',
    #                    default='WARNING',
    #                    help='Specify debuging level like: INFO, DEBUG, WARNING...')
    
    user = subparsers.add_parser('user')
    user_cmd = user.add_mutually_exclusive_group(required=True)

    user_cmd.add_argument('-c', '--create', dest='create',
                        action='store_true',
                        default=False,
                        help='Create users')
    
    user_cmd.add_argument('-d', '--delete', dest='delete',
                        action='store_true',
                        default=False,
                        help='Delete users')

    user.add_argument('-t', '--template', dest='template',
                        type=str,
                        default='user_',
                        help='Prefix for user name genaration, default user_')
    
    user.add_argument('--pool', dest='pool', type=str,
                        action='store',
                        default='Pool-0',
                        help='Jovian Pool name, default Pool-0')
    

    user.add_argument('-f','--first', dest='first', type=int, action='store',
                        default=1,
                        help='First index')

    user.add_argument('-l','--last', dest='last', type=int, action='store',
                        default=1000,
                        help='Last index')

    share = subparsers.add_parser('share')

    share_cmd = share.add_mutually_exclusive_group(required=True)

    share_cmd.add_argument('-c', '--create', dest='create',
                           action='store_true',
                           default=False,
                           help='Create shares')
    
    share_cmd.add_argument('-d', '--delete', dest='delete',
                        action='store_true',
                        default=False,
                        help='Delete shares')

    share.add_argument('--path', dest='path', type=str,
                        action='store',
                        default='win_perf_test',
                        help='Share path, default win_perf_test')

    share.add_argument('--pool', dest='pool', type=str,
                        action='store',
                        default='Pool-0',
                        help='Jovian pool name, default Pool-0')

    share.add_argument('-t', '--template', dest='template',
                        type=str,
                        default='user_',
                        help='Prefix for share name genaration, default user_')

    share.add_argument('-f','--first', dest='first', type=int, action='store',
                        default=1,
                        help='First index')

    share.add_argument('-l','--last', dest='last', type=int, action='store',
                        default=1000,
                        help='Last index')

    return parser.parse_args()

def main():

    args = __get_arguments()

    actions = {'user': user_action,
               'share': share_action}

    actions[args.cmd](args)
    #generate_test_shares(1, 1001)
    #rapi = JovianRESTAPI(CONFIG)

    #rapi.set_share_user("t1", "user_2")
    #rapi.delete_share("t1")
    #rapi.create_share("win_perf_test", "t1")
    #create_users()
    #get_users()
    #delete_users()
    #luns = rapi.get_luns()
    #for l in luns:
    #    print(l['name'])
    #    try:
    #        rapi.delete_lun(l['name'],
    #                        recursively_children=True,
    #                        recursively_dependents=True,
    #                        force_umount=True)
    #    except:
    #        continue

if __name__ == "__main__":
    main()
