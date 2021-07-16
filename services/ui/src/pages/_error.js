import React from 'react';
import PropTypes from 'prop-types';
import Head from 'next-server/head';
import StatusLayout from 'layouts/StatusLayout';

const statusCodes = {
  400: 'Bad Request',
  401: 'Not Authenticated',
  404: 'This page could not be found',
  500: 'Internal Server Error',
  501: 'Not Implemented'
};

/**
 * Displays an error page, given a status code and optional error message.
 */
export default class Error extends React.Component {
  static displayName = 'ErrorPage';

  static getInitialProps({ res, err }) {
    const statusCode =
      res && res.statusCode ? res.statusCode : err ? err.statusCode : 404;
    return { statusCode };
  }

  render() {
    const { statusCode, errorMessage } = this.props;
    const title = this.props.title || statusCodes[statusCode] || 'An unexpected error has occurred';

    return (
      <StatusLayout>
        <Head>
          <title>
            {statusCode}: {title}
          </title>
        </Head>
        <h2>{title}</h2>
        {errorMessage && <p>{errorMessage}</p>}
      </StatusLayout>
    );
  }
}

export class ErrorNoHeader extends React.Component {
    static displayName = 'ErrorNoHeader';

    render() {
        const { errorMessage } = this.props;
        return (errorMessage && <p>{errorMessage}</p>);
    }
}

if (process.env.NODE_ENV !== 'production') {
  Error.propTypes = {
    errorMessage: PropTypes.string,
  };
}
