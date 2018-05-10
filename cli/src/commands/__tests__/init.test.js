// @flow

import { fileExists } from '../../util/fs';
import { handler } from '../init';

jest.mock('fs');
jest.mock('../../config');
jest.mock('../../util/fs');

function _mock(fn: any): JestMockFn {
  return fn;
}

describe('handler', () => {
  // TODO: Also write a test where it bails
  it('should overwrite existing config file if overwrite option passed as true', async () => {
    _mock(fileExists).mockImplementationOnce(() => Promise.resolve(true));

    const clog = jest.fn();
    const cerr = jest.fn();
    const cwd = 'some/path';

    const code = await handler({
      _: [],
      $0: '',
      cwd,
      clog,
      cerr,
      argv: {
        overwrite: true,
        project: 'test_project',
      },
    });

    expect(code).toBe(0);
    expect(clog.mock.calls).toMatchSnapshot();
  });

  it('should not overwrite config file when `overwrite` option set to false', async () => {
    _mock(fileExists).mockImplementationOnce(() => Promise.resolve(true));

    const clog = jest.fn();
    const cerr = jest.fn();
    const cwd = 'some/path';

    const code = await handler({
      _: [],
      $0: '',
      cwd,
      clog,
      cerr,
      argv: {
        overwrite: false,
        project: 'test_project',
      },
    });

    expect(code).toBe(1);
    expect(cerr.mock.calls).toMatchSnapshot();
  });

  it('should write default yaml to given cwd + .lagoon.yml', async () => {
    _mock(fileExists).mockImplementationOnce(() => Promise.resolve(false));

    const clog = jest.fn();
    const cerr = jest.fn();
    const cwd = 'some/path';

    const code = await handler({
      _: [],
      $0: '',
      cwd,
      clog,
      cerr,
      argv: {
        overwrite: false,
        project: 'test_project',
      },
    });

    expect(code).toBe(0);
    expect(clog.mock.calls).toMatchSnapshot();
  });
});
