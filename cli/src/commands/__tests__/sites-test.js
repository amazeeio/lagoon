// @flow

import { runGQLQuery } from '../../query';
import { listSites } from '../sites';

jest.mock('../../query');

const _mock = (mockFn: any): JestMockFn => mockFn;

const mockResponse = {
  data: {
    siteGroupByName: {
      sites: [
        {
          siteName: 'site1',
          siteBranch: 'dev',
          siteEnvironment: 'development',
        },
        {
          siteName: 'site2',
          siteBranch: 'dev',
          siteEnvironment: 'development',
        },
        {
          siteName: 'site1',
          siteBranch: 'prod',
          siteEnvironment: 'production',
        },
      ],
    },
  },
};

describe('listSites', () => {
  it('should list sites as given by GraphQL', async () => {
    _mock(runGQLQuery).mockImplementationOnce(() =>
      Promise.resolve(mockResponse),
    );

    const clog = jest.fn();
    const cerr = jest.fn();

    const code = await listSites({
      sitegroup: 'some_sitegroup',
      clog,
      cerr,
    });

    expect(code).toBe(0);
    expect(clog.mock.calls).toMatchSnapshot();
  });

  it('should show error message if GraphQL returns errors', async () => {
    _mock(runGQLQuery).mockImplementationOnce(() =>
      Promise.resolve({
        errors: [{ message: 'Something, something missing parameter X' }],
      }),
    );

    const clog = jest.fn();
    const cerr = jest.fn();

    const code = await listSites({
      sitegroup: 'some_sitegroup',
      clog,
      cerr,
    });

    expect(code).toBe(1);
    expect(cerr.mock.calls).toMatchSnapshot();
  });

  it('should show message for non-existing sites', async () => {
    _mock(runGQLQuery).mockImplementationOnce(() => Promise.resolve({}));

    const clog = jest.fn();
    const cerr = jest.fn();

    const code = await listSites({
      sitegroup: 'some_sitegroup',
      clog,
      cerr,
    });

    expect(code).toBe(0);
    expect(clog.mock.calls).toMatchSnapshot();
  });
});
