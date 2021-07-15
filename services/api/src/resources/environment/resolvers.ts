import * as R from 'ramda';
// @ts-ignore
import { sendToLagoonLogs } from '@lagoon/commons/dist/logs';
// @ts-ignore
import { createRemoveTask } from '@lagoon/commons/dist/tasks';
import { ResolverFn } from '../';
import { isPatchEmpty, query, knex } from '../../util/db';
import convertDateToMYSQLDateTimeFormat from '../../util/convertDateToMYSQLDateTimeFormat';
import { Helpers } from './helpers';
import { Sql } from './sql';
import { Sql as projectSql } from '../project/sql';
import { Helpers as projectHelpers } from '../project/helpers';
import { getFactFilteredEnvironmentIds } from '../fact/resolvers';

export const getEnvironmentByName: ResolverFn = async (
  root,
  args,
  { sqlClientPool, hasPermission }
) => {
  const rows = await query(
    sqlClientPool,
    `SELECT *
    FROM environment
    WHERE name = :name AND
    project = :project`,
    args
  );
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);
  const environment = withK8s[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: args.project
  });

  return environment;
};

export const getEnvironmentById = async (
  root,
  args,
  { sqlClientPool, hasPermission }
) => {
  const environment = await Helpers(sqlClientPool).getEnvironmentById(args.id);

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project
  });

  return environment;
};

export const getEnvironmentsByProjectId: ResolverFn = async (
  project,
  args,
  { sqlClientPool, hasPermission, keycloakGrant, models }
) => {
  const { id: pid } = project;

  let isAdmin = false;
  // The getAllProjects resolver will authorize environment access already,
  // so we can skip the request to keycloak.
  //
  // @TODO: When this performance issue is fixed for real, remove this hack as
  // it hardcodes a "everyone can view environments" authz rule.
  if (!R.prop('environmentAuthz', project)) {
    await hasPermission('environment', 'view', {
      project: pid
    });
    isAdmin = true;
  }

  let filterEnvironments = false;
  let filteredEnvironments = [];

  if (args.factFilter && args.factFilter.filters && args.factFilter.filters.length !== 0) {
    filterEnvironments = true;
    filteredEnvironments = await getFactFilteredEnvironmentIds(args.factFilter, [project.id], sqlClientPool, isAdmin);
  }

  const rows = await query(
    sqlClientPool,
    `SELECT *
    FROM environment e
    WHERE e.project = :pid
    ${args.includeDeleted ? '' : 'AND deleted = "0000-00-00 00:00:00"'}
    ${args.type ? 'AND e.environment_type = :type' : ''}
    ${filterEnvironments && filteredEnvironments.length !== 0 ? `AND e.id in (${filteredEnvironments.join(",")})` : ''}`,
    { pid, type: args.type }
  );
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);

  return withK8s;
};

export const getEnvironmentByDeploymentId: ResolverFn = async (
  { id: deployment_id },
  args,
  { sqlClientPool, hasPermission }
) => {
  const rows = await query(
    sqlClientPool,
    `SELECT e.*
    FROM deployment d
    JOIN environment e on d.environment = e.id
    JOIN project p ON e.project = p.id
    WHERE d.id = :deployment_id
    LIMIT 1`,
    { deployment_id }
  );
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);
  const environment = withK8s[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project
  });

  return environment;
};

export const getEnvironmentByTaskId: ResolverFn = async (
  { id: task_id },
  args,
  { sqlClientPool, hasPermission }
) => {
  const rows = await query(
    sqlClientPool,
    `SELECT e.*
    FROM task t
    JOIN environment e on t.environment = e.id
    JOIN project p ON e.project = p.id
    WHERE t.id = :task_id
    LIMIT 1`,
    { task_id }
  );
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);
  const environment = withK8s[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project
  });

  return environment;
};

export const getEnvironmentByBackupId: ResolverFn = async (
  { id: backup_id },
  args,
  { sqlClientPool, hasPermission }
) => {
  const rows = await query(
    sqlClientPool,
    `SELECT e.*
    FROM environment_backup eb
    JOIN environment e on eb.environment = e.id
    JOIN project p ON e.project = p.id
    WHERE eb.id = :backup_id
    LIMIT 1`,
    { backup_id }
  );
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);
  const environment = withK8s[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project
  });

  return environment;
};

export const getEnvironmentStorageByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('environment', 'storage');

  const rows = await query(
    sqlClientPool,
    `SELECT *
    FROM environment_storage es
    WHERE es.environment = :eid`,
    { eid }
  );

  return rows;
};

export const getEnvironmentStorageMonthByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { models, hasPermission }
) => {
  await hasPermission('environment', 'storage');

  return models.EnvironmentModel.environmentStorageMonthByEnvironmentId(
    eid,
    args.month
  );
};

export const getEnvironmentHoursMonthByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { models, hasPermission }
) => {
  await hasPermission('environment', 'storage');

  return models.EnvironmentModel.environmentHoursMonthByEnvironmentId(
    eid,
    args.month
  );
};

export const getEnvironmentHitsMonthByEnvironmentId: ResolverFn = async (
  { id, openshiftProjectName },
  args,
  { sqlClientPool, models, hasPermission }
) => {
  await hasPermission('environment', 'storage');

  const { name: projectName } = await projectHelpers(
    sqlClientPool
  ).getProjectByEnvironmentId(id);
  return models.EnvironmentModel.environmentHitsMonthByEnvironmentId(
    projectName,
    openshiftProjectName,
    args.month
  );
};

export const getEnvironmentServicesByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { sqlClientPool, hasPermission }
) => {
  const environment = await Helpers(sqlClientPool).getEnvironmentById(eid);
  await hasPermission('environment', 'view', {
    project: environment.project
  });

  const rows = await query(
    sqlClientPool,
    Sql.selectServicesByEnvironmentId(eid)
  );

  return rows;
};

export const getEnvironmentByOpenshiftProjectName: ResolverFn = async (
  root,
  args,
  { sqlClientPool, hasPermission }
) => {
  const rows = await query(
    sqlClientPool,
    `SELECT e.*
    FROM
    environment e
    JOIN project p ON e.project = p.id
    WHERE e.openshift_project_name = :openshift_project_name
    AND e.deleted = "0000-00-00 00:00:00"`,
    args
  );
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);
  const environment = withK8s[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project
  });

  return environment;
};

export const getEnvironmentByKubernetesNamespaceName: ResolverFn = async (
  root,
  args,
  ctx
) =>
  getEnvironmentByOpenshiftProjectName(
    root,
    {
      ...args,
      openshiftProjectName: args.kubernetesNamespaceName
    },
    ctx
  );

export const addOrUpdateEnvironment: ResolverFn = async (
  root,
  { input },
  { sqlClientPool, hasPermission, userActivityLogger }
) => {
  const inputDefaults = {
    deployHeadRef: null,
    deployTitle: null
  };

  // @ts-ignore
  const pid = input.project.toString();
  const openshiftProjectName =
    input.kubernetesNamespaceName || input.openshiftProjectName;
  if (!openshiftProjectName) {
    throw new Error(
      'Must provide kubernetesNamespaceName or openshiftProjectName'
    );
  }

  await hasPermission('environment', `addOrUpdate:${input.environmentType}`, {
    project: pid
  });

  const rows = await query(
    sqlClientPool,
    `CALL CreateOrUpdateEnvironment(
      ${input.id ? ':id' : 'NULL'},
      :name,
      :project,
      :deploy_type,
      :deploy_base_ref,
      :deploy_head_ref,
      :deploy_title,
      :environment_type,
      :openshift_project_name
    );`,
    {
      ...inputDefaults,
      ...input,
      openshiftProjectName
    }
  );

  userActivityLogger.user_action(`User updated environment`, {
    payload: {
      ...input
    }
  });

  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s([
    R.path([0, 0], rows)
  ]);
  const environment = withK8s[0];

  return environment;
};

export const addOrUpdateEnvironmentStorage: ResolverFn = async (
  root,
  { input: unformattedInput },
  { sqlClientPool, hasPermission, userActivityLogger }
) => {
  await hasPermission('environment', 'storage');

  const input = {
    ...unformattedInput,
    updated: unformattedInput.updated
      ? unformattedInput.updated
      : convertDateToMYSQLDateTimeFormat(new Date().toISOString())
  };

  const rows = await query(
    sqlClientPool,
    `CALL CreateOrUpdateEnvironmentStorage(
      :environment,
      :persistent_storage_claim,
      :bytes_used,
      :updated
    );`,
    input
  );
  const environment = R.path([0, 0], rows);
  const { name: projectName } = await projectHelpers(sqlClientPool).getProjectByEnvironmentId(environment['environment']);

  userActivityLogger.user_action(`User updated environment storage on project '${projectName}'`, {
    payload: {
      projectName,
      input
    }
  });

  return environment;
};

export const deleteEnvironment: ResolverFn = async (
  root,
  { input: { project: projectName, name, execute } },
  { sqlClientPool, hasPermission, userActivityLogger }
) => {
  const projectId = await projectHelpers(sqlClientPool).getProjectIdByName(
    projectName
  );

  const projectRows = await query(
    sqlClientPool,
    projectSql.selectProject(projectId)
  );
  const project = projectRows[0];

  const environmentRows = await query(
    sqlClientPool,
    Sql.selectEnvironmentByNameAndProject(name, projectId)
  );
  const environment = environmentRows[0];

  if (!environment) {
    throw new Error(
      `Environment "${name}" does not exist in project "${projectId}"`
    );
  }

  await hasPermission('environment', `delete:${environment.environmentType}`, {
    project: projectId
  });

  // Deleting environment in api w/o executing the openshift remove.
  // This gets called after successful removal from cluster.
  if (execute === false) {
    try {
      await hasPermission('environment', 'deleteNoExec', {
        project: projectId
      });

      await query(sqlClientPool, 'CALL DeleteEnvironment(:name, :project)', {
        name,
        project: projectId
      });

      return 'success';
    } catch (err) {
      // Not allowed to stop execution.
    }
  }

  let canDeleteProduction;
  try {
    await hasPermission('environment', 'delete:production', {
      project: projectId
    });
    canDeleteProduction = true;
  } catch (err) {
    canDeleteProduction = false;
  }

  let data: {
    [key: string]: any;
  } = {
    projectName: project.name,
    type: environment.deployType,
    openshiftProjectName: environment.openshiftProjectName,
    forceDeleteProductionEnvironment: canDeleteProduction
  };

  const meta: {
    [key: string]: any;
  } = {
    projectName: data.projectName,
    environmentName: environment.name
  };

  switch (environment.deployType) {
    case 'branch':
    case 'promote':
      data = {
        ...data,
        branch: name
      };
      break;

    case 'pullrequest':
      data = {
        ...data,
        pullrequestNumber: environment.name.replace('pr-', '')
      };
      break;

    default:
      sendToLagoonLogs(
        'error',
        data.projectName,
        '',
        'api:deleteEnvironment:error',
        meta,
        `*[${data.projectName}]* Unknown deploy type ${environment.deployType} \`${environment.name}\``
      );
      return `Error: unknown deploy type ${environment.deployType}`;
  }

  userActivityLogger.user_action(`User deleted environment '${environment.name}' on project '${projectName}'`, {
    payload: {
      projectName,
      environment,
      data
    }
  });

  await createRemoveTask(data);
  sendToLagoonLogs(
    'info',
    data.projectName,
    '',
    'api:deleteEnvironment',
    meta,
    `*[${data.projectName}]* Deleting environment \`${environment.name}\``
  );

  return 'success';
};

export const updateEnvironment: ResolverFn = async (
  root,
  { input },
  { sqlClientPool, hasPermission, userActivityLogger }
) => {
  if (isPatchEmpty(input)) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  const id = input.id;
  const curEnv = await Helpers(sqlClientPool).getEnvironmentById(id);
  const openshiftProjectName =
    input.patch.kubernetesNamespaceName || input.patch.openshiftProjectName;

  await hasPermission('environment', `update:${curEnv.environmentType}`, {
    project: curEnv.project
  });

  const newType = R.pathOr(
    curEnv.environment_type,
    ['patch', 'environmentType'],
    input
  );
  const newProject = R.pathOr(curEnv.project, ['patch', 'project'], input);

  await hasPermission('environment', `update:${newType}`, {
    project: newProject
  });

  await query(
    sqlClientPool,
    Sql.updateEnvironment({
      id,
      patch: {
        project: input.patch.project,
        deployType: input.patch.deployType,
        deployBaseRef: input.patch.deployBaseRef,
        deployHeadRef: input.patch.deployHeadRef,
        deployTitle: input.patch.deployTitle,
        environmentType: input.patch.environmentType,
        openshiftProjectName,
        route: input.patch.route,
        routes: input.patch.routes,
        monitoringUrls: input.patch.monitoringUrls,
        autoIdle: input.patch.autoIdle
      }
    })
  );

  const rows = await query(sqlClientPool, Sql.selectEnvironmentById(id));
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);

  userActivityLogger.user_action(`User updated environment '${curEnv.name}' on project '${curEnv.project}'`, {
    payload: {
      openshiftProjectName,
      patch: {
        project: input.patch.project,
        deployType: input.patch.deployType,
        deployBaseRef: input.patch.deployBaseRef,
        deployHeadRef: input.patch.deployHeadRef,
        deployTitle: input.patch.deployTitle,
        environmentType: input.patch.environmentType,
        openshiftProjectName,
        route: input.patch.route,
        routes: input.patch.routes,
        monitoringUrls: input.patch.monitoringUrls,
        autoIdle: input.patch.autoIdle,
      },
      data: withK8s
    }
  });

  return R.prop(0, withK8s);
};

export const getAllEnvironments: ResolverFn = async (
  root,
  { createdAfter, type, order },
  { sqlClientPool, hasPermission }
) => {
  await hasPermission('environment', 'viewAll');

  let queryBuilder = knex('environment').where('deleted', '0000-00-00 00:00:00');

  if (createdAfter) {
    queryBuilder = queryBuilder.andWhere('created', '>=', createdAfter);
  }

  if (type) {
    queryBuilder = queryBuilder.andWhere('environment_type', type);
  }

  if (order) {
    queryBuilder = queryBuilder.orderBy(order);
  }

  const rows = await query(sqlClientPool, queryBuilder.toString());
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);
  return withK8s;
};

export const deleteAllEnvironments: ResolverFn = async (
  root,
  args,
  { sqlClientPool, hasPermission, userActivityLogger }
) => {
  await hasPermission('environment', 'deleteAll');

  await query(sqlClientPool, Sql.truncateEnvironment());

  userActivityLogger.user_action(`User deleted all environments'`, {
    payload: {
      args
    }
  });

  // TODO: Check rows for success
  return 'success';
};

export const setEnvironmentServices: ResolverFn = async (
  root,
  { input: { environment: environmentId, services } },
  { sqlClientPool, hasPermission, userActivityLogger }
) => {
  const environment = await Helpers(sqlClientPool).getEnvironmentById(
    environmentId
  );
  await hasPermission('environment', `update:${environment.environmentType}`, {
    project: environment.project
  });

  await query(sqlClientPool, Sql.deleteServices(environmentId));

  for (const service of services) {
    await query(sqlClientPool, Sql.insertService(environmentId, service));
  }

  userActivityLogger.user_action(`User set environment services for '${environment.name}'`, {
    payload: {
      environment,
      services
    }
  });

  return query(
    sqlClientPool,
    Sql.selectServicesByEnvironmentId(environmentId)
  );
};

export const userCanSshToEnvironment: ResolverFn = async (
  root,
  args,
  { sqlClientPool, hasPermission }
) => {
  const openshiftProjectName =
    args.kubernetesNamespaceName || args.openshiftProjectName;

  const rows = await query(
    sqlClientPool,
    `SELECT e.*
    FROM
    environment e
    JOIN project p ON e.project = p.id
    WHERE e.openshift_project_name = :openshift_project_name`,
    { openshiftProjectName }
  );
  const withK8s = Helpers(sqlClientPool).aliasOpenshiftToK8s(rows);
  const environment = withK8s[0];

  if (!environment) {
    return null;
  }

  try {
    await hasPermission('environment', `ssh:${environment.environmentType}`, {
      project: environment.project
    });

    return environment;
  } catch (err) {
    return null;
  }
};
