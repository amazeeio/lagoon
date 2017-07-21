// @flow

/* eslint-disable no-console */

import os from 'os';
import path from 'path';
import { sshConnect, sshExec } from '../util/ssh';
import { fileExists, readFile, unlink } from '../util/fs';

import typeof Yargs from 'yargs';
import type { BaseArgs } from './index';

const name = 'logout';
const description =
  'Invalidate the authentication token in $HOME/.ioauth and delete the file';

export async function setup(yargs: Yargs): Promise<Object> {
  return yargs.usage(`$0 ${name} - ${description}`).argv;
}

type Args = BaseArgs;

export async function run(args: Args): Promise<number> {
  const { clog = console.log } = args;

  // TODO: We need to make the ssh key path lookup smarter or request it via prompt.
  const homeDir = os.homedir();
  const privateKeyFilePath = path.join(homeDir, '.ssh', 'id_rsa');
  const privateKey = await readFile(privateKeyFilePath);
  const connection = await sshConnect({
    host: process.env.SSH_AUTH_HOST || 'auth.amazee.io',
    port: Number(process.env.SSH_AUTH_PORT) || 2020,
    username: process.env.SSH_AUTH_USER || 'api',
    privateKey,
  });

  await sshExec(connection, 'logout');
  const tokenFilePath = path.join(homeDir, '.ioauth');
  if (await fileExists(tokenFilePath)) {
    await unlink(tokenFilePath);
  }

  clog('Logout successful');

  // Be responsible and close the connection after our transaction.
  connection.end();

  return 0;
}

export default {
  setup,
  name,
  description,
  run,
};
