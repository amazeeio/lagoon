/*
 * Copyright 2015-2018 _floragunn_ GmbH
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 */
/*
 * Portions Copyright 2019 Amazon.com, Inc. or its affiliates. All Rights Reserved.
 *
 * Licensed under the Apache License, Version 2.0 (the "License").
 * You may not use this file except in compliance with the License.
 * A copy of the License is located at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * or in the "license" file accompanying this file. This file is distributed
 * on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
 * express or implied. See the License for the specific language governing
 * permissions and limitations under the License.
 */

import _ from 'lodash';
import filterAuthHeaders from '../auth/filter_auth_headers';
import SecurityPlugin from './opendistro_security_plugin';
import AuthenticationError from '../auth/errors/authentication_error';
import wrapElasticsearchError from './errors/wrap_elasticsearch_error';
import User from '../auth/user';

/**
 * The Security  backend.
 */
export default class SecurityBackend {

    constructor(server, serverConfig, esConfig) {
        // client for authentication and authorization
        const config = Object.assign({ plugins: [SecurityPlugin], auth: true }, server.config().get('elasticsearch'));
        this._cluster = server.plugins.elasticsearch.createCluster('security', config);

        // the es config for later use
        this._esconfig = esConfig;
    }

    /**
     * "Simulate" the old _noAuthClient behaviour by calling the client with an empty request,
     * i.e. with no request headers
     * @param endPoint
     * @param clientParams
     * @param options
     * @returns {Promise<{(params: BulkIndexDocumentsParams, callback: (error: any, response: any) => void): void; (params: BulkIndexDocumentsParams): Promise<any>}>}
     * @private
     */
    async _client(endPoint, clientParams, options) {
        let request = {};
        // Kibana will overwrite the clientParams.headers if we don't add them like this
        if (clientParams.headers) {
            request.headers = clientParams.headers;
        }
        return await this._cluster.callWithRequest(request, endPoint, clientParams, options);
    }

    async authenticate(credentials) {
        const authHeader = Buffer.from(`${credentials.username}:${credentials.password}`).toString('base64');
        try {
            let response = await this._client('opendistro_security.authinfo', {
                headers: {
                    authorization: `Basic ${authHeader}`
                }
            });
            return new User(credentials.username, credentials, credentials, response.roles, response.backend_roles, response.tenants, response.user_requested_tenant);
        } catch(error) {
            if (error.status == 401) {
                throw new AuthenticationError("Invalid username or password");
            } else {
                throw new Error(error.message);
            }
        }
    }

    async authenticateWithHeader(headerName, headerValue, whitelistedHeadersAndValues, additionalAuthHeaders = {}) {

        try {
            const credentials = {
                headerName: headerName,
                headerValue: headerValue
            };

            let headers = filterAuthHeaders(additionalAuthHeaders, this._esconfig.requestHeadersWhitelist);

            // For anonymous auth, we wouldn't have any value here
            if (headerValue) {
                headers[headerName] = headerValue
                if (whitelistedHeadersAndValues != null && whitelistedHeadersAndValues != undefined) {
                    // Add all whitelisted headers that are not headerName -> i.e. basic auth
                    // Skipping over the headerName key because we want session credentials, not
                    // request credentials.
                    for (var key in whitelistedHeadersAndValues) {
                        if (key != headerName) {
                            headers[key] = whitelistedHeadersAndValues[key];
                        }
                    }
                }
            }

            const response = await this._client('opendistro_security.authinfo', {
                headers: headers
            });
            return new User(response.user_name, credentials, null, response.roles, response.backend_roles, response.tenants, response.user_requested_tenant);
        } catch(error) {
            if (error.status == 401) {
                throw new AuthenticationError("Invalid username or password");
            } else {
                throw new Error(error.message);
            }
        }

    }

    /**
     * A wrapper for authinfo() when we expect a response to be used for a cookie
     * @param headers
     * @param credentials
     * @returns {Promise<User>}
     */
    async authenticateWithHeaders(headers, credentials = {}, additionalAuthHeaders = {}) {
        headers = {
            ...filterAuthHeaders(additionalAuthHeaders, this._esconfig.requestHeadersWhitelist),
            ...headers,
        };
        try {
            const response = await this._client('opendistro_security.authinfo', {
                headers: headers
            });
            return new User(response.user_name, credentials, null, response.roles, response.backend_roles, response.tenants, response.user_requested_tenant);
        } catch(error) {
            if (error.status == 401) {
                throw new AuthenticationError("Invalid username or password");
            } else {
                throw new Error(error.message);
            }
        }

    }

    buildSessionResponse(credentials, authInfoResponse) {
        return new User(authInfoResponse.user_name, credentials, null, authInfoResponse.roles, authInfoResponse.backend_roles, authInfoResponse.tenants, authInfoResponse.user_requested_tenant);
    }

    async authinfo(headers) {
        try {
            const authHeaders = filterAuthHeaders(headers, this._esconfig.requestHeadersWhitelist);
            const response = await this._client('opendistro_security.authinfo', {
                headers: authHeaders
            });
            return response
        } catch(error) {
            throw wrapElasticsearchError(error);
        }
    }

    getSamlHeader() {

        return this._client('opendistro_security.authinfo', {})
            .then(() => {})
            .catch((error) => {

                if (! error.wwwAuthenticateDirective) {
                    throw error;
                }

                try {
                    let locationRegExp = /location="(.*?)"/;
                    let requestIdRegExp = /requestId="(.*?)"/;

                    return {
                        location: locationRegExp.exec(error.wwwAuthenticateDirective)[1],
                        requestId: requestIdRegExp.exec(error.wwwAuthenticateDirective)[1]
                    }

                } catch (error) {
                    throw new AuthenticationError();
                }
            });
    }

    /**
     * Exchanges a SAMLResponse from the IdP against a token for internal use
     * @param RequestId
     * @param SAMLResponse
     * @param acsEndpoint
     * @returns {Promise<Promise<*>|*>}
     */
    async authtoken(RequestId, SAMLResponse, acsEndpoint = null) {
        const body = {
            RequestId,
            SAMLResponse,
            acsEndpoint
        };

        return this._client('opendistro_security.authtoken', {
            body: body,
        });
    }

    async getKibanaInfoWithInternalUser() {
        try {
            return await this._cluster.callWithInternalUser('opendistro_security.multitenancyinfo', {});
        } catch(error) {
            throw wrapElasticsearchError(error);
        }
    }

    async multitenancyinfo(headers) {
        try {
            const authHeaders = filterAuthHeaders(headers, this._esconfig.requestHeadersWhitelist);
            const response = await this._client('opendistro_security.multitenancyinfo', {
                headers: authHeaders
            });
            return response
        } catch(error) {
            throw wrapElasticsearchError(error);
        }
    }

    async systeminfo(headers) {
        try {
            const authHeaders = filterAuthHeaders(headers, this._esconfig.requestHeadersWhitelist);
            const response = await this._client('opendistro_security.systeminfo', {
                headers: authHeaders
            });

            return response
        } catch(error) {
            throw wrapElasticsearchError(error);
        }
    }

    async getTenantInfoWithInternalUser() {
        try {
            return await this._cluster.callWithInternalUser('opendistro_security.tenantinfo', {});
        } catch(error) {
            throw wrapElasticsearchError(error);
        }
    }

    async getTenantInfoWithInternalUser() {
        try {
            return await this._cluster.callWithInternalUser('opendistro_security.tenantinfo', {});
        } catch(error) {
            throw wrapElasticsearchError(error);
        }
    }

    async getTenantInfo(headers) {
        try {
            const authHeaders = filterAuthHeaders(headers, this._esconfig.requestHeadersWhitelist);
            const response = await this._client('opendistro_security.tenantinfo', {
                headers: authHeaders
            });
            return response
        } catch(error) {
            throw wrapElasticsearchError(error);
        }
    }

    /**
     * @deprecated, use the sessionPlugin instead
     * @param user
     * @returns {Promise<{authorization: string}>}
     */
    async getAuthHeaders(user) {
        const credentials = user.credentials;
        const authHeader = Buffer.from(`${credentials.username}:${credentials.password}`).toString('base64');
        return {
            'authorization': `Basic ${authHeader}`
        };
    }

    getAuthHeaders(username, password) {
        const authHeader = Buffer.from(`${username}:${password}`).toString('base64');
        return {
            'authorization': `Basic ${authHeader}`
        };
    }

    getUser(username, password) {
        var credentials = {"username": username, "password": password};
        var user = new User(credentials.username, credentials, credentials, [], {});
        return user;
    }

    getServerUser() {
        return this.getUser(this._esconfig.username, this._esconfig.password);
    }

    updateAndGetTenantPreferences(request, user, tenant) {

        var prefs = request.state.security_preferences;
        // no prefs cookie present
        if (!prefs) {
            var newPrefs = {};
            newPrefs[user] = tenant;
            return newPrefs;
        }
        prefs[user] = tenant;
        return prefs;
    }

    getTenantByPreference(request, username, tenants, preferredTenants, globalEnabled, privateEnabled) {
        // delete user from tenants first to check if we have a tenant to choose from at all
        // keep original preferences untouched, we need the original values again
        // http://stackoverflow.com/questions/728360/how-do-i-correctly-clone-a-javascript-object
        var tenantsCopy = JSON.parse(JSON.stringify(tenants));
        delete tenantsCopy[username];

        // sanity check
        if (!globalEnabled && !privateEnabled && _.isEmpty(tenantsCopy)) {
            return null;
        }
        // get users preferred tenant
        var prefs = request.state.security_preferences;

        if (prefs) {
            var preferredTenant = prefs[username];

            // user has a preferred tenant, check if it is accessible
            if (preferredTenant && tenants[preferredTenant] != undefined) {
                return preferredTenant;
            }

            // special case: in tenants returned from SECURITY, the private tenant is
            // the username of the logged in user, but the header value is __user__
            if ((preferredTenant == "__user__" || preferredTenant == "private") && tenants[username] != undefined && privateEnabled) {
                return "__user__";
            }

            if ((preferredTenant == "global" || preferredTenant === '' ) && globalEnabled) {
                return "";
            }

        }

        // no preference in cookie, or tenant no accessible anymore, evaluate preferredTenants from kibana config
        if (preferredTenants && !_.isEmpty(preferredTenants)) {
            for (var i = 0; i < preferredTenants.length; i++) {
                var check = preferredTenants[i].toLowerCase();

                if (globalEnabled && (check === 'global' || check === '__global__')) {
                    return '';
                }

                if (privateEnabled && (check === 'private' || check === '__user__') && tenants[username] != undefined) {
                    return '__user__';
                }

                if (tenants[check] != undefined) {
                    return check;
                }
                if (check.toLowerCase() == "private" && privateEnabled) {
                    return "__user__";
                }
            }
        }

        // no pref in cookie, no preferred tenant in kibana, use GLOBAL, Private or the first tenant in the list
        if (globalEnabled) {
            return "";
        }

        if (privateEnabled) {
            return "__user__";
        } else {
            delete tenants[username];
        }

        // sort tenants by putting the keys in an array first
        var tenantkeys = [];
        var k;

        for (k in tenants) {
            /* LAGOON start fix */
            if (globalEnabled === false && k == "global_tenant") {
                continue;
            }
            /* LAGOON end fix */
            tenantkeys.push(k);
        }
        tenantkeys.sort();
        return tenantkeys[0];
    }

    validateTenant(username, requestedTenant, tenants, globalEnabled, privateEnabled) {
        // delete user from tenants first to check if we have a tenant to choose from at all
        // keep original preferences untouched, we need the original values again
        // http://stackoverflow.com/questions/728360/how-do-i-correctly-clone-a-javascript-object
        var tenantsCopy = JSON.parse(JSON.stringify(tenants));
        delete tenantsCopy[username];

        // sanity check: no global, no private, no other tenants -> no tenant available
        if (!globalEnabled && !privateEnabled && _.isEmpty(tenantsCopy)) {
            return null;
        }

        // requested tenant accessible for user
        if (tenants[requestedTenant] != undefined) {
            return requestedTenant;
        }

        if ((requestedTenant == "__user__" || requestedTenant == "private") && tenants[username] && privateEnabled) {
            return "__user__";
        }

        if ((requestedTenant == "global" || requestedTenant === '') && globalEnabled) {
            return "";
        }

        return null;
    }



}