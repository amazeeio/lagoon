// @flow

const R = require('ramda');
const {
  ApolloServer,
  AuthenticationError,
  makeExecutableSchema,
} = require('apollo-server-express');
const { applyMiddleware } = require('graphql-middleware');
const {
  getCredentialsForLegacyToken,
  getCredentialsForKeycloakToken,
} = require('./util/auth');
const logger = require('./logger');
const typeDefs = require('./typeDefs');
const resolvers = require('./resolvers');

const schema = makeExecutableSchema({ typeDefs, resolvers });

const operationBlacklist = R.split(
  ',',
  R.propOr('', 'LAGOON_API_OPERATION_BLACKLIST', process.env),
);

const evaluateOperationsBlacklist = async (
  resolve,
  parent,
  args,
  context,
  info,
) => {
  const {
    credentials: { role },
  } = context;

  if (role !== 'admin' && R.contains(info.fieldName, operationBlacklist)) {
    throw new Error('Unauthorized.');
  }

  const result = await resolve(parent, args, context, info);
  return result;
};

const schemaWithMiddleware = applyMiddleware(schema, {
  Query: evaluateOperationsBlacklist,
  Mutation: evaluateOperationsBlacklist,
  Subscription: evaluateOperationsBlacklist,
});

const apolloServer = new ApolloServer({
  schema: schemaWithMiddleware,
  debug: process.env.NODE_ENV === 'development',
  introspection: true,
  subscriptions: {
    onConnect: async (connectionParams, webSocket) => {
      const token = R.prop('authToken', connectionParams);
      let credentials;

      if (!token) {
        throw new AuthenticationError('Auth token missing.');
      }

      try {
        credentials = await getCredentialsForKeycloakToken(token);
      } catch (e) {
        // It might be a legacy token, so continue on.
        logger.debug(`Keycloak token auth failed: ${e.message}`);
      }

      try {
        if (!credentials) {
          credentials = await getCredentialsForLegacyToken(token);
        }
      } catch (e) {
        throw new AuthenticationError(e.message);
      }

      // Add credentials to context.
      return { credentials };
    },
  },
  context: ({ req, connection }) => {
    // Websocket requests
    if (connection) {
      // onConnect must always provide connection.context.
      return connection.context;
    }

    // HTTP requests
    if (!connection) {
      return {
        // Express middleware must always provide req.credentials.
        credentials: req.credentials,
      };
    }
  },
  formatError: error => {
    logger.warn(error.message);
    return {
      message: error.message,
      locations: error.locations,
      path: error.path,
    };
  },
});

module.exports = apolloServer;
