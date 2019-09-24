// @flow


const R = require('ramda');
const getFieldNames = require('graphql-list-fields');
const {
  impersonateUser,
} = require('../../clients/keycloakClient');
const {
  pubSub,
  createEnvironmentFilteredSubscriber,
} = require('../../clients/pubSub');
const {
  knex,
  prepare,
  query,
  isPatchEmpty,
} = require('../../util/db');
const logger = require('../../logger');
const Sql = require('./sql');
const EVENTS = require('./events');
const Helpers = require('./helpers');
const environmentHelpers = require('../environment/helpers');
const envValidators = require('../environment/validators');
const projectHelpers = require('../project/helpers');

/* ::

import type {ResolversObj} from '../';

*/

const taskStatusTypeToString = R.cond([
  [R.equals('ACTIVE'), R.toLower],
  [R.equals('SUCCEEDED'), R.toLower],
  [R.equals('FAILED'), R.toLower],
  [R.T, R.identity],
]);

const getTasksByEnvironmentId = async (
  { id: eid },
  { id: filterId },
  {
    sqlClient,
    hasPermission,
  },
  info,
) => {
  const environment = await environmentHelpers(sqlClient).getEnvironmentById(eid);
  await hasPermission('task', 'view', {
    project: environment.project,
  });

  const prep = prepare(
    sqlClient,
    `SELECT
        t.*, e.project
      FROM environment e
      JOIN task t on e.id = t.environment
      WHERE e.id = :eid
    `,
  );

  const rows = await query(sqlClient, prep({ eid }));
  const newestFirst = R.sort(R.descend(R.prop('created')), rows);

  const requestedFields = getFieldNames(info);

  return newestFirst
    .filter(row => {
      if (R.isNil(filterId) || R.isEmpty(filterId)) {
        return true;
      }

      return row.id === String(filterId);
    })
    .map(row => {
      if (R.contains('logs', requestedFields)) {
        return Helpers(sqlClient).injectLogs(row);
      }

      return {
        ...row,
        logs: null,
      };
    });
};

const getTaskByRemoteId = async (
  root,
  { id },
  {
    sqlClient,
    hasPermission,
  },
) => {
  const queryString = knex('task')
    .where('remote_id', '=', id)
    .toString();

  const rows = await query(sqlClient, queryString);
  const task = R.prop(0, rows);

  if (!task) {
    return null;
  }

  const rowsPerms = await query(sqlClient, Sql.selectPermsForTask(task.id));
  await hasPermission('task', 'view', {
    project: R.path(['0', 'pid'], rowsPerms),
  });

  return Helpers(sqlClient).injectLogs(task);
};

const addTask = async (
  root,
  {
    input: {
      id,
      name,
      status: unformattedStatus,
      created,
      started,
      completed,
      environment,
      service,
      command,
      remoteId,
      execute: executeRequest,
    },
  },
  { sqlClient, hasPermission },
) => {
  const status = taskStatusTypeToString(unformattedStatus);

  await envValidators(sqlClient).environmentExists(environment);
  const envPerm = await environmentHelpers(sqlClient).getEnvironmentById(environment);
  await hasPermission('task', `add:${envPerm.environmentType}`, {
    project: envPerm.project,
  });

  let execute;
  try {
    await hasPermission('task', 'addNoExec', {
      project: envPerm.project,
    });
    execute = executeRequest;
  } catch (err) {
    execute = true;
  }

  const taskData = await Helpers(sqlClient).addTask({
    id,
    name,
    status,
    created,
    started,
    completed,
    environment,
    service,
    command,
    remoteId,
    execute,
  });

  return taskData;
};

const deleteTask = async (
  root,
  { input: { id } },
  {
    sqlClient,
    hasPermission,
  },
) => {
  const rows = await query(sqlClient, Sql.selectPermsForTask(id));
  await hasPermission('task', 'delete', {
    project: R.path(['0', 'pid'], rows),
  });

  await query(sqlClient, Sql.deleteTask(id));

  return 'success';
};

const updateTask = async (
  root,
  {
    input: {
      id,
      patch,
      patch: {
        name,
        status: unformattedStatus,
        created,
        started,
        completed,
        environment,
        service,
        command,
        remoteId,
      },
    },
  },
  {
    sqlClient,
    hasPermission,
  },
) => {
  const status = taskStatusTypeToString(unformattedStatus);

  // Check access to modify task as it currently stands
  const curPerms = await query(sqlClient, Sql.selectPermsForTask(id));
  await hasPermission('task', 'update', {
    project: R.path(['0', 'pid'], curPerms),
  });

  if (environment) {
    // Check access to modify task as it will be updated
    const envPerm = await environmentHelpers(sqlClient).getEnvironmentById(environment);
    await hasPermission('task', 'update', {
      project: envPerm.project,
    });
  }

  if (isPatchEmpty({ patch })) {
    throw new Error('Input patch requires at least 1 attribute');
  }

  await query(
    sqlClient,
    Sql.updateTask({
      id,
      patch: {
        name,
        status,
        created,
        started,
        completed,
        environment,
        service,
        command,
        remoteId,
      },
    }),
  );

  const rows = await query(sqlClient, Sql.selectTask(id));
  const taskData = await Helpers(sqlClient).injectLogs(R.prop(0, rows));

  pubSub.publish(EVENTS.TASK.UPDATED, taskData);

  return taskData;
};

const taskDrushArchiveDump = async (
  root,
  { environment: environmentId },
  { sqlClient, hasPermission },
) => {
  await envValidators(sqlClient).environmentExists(environmentId);
  await envValidators(sqlClient).environmentHasService(environmentId, 'cli');
  const envPerm = await environmentHelpers(sqlClient).getEnvironmentById(environmentId);
  await hasPermission('task', `drushArchiveDump:${envPerm.environmentType}`, {
    project: envPerm.project,
  });

  const command = String.raw`file="/tmp/$LAGOON_SAFE_PROJECT-$LAGOON_GIT_SAFE_BRANCH-$(date --iso-8601=seconds).tar" && drush ard --destination=$file && \
TOKEN="$(ssh -p $TASK_SSH_PORT -t lagoon@$TASK_SSH_HOST token)" && curl -sS "$TASK_API_HOST"/graphql \
-H "Authorization: Bearer $TOKEN" \
-F operations='{ "query": "mutation ($task: Int!, $files: [Upload!]!) { uploadFilesForTask(input:{task:$task, files:$files}) { id files { filename } } }", "variables": { "task": '"$TASK_DATA_ID"', "files": [null] } }' \
-F map='{ "0": ["variables.files.0"] }' \
-F 0=@$file; rm -rf $file;
`;

  const taskData = await Helpers(sqlClient).addTask({
    name: 'Drush archive-dump',
    environment: environmentId,
    service: 'cli',
    command,
    execute: true,
  });

  return taskData;
};

const taskDrushSqlDump = async (
  root,
  { environment: environmentId },
  { sqlClient, hasPermission },
) => {
  await envValidators(sqlClient).environmentExists(environmentId);
  await envValidators(sqlClient).environmentHasService(environmentId, 'cli');
  const envPerm = await environmentHelpers(sqlClient).getEnvironmentById(environmentId);
  await hasPermission('task', `drushSqlDump:${envPerm.environmentType}`, {
    project: envPerm.project,
  });

  const command = String.raw`file="/tmp/$LAGOON_SAFE_PROJECT-$LAGOON_GIT_SAFE_BRANCH-$(date --iso-8601=seconds).sql" && drush sql-dump --result-file=$file --gzip && \
TOKEN="$(ssh -p $TASK_SSH_PORT -t lagoon@$TASK_SSH_HOST token)" && curl -sS "$TASK_API_HOST"/graphql \
-H "Authorization: Bearer $TOKEN" \
-F operations='{ "query": "mutation ($task: Int!, $files: [Upload!]!) { uploadFilesForTask(input:{task:$task, files:$files}) { id files { filename } } }", "variables": { "task": '"$TASK_DATA_ID"', "files": [null] } }' \
-F map='{ "0": ["variables.files.0"] }' \
-F 0=@$file.gz; rm -rf $file.gz
`;

  const taskData = await Helpers(sqlClient).addTask({
    name: 'Drush sql-dump',
    environment: environmentId,
    service: 'cli',
    command,
    execute: true,
  });

  return taskData;
};

const taskDrushCacheClear = async (
  root,
  { environment: environmentId },
  { sqlClient, hasPermission },
) => {
  await envValidators(sqlClient).environmentExists(environmentId);
  await envValidators(sqlClient).environmentHasService(environmentId, 'cli');
  const envPerm = await environmentHelpers(sqlClient).getEnvironmentById(environmentId);
  await hasPermission('task', `drushCacheClear:${envPerm.environmentType}`, {
    project: envPerm.project,
  });

  const command =
    'drupal_version=$(drush status drupal-version --format=list) && \
  if [ ${drupal_version%.*.*} == "8" ]; then \
    drush cr; \
  elif [ ${drupal_version%.*} == "7" ]; then \
    drush cc all; \
  else \
    echo "could not clear cache for found Drupal Version ${drupal_version}"; \
    exit 1; \
  fi';

  const taskData = await Helpers(sqlClient).addTask({
    name: 'Drush cache-clear',
    environment: environmentId,
    service: 'cli',
    command,
    execute: true,
  });

  return taskData;
};

const taskDrushSqlSync = async (
  root,
  {
    sourceEnvironment: sourceEnvironmentId,
    destinationEnvironment: destinationEnvironmentId,
  },
  { sqlClient, dataSources, hasPermission },
) => {
  await envValidators(sqlClient).environmentExists(sourceEnvironmentId);
  await envValidators(sqlClient).environmentExists(destinationEnvironmentId);
  await envValidators(sqlClient).environmentsHaveSameProject([
    sourceEnvironmentId,
    destinationEnvironmentId,
  ]);
  await envValidators(sqlClient).environmentHasService(
    sourceEnvironmentId,
    'cli',
  );

  const sourceEnvironment = await environmentHelpers(
    sqlClient,
  ).getEnvironmentById(sourceEnvironmentId);
  const destinationEnvironment = await environmentHelpers(
    sqlClient,
  ).getEnvironmentById(destinationEnvironmentId);

  await hasPermission('task', `drushSqlSync:source:${sourceEnvironment.environmentType}`, {
    project: sourceEnvironment.project,
  });
  await hasPermission('task', `drushSqlSync:destination:${destinationEnvironment.environmentType}`, {
    project: destinationEnvironment.project,
  });

  // Attempt to run the task as the source projects default maintainer user
  let lagoonToken;
  try {
    const sourceProject = await projectHelpers(sqlClient).getProjectById(sourceEnvironment.project);
    const maintainerUser = await Helpers(sqlClient, dataSources.UserModel, dataSources.GroupModel).getProjectMaintainer(sourceProject.name);
    const grant = await impersonateUser(maintainerUser.id);
    lagoonToken = grant.access_token;
  } catch (err) {
    logger.error(`Could not impersonate default maintainer for project ${sourceEnvironment.project}: ${err}`);
    lagoonToken = null;
  }

  const taskData = await Helpers(sqlClient).addTask({
    name: `Sync DB ${sourceEnvironment.name} -> ${destinationEnvironment.name}`,
    environment: destinationEnvironmentId,
    service: 'cli',
    command: `drush -y sql-sync @${sourceEnvironment.name} @self`,
    execute: true,
    lagoonToken,
  });

  return taskData;
};

const taskDrushRsyncFiles = async (
  root,
  {
    sourceEnvironment: sourceEnvironmentId,
    destinationEnvironment: destinationEnvironmentId,
  },
  { sqlClient, dataSources, hasPermission },
) => {
  await envValidators(sqlClient).environmentExists(sourceEnvironmentId);
  await envValidators(sqlClient).environmentExists(destinationEnvironmentId);
  await envValidators(sqlClient).environmentsHaveSameProject([
    sourceEnvironmentId,
    destinationEnvironmentId,
  ]);
  await envValidators(sqlClient).environmentHasService(
    sourceEnvironmentId,
    'cli',
  );

  const sourceEnvironment = await environmentHelpers(
    sqlClient,
  ).getEnvironmentById(sourceEnvironmentId);
  const destinationEnvironment = await environmentHelpers(
    sqlClient,
  ).getEnvironmentById(destinationEnvironmentId);

  await hasPermission('task', `drushRsync:source:${sourceEnvironment.environmentType}`, {
    project: sourceEnvironment.project,
  });
  await hasPermission('task', `drushRsync:destination:${destinationEnvironment.environmentType}`, {
    project: destinationEnvironment.project,
  });

  // Attempt to run the task as the source projects default maintainer user
  let lagoonToken;
  try {
    const sourceProject = await projectHelpers(sqlClient).getProjectById(sourceEnvironment.project);
    const maintainerUser = await Helpers(sqlClient, dataSources.UserModel, dataSources.GroupModel).getProjectMaintainer(sourceProject.name);
    const grant = await impersonateUser(maintainerUser.id);
    lagoonToken = grant.access_token;
  } catch (err) {
    logger.error(`Could not impersonate default maintainer for project ${sourceEnvironment.project}: ${err}`);
    lagoonToken = null;
  }

  const taskData = await Helpers(sqlClient).addTask({
    name: `Sync files ${sourceEnvironment.name} -> ${
      destinationEnvironment.name
    }`,
    environment: destinationEnvironmentId,
    service: 'cli',
    command: `drush -y rsync @${sourceEnvironment.name}:%files @self:%files`,
    execute: true,
    lagoonToken,
  });

  return taskData;
};

const taskSubscriber = createEnvironmentFilteredSubscriber([
  EVENTS.TASK.ADDED,
  EVENTS.TASK.UPDATED,
]);

const Resolvers /* : ResolversObj */ = {
  getTasksByEnvironmentId,
  getTaskByRemoteId,
  addTask,
  deleteTask,
  updateTask,
  taskDrushArchiveDump,
  taskDrushSqlDump,
  taskDrushCacheClear,
  taskDrushSqlSync,
  taskDrushRsyncFiles,
  taskSubscriber,
};

module.exports = Resolvers;
