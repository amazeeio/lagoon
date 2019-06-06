// @flow

const R = require('ramda');
const { isPatchEmpty, prepare, query } = require('../../util/db');
const { validateSshKey, getSshKeyFingerprint } = require('.');
const Sql = require('./sql');

/* ::

import type {Cred, ResolversObj} from '../';

*/

const formatSshKey = ({ keyType, keyValue }) => `${keyType} ${keyValue}`;

const sshKeyTypeToString = R.cond([
  [R.equals('SSH_RSA'), R.always('ssh-rsa')],
  [R.equals('SSH_ED25519'), R.always('ssh-ed25519')],
  [R.T, R.identity],
]);

const getCustomerSshKeys = async (
  root,
  args,
  { credentials: { role }, sqlClient },
) => {
  if (role !== 'admin') {
    throw new Error('Unauthorized');
  }
  const rows = await query(
    sqlClient,
    Sql.selectAllCustomerSshKeys({ credentials: { role } }),
  );
  return R.map(R.prop('sshKey'), rows);
};

const getProjectSshKeys = async (
  root,
  args,
  { credentials: { role }, sqlClient },
) => {
  if (role !== 'admin') {
    throw new Error('Unauthorized');
  }
  const rows = await query(
    sqlClient,
    Sql.selectAllProjectSshKeys({ credentials: { role } }),
  );
  return R.map(R.prop('sshKey'), rows);
};

const getUserSshKeys = async (
  { id: userId },
  args,
  { credentials: { role, userId: credentialsUserId }, sqlClient },
) => {
  if (role !== 'admin' && !R.equals(credentialsUserId, userId)) {
    throw new Error('Unauthorized.');
  }

  const queryString = Sql.selectSshKeysByUserId(userId);
  const rows = await query(sqlClient, queryString);
  return rows;
};

const addSshKey = async (
  root,
  {
    input: {
      id, name, keyValue, keyType: unformattedKeyType, userId,
    },
  },
  { credentials: { role, userId: credentialsUserId }, sqlClient },
) => {
  const keyType = sshKeyTypeToString(unformattedKeyType);
  const keyFormatted = formatSshKey({ keyType, keyValue });

  if (!validateSshKey(keyFormatted)) {
    throw new Error('Invalid SSH key format! Please verify keyType + keyValue');
  }

  if (role !== 'admin' && !R.equals(credentialsUserId, userId)) {
    throw new Error('Unauthorized.');
  }

  const {
    info: { insertId },
  } = await query(
    sqlClient,
    Sql.insertSshKey({
      id,
      name,
      keyValue,
      keyType,
      keyFingerprint: getSshKeyFingerprint(keyFormatted),
    }),
  );
  await query(sqlClient, Sql.addSshKeyToUser({ sshKeyId: insertId, userId }));
  const rows = await query(sqlClient, Sql.selectSshKey(insertId));

  return R.prop(0, rows);
};

const updateSshKey = async (
  root,
  {
    input: {
      id,
      patch,
      patch: { name, keyType: unformattedKeyType, keyValue },
    },
  },
  { credentials: { role, userId }, sqlClient },
) => {
  const keyType = sshKeyTypeToString(unformattedKeyType);

  if (role !== 'admin') {
    const rows = await query(sqlClient, Sql.selectSshKeyIdsByUserId(userId));
    const sshKeyIds = R.map(
      R.pipe(
        R.prop('skid'),
        parseInt,
      ),
      rows,
    );
    if (!R.contains(id, sshKeyIds)) {
      throw new Error('Unauthorized.');
    }
  }

  if (isPatchEmpty({ patch })) {
    throw new Error('Input patch requires at least 1 attribute');
  }

  let keyFingerprint = null;
  if (keyType || keyValue) {
    const keyFormatted = formatSshKey({ keyType, keyValue });

    if (!validateSshKey(keyFormatted)) {
      throw new Error(
        'Invalid SSH key format! Please verify keyType + keyValue',
      );
    }

    keyFingerprint = getSshKeyFingerprint(keyFormatted);
  }

  await query(
    sqlClient,
    Sql.updateSshKey({
      id,
      patch: {
        name, keyType, keyValue, keyFingerprint,
      },
    }),
  );
  const rows = await query(sqlClient, Sql.selectSshKey(id));

  return R.prop(0, rows);
};

const deleteSshKey = async (
  root,
  { input: { name } },
  { credentials: { role, userId }, sqlClient },
) => {
  if (role !== 'admin') {
    // Map from sshKey name to id and throw on several error cases
    const skidResult = await query(sqlClient, Sql.selectSshKeyIdByName(name));

    const amount = R.length(skidResult);
    if (amount > 1) {
      throw new Error(
        `Multiple sshKey candidates for '${name}' (${amount} found). Do nothing.`,
      );
    }

    if (amount === 0) {
      throw new Error(`Not found: '${name}'`);
    }

    const skid = R.path(['0', 'id'], skidResult);

    const rows = await query(sqlClient, Sql.selectSshKeyIdsByUserId(userId));
    const sshKeyIds = R.map(R.prop('skid'), rows);
    if (!R.contains(skid, sshKeyIds)) {
      throw new Error('Unauthorized.');
    }
  }

  const prep = prepare(sqlClient, 'CALL DeleteSshKey(:name)');
  await query(sqlClient, prep({ name }));

  return 'success';
};

const deleteAllSshKeys = async (
  root,
  args,
  { credentials: { role }, sqlClient },
) => {
  if (role !== 'admin') {
    throw new Error('Unauthorized.');
  }

  await query(sqlClient, Sql.truncateSshKey());

  // TODO: Check rows for success
  return 'success';
};

const removeAllSshKeysFromAllUsers = async (
  root,
  args,
  { credentials: { role }, sqlClient },
) => {
  if (role !== 'admin') {
    throw new Error('Unauthorized.');
  }

  await query(sqlClient, Sql.truncateUserSshKey());

  // TODO: Check rows for success
  return 'success';
};

const Resolvers /* : ResolversObj */ = {
  getCustomerSshKeys,
  getProjectSshKeys,
  getUserSshKeys,
  addSshKey,
  updateSshKey,
  deleteSshKey,
  deleteAllSshKeys,
  removeAllSshKeysFromAllUsers,
};

module.exports = Resolvers;
