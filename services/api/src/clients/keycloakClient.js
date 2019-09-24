// @flow

const crypto = require('crypto');
const querystring = require('querystring');
const R = require('ramda');
const axios = require('axios');
const KeycloakAdmin = require('keycloak-admin').default;
const KeycloakConfig = require('keycloak-connect/middleware/auth-utils/config');
const KeycloakGrantManager = require('../lib/keycloak-grant-manager');

// Must be initialized with `waitAndInitKeycloak`
const keycloakAdminClient = new KeycloakAdmin({
  baseUrl: 'http://keycloak:8080/auth',
  realmName: 'master',
});

const lagoonKeycloakRoute = R.compose(
  R.defaultTo('http://keycloak:8080'),
  R.find(R.test(/keycloak-/)),
  R.split(','),
  R.propOr('', 'LAGOON_ROUTES'),
)(process.env);

const lagoonKeycloakApiSecret = R.propOr(
  'no-client-secret-configured',
  'KEYCLOAK_API_CLIENT_SECRET',
  process.env,
);

const config = new KeycloakConfig({
  authServerUrl: `${lagoonKeycloakRoute}/auth`,
  realm: 'lagoon',
  clientId: 'api',
  bearerOnly: true,
  credentials: {
    secret: lagoonKeycloakApiSecret,
  },
});

const keycloakGrantManager = new KeycloakGrantManager(config);

// Override the library "validateToken" function because it is very strict about
// verifiying the ISS, which is the URI of the keycloak server. This will almost
// always fail since the URI will be different for end users authenticated via
// the web console and services communicating via backchannel.
keycloakGrantManager.validateToken = function validateToken(token, expectedType) {
  return new Promise((resolve, reject) => {
    if (!token) {
      reject(new Error('invalid token (missing)'));
    } else if (token.isExpired()) {
      reject(new Error('invalid token (expired)'));
    } else if (!token.signed) {
      reject(new Error('invalid token (not signed)'));
    } else if (token.content.typ !== expectedType) {
      reject(new Error('invalid token (wrong type)'));
    } else if (token.content.iat < this.notBefore) {
      reject(new Error('invalid token (future dated)'));
    } else if (!token.content.iss.includes('auth/realms/lagoon')) {
      reject(new Error('invalid token (wrong ISS)'));
    } else {
      const verify = crypto.createVerify('RSA-SHA256');
      // if public key has been supplied use it to validate token
      if (this.publicKey) {
        try {
          verify.update(token.signed);
          if (!verify.verify(this.publicKey, token.signature, 'base64')) {
            reject(new Error('invalid token (signature)'));
          } else {
            resolve(token);
          }
        } catch (err) {
          reject(
            new Error(
              'Misconfigured parameters while validating token. Check your keycloak.json file!',
            ),
          );
        }
      } else {
        // retrieve public KEY and use it to validate token
        this.rotation
          .getJWK(token.header.kid)
          .then(key => {
            verify.update(token.signed);
            if (!verify.verify(key, token.signature)) {
              reject(new Error('invalid token (public key signature)'));
            } else {
              resolve(token);
            }
          })
          .catch(err => {
            reject(
              new Error(
                `failed to load public key to verify token. Reason: ${
                  err.message}`,
              ),
            );
          });
      }
    }
  });
};

const impersonateUser = async (userId /* :string */) => {
  try {
    const data = {
      grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
      client_id: 'api',
      client_secret: lagoonKeycloakApiSecret,
      requested_subject: userId,
    };

    const response = await axios.post(
      `${lagoonKeycloakRoute}/auth/realms/lagoon/protocol/openid-connect/token`,
      querystring.stringify(data),
    );

    return response.data;
  } catch (err) {
    if (err.response) {
      const msg = R.pathOr('Unknown error', ['response', 'data', 'error_description'], err);
      throw new Error(`Could not get impersonate user ${userId}: ${msg}`);
    }
  }
};

module.exports = {
  keycloakAdminClient,
  keycloakGrantManager,
  impersonateUser,
};
