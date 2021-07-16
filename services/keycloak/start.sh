#!/bin/bash

set -eo pipefail

# 1. The first part of this entrypoint script deals with adding realms and users. Code is a modified version of this entrypoint script:
# https://github.com/stefanjacobs/keycloak_min/blob/f26927426e60c1ec29fc0c0980e5a694a45dcc05/run.sh

function is_keycloak_running {
    local http_code=$(curl -s -o /dev/null -w "%{http_code}" http://$(hostname -i):8080/auth/admin/realms)
    if [[ $http_code -eq 401 ]]; then
        return 0
    else
        return 1
    fi
}

function configure_lagoon_realm {
    if /opt/jboss/keycloak/bin/kcadm.sh get realms/$KEYCLOAK_REALM --config $CONFIG_PATH > /dev/null; then
        echo "Realm $KEYCLOAK_REALM is already created, skipping initial setup"
        return 0
    fi

    if [ $KEYCLOAK_REALM ]; then
        echo Creating realm $KEYCLOAK_REALM
        /opt/jboss/keycloak/bin/kcadm.sh create realms --config $CONFIG_PATH -s realm=$KEYCLOAK_REALM -s enabled=true
    fi

    if [ "$KEYCLOAK_REALM_ROLES" ]; then
        for role in ${KEYCLOAK_REALM_ROLES//,/ }; do
            echo Creating role $role
            /opt/jboss/keycloak/bin/kcadm.sh create roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name=${role}
        done
    fi
    # Configure keycloak for ui
    echo Creating client lagoon-ui
    echo '{"clientId": "lagoon-ui", "publicClient": true, "webOrigins": ["*"], "redirectUris": ["*"]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating mapper for lagoon-ui "lagoon-uid"
    CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=lagoon-ui --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    echo '{"protocol":"openid-connect","config":{"id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","user.attribute":"lagoon-uid","claim.name":"lagoon.user_id","jsonType.label":"int","multivalued":""},"name":"Lagoon User ID","protocolMapper":"oidc-usermodel-attribute-mapper"}' | /opt/jboss/keycloak/bin/kcadm.sh create -r ${KEYCLOAK_REALM:-master} clients/$CLIENT_ID/protocol-mappers/models --config $CONFIG_PATH -f -

    if [ "$KEYCLOAK_REALM_SETTINGS" ]; then
        echo Applying extra Realm settings
        echo $KEYCLOAK_REALM_SETTINGS | /opt/jboss/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM:-master} --config $CONFIG_PATH -f -
    fi

    if [ $KEYCLOAK_LAGOON_ADMIN_USERNAME ]; then
        echo Creating user $KEYCLOAK_LAGOON_ADMIN_USERNAME
        # grep would have been nice instead of the double sed, but we don't have gnu grep available, only the busybox grep which is very limited
        local user_id=$(echo '{"username": "'$KEYCLOAK_LAGOON_ADMIN_USERNAME'", "enabled": true}' \
        | /opt/jboss/keycloak/bin/kcadm.sh create users --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f - 2>&1  | sed -e 's/Created new user with id //g' -e "s/'//g")
        echo "Created user with id ${user_id}"
        /opt/jboss/keycloak/bin/kcadm.sh update users/${user_id}/reset-password --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s type=password -s value=${KEYCLOAK_LAGOON_ADMIN_PASSWORD} -s temporary=false -n
        echo "Set password for user ${user_id}"

        /opt/jboss/keycloak/bin/kcadm.sh add-roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} --uid ${user_id} --rolename admin
        echo "Gave user '$KEYCLOAK_LAGOON_ADMIN_USERNAME' the role 'admin'"

        local group_name="lagoonadmin"
        local group_id=$(/opt/jboss/keycloak/bin/kcadm.sh create groups --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name=${group_name} 2>&1 | sed -e 's/Created new group with id //g' -e "s/'//g")
        /opt/jboss/keycloak/bin/kcadm.sh update users/${user_id}/groups/${group_id} --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master}
        echo "Created group '$group_name' and made user '$KEYCLOAK_LAGOON_ADMIN_USERNAME' member of it"
    fi
}

function configure_opendistro_security_client {

    # delete old SearchGuard Clients
    searchguard_client_id=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=searchguard --config $CONFIG_PATH)
    if [ "$searchguard_client_id" != "[ ]" ]; then
        echo "Client searchguard is exising, will delete"
        SEARCHGUARD_CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=searchguard --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
        /opt/jboss/keycloak/bin/kcadm.sh delete clients/${SEARCHGUARD_CLIENT_ID} --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master}
    fi
    lagoon_searchguard_client_id=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=lagoon-searchguard --config $CONFIG_PATH)
    if [ "$lagoon_searchguard_client_id" != "[ ]" ]; then
        echo "Client lagoon-searchguard is exising, will delete"
        LAGOON_SEARCHGUARD_CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=lagoon-searchguard --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
        /opt/jboss/keycloak/bin/kcadm.sh delete clients/${LAGOON_SEARCHGUARD_CLIENT_ID} --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master}
    fi


    opendistro_security_client_id=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=lagoon-opendistro-security --config $CONFIG_PATH)
    if [ "$opendistro_security_client_id" != "[ ]" ]; then
        echo "Client lagoon-opendistro-security is already created, skipping setup"
        return 0
    fi

    # Configure keycloak for lagoon-opendistro-security
    echo Creating client lagoon-opendistro-security
    echo '{"clientId": "lagoon-opendistro-security", "webOrigins": ["*"], "redirectUris": ["*"]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating mapper for lagoon-opendistro-security "groups"
    CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=lagoon-opendistro-security --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    echo '{"protocol":"openid-connect","config":{"script":"var ArrayList = Java.type(\"java.util.ArrayList\");\nvar groupsAndRoles = new ArrayList();\nvar forEach = Array.prototype.forEach;\n\n\/\/ add all groups the user is part of\nforEach.call(user.getGroups().toArray(), function(group) {\n  \/\/ remove the group role suffixes\n  \/\/lets check if the group has a parent if this is a child\n  if(group.getFirstAttribute(\"type\") == \"role-subgroup\") {\n    var parent = group.getParent();\n    var projectIds = parent.getFirstAttribute(\"lagoon-projects\");\n    if(projectIds != null) {\n        forEach.call(projectIds.split(\",\"), function(g) {\n          groupsAndRoles.add(\"p-\" + g);  \n        });\n        return;\n    }\n  }\n \n  var groupName = group.getName().replace(\/-owner|-maintainer|-developer|-reporter|-guest\/gi,\"\");\n  groupsAndRoles.add(groupName);\n  return;\n});\n\n\/\/ add all roles the user is part of\nforEach.call(user.getRoleMappings().toArray(), function(role) {\n   var roleName = role.getName();\n   groupsAndRoles.add(roleName);\n});\n\nexports = groupsAndRoles;","id.token.claim":"true","access.token.claim":"true","userinfo.token.claim":"true","multivalued":"true","claim.name":"groups","jsonType.label":"String"},"name":"groups","protocolMapper":"oidc-script-based-protocol-mapper"}' | /opt/jboss/keycloak/bin/kcadm.sh create -r ${KEYCLOAK_REALM:-master} clients/$CLIENT_ID/protocol-mappers/models --config $CONFIG_PATH -f -

}

function configure_api_client {
    api_client_id=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH)
    if [ "$api_client_id" != "[ ]" ]; then
        echo "Client api is already created, skipping basic setup"
        return 0
    fi

    # Enable username edit
    /opt/jboss/keycloak/bin/kcadm.sh update realms/${KEYCLOAK_REALM:-master} --config $CONFIG_PATH -s editUsernameAllowed=true

    echo Creating client auth-server
    echo '{"clientId": "auth-server", "publicClient": false, "standardFlowEnabled": false, "serviceAccountsEnabled": true, "secret": "'$KEYCLOAK_AUTH_SERVER_CLIENT_SECRET'"}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    AUTH_SERVER_CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=auth-server --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    REALM_MANAGEMENT_CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=realm-management --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    echo Enable auth-server token exchange
    # 1 Enable fine grained admin permissions for users
    /opt/jboss/keycloak/bin/kcadm.sh update users-management-permissions --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s enabled=true
    # 2 Enable fine grained admin perions for client
    /opt/jboss/keycloak/bin/kcadm.sh update clients/$AUTH_SERVER_CLIENT_ID/management/permissions --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s enabled=true
    # 3 Create policy for auth-server client
    echo '{"type":"client","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Client auth-server Policy","clients":["'$AUTH_SERVER_CLIENT_ID'"]}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/policy/client --config $CONFIG_PATH -r lagoon -f -
    AUTH_SERVER_CLIENT_POLICY_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/policy?name=Client+auth-server+Policy --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    # 4 Update user impersonate permission to add client policy (PUT)
    IMPERSONATE_PERMISSION_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/permission?name=admin-impersonating.permission.users --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    /opt/jboss/keycloak/bin/kcadm.sh update clients/$REALM_MANAGEMENT_CLIENT_ID/authz/resource-server/permission/scope/$IMPERSONATE_PERMISSION_ID --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s 'policies=["'$AUTH_SERVER_CLIENT_POLICY_ID'"]'



    # Setup composite roles. Each role will include the roles to the left of it
    composite_role_names=(guest reporter developer maintainer owner)
    composites_add=()
    for crn_key in ${!composite_role_names[@]}; do
        echo Creating role ${composite_role_names[$crn_key]}
        /opt/jboss/keycloak/bin/kcadm.sh create roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s composite=true -s name=${composite_role_names[$crn_key]}

        for ca_key in ${!composites_add[@]}; do
            /opt/jboss/keycloak/bin/kcadm.sh add-roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} --rname ${composite_role_names[$crn_key]} --rolename ${composites_add[$ca_key]}
        done

        composites_add+=(${composite_role_names[$crn_key]})
    done

    # Setup platform wide roles.
    /opt/jboss/keycloak/bin/kcadm.sh create roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name=platform-owner
    /opt/jboss/keycloak/bin/kcadm.sh add-roles --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} --rname admin --rolename platform-owner

    # Configure keycloak for api
    echo Creating client api
    echo '{"clientId": "api", "publicClient": false, "standardFlowEnabled": false, "serviceAccountsEnabled": true, "authorizationServicesEnabled": true, "secret": "'$KEYCLOAK_API_CLIENT_SECRET'"}' | /opt/jboss/keycloak/bin/kcadm.sh create clients --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    ADMIN_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/admin --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    GUEST_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/guest --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    REPORTER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/reporter --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    DEVELOPER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/developer --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    MAINTAINER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/maintainer --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    OWNER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/owner --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')
    PLATFORM_OWNER_ROLE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get  -r lagoon roles/platform-owner --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)["id"]')

    # Resource Scopes
    resource_scope_names=(add add:development add:production addGroup addNoExec addNotification addOrUpdate:development addOrUpdate:production addUser delete delete:development delete:production deleteAll deleteNoExec deploy:development deploy:production drushArchiveDump:development drushArchiveDump:production drushCacheClear:development drushCacheClear:production drushRsync:destination:development drushRsync:destination:production drushRsync:source:development drushRsync:source:production drushSqlDump:development drushSqlDump:production drushSqlSync:destination:development drushSqlSync:destination:production drushSqlSync:source:development drushSqlSync:source:production environment:add:development environment:add:production environment:view:development environment:view:production getBySshKey project:add project:view removeAll removeGroup removeNotification removeUser ssh:development ssh:production storage update update:development update:production view view:token view:user viewAll viewPrivateKey)
    for rsn_key in ${!resource_scope_names[@]}; do
        echo Creating resource scope ${resource_scope_names[$rsn_key]}
        /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/scope --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name=${resource_scope_names[$rsn_key]}
    done

    # Resources with scopes
    echo Creating resource backup
    echo '{"name":"backup","displayName":"backup","scopes":[{"name":"view"},{"name":"add"},{"name":"delete"},{"name":"deleteAll"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource restore
    echo '{"name":"restore","displayName":"restore","scopes":[{"name":"add"},{"name":"addNoExec"},{"name":"update"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource deployment
    echo '{"name":"deployment","displayName":"deployment","scopes":[{"name":"view"},{"name":"update"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource env_var
    echo '{"name":"env_var","displayName":"env_var","scopes":[{"name":"project:view"},{"name":"project:add"},{"name":"environment:view:production"},{"name":"environment:view:development"},{"name":"environment:add:production"},{"name":"environment:add:development"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource task
    echo '{"name":"task","displayName":"task","scopes":[{"name":"view"},{"name":"update"},{"name":"delete"},{"name":"add:production"},{"name":"add:development"},{"name":"addNoExec"},{"name":"drushArchiveDump:development"},{"name":"drushArchiveDump:production"},{"name":"drushSqlDump:development"},{"name":"drushSqlDump:production"},{"name":"drushCacheClear:development"},{"name":"drushCacheClear:production"},{"name":"drushSqlSync:source:development"},{"name":"drushSqlSync:source:production"},{"name":"drushSqlSync:destination:development"},{"name":"drushSqlSync:destination:production"},{"name":"drushRsync:source:development"},{"name":"drushRsync:source:production"},{"name":"drushRsync:destination:development"},{"name":"drushRsync:destination:production"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource openshift
    echo '{"name":"openshift","displayName":"openshift","scopes":[{"name":"add"},{"name":"delete"},{"name":"update"},{"name":"deleteAll"},{"name":"view"},{"name":"viewAll"},{"name":"view:token"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource user
    echo '{"name":"user","displayName":"user","scopes":[{"name":"add"},{"name":"getBySshKey"},{"name":"update"},{"name":"delete"},{"name":"deleteAll"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource environment
    echo '{"name":"environment","displayName":"environment","scopes":[{"name":"ssh:production"},{"name":"ssh:development"},{"name":"view"},{"name":"deploy:production"},{"name":"deploy:development"},{"name":"addOrUpdate:production"},{"name":"addOrUpdate:development"},{"name":"storage"},{"name":"delete:production"},{"name":"delete:development"},{"name":"deleteNoExec"},{"name":"update:production"},{"name":"update:development"},{"name":"viewAll"},{"name":"deleteAll"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource project
    echo '{"name":"project","displayName":"project","scopes":[{"name":"update"},{"name":"add"},{"name":"addGroup"},{"name":"removeGroup"},{"name":"addNotification"},{"name":"removeNotification"},{"name":"view"},{"name":"delete"},{"name":"deleteAll"},{"name":"viewAll"},{"name":"viewPrivateKey"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource group
    echo '{"name":"group","displayName":"group","scopes":[{"name":"add"},{"name":"update"},{"name":"delete"},{"name":"deleteAll"},{"name":"addUser"},{"name":"removeUser"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource notification
    echo '{"name":"notification","displayName":"notification","scopes":[{"name":"add"},{"name":"delete"},{"name":"view"},{"name":"deleteAll"},{"name":"removeAll"},{"name":"update"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -
    echo Creating resource ssh_key
    echo '{"name":"ssh_key","displayName":"ssh_key","scopes":[{"name":"view:user"},{"name":"view:project"},{"name":"add"},{"name":"deleteAll"},{"name":"removeAll"},{"name":"update"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -

    # Authorization policies
    echo Creating api authz js policies

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for realm is Platform Owner",
  "description": "Checks the users role for the realm is Platform Owner or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\n\nif (!ctxAttr.exists('currentUser')) {\n    $evaluation.deny();\n} else {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for realm is Admin",
  "description": "Checks the users role for the realm is Admin",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\n\nif (!ctxAttr.exists('currentUser')) {\n    $evaluation.deny();\n} else {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'admin')) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Developer",
  "description": "Checks the users role for a group is Developer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 0,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Developer",
  "description": "Checks the users role for a project is Developer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 0,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "User has access to project",
  "description": "Checks that the user has access to a project via groups",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\n\n// Check projects calculated by lagoon\nif (!ctxAttr.exists('projectQuery') || !ctxAttr.exists('userProjects')) {\n    $evaluation.deny();\n} else {\n    var project = ctxAttr.getValue('projectQuery').asString(0);\n    var projects = ctxAttr.getValue('userProjects').asString(0);\n    var projectsArr = projects.split('-');\n    var grant = false;\n\n    for (var i=0; i<projectsArr.length; i++) {\n        if (project == projectsArr[i]) {\n            grant = true;\n            break;\n        }\n    }\n\n    if (grant) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Reporter",
  "description": "Checks the users role for a project is Reporter or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "User has access to own data",
  "description": "Checks that the current user is same as queried",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\n\nif (!ctxAttr.exists('usersQuery') || !ctxAttr.exists('currentUser')) {\n    $evaluation.deny();\n} else {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n    var users = ctxAttr.getValue('usersQuery').asString(0);\n    var usersArr = users.split('|');\n    var grant = false;\n    \n    for (var i=0; i<usersArr.length; i++) {\n        if (currentUser == usersArr[i]) {\n            grant = true;\n            break;\n        }\n    }\n\n    if (grant) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Guest",
  "description": "Checks the users role for a group is Guest or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 1,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Maintainer",
  "description": "Checks the users role for a group is Maintainer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Guest",
  "description": "Checks the users role for a project is Guest or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 1,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Maintainer",
  "description": "Checks the users role for a project is Maintainer or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Reporter",
  "description": "Checks the users role for a group is Reporter or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 1,\n    developer: 1,\n    reporter: 1,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for group is Owner",
  "description": "Checks the users role for a group is Owner or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 0,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userGroupRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userGroupRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/policy/js --config $CONFIG_PATH -r lagoon -f - <<'EOF'
{
  "name": "Users role for project is Owner",
  "description": "Checks the users role for a project is Owner or higher",
  "type": "js",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "code": "var realm = $evaluation.getRealm();\nvar ctx = $evaluation.getContext();\nvar ctxAttr = ctx.getAttributes();\nvar validRoles = {\n    owner: 1,\n    maintainer: 0,\n    developer: 0,\n    reporter: 0,\n    guest: 0,\n};\n\n// Check roles calculated by lagoon\nif (!ctxAttr.exists('userProjectRole')) {\n    $evaluation.deny();\n} else {\n    var groupRole = ctxAttr.getValue('userProjectRole').asString(0);\n\n    if (validRoles[groupRole.toLowerCase()]) {\n        $evaluation.grant();\n    } else {\n        $evaluation.deny();\n    }\n}\n\n// Check admin access\nif (ctxAttr.exists('currentUser')) {\n    var currentUser = ctxAttr.getValue('currentUser').asString(0);\n\n    if (realm.isUserInRealmRole(currentUser, 'platform-owner')) {\n        $evaluation.grant();\n    }\n}"
}
EOF

    #Authorization permissions
    echo Creating api authz permissions
    DEFAULT_PERMISSION_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=Default+Permission --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
    /opt/jboss/keycloak/bin/kcadm.sh delete -r lagoon clients/$CLIENT_ID/authz/resource-server/permission/$DEFAULT_PERMISSION_ID --config $CONFIG_PATH


    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Task",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Variable for Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["environment:view:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Task",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["update"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Environment Variable to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["environment:add:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["delete:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Backup",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-sync from Any Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushSqlSync:source:production","drushSqlSync:source:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["update"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Environment Variable to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["environment:add:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Backups",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["view"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Restore",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["restore"],
  "scopes": ["update"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Deployment to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["deploy:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add or Update Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["addOrUpdate:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Backups",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["deleteAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Deployments",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["deployment"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["user"],
  "scopes": ["add"],
  "policies": ["Default Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add or Update Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["addOrUpdate:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF


    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Notification",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["notification"],
  "scopes": ["view"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View All Projects",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["viewAll"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["delete:production"],
  "policies": ["Users role for project is Owner","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Notification to Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["addNotification"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Task",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["add"],
  "policies": ["Default Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Variable for Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["project:view"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Project Private Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["viewPrivateKey"],
  "policies": ["User has access to project","Users role for project is Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Groups",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["deleteAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Users",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["user"],
  "scopes": ["deleteAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Manage Openshift",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["openshift"],
  "scopes": ["delete","update","deleteAll","add","view:token"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View All Openshifts",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["openshift"],
  "scopes": ["viewAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete SSH Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "AFFIRMATIVE",
  "resources": ["ssh_key"],
  "scopes": ["delete"],
  "policies": ["User has access to own data","Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Environment Variable to Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["project:add"],
  "policies": ["Users role for project is Owner","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["add"],
  "policies": ["Default Policy"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Get SSH Keys for User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "AFFIRMATIVE",
  "resources": ["ssh_key"],
  "scopes": ["view:user"],
  "policies": ["User has access to own data","Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Openshift",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["openshift"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush rsync from Any Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushRsync:source:production","drushRsync:source:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All SSH Keys",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["ssh_key"],
  "scopes": ["removeAll","deleteAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Metrics",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["storage"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-sync to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushSqlSync:destination:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush cache-clear",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushCacheClear:production","drushCacheClear:development"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add User to Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["addUser"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Backup",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["backup"],
  "scopes": ["add"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-sync to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushSqlSync:destination:production"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["update:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush rsync to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushRsync:destination:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update SSH Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "AFFIRMATIVE",
  "resources": ["ssh_key"],
  "scopes": ["update"],
  "policies": ["User has access to own data","Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Task to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["add:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Task to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["add:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF


    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add SSH Key",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "AFFIRMATIVE",
  "resources": ["ssh_key"],
  "scopes": ["add"],
  "policies": ["User has access to own data","Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Notifications",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["notification"],
  "scopes": ["removeAll","deleteAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "CUD Notification",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["notification"],
  "scopes": ["delete","update","add"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Groups to Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["addGroup"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Deployment to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["deploy:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Environments",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["deleteAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Deployment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["deployment"],
  "scopes": ["update"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Deployment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["deployment"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["update"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Remove Notification from Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["removeNotification"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "AFFIRMATIVE",
  "resources": ["user"],
  "scopes": ["delete"],
  "policies": ["User has access to own data","Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Projects",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["deleteAll"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Remove User from Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["removeUser"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["view"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Group",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["delete"],
  "policies": ["Users role for group is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Restore",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["restore"],
  "scopes": ["add"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush archive-dump",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushArchiveDump:production","drushArchiveDump:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update User",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "AFFIRMATIVE",
  "resources": ["user"],
  "scopes": ["update"],
  "policies": ["User has access to own data","Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["delete"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Remove Groups from Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["removeGroup"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush rsync to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushRsync:destination:production"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush sql-dump",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushSqlDump:production","drushSqlDump:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Environment Variable for Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["environment:view:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Project",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["project"],
  "scopes": ["delete"],
  "policies": ["User has access to project","Users role for project is Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Environment Variable",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["env_var"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["update:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "User can SSH to Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["ssh:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "User can SSH to Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["environment"],
  "scopes": ["ssh:production"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF

    # http://localhost:8088/auth/admin/realms/lagoon/clients/1329f641-a440-44a7-996f-ed1c560e2edd/authz/resource-server/permission/scope
    # {"type":"scope","logic":"POSITIVE","decisionStrategy":"UNANIMOUS","name":"Backup View","resources":["2ebb5852-6624-4dc6-8374-e1e54a7fd9c5"],"scopes":["8e78b877-f930-43ff-995f-c907af64f69f"],"policies":["d4fae4e2-ddc7-462c-b712-d68aaeb269e1"]}
}

function add_billing_modifier {
  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  billing_modifier=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=Delete+All+Billing+Group+Modifiers --config $CONFIG_PATH)

  if [ "$billing_modifier" != "[ ]" ]; then
      echo "billing_modifier:add|update|delete|deleteAll already configured"
      return 0
  fi

  echo Creating resource billing_modifier

  # Add Scopes to Resource
  echo '{"name":"billing_modifier","displayName":"billing_modifier","scopes":[{"name":"add"},{"name":"update"},{"name":"delete"},{"name":"deleteAll"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -


  # Create new permission
    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Billing Modifier",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["billing_modifier"],
  "scopes": ["add"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Update Billing Modifier",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["billing_modifier"],
  "scopes": ["update"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Billing Modifier",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["billing_modifier"],
  "scopes": ["delete"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete All Billing Group Modifiers",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["billing_modifier"],
  "scopes": ["deleteAll"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF

}

function add_group_viewall {
  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  view_all_groups=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=View+All+Groups --config $CONFIG_PATH)

  if [ "$view_all_groups" != "[ ]" ]; then
      echo "group:viewAll already configured"
      return 0
  fi

  echo Configuring group:viewAll

  GROUP_RESOURCE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/resource?name=group --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["_id"]')
  /opt/jboss/keycloak/bin/kcadm.sh update clients/$CLIENT_ID/authz/resource-server/resource/$GROUP_RESOURCE_ID --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s 'scopes=[{"name":"add"},{"name":"update"},{"name":"delete"},{"name":"deleteAll"},{"name":"addUser"},{"name":"removeUser"},{"name":"viewAll"}]'

  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View All Groups",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["group"],
  "scopes": ["viewAll"],
  "policies": ["Users role for realm is Platform Owner"]
}
EOF
}

function add_deployment_cancel {
  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  cancel_deployment=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=Cancel+Deployment --config $CONFIG_PATH)

  if [ "$cancel_deployment" != "[ ]" ]; then
      echo "deployment:cancel already configured"
      return 0
  fi

  echo Configuring deployment:cancel

  DEPLOYMENT_RESOURCE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/resource?name=deployment --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["_id"]')
  /opt/jboss/keycloak/bin/kcadm.sh update clients/$CLIENT_ID/authz/resource-server/resource/$DEPLOYMENT_RESOURCE_ID --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s 'scopes=[{"name":"view"},{"name":"update"},{"name":"delete"},{"name":"cancel"}]'

  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Cancel Deployment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["deployment"],
  "scopes": ["cancel"],
  "policies": ["Users role for project is Maintainer","User has access to project"]
}
EOF
}

function configure_task_cron {

  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  cron_task_groups=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=Run+Drush+cron --config $CONFIG_PATH)

  if [ "$cron_task_groups" != "[ ]" ]; then
    echo "group:drushCron already configured"
    return 0
  fi

  echo Configuring group:drushCron

  # Create new scopes
  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/scope --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name="drushCron:development"
  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/scope --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name="drushCron:production"

  # Add new scopes to resources
  TASK_RESOURCE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/resource?name=task --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["_id"]')
  /opt/jboss/keycloak/bin/kcadm.sh update clients/$CLIENT_ID/authz/resource-server/resource/$TASK_RESOURCE_ID --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s 'scopes=[{"name":"view"},{"name":"update"},{"name":"delete"},{"name":"add:production"},{"name":"add:development"},{"name":"addNoExec"},{"name":"drushArchiveDump:development"},{"name":"drushArchiveDump:production"},{"name":"drushSqlDump:development"},{"name":"drushSqlDump:production"},{"name":"drushCacheClear:development"},{"name":"drushCacheClear:production"},{"name":"drushCron:development"},{"name":"drushCron:production"},{"name":"drushSqlSync:source:development"},{"name":"drushSqlSync:source:production"},{"name":"drushSqlSync:destination:development"},{"name":"drushSqlSync:destination:production"},{"name":"drushRsync:source:development"},{"name":"drushRsync:source:production"},{"name":"drushRsync:destination:development"},{"name":"drushRsync:destination:production"}]'


  # Create new permission
  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush cron",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushCron:production","drushCron:development"],
  "policies": ["User has access to project","Users role for project is Guest"]
}
EOF
}

function configure_task_uli {

  echo "configure_task_uli running"

  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  uli_task=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=Run+Drush+uli+on+Production+Environment --config $CONFIG_PATH)
  echo Checking task:drushUserLogin

  if [ "$uli_task" != "[ ]" ]; then
    echo "scopes:drushUserLogin already configured"
    return 0
  fi

  echo Configuring group:drushUserLogin

  # Create new scopes
  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/scope --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name="drushUserLogin:development"
  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/scope --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s name="drushUserLogin:production"

  # Add new scopes to resources
  TASK_RESOURCE_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/resource?name=task --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["_id"]')
  /opt/jboss/keycloak/bin/kcadm.sh update clients/$CLIENT_ID/authz/resource-server/resource/$TASK_RESOURCE_ID --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -s 'scopes=[{"name":"view"},{"name":"update"},{"name":"delete"},{"name":"add:production"},{"name":"add:development"},{"name":"addNoExec"},{"name":"drushArchiveDump:development"},{"name":"drushArchiveDump:production"},{"name":"drushSqlDump:development"},{"name":"drushSqlDump:production"},{"name":"drushCacheClear:development"},{"name":"drushCacheClear:production"},{"name":"drushCron:development"},{"name":"drushCron:production"},{"name":"drushUserLogin:development"},{"name":"drushUserLogin:production"},{"name":"drushSqlSync:source:development"},{"name":"drushSqlSync:source:production"},{"name":"drushSqlSync:destination:development"},{"name":"drushSqlSync:destination:production"},{"name":"drushRsync:source:development"},{"name":"drushRsync:source:production"},{"name":"drushRsync:destination:development"},{"name":"drushRsync:destination:production"}]'


  # Create new permissions
  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush uli on Production Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushUserLogin:production"],
  "policies": ["User has access to project","Users role for project is Maintainer"]
}
EOF

  /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Run Drush uli on Development Environment",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["task"],
  "scopes": ["drushUserLogin:development"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

}

function configure_problems_system {

  echo "configure_problems_system running"

  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  problems_system=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=View+Problems --config $CONFIG_PATH)
  echo Checking task:manageProblems

  if [ "$problems_system" != "[ ]" ]; then
    echo "Problems Permissions already configured"
    return 0
  fi

  echo Configuring Problems Permissions

  echo Creating resource problem

  echo '{"name":"problem","displayName":"problem","scopes":[{"name":"view"},{"name":"add"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -

  # Create new permissions
    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Problems",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["problem"],
  "scopes": ["view"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Problem",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["problem"],
  "scopes": ["add"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Problem",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["problem"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

}


function configure_harbor_scan_system {

  echo "configure_harbor_scan_system running"

  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  hs_system=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=View+Harbor+Scan+Match --config $CONFIG_PATH)
  echo Checking task:View Harbor Scan Match

  if [ "$hs_system" != "[ ]" ]; then
    echo "Harbor Scan Match Permissions already configured"
    return 0
  fi

  echo Configuring Harbor Scan Match Permissions

  echo Creating resource harbor_scan_match

  echo '{"name":"harbor_scan_match","displayName":"Harbor scan match","scopes":[{"name":"view"},{"name":"add"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -

  # Create new permissions
    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Harbor Scan Match",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["harbor_scan_match"],
  "scopes": ["view"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Harbor Scan Match",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["harbor_scan_match"],
  "scopes": ["add"],
  "policies": ["Users role for realm is Admin"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Harbor Scan Match",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["harbor_scan_match"],
  "scopes": ["delete"],
  "policies": ["Users role for realm is Admin"]
}
EOF

}


function configure_facts_system {

  echo "configure_facts_system running"

  CLIENT_ID=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients?clientId=api --config $CONFIG_PATH | python -c 'import sys, json; print json.load(sys.stdin)[0]["id"]')
  facts_system=$(/opt/jboss/keycloak/bin/kcadm.sh get -r lagoon clients/$CLIENT_ID/authz/resource-server/permission?name=View+Facts --config $CONFIG_PATH)
  echo Checking task:manageFacts

  if [ "$facts_system" != "[ ]" ]; then
    echo "Facts Permissions already configured"
    return 0
  fi

  echo Configuring Facts Permissions

  echo Creating resource fact

  echo '{"name":"fact","displayName":"fact","scopes":[{"name":"view"},{"name":"add"},{"name":"delete"}],"attributes":{},"uris":[],"ownerManagedAccess":""}' | /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/resource --config $CONFIG_PATH -r ${KEYCLOAK_REALM:-master} -f -

  # Create new permissions
    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "View Facts",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["fact"],
  "scopes": ["view"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Add Fact",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["fact"],
  "scopes": ["add"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

    /opt/jboss/keycloak/bin/kcadm.sh create clients/$CLIENT_ID/authz/resource-server/permission/scope --config $CONFIG_PATH -r lagoon -f - <<EOF
{
  "name": "Delete Fact",
  "type": "scope",
  "logic": "POSITIVE",
  "decisionStrategy": "UNANIMOUS",
  "resources": ["fact"],
  "scopes": ["delete"],
  "policies": ["Users role for project is Developer","User has access to project"]
}
EOF

}


function configure_keycloak {
    until is_keycloak_running; do
        echo Keycloak still not running, waiting 5 seconds
        sleep 5
    done

    # Set the config file path because $HOME/.keycloak/kcadm.config resolves to /opt/jboss/?/.keycloak/kcadm.config for some reason, causing it to fail
    CONFIG_PATH=/opt/jboss/keycloak/standalone/data/.keycloak/kcadm.config

    echo Keycloak is running, proceeding with configuration

    /opt/jboss/keycloak/bin/kcadm.sh config credentials --config $CONFIG_PATH --server http://$(hostname -i):8080/auth --user $KEYCLOAK_ADMIN_USER --password $KEYCLOAK_ADMIN_PASSWORD --realm master

    configure_lagoon_realm
    configure_opendistro_security_client
    configure_api_client
    add_group_viewall
    add_deployment_cancel
    configure_task_cron
    add_billing_modifier
    configure_task_uli
    configure_problems_system
    configure_facts_system
    configure_harbor_scan_system

    echo "Config of Keycloak done. Log in via admin user '$KEYCLOAK_ADMIN_USER' and password '$KEYCLOAK_ADMIN_PASSWORD'"
}

/opt/jboss/keycloak/bin/add-user-keycloak.sh --user $KEYCLOAK_ADMIN_USER --password $KEYCLOAK_ADMIN_PASSWORD
configure_keycloak &

/bin/sh /opt/jboss/tools/databases/change-database.sh mariadb

BIND=$(hostname --all-ip-addresses | cut -d' ' -f1)
BIND_OPTS=" -Djboss.bind.address=0.0.0.0"
BIND_OPTS+=" -Djboss.bind.address.private=0.0.0.0"
BIND_OPTS+=" -Djgroups.bind_addr=$BIND"

SYS_PROPS+=" $BIND_OPTS"

# If the server configuration parameter is not present, append the HA profile.
if echo "$@" | egrep -v -- '-c |-c=|--server-config |--server-config='; then
    SYS_PROPS+=" -c=standalone-ha.xml"
fi

# in 7.0.1+ script uploads are disabled by default. Enable them here.
# https://www.keycloak.org/docs/latest/release_notes/index.html#keycloak-7-0-1-final
SYS_PROPS+=" -Dkeycloak.profile.feature.upload_scripts=enabled"

##################
# Start Keycloak #
##################

/opt/jboss/tools/jgroups.sh

exec /opt/jboss/keycloak/bin/standalone.sh $SYS_PROPS
