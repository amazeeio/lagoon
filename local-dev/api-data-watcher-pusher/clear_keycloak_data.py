#!/usr/bin/env python3

from keycloak import KeycloakAdmin
from keycloak.exceptions import raise_error_from_response, KeycloakGetError

keycloak_admin = KeycloakAdmin(server_url="http://keycloak:8080/auth/",
                               username='admin',
                               password='admin',
                               realm_name='master',
                               verify=True)

keycloak_admin.realm_name = 'lagoon'

users = keycloak_admin.get_users({})
for user in users:
    if user['username'] != 'lagoonadmin':
        keycloak_admin.delete_user(user_id=user['id'])


groups = keycloak_admin.get_groups()
for group in groups:
    keycloak_admin.delete_group(group_id=group['id'])


# delete every user except for lagoon admin