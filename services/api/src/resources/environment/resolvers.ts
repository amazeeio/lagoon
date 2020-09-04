import * as R from 'ramda';
import { sendToLagoonLogs } from '@lagoon/commons/dist/logs';
import { createRemoveTask } from '@lagoon/commons/dist/tasks';
import { ResolverFn } from '../';
import { isPatchEmpty, prepare, query, whereAnd } from '../../util/db';
import { Helpers } from './helpers';
import { Sql } from './sql';
import { Sql as projectSql } from '../project/sql';
import { Helpers as projectHelpers } from '../project/helpers';

const deployTypeToString = R.cond([
  [R.equals('BRANCH'), R.toLower],
  [R.equals('PULLREQUEST'), R.toLower],
  [R.equals('PROMOTE'), R.toLower],
  [R.T, R.identity],
]);

const envTypeToString = R.cond([
  [R.equals('PRODUCTION'), R.toLower],
  [R.equals('DEVELOPMENT'), R.toLower],
  [R.T, R.identity],
]);

export const getEnvironmentByName: ResolverFn = async (
  root,
  args,
  { sqlClient, hasPermission },
) => {
  const str = `
    SELECT *
    FROM environment
    WHERE name = :name AND
    project = :project
  `;

  const prep = prepare(sqlClient, str);

  const rows = await query(sqlClient, prep(args));
  const environment = rows[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: args.project,
  });

  return environment;
};

export const getEnvironmentById = async (
  root,
  args,
  { sqlClient, hasPermission },
) => {
    const environment = await Helpers(sqlClient).getEnvironmentById(args.id);

    if (!environment) {
      return null;
    }

    await hasPermission('environment', 'view', {
        project: environment.project,
    });

    const rows = await query(sqlClient, Sql.selectEnvironmentById(args.id));
    return rows[0];
};

export const getEnvironmentsByProjectId: ResolverFn = async (
  project,
  unformattedArgs,
  { sqlClient, hasPermission },
) => {
  const { id: pid } = project;
  const args = R.compose(R.over(R.lensProp('type'), envTypeToString))(
    unformattedArgs,
  ) as any;

  // The getAllProjects resolver will authorize environment access already,
  // so we can skip the request to keycloak.
  //
  // @TODO: When this performance issue is fixed for real, remove this hack as
  // it hardcodes a "everyone can view environments" authz rule.
  if (!R.prop('environmentAuthz', project)) {
    await hasPermission('environment', 'view', {
      project: pid,
    });
  }

  const prep = prepare(
    sqlClient,
    `
      SELECT *
      FROM environment e
      WHERE e.project = :pid
      ${args.includeDeleted ? '' : 'AND deleted = "0000-00-00 00:00:00"'}
      ${args.type ? 'AND e.environment_type = :type' : ''}
    `,
  );

  const rows = await query(sqlClient, prep({ pid, type: args.type }));

  return rows;
};

export const getEnvironmentByDeploymentId: ResolverFn = async (
  { id: deployment_id },
  args,
  { sqlClient, hasPermission },
) => {
  const prep = prepare(
    sqlClient,
    `SELECT
        e.*
      FROM deployment d
      JOIN environment e on d.environment = e.id
      JOIN project p ON e.project = p.id
      WHERE d.id = :deployment_id
      LIMIT 1
    `,
  );

  const rows = await query(sqlClient, prep({ deployment_id }));

  const environment = rows[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project,
  });

  return environment;
};

export const getEnvironmentByTaskId: ResolverFn = async (
  { id: task_id },
  args,
  { sqlClient, hasPermission },
) => {
  const prep = prepare(
    sqlClient,
    `SELECT
        e.*
      FROM task t
      JOIN environment e on t.environment = e.id
      JOIN project p ON e.project = p.id
      WHERE t.id = :task_id
      LIMIT 1
    `,
  );

  const rows = await query(sqlClient, prep({ task_id }));

  const environment = rows[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project,
  });

  return environment;
};

export const getEnvironmentByBackupId: ResolverFn = async (
  { id: backup_id },
  args,
  { sqlClient, hasPermission },
) => {
  const prep = prepare(
    sqlClient,
    `SELECT
        e.*
      FROM environment_backup eb
      JOIN environment e on eb.environment = e.id
      JOIN project p ON e.project = p.id
      WHERE eb.id = :backup_id
      LIMIT 1
    `,
  );

  const rows = await query(sqlClient, prep({ backup_id }));

  const environment = rows[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project,
  });

  return environment;
};

export const getEnvironmentStorageByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { sqlClient, hasPermission },
) => {
  await hasPermission('environment', 'storage');

  const prep = prepare(
    sqlClient,
    `
      SELECT *
      FROM environment_storage es
      WHERE es.environment = :eid
    `,
  );

  const rows = await query(sqlClient, prep({ eid }));

  return rows;
};

export const getEnvironmentStorageMonthByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { models, hasPermission },
) => {
  await hasPermission('environment', 'storage');

  return models.EnvironmentModel.environmentStorageMonthByEnvironmentId(eid, args.month);
};

export const getEnvironmentHoursMonthByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { models, hasPermission },
) => {
  await hasPermission('environment', 'storage');

  return models.EnvironmentModel.environmentHoursMonthByEnvironmentId(eid, args.month);
};

export const getEnvironmentHitsMonthByEnvironmentId: ResolverFn = async (
  { openshiftProjectName },
  args,
  { models, hasPermission },
) => {
  await hasPermission('environment', 'storage');

  return models.EnvironmentModel.environmentHitsMonthByEnvironmentId(openshiftProjectName, args.month);
};

export const getEnvironmentServicesByEnvironmentId: ResolverFn = async (
  { id: eid },
  args,
  { sqlClient, hasPermission },
) => {
  const environment = await Helpers(sqlClient).getEnvironmentById(eid);
  await hasPermission('environment', 'view', {
    project: environment.project,
  });

  const rows = await query(sqlClient, Sql.selectServicesByEnvironmentId(eid));

  return rows;
};

export const getEnvironmentByOpenshiftProjectName: ResolverFn = async (
  root,
  args,
  { sqlClient, hasPermission },
) => {
  const str = `
    SELECT
      e.*
    FROM
      environment e
      JOIN project p ON e.project = p.id
    WHERE e.openshift_project_name = :openshift_project_name
    AND e.deleted = "0000-00-00 00:00:00"
  `;

  const prep = prepare(sqlClient, str);

  const rows = await query(sqlClient, prep(args));

  const environment = rows[0];

  if (!environment) {
    return null;
  }

  await hasPermission('environment', 'view', {
    project: environment.project,
  });

  return environment;
};

export const addOrUpdateEnvironment: ResolverFn = async (
  root,
  { input: unformattedInput },
  { sqlClient, hasPermission },
) => {
  const input = R.compose(
    R.over(R.lensProp('environmentType'), envTypeToString),
    // @ts-ignore
    R.over(R.lensProp('deployType'), deployTypeToString),
    R.over(R.lensProp('deployHeadRef'), R.defaultTo(null)),
    R.over(R.lensProp('deployTitle'), R.defaultTo(null)),
  )(unformattedInput);

  const pid = input.project.toString();

  await hasPermission('environment', `addOrUpdate:${input.environmentType}`, {
    project: pid,
  });

  const prep = prepare(
    sqlClient,
    `
      CALL CreateOrUpdateEnvironment(
        :id,
        :name,
        :project,
        :deploy_type,
        :deploy_base_ref,
        :deploy_head_ref,
        :deploy_title,
        :environment_type,
        :openshift_project_name
      );
    `,
  );

  const rows = await query(sqlClient, prep(input));
  const environment = R.path([0, 0], rows);

  return environment;
};

export const addOrUpdateEnvironmentStorage: ResolverFn = async (
  root,
  { input },
  { sqlClient, hasPermission },
) => {
  await hasPermission('environment', 'storage');

  const prep = prepare(
    sqlClient,
    `
      CALL CreateOrUpdateEnvironmentStorage(
        :environment,
        :persistent_storage_claim,
        :bytes_used
      );
    `,
  );

  const rows = await query(sqlClient, prep(input));
  const environment = R.path([0, 0], rows);

  return environment;
};

export const deleteEnvironment: ResolverFn = async (
  root,
  { input: { project: projectName, name, execute } },
  { sqlClient, hasPermission },
) => {
  const projectId = await projectHelpers(sqlClient).getProjectIdByName(
    projectName,
  );

  const projectRows = await query(
    sqlClient,
    projectSql.selectProject(projectId),
  );
  const project = projectRows[0];

  const environmentRows = await query(
    sqlClient,
    Sql.selectEnvironmentByNameAndProject(name, projectId),
  );
  const environment = environmentRows[0];

  if (!environment) {
    throw new Error(
      `Environment "${name}" does not exist in project "${projectId}"`,
    );
  }

  await hasPermission('environment', `delete:${environment.environmentType}`, {
    project: projectId,
  });

  // Deleting environment in api w/o executing the openshift remove.
  // This gets called by openshiftremove service after successful remove.
  if (execute === false) {
    try {
      await hasPermission('environment', 'deleteNoExec', {
        project: projectId,
      });

      const prep = prepare(
        sqlClient,
        'CALL DeleteEnvironment(:name, :project)',
      );
      await query(sqlClient, prep({ name, project: projectId }));

      return 'success';
    } catch (err) {
      // Not allowed to stop execution.
    }
  }

  let canDeleteProduction;
  try {
    await hasPermission('environment', 'delete:production', {
      project: projectId,
    });
    canDeleteProduction = true;
  } catch (err) {
    canDeleteProduction = false;
  }

  let data: {
    [key: string]: any
  } = {
    projectName: project.name,
    type: environment.deployType,
    forceDeleteProductionEnvironment: canDeleteProduction,
  };

  const meta: {
    [key: string]: any
  } = {
    projectName: data.projectName,
    environmentName: environment.name,
  };

  switch (environment.deployType) {
    case 'branch':
    case 'promote':
      data = {
        ...data,
        branch: name,
      };
      break;

    case 'pullrequest':
      data = {
        ...data,
        pullrequestNumber: environment.name.replace('pr-', ''),
      };
      break;

    default:
      sendToLagoonLogs(
        'error',
        data.projectName,
        '',
        'api:deleteEnvironment:error',
        meta,
        `*[${data.projectName}]* Unknown deploy type ${environment.deployType} \`${environment.name}\``,
      );
      return `Error: unknown deploy type ${environment.deployType}`;
  }

  await createRemoveTask(data);
  sendToLagoonLogs(
    'info',
    data.projectName,
    '',
    'api:deleteEnvironment',
    meta,
    `*[${data.projectName}]* Deleting environment \`${environment.name}\``,
  );

  return 'success';
};

export const updateEnvironment: ResolverFn = async (
  root,
  { input: unformattedInput },
  { sqlClient, hasPermission },
) => {
  const input = R.compose(
    R.over(R.lensPath(['patch', 'environmentType']), envTypeToString),
    R.over(R.lensPath(['patch', 'deployType']), deployTypeToString),
  )(unformattedInput) as any;

  if (isPatchEmpty(input)) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  const id = input.id;
  const curEnv = await Helpers(sqlClient).getEnvironmentById(id);

  await hasPermission('environment', `update:${curEnv.environmentType}`, {
    project: curEnv.project,
  });

  const newType = R.pathOr(
    curEnv.environment_type,
    ['patch', 'environmentType'],
    input,
  );
  const newProject = R.pathOr(curEnv.project, ['patch', 'project'], input);

  await hasPermission('environment', `update:${newType}`, {
    project: newProject,
  });

  await query(sqlClient, Sql.updateEnvironment(input));

  const rows = await query(sqlClient, Sql.selectEnvironmentById(id));

  return R.prop(0, rows);
};

export const getAllEnvironments: ResolverFn = async (
  root,
  unformattedArgs,
  { sqlClient, hasPermission },
) => {
  const args = R.compose(R.over(R.lensProp('type'), envTypeToString))(
    unformattedArgs,
  ) as any;

  await hasPermission('environment', 'viewAll');

  const where = whereAnd([
    args.createdAfter ? 'created >= :created_after' : '',
    args.type ? 'environment_type = :type' : '',
    'deleted = "0000-00-00 00:00:00"',
  ]);

  const order = args.order ? ` ORDER BY ${R.toLower(args.order)} ASC` : '';

  const prep = prepare(sqlClient, `SELECT * FROM environment ${where}${order}`);
  const rows = await query(sqlClient, prep(args));

  return rows;
};

export const setEnvironmentServices: ResolverFn = async (
  root,
  { input: { environment: environmentId, services } },
  { sqlClient, hasPermission },
) => {
  const environment = await Helpers(sqlClient).getEnvironmentById(
    environmentId,
  );
  await hasPermission('environment', `update:${environment.environmentType}`, {
    project: environment.project,
  });

  await query(sqlClient, Sql.deleteServices(environmentId));

  for (const service of services) {
    await query(sqlClient, Sql.insertService(environmentId, service));
  }

  return query(sqlClient, Sql.selectServicesByEnvironmentId(environmentId));
};

export const userCanSshToEnvironment: ResolverFn = async (
  root,
  args,
  { sqlClient, hasPermission },
) => {
  const str = `
    SELECT
      e.*
    FROM
      environment e
      JOIN project p ON e.project = p.id
    WHERE e.openshift_project_name = :openshift_project_name
  `;

  const prep = prepare(sqlClient, str);

  const rows = await query(sqlClient, prep(args));

  const environment = rows[0];

  if (!environment) {
    return null;
  }

  try {
    await hasPermission('environment', `ssh:${environment.environmentType}`, {
      project: environment.project,
    });

    return environment;
  } catch (err) {
    return null;
  }
};
