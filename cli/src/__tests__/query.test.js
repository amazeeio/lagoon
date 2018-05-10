// @flow

import request from '../util/request';

import * as allConfigExports from '../config';
import { runGQLQuery } from '../query';

jest.mock('../util/request');

jest.mock('../util/fs', () => ({
  fileExists: jest.fn(async () => true),
  readFile: jest.fn(async () => 'TOKEN'),
}));

// Flow does not know which objects are actual mocks
// this function casts given parameter to JestMockFn
const _mock = (mockFn: any): JestMockFn => mockFn;

describe('runGQLQuery', () => {
  it('Should reject because of missing hostname', async () => {
    // $FlowFixMe Jest can mutate exports https://stackoverflow.com/a/42979724/1268612
    allConfigExports.config = {
      api: 'invalid-url',
    };

    try {
      await runGQLQuery({
        cerr: jest.fn(),
        query: '',
      });
    } catch (err) {
      // request should not be called in that case
      const call = _mock(request).mock.calls;
      expect(call).toEqual([]);

      expect(err).toEqual(
        new Error(
          'API URL configured under the "api" key in .lagoon.yml doesn\'t contain a valid hostname.',
        ),
      );
    }
  });

  it('should do a POST request via GraphQL', async () => {
    // $FlowFixMe Jest can mutate exports https://stackoverflow.com/a/42979724/1268612
    allConfigExports.config = null;

    const mockedRequest = _mock(request).mockImplementationOnce(() =>
      Promise.resolve({ data: 'data' }),
    );

    const result = await runGQLQuery({
      cerr: jest.fn(),
      query: 'test',
    });

    // Check if the url parsing was correct
    const call = mockedRequest.mock.calls[0][0];

    expect(call).toEqual({
      hostname: 'api.amazee.io',
      path: '/graphql',
      port: 443,
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: 'Bearer TOKEN',
      },
      body: '{"query":"test"}',
      rejectUnauthorized: false,
    });

    expect(result).toEqual({ data: 'data' });

    mockedRequest.mockClear();
  });

  it('should do a POST request to a custom API via GraphQL', async () => {
    // $FlowFixMe Jest can mutate exports https://stackoverflow.com/a/42979724/1268612
    allConfigExports.config = {
      api: 'https://www.example.com/api',
    };

    const mockedRequest = _mock(request).mockImplementationOnce(() =>
      Promise.resolve({ data: 'data' }),
    );

    const result = await runGQLQuery({
      cerr: jest.fn(),
      query: 'test',
    });

    // Check if the url parsing was correct
    const call = mockedRequest.mock.calls[0][0];

    expect(call).toEqual({
      hostname: 'www.example.com',
      path: '/api',
      port: 443,
      method: 'POST',
      headers: {
        Accept: 'application/json',
        'Content-Type': 'application/json',
        Authorization: 'Bearer TOKEN',
      },
      body: '{"query":"test"}',
      rejectUnauthorized: false,
    });

    expect(result).toEqual({ data: 'data' });
    mockedRequest.mockClear();
  });
});
