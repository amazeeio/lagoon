// @flow

import type { AmazeeConfig } from '../parseConfig';
import typeof Yargs from 'yargs';

export type BaseArgs = {
  _: Array<string>,
  $0: string,
  config: ?AmazeeConfig,
  cwd: string,
  clog: typeof console.log,
  cerr: typeof console.error,
};

export type CommandModule = {
  name: string,
  description: string,
  setup?: (yargs: Yargs) => Promise<Object>,
  run: (argv: Object) => Promise<number>,
};

import login from './login';
import logout from './logout';
import sites from './sites';
import info from './info';
import init from './init';

export default ([login, logout, sites, init, info]: Array<CommandModule>);
