// @flow

const R = require('ramda');
const validator = require('validator');
const sshpk = require('sshpk');
const { keycloakAdminClient } = require('../../clients/keycloakClient');
const opendistroSecurityClient = require('../../clients/opendistroSecurityClient');
const logger = require('../../logger');
const {
  inClause,
  prepare,
  query,
  whereAnd,
  isPatchEmpty,
} = require('../../util/db');

const Helpers = require('./helpers');
const KeycloakOperations = require('./keycloak');
const { OpendistroSecurityOperations } = require('../group/opendistroSecurity');
const Sql = require('./sql');
const { generatePrivateKey, getSshKeyFingerprint } = require('../sshKey');
const sshKeySql = require('../sshKey/sql');

/* ::

import type {ResolversObj} from '../';

*/

const removePrivateKey = R.assoc('privateKey', null);

const getAllProjects = async (
  root,
  args,
  {
    sqlClient,
    hasPermission,
    dataSources,
    keycloakGrant,
  },
) => {
  let where;
  try {
    await hasPermission('project', 'viewAll');

    where = whereAnd([
      args.createdAfter ? 'created >= :created_after' : '',
      args.gitUrl ? 'git_url = :git_url' : '',
    ]);
  } catch (err) {
    if (!keycloakGrant) {
      logger.warn('No grant available for getAllProjects');
      return [];
    }

    const userProjectIds = await dataSources.UserModel.getAllProjectsIdsForUser({
      id: keycloakGrant.access_token.content.sub,
    });

    where = whereAnd([
      args.createdAfter ? 'created >= :created_after' : '',
      args.gitUrl ? 'git_url = :git_url' : '',
      inClause('id', userProjectIds),
    ]);
  }

  const order = args.order ? ` ORDER BY ${R.toLower(args.order)} ASC` : '';

  const prep = prepare(sqlClient, `SELECT * FROM project ${where}${order}`);
  const rows = await query(sqlClient, prep(args));

  return rows;
};

const getProjectByEnvironmentId = async (
  { id: eid },
  args,
  {
    sqlClient,
    hasPermission,
  },
) => {
  const prep = prepare(
    sqlClient,
    `SELECT
        p.*
      FROM environment e
      JOIN project p ON e.project = p.id
      WHERE e.id = :eid
      LIMIT 1
    `,
  );

  const rows = await query(sqlClient, prep({ eid }));

  const project = rows[0];

  await hasPermission('project', 'view', {
    project: project.id,
  });

  try {
    await hasPermission('project', 'viewPrivateKey', {
      project: project.id,
    });

    return project;
  } catch (err) {
    return removePrivateKey(project);
  }
};

const getProjectByGitUrl = async (
  root,
  args,
  {
    sqlClient,
    hasPermission,
  },
) => {
  const str = `
      SELECT
        *
      FROM project
      WHERE git_url = :git_url
      LIMIT 1
    `;

  const prep = prepare(sqlClient, str);
  const rows = await query(sqlClient, prep(args));

  const project = rows[0];

  await hasPermission('project', 'view', {
    project: project.id,
  });

  try {
    await hasPermission('project', 'viewPrivateKey', {
      project: project.id,
    });

    return project;
  } catch (err) {
    return removePrivateKey(project);
  }
};

const getProjectByName = async (
  root,
  args,
  {
    sqlClient,
    hasPermission,
  },
) => {
  const str = `
      SELECT
        *
      FROM project
      WHERE name = :name
    `;

  const prep = prepare(sqlClient, str);

  const rows = await query(sqlClient, prep(args));
  const project = rows[0];

  await hasPermission('project', 'view', {
    project: project.id,
  });

  try {
    await hasPermission('project', 'viewPrivateKey', {
      project: project.id,
    });

    return project;
  } catch (err) {
    return removePrivateKey(project);
  }
};

const addProject = async (
  root,
  { input },
  {
    hasPermission,
    sqlClient,
    dataSources,
  },
) => {
  await hasPermission('project', 'add');

  if (validator.matches(input.name, /[^0-9a-z-]/)) {
    throw new Error(
      'Only lowercase characters, numbers and dashes allowed for name!',
    );
  }

  let keyPair = {};
  try {
    const privateKey = R.cond([
      [R.isNil, generatePrivateKey],
      [R.isEmpty, generatePrivateKey],
      [R.T, sshpk.parsePrivateKey],
    ])(R.prop('privateKey', input));

    const publicKey = privateKey.toPublic();

    keyPair = {
      ...keyPair,
      private: R.replace(/\n/g, '\n', privateKey.toString('openssh')),
      public: publicKey.toString(),
    };
  } catch (err) {
    throw new Error(`There was an error with the privateKey: ${err.message}`);
  }

  const prep = prepare(
    sqlClient,
    `CALL CreateProject(
        :id,
        :name,
        :git_url,
        :private_key,
        ${input.subfolder ? ':subfolder' : 'NULL'},
        :openshift,
        ${
  input.openshiftProjectPattern ? ':openshift_project_pattern' : 'NULL'
},
        ${
  input.activeSystemsDeploy
    ? ':active_systems_deploy'
    : '"lagoon_openshiftBuildDeploy"'
},
        ${
  input.activeSystemsPromote
    ? ':active_systems_promote'
    : '"lagoon_openshiftBuildDeploy"'
},
        ${
  input.activeSystemsRemove
    ? ':active_systems_remove'
    : '"lagoon_openshiftRemove"'
},
        ${
  input.activeSystemsTask
    ? ':active_systems_task'
    : '"lagoon_openshiftJob"'
},
        ${input.branches ? ':branches' : '"true"'},
        ${input.pullrequests ? ':pullrequests' : '"true"'},
        ${input.productionEnvironment ? ':production_environment' : 'NULL'},
        ${input.autoIdle ? ':auto_idle' : '1'},
        ${input.storageCalc ? ':storage_calc' : '1'},
        ${
  input.developmentEnvironmentsLimit
    ? ':development_environments_limit'
    : '5'
}
      );
    `,
  );

  const rows = await query(sqlClient, prep({
    ...input,
    privateKey: keyPair.private,
  }));
  const project = R.path([0, 0], rows);

  // Create a default group for this project
  let group;
  try {
    group = await dataSources.GroupModel.addGroup({
      name: `project-${project.name}`,
      attributes: {
        type: ['project-default-group'],
        'lagoon-projects': [project.id],
      },
    });
  } catch (err) {
    logger.error(`Could not create default project group for ${project.name}: ${err.message}`);
  }

  OpendistroSecurityOperations(sqlClient, dataSources.GroupModel).syncGroup(`project-${project.name}`, project.id);


  // Find or create a user that has the public key linked to them
  const userRows = await query(
    sqlClient,
    sshKeySql.selectUserIdsBySshKeyFingerprint(getSshKeyFingerprint(keyPair.public)),
  );
  const userId = R.path([0, 'usid'], userRows);

  let user;
  if (!userId) {
    try {
      user = await dataSources.UserModel.addUser({
        email: `default-user@${project.name}`,
        username: `default-user@${project.name}`,
        comment: `autogenerated user for project ${project.name}`,
      });

      const keyParts = keyPair.public.split(' ');

      const {
        info: { insertId },
      } = await query(
        sqlClient,
        sshKeySql.insertSshKey({
          id: null,
          name: 'auto-add via api',
          keyValue: keyParts[1],
          keyType: keyParts[0],
          keyFingerprint: getSshKeyFingerprint(keyPair.public),
        }),
      );
      await query(sqlClient, sshKeySql.addSshKeyToUser({ sshKeyId: insertId, userId: user.id }));
    } catch (err) {
      logger.error(`Could not create default project user for ${project.name}: ${err.message}`);
    }
  } else {
    user = await dataSources.UserModel.loadUserById(userId);
  }

  // Add a default maintainer user
  const maintainerUser = await dataSources.UserModel.addUser({
    email: `default-maintainer@${project.name}`,
    username: `default-maintainer@${project.name}`,
    comment: `autogenerated maintainer for project ${project.name}`,
  });

  // Add the user (with linked public key) to the default group as guest
  try {
    await dataSources.GroupModel.addUserToGroup(user, group, 'guest');
    await dataSources.GroupModel.addUserToGroup(maintainerUser, group, 'maintainer');
  } catch (err) {
    logger.error(`Could not link user to default projet group for ${project.name}: ${err.message}`);
  }

  return project;
};

const deleteProject = async (
  root,
  { input: { project: projectName } },
  {
    sqlClient,
    hasPermission,
    dataSources,
  },
) => {
  // Will throw on invalid conditions
  const pid = await Helpers(sqlClient).getProjectIdByName(projectName);
  const project = await Helpers(sqlClient).getProjectById(pid);

  await hasPermission('project', 'delete', {
    project: pid,
  });

  const prep = prepare(sqlClient, 'CALL DeleteProject(:name)');
  await query(sqlClient, prep(project));

  // Remove the default group and user
  try {
    const group = await dataSources.GroupModel.loadGroupByName(`project-${project.name}`);
    await dataSources.GroupModel.deleteGroup(group.id);
    OpendistroSecurityOperations(sqlClient, dataSources.GroupModel).deleteGroup(group.name);
  } catch (err) {
    logger.error(`Could not delete default group for project ${project.name}: ${err.message}`);
  }

  try {
    const user = await dataSources.UserModel.loadUserByUsername(`default-user@${project.name}`);
    await dataSources.UserModel.deleteUser(user.id);
  } catch (err) {
    logger.error(`Could not delete default user for project ${project.name}: ${err.message}`);
  }

  try {
    const user = await dataSources.UserModel.loadUserByUsername(`default-maintainer@${project.name}`);
    await dataSources.UserModel.deleteUser(user.id);
  } catch (err) {
    logger.error(`Could not delete default maintainer for project ${project.name}: ${err.message}`);
  }

  return 'success';
};

const updateProject = async (
  root,
  {
    input: {
      id,
      patch,
      patch: {
        name,
        gitUrl,
        privateKey,
        subfolder,
        activeSystemsDeploy,
        activeSystemsRemove,
        activeSystemsTask,
        branches,
        productionEnvironment,
        autoIdle,
        storageCalc,
        pullrequests,
        openshift,
        openshiftProjectPattern,
        developmentEnvironmentsLimit,
      },
    },
  },
  {
    sqlClient,
    hasPermission,
    dataSources,
  },
) => {
  await hasPermission('project', 'update', {
    project: id,
  });

  if (isPatchEmpty({ patch })) {
    throw new Error('input.patch requires at least 1 attribute');
  }

  if (typeof name === 'string') {
    if (validator.matches(name, /[^0-9a-z-]/)) {
      throw new Error(
        'Only lowercase characters, numbers and dashes allowed for name!',
      );
    }
  }

  const oldProject = await Helpers(sqlClient).getProjectById(id);

  // TODO If the privateKey changes, automatically remove the old one from the
  // default user and link the new one.

  // const originalProject = await Helpers(sqlClient).getProjectById(id);
  // const originalName = R.prop('name', originalProject);
  // const originalCustomer = parseInt(R.prop('customer', originalProject));

  // // If the project will be updating the `name` or `customer` fields, update Keycloak groups and users accordingly
  // if (typeof customer === 'number' && customer !== originalCustomer) {
  //   // Delete Keycloak users from original projects where given user ids do not have other access via `project_user` (projects where the user loses access if they lose customer access).
  //   await Helpers(sqlClient).mapIfNoDirectProjectAccess(
  //     id,
  //     originalCustomer,
  //     async ({
  //       keycloakUserId,
  //       keycloakUsername,
  //       keycloakGroupId,
  //       keycloakGroupName,
  //     }) => {
  //       await keycloakAdminClient.users.delFromGroup({
  //         id: keycloakUserId,
  //         groupId: keycloakGroupId,
  //       });
  //       logger.debug(
  //         `Removed Keycloak user ${keycloakUsername} from group "${keycloakGroupName}"`,
  //       );
  //     },
  //   );
  // }

  await query(
    sqlClient,
    Sql.updateProject({
      id,
      patch: {
        name,
        gitUrl,
        privateKey,
        subfolder,
        activeSystemsDeploy,
        activeSystemsRemove,
        activeSystemsTask,
        branches,
        productionEnvironment,
        autoIdle,
        storageCalc,
        pullrequests,
        openshift,
        openshiftProjectPattern,
        developmentEnvironmentsLimit,
      },
    }),
  );

  // Rename the default group and user
  if (patch.name && oldProject.name !== patch.name) {
    try {
      const group = await dataSources.GroupModel.loadGroupByName(`project-${oldProject.name}`);
      await dataSources.GroupModel.updateGroup({
        id: group.id,
        name: `project-${patch.name}`,
      });
    } catch (err) {
      logger.error(`Could not rename default group for project ${patch.name}: ${err.message}`);
    }

    try {
      const user = await dataSources.UserModel.loadUserByUsername(`default-user@${oldProject.name}`);
      await dataSources.UserModel.updateUser({
        id: user.id,
        email: `default-user@${patch.name}`,
        username: `default-user@${patch.name}`,
        comment: `autogenerated user for project ${patch.name}`,
      });
    } catch (err) {
      logger.error(`Could not rename default user for project ${patch.name}: ${err.message}`);
    }

    try {
      const user = await dataSources.UserModel.loadUserByUsername(`default-maintainer@${oldProject.name}`);
      await dataSources.UserModel.updateUser({
        id: user.id,
        email: `default-maintainer@${patch.name}`,
        username: `default-maintainer@${patch.name}`,
        comment: `autogenerated maintainer for project ${patch.name}`,
      });
    } catch (err) {
      logger.error(`Could not rename default maintainer for project ${patch.name}: ${err.message}`);
    }
  }

  // if (typeof name === 'string' && name !== originalName) {
  //   const groupId = await KeycloakOperations.findGroupIdByName(originalName);

  //   await keycloakAdminClient.groups.update({ id: groupId }, { name });
  //   logger.debug(
  //     `Renamed Keycloak group ${groupId} from "${originalName}" to "${name}"`,
  //   );
  // }

  // if (typeof customer === 'number' && customer !== originalCustomer) {
  //   // Add Keycloak users to new projects where given user ids do not have other access via `project_user` (projects where the user loses access if they lose customer access).
  //   await Helpers(sqlClient).mapIfNoDirectProjectAccess(
  //     id,
  //     customer,
  //     async ({
  //       keycloakUserId,
  //       keycloakUsername,
  //       keycloakGroupId,
  //       keycloakGroupName,
  //     }) => {
  //       await keycloakAdminClient.users.addToGroup({
  //         id: keycloakUserId,
  //         groupId: keycloakGroupId,
  //       });
  //       logger.debug(
  //         `Added Keycloak user ${keycloakUsername} to group "${keycloakGroupName}"`,
  //       );
  //     },
  //   );
  // }

  return Helpers(sqlClient).getProjectById(id);
};


const deleteAllProjects = async (
  root,
  args,
  { sqlClient, hasPermission },
) => {
  await hasPermission('project', 'deleteAll');

  const projectNames = await Helpers(sqlClient).getAllProjectNames();

  await query(sqlClient, Sql.truncateProject());

  for (const name of projectNames) {
    await KeycloakOperations.deleteGroup(name);
  }

  // TODO: Check rows for success
  return 'success';
};

const Resolvers /* : ResolversObj */ = {
  deleteProject,
  addProject,
  getProjectByName,
  getProjectByGitUrl,
  getProjectByEnvironmentId,
  getAllProjects,
  updateProject,
  deleteAllProjects,
};

module.exports = Resolvers;
