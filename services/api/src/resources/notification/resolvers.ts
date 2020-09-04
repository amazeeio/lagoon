import * as R from 'ramda';
import { ResolverFn } from '../';
import { query, prepare, isPatchEmpty } from '../../util/db';
import { Helpers as projectHelpers } from '../project/helpers';
import { Helpers } from './helpers';
import { Sql } from './sql';
import { Sql as projectSql } from '../project/sql';
import DEFAULTS from './defaults';
import convertDateToMYSQLDateTimeFormat from '../../util/convertDateToMYSQLDateTimeFormat';
import { notificationIntToContentType, notificationContentTypeToInt } from '@lagoon/commons/dist/notificationCommons';

const notificationTypeToString = R.cond([
  [R.equals('MICROSOFTTEAMS'), R.toLower],
  [R.equals('ROCKETCHAT'), R.toLower],
  [R.equals('EMAIL'), R.toLower],
  [R.equals('SLACK'), R.toLower],
  [R.T, R.identity],
]);

const notificationContentTypeToString = R.cond([
  [R.equals('DEPLOYMENT'), R.toLower],
  [R.equals('PROBLEM'), R.toLower],
  [R.T, R.identity],
]);

export const addNotificationMicrosoftTeams: ResolverFn = async (root, { input }, { sqlClient, hasPermission }) => {
  await hasPermission('notification', 'add');

  const prep = prepare(
    sqlClient,
    'CALL CreateNotificationMicrosoftTeams(:name, :webhook)',
  );

  const rows = await query(sqlClient, prep(input));
  const microsoftTeams = R.path([0, 0], rows);

  return microsoftTeams;
};

export const addNotificationEmail: ResolverFn = async (root, { input }, { sqlClient, hasPermission }) => {
  await hasPermission('notification', 'add');

  const prep = prepare(
    sqlClient,
    'CALL CreateNotificationEmail(:name, :email_address)',
  );

  const rows = await query(sqlClient, prep(input));
  const email = R.path([0, 0], rows);

  return email;
};

export const addNotificationRocketChat: ResolverFn = async (root, { input }, { sqlClient, hasPermission }) => {
  await hasPermission('notification', 'add');

  const prep = prepare(
    sqlClient,
    'CALL CreateNotificationRocketChat(:name, :webhook, :channel)',
  );

  const rows = await query(sqlClient, prep(input));
  const rocketchat = R.path([0, 0], rows);

  return rocketchat;
};

export const addNotificationSlack: ResolverFn = async (root, { input }, { sqlClient, hasPermission }) => {
  await hasPermission('notification', 'add');

  const prep = prepare(
    sqlClient,
    'CALL CreateNotificationSlack(:name, :webhook, :channel)',
  );

  const rows = await query(sqlClient, prep(input));
  const slack = R.path([0, 0], rows);

  return slack;
};

export const addNotificationToProject: ResolverFn = async (
  root,
  { input: unformattedInput },
  {
    sqlClient,
    hasPermission,
  },
) => {

  const input = [
    R.over(R.lensProp('notificationType'), notificationTypeToString),
    R.over(R.lensProp('contentType'), notificationContentTypeToString),
    R.over(R.lensProp('notificationSeverityThreshold'), notificationContentTypeToInt),
  ].reduce((argumentsToProcess, functionToApply) => functionToApply(argumentsToProcess), unformattedInput);


  const pid = await projectHelpers(sqlClient).getProjectIdByName(input.project);
  await hasPermission('project', 'addNotification', {
    project: pid,
  });

  const rows = await query(sqlClient, Sql.selectProjectNotification(input));
  const projectNotification = R.path([0], rows) as any;
  if (!projectNotification) {
    throw new Error(
      `Could not find notification '${input.notificationName}' of type '${
        input.notificationType
      }'`,
    );
  }
  projectNotification.notificationType = input.notificationType;
  projectNotification.contentType = input.contentType || DEFAULTS.NOTIFICATION_CONTENT_TYPE;
  projectNotification.notificationSeverityThreshold = input.notificationSeverityThreshold || DEFAULTS.NOTIFICATION_SEVERITY_THRESHOLD;

  await query(sqlClient, Sql.createProjectNotification(projectNotification));
  const select = await query(
    sqlClient,
    Sql.selectProjectById(projectNotification.pid),
  );
  const project = R.path([0], select);
  return project;
};

export const deleteNotificationMicrosoftTeams: ResolverFn = async (
    root,
    { input },
    {
      sqlClient,
      hasPermission,
    },
  ) => {
    await hasPermission('notification', 'delete');

    const { name } = input;

    const nids = await Helpers(sqlClient).getAssignedNotificationIds({
      name,
      type: 'microsoftTeams',
    });

    if (R.length(nids) > 0) {
      throw new Error("Can't delete notification linked to projects");
    }

    const prep = prepare(sqlClient, 'CALL DeleteNotificationMicrosoftTeams(:name)');
    await query(sqlClient, prep(input));

    // TODO: maybe check rows for changed result
    return 'success';
  };

export const deleteNotificationEmail: ResolverFn = async (
  root,
  { input },
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('notification', 'delete');

  const { name } = input;

  const nids = await Helpers(sqlClient).getAssignedNotificationIds({
    name,
    type: 'email',
  });

  if (R.length(nids) > 0) {
    throw new Error("Can't delete notification linked to projects");
  }

  const prep = prepare(sqlClient, 'CALL DeleteNotificationEmail(:name)');
  await query(sqlClient, prep(input));

  // TODO: maybe check rows for changed result
  return 'success';
};

export const deleteNotificationRocketChat: ResolverFn = async (
  root,
  { input },
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('notification', 'delete');

  const { name } = input;

  const nids = await Helpers(sqlClient).getAssignedNotificationIds({
    name,
    type: 'rocketchat',
  });

  if (R.length(nids) > 0) {
    throw new Error("Can't delete notification linked to projects");
  }

  const prep = prepare(sqlClient, 'CALL DeleteNotificationRocketChat(:name)');
  await query(sqlClient, prep(input));

  // TODO: maybe check rows for changed result
  return 'success';
};

export const deleteNotificationSlack: ResolverFn = async (
  root,
  { input },
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('notification', 'delete');

  const { name } = input;

  const nids = await Helpers(sqlClient).getAssignedNotificationIds({
    name,
    type: 'slack',
  });

  if (R.length(nids) > 0) {
    throw new Error("Can't delete notification linked to projects");
  }

  const prep = prepare(sqlClient, 'CALL DeleteNotificationSlack(:name)');
  await query(sqlClient, prep(input));

  // TODO: maybe check rows for changed result
  return 'success';
};

export const removeNotificationFromProject: ResolverFn = async (
  root,
  { input: unformattedInput },
  {
    sqlClient,
    hasPermission,
  },
) => {
  const input = R.compose(
    R.over(R.lensProp('notificationType'), notificationTypeToString),
  )(unformattedInput) as any;

  const select = await query(sqlClient, projectSql.selectProjectByName(input.project));
  const project = R.path([0], select) as any;

  await hasPermission('project', 'removeNotification', {
    project: project.id,
  });

  await query(
    sqlClient,
    Sql.deleteProjectNotification(input),
  );

  return project;
};

const NOTIFICATION_TYPES = ['slack', 'rocketchat', 'microsoftteams', 'email'];

export const getNotificationsByProjectId: ResolverFn = async (
  { id: pid },
  unformattedArgs,
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('notification', 'view', {
    project: pid,
  });

  const args = [
    R.over(R.lensProp('type'), notificationTypeToString),
    R.over(R.lensProp('contentType'), notificationContentTypeToString),
    R.over(R.lensProp('notificationSeverityThreshold'), notificationContentTypeToInt),
  ].reduce((argumentsToProcess, functionToApply) => functionToApply(argumentsToProcess), unformattedArgs);

  const { type: argsType,
    contentType = DEFAULTS.NOTIFICATION_CONTENT_TYPE,
    notificationSeverityThreshold = DEFAULTS.NOTIFICATION_SEVERITY_THRESHOLD,
  } = args;

  // Types to collect notifications from all different
  // notification type tables
  const types = argsType == null ? NOTIFICATION_TYPES : [argsType];

  const results = await Promise.all(
    types.map(type =>
      query(
        sqlClient,
        Sql.selectNotificationsByTypeByProjectId(
          {
            type,
            pid,
            contentType,
            notificationSeverityThreshold,
          },
        ),
      ),
    ),
  );

  let resultArray =  results.reduce((acc, rows) => {
    if (rows == null) {
      return acc;
    }
    return R.concat(acc, rows);
  }, []);

  return resultArray.map((e) => R.over(R.lensProp('notificationSeverityThreshold'), notificationIntToContentType, e))
};

export const updateNotificationMicrosoftTeams: ResolverFn = async (
    root,
    { input },
    {
      sqlClient,
      hasPermission,
    },
  ) => {
    await hasPermission('notification', 'update');

    const { name } = input;

    if (isPatchEmpty(input)) {
      throw new Error('input.patch requires at least 1 attribute');
    }

    await query(sqlClient, Sql.updateNotificationMicrosoftTeams(input));
    const rows = await query(
      sqlClient,
      Sql.selectNotificationMicrosoftTeamsByName(name),
    );

    return R.prop(0, rows);
  };

export const updateNotificationEmail: ResolverFn = async (
  root,
  { input },
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('notification', 'update');

  const { name } = input;

  if (isPatchEmpty(input)) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  await query(sqlClient, Sql.updateNotificationEmail(input));
  const rows = await query(
    sqlClient,
    Sql.selectNotificationEmailByName(name),
  );

  return R.prop(0, rows);
};

export const updateNotificationRocketChat: ResolverFn = async (
  root,
  { input },
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('notification', 'update');

  const { name } = input;

  if (isPatchEmpty(input)) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  await query(sqlClient, Sql.updateNotificationRocketChat(input));
  const rows = await query(
    sqlClient,
    Sql.selectNotificationRocketChatByName(name),
  );

  return R.prop(0, rows);
};

export const updateNotificationSlack: ResolverFn = async (
  root,
  { input },
  {
    sqlClient,
    hasPermission,
  },
) => {
  await hasPermission('notification', 'update');

  const { name } = input;

  if (isPatchEmpty(input)) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  await query(sqlClient, Sql.updateNotificationSlack(input));
  const rows = await query(sqlClient, Sql.selectNotificationSlackByName(name));

  return R.prop(0, rows);
};

