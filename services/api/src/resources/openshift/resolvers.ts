import * as R from 'ramda';
import { ResolverFn } from '../';
import {
  query,
  prepare,
  isPatchEmpty,
} from '../../util/db';
import { Sql } from './sql';

const attrFilter = async (hasPermission, entity) => {
  try {
    await hasPermission('openshift', 'view:token');
    return entity;
  } catch (err) {
    return R.omit(['token'], entity);
  }
};

export const addOpenshift: ResolverFn = async (
  args,
  { input },
  { sqlClient, hasPermission },
) => {
  await hasPermission('openshift', 'add');

  const prep = prepare(
    sqlClient,
    `CALL CreateOpenshift(
        :id,
        :name,
        :console_url,
        ${input.token ? ':token' : 'NULL'},
        ${input.routerPattern ? ':router_pattern' : 'NULL'},
        ${input.projectUser ? ':project_user' : 'NULL'},
        ${input.sshHost ? ':ssh_host' : 'NULL'},
        ${input.sshPort ? ':ssh_port' : 'NULL'},
        ${input.monitoringConfig ? ':monitoring_config' : 'NULL'}
      );
    `,
  );

  const rows = await query(sqlClient, prep(input));
  const openshift = R.path([0, 0], rows);

  return openshift;
};

export const deleteOpenshift: ResolverFn = async (
  args,
  { input },
  { sqlClient, hasPermission },
) => {
  await hasPermission('openshift', 'delete');

  const prep = prepare(sqlClient, 'CALL deleteOpenshift(:name)');
  await query(sqlClient, prep(input));

  // TODO: maybe check rows for changed result
  return 'success';
};

export const getAllOpenshifts: ResolverFn = async (
  root,
  args,
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('openshift', 'viewAll');

  const prep = prepare(
    sqlClient,
    `SELECT
        o.*
      FROM openshift o
    `,
  );

  const rows = await query(sqlClient, prep(args));

  return rows;
};

export const getOpenshiftByProjectId: ResolverFn = async (
  { id: pid },
  args,
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('openshift', 'view', {
    project: pid,
  });

  const prep = prepare(
    sqlClient,
    `SELECT
        o.*
      FROM project p
      JOIN openshift o ON o.id = p.openshift
      WHERE p.id = :pid
    `,
  );

  const rows = await query(sqlClient, prep({ pid }));

  return rows ? attrFilter(hasPermission, rows[0]) : null;
};

export const updateOpenshift: ResolverFn = async (
  root,
  { input },
  { sqlClient, hasPermission },
) => {
  await hasPermission('openshift', 'update');

  const oid = input.id.toString();

  if (isPatchEmpty(input)) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  await query(sqlClient, Sql.updateOpenshift(input));
  const rows = await query(sqlClient, Sql.selectOpenshift(oid));

  return R.prop(0, rows);
};