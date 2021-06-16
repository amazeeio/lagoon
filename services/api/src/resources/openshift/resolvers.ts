import * as R from 'ramda';
import { ResolverFn } from '../';
import { query, isPatchEmpty } from '../../util/db';
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
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('openshift', 'add');

  const rows = await query(
    sqlClientPool,
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
    );`,
    input
  );
  const openshift = R.path([0, 0], rows);

  return openshift;
};

export const deleteOpenshift: ResolverFn = async (
  args,
  { input },
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('openshift', 'delete');

  await query(sqlClientPool, 'CALL deleteOpenshift(:name)', input);

  // TODO: maybe check rows for changed result
  return 'success';
};

export const getAllOpenshifts: ResolverFn = async (
  root,
  args,
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('openshift', 'viewAll');

  return query(sqlClientPool, 'SELECT * FROM openshift');
};

export const getOpenshiftByProjectId: ResolverFn = async (
  { id: pid },
  args,
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('openshift', 'view', {
    project: pid
  });

  const rows = await query(
    sqlClientPool,
    `SELECT o.*
    FROM project p
    JOIN openshift o ON o.id = p.openshift
    WHERE p.id = :pid
    `,
    {
      pid
    }
  );

  return rows ? attrFilter(hasPermission, rows[0]) : null;
};

export const updateOpenshift: ResolverFn = async (
  root,
  { input },
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('openshift', 'update');

  const oid = input.id.toString();

  if (isPatchEmpty(input)) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  await query(sqlClientPool, Sql.updateOpenshift(input));
  const rows = await query(sqlClientPool, Sql.selectOpenshiftById(oid));

  return R.prop(0, rows);
};

export const deleteAllOpenshifts: ResolverFn = async (
  root,
  args,
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('openshift', 'deleteAll');

  await query(sqlClientPool, Sql.truncateOpenshift());

  // TODO: Check rows for success
  return 'success';
};
