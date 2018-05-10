// @flow

import { red } from 'chalk';
import R from 'ramda';

type Cerr = typeof console.error;
type GraphQLError = { message: string };

const formatError = err =>
  R.cond([
    // If a `stack` property exists on the error object, use that
    [R.prop('stack'), R.prop('stack')],
    // If the error is an object without a `stack` property and isn't null, stringify it
    [
      R.allPass([R.is(Object), R.complement(R.equals(null))]),
      errWithoutStack => JSON.stringify(errWithoutStack, null, 2),
    ],
    // Otherwise, just pass it back unmodified
    [R.T, R.identity],
  ])(err);

export function printErrors(
  cerr: Cerr,
  ...errors: Array<string | Error | GraphQLError>
): number {
  R.compose(R.forEach(cerr), R.map(red), R.map(formatError))(errors);
  return 1;
}

export function printNoConfigError(cerr: Cerr): number {
  return printErrors(
    cerr,
    '.lagoon.yml config file not found. Please create one with "lagoon init".\nOnline documentation: https://github.com/amazeeio/lagoon/blob/master/cli/README.md#lagoon-init',
  );
}

export function printProjectConfigurationError(cerr: Cerr): number {
  return printErrors(
    cerr,
    'No project configured. Please create a .lagoon.yml config file with "lagoon init" or pass a project to this command via the --project option.\nOnline documentation: https://github.com/amazeeio/lagoon/blob/master/cli/README.md#lagoon-init',
  );
}

export function printGraphQLErrors(
  cerr: Cerr,
  ...errors: Array<GraphQLError>
): number {
  if (
    R.find(R.propEq('message', 'Unauthorized - Bearer Token Required'))(errors)
  ) {
    return printErrors(
      cerr,
      'No authentication token found. Please log in first with "lagoon login".\nOnline documentation: https://github.com/amazeeio/lagoon/blob/master/cli/README.md#lagoon-login',
    );
  }
  const errorMessage =
    R.length(errors) === 1
      ? 'Oops! The lagoon API returned an error:'
      : 'Oops! The lagoon API returned errors:';
  return printErrors(cerr, errorMessage, ...errors);
}
