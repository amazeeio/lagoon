const { Lokka } = require('lokka');
const { Transport } = require('./lokka-transport-http-retry');
const R = require('ramda');
const { createJWTWithoutUserId } = require('./jwt');
const { logger } = require('./local-logging');

const { JWTSECRET, JWTAUDIENCE } = process.env;
const API_HOST = R.propOr('http://api:3000', 'API_HOST', process.env);

if (JWTSECRET == null) {
  logger.warn(
    'No JWTSECRET env variable set... this will cause api requests to fail',
  );
}

if (JWTAUDIENCE == null) {
  logger.warn(
    'No JWTAUDIENCE env variable set... this may cause api requests to fail',
  );
}

const apiAdminToken = createJWTWithoutUserId({
  payload: {
    role: 'admin',
    iss: 'lagoon-commons',
    aud: JWTAUDIENCE || 'api.amazee.io',
  },
  jwtSecret: JWTSECRET || '',
});

const options = {
  headers: {
    Authorization: `Bearer ${apiAdminToken}`,
  },
  timeout: 60000,
};

const transport = new Transport(`${API_HOST}/graphql`, options);

const graphqlapi = new Lokka({ transport });

class ProjectNotFound extends Error {
  constructor(message) {
    super(message);
    this.name = 'ProjectNotFound';
  }
}

class EnvironmentNotFound extends Error {
  constructor(message) {
    super(message);
    this.name = 'EnvironmentNotFound';
  }
}

class NoActiveSystemsDefined extends Error {
  constructor(message) {
    super(message);
    this.name = 'NoActiveSystemsDefined';
  }
}

const capitalize = R.replace(/^\w/, R.toUpper);

const sshKeyFragment = graphqlapi.createFragment(`
fragment on SshKey {
  id
  name
  keyValue
  keyType
}
`);

const userFragment = graphqlapi.createFragment(`
fragment on User {
  id
  email
  firstName
  lastName
  gitlabId
  sshKeys {
    id
    name
  }
}
`);

const groupFragment = graphqlapi.createFragment(`
fragment on Group {
  id
  name
}
`);


const projectFragment = graphqlapi.createFragment(`
fragment on Project {
  id
  name
  gitUrl
  privateKey
}
`);

const backupFragment = graphqlapi.createFragment(`
fragment on Backup {
  id
  environment {
    id
  }
  backupId
  source
  created
}
`);

const addGroup = (
  name,
) =>
  graphqlapi.mutate(
    `
  ($name: String!) {
    addGroup(input: {
        name: $name
    }) {
      ...${groupFragment}
    }
  }
`,
    {
      name,
    },
  );

const addGroupWithParent = (
  name,
  parentGroupName,
) =>
  graphqlapi.mutate(
    `
    ($name: String!, $parentGroupName: String) {
      addGroup(input: {
          name: $name
          parentGroup: { name: $parentGroupName }
      }) {
        ...${groupFragment}
      }
    }
  `,
    {
      name,
      parentGroupName,
    },
  );

const addBackup = (
  id = null,
  environment,
  source,
  backupId,
  created,
) =>
  graphqlapi.mutate(
    `
    ($id: Int, $environment: Int!, $source: String!, $backupId: String!, $created: String!) {
      addBackup(input: {
          id: $id
          environment: $environment
          source: $source
          backupId: $backupId
          created: $created
      }) {
        ...${backupFragment}
      }
    }
  `,
    {
      id,
      environment,
      source,
      backupId,
      created,
    },
  );

const deleteBackup = (backupId) =>
  graphqlapi.mutate(
    `
  ($backupId: String!) {
    deleteBackup(input: {
      backupId: $backupId
    })
  }
  `,
    { backupId },
  );

const restoreFragment = graphqlapi.createFragment(`
  fragment on Restore {
    id
    status
    created
    restoreLocation
    backupId
  }
  `);

const updateRestore = (
  backupId,
  patch,
) =>
  graphqlapi.mutate(
    `
  ($backupId: String!, $patch: UpdateRestorePatchInput!) {
    updateRestore(input: {
      backupId: $backupId
      patch: $patch
    }) {
      ...${restoreFragment}
    }
  }
`,
    { backupId, patch },
  );

const getAllEnvironmentBackups = () =>
  graphqlapi.query(
    `
  {
    allEnvironments {
      id
      name
      openshiftProjectName
      project {
        name
      }
      backups {
        ...${backupFragment}
      }
    }
  }
`,
  );

const getEnvironmentBackups = (openshiftProjectName) =>
  graphqlapi.query(
    `
  query environmentByOpenshiftProjectName($openshiftProjectName: String!) {
    environmentByOpenshiftProjectName(openshiftProjectName: $openshiftProjectName) {
      id
      name
      openshiftProjectName
      project {
        name
      }
      backups {
        id
        backupId
        source
        created
      }
    }
  }
`, { openshiftProjectName }
  );

const updateGroup = (name, patch) =>
  graphqlapi.mutate(
    `
  ($name: String!, $patch: UpdateGroupPatchInput!) {
    updateGroup(input: {
      group: {
        name: $name
      }
      patch: $patch
    }) {
      ...${groupFragment}
    }
  }
  `,
    { name, patch },
  );

const deleteGroup = (name) =>
  graphqlapi.mutate(
    `
  ($name: String!) {
    deleteGroup(input: {
      group: {
        name: $name
      }
    })
  }
  `,
    { name },
  );

const getUserBySshKey = (sshKey) =>
  graphqlapi.query(
    `
  query userBySshKey($sshKey: String!) {
    userBySshKey(sshKey: $sshKey) {
      ...${userFragment}
    }
  }
`,
    { sshKey },
  );

const addUser = (
  email,
  firstName = null,
  lastName = null,
  comment = null,
  gitlabId = null,
) =>
  graphqlapi.mutate(
    `
  ($email: String!, $firstName: String, $lastName: String, $comment: String, $gitlabId: Int) {
    addUser(input: {
      email: $email
      firstName: $firstName
      lastName: $lastName
      comment: $comment
      gitlabId: $gitlabId
    }) {
      ...${userFragment}
    }
  }
`,
    {
      email,
      firstName,
      lastName,
      comment,
      gitlabId,
    },
  );

const updateUser = (email, patch) =>
  graphqlapi.mutate(
    `
  ($email: String!, $patch: UpdateUserPatchInput!) {
    updateUser(input: {
      user: {
        email: $email
      }
      patch: $patch
    }) {
      ...${userFragment}
    }
  }
  `,
    { email, patch },
  );

const deleteUser = (email) =>
  graphqlapi.mutate(
    `
  ($email: Int!) {
    deleteUser(input: {
      user: {
        email: $email
      }
    })
  }
  `,
    { email },
  );

const addUserToGroup = (userEmail, groupName, role) =>
  graphqlapi.mutate(
    `
  ($userEmail: String!, $groupName: String!, $role: GroupRole!) {
    addUserToGroup(input: {
      user: { email: $userEmail }
      group: { name: $groupName }
      role: $role
    }) {
      ...${groupFragment}
    }
  }
  `,
    { userEmail, groupName, role },
  );

const addGroupToProject = (project, group) =>
  graphqlapi.mutate(
    `
  ($project: String!, $group: String!) {
    addGroupsToProject(input: {
      project: { name: $project}
      groups: [{name: $group}]
    }) {
      ...${projectFragment}
    }
  }
  `,
    { project, group },
  );

const removeGroupFromProject = (project, group) =>
  graphqlapi.mutate(
    `
  ($project: String!, $group: String!) {
    removeGroupsFromProject(input: {
      project: { name: $project}
      groups: [{name: $group}]
    }) {
      ...${projectFragment}
    }
  }
  `,
    { project, group },
  );

const removeUserFromGroup = (
  userEmail, groupName,
) =>
  graphqlapi.mutate(
    `
  ($userEmail: String!, $groupName: String!) {
    removeUserFromGroup(input: {
      user: { email: $userEmail }
      group: { name: $groupName }
    }) {
      ...${groupFragment}
    }
  }
  `,
    { userEmail, groupName },
  );

const addSshKey = (
  id = null,
  name,
  keyValue,
  keyType,
  userEmail,
) =>
  graphqlapi.mutate(
    `
  ($id: Int, $name: String!, $keyValue: String!, $keyType: SshKeyType!, $userEmail: String!) {
    addSshKey(input: {
      id: $id
      name: $name
      keyValue: $keyValue
      keyType: $keyType
      user: {
        email: $userEmail
      }
    }) {
      ...${sshKeyFragment}
    }
  }
  `,
    {
      id,
      name,
      keyValue,
      userEmail,
      keyType,
    },
  );

const deleteSshKey = (name) =>
  graphqlapi.mutate(
    `
    ($name: String!) {
      deleteSshKey(input: {
        name: $name
      })
    }
    `,
    {
      name,
    },
  );

  const deleteSshKeyById = (id) =>
  graphqlapi.mutate(
    `
    ($id: Int!) {
      deleteSshKeyById(input: {
        id: $id
      })
    }
    `,
    {
      name,
    },
  );

const addProject = (
  name,
  gitUrl,
  openshift,
  productionenvironment,
  id = null,
) =>
  graphqlapi.mutate(
    `
    ($name: String!, $gitUrl: String!, $openshift: Int!, $productionenvironment: String!, $id: Int) {
      addProject(input: {
        name: $name,
        gitUrl: $gitUrl,
        openshift: $openshift,
        productionEnvironment: $productionenvironment,
        id: $id,
      }) {
        ...${projectFragment}
      }
    }
  `,
    {
      name,
      gitUrl,
      openshift,
      productionenvironment,
      id,
    },
  );

const updateProject = (id, patch) =>
  graphqlapi.mutate(
    `
  ($id: Int!, $patch: UpdateProjectPatchInput!) {
    updateProject(input: {
      id: $id
      patch: $patch
    }) {
      ...${projectFragment}
    }
  }
  `,
    { id, patch },
  );

const deleteProject = (name) =>
  graphqlapi.mutate(
    `
  ($name: String!) {
    deleteProject(input: {
      project: $name
    })
  }
  `,
    { name },
  );

async function getProjectsByGitUrl(gitUrl) {
  const result = await graphqlapi.query(`
    {
      allProjects(gitUrl: "${gitUrl}") {
        name
        productionEnvironment
        openshift {
          consoleUrl
          token
          projectUser
          routerPattern
        }
      }
    }
  `);

  if (!result || !result.allProjects || !result.allProjects.length) {
    throw new ProjectNotFound(`Cannot find project for git repo ${gitUrl}`);
  }

  return result.allProjects;
}

async function getProjectByName(
  project,
) {
  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        ...${projectFragment}
      }
    }
  `);

  if (!result || !result.project) {
    throw new ProjectNotFound(
      `Cannot find project ${project}`,
    );
  }

  return result.project;
}

async function getMicrosoftTeamsInfoForProject(
  project,
) {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationMicrosoftTeams {
      webhook
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        microsoftTeams: notifications(type: MICROSOFTTEAMS) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.microsoftTeams) {
    throw new ProjectNotFound(
      `Cannot find Microsoft Teams information for project ${project}`,
    );
  }

  return result.project.microsoftTeams;
}

async function getRocketChatInfoForProject(
  project,
) {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationRocketChat {
      webhook
      channel
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        rocketchats: notifications(type: ROCKETCHAT) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.rocketchats) {
    throw new ProjectNotFound(
      `Cannot find rocketchat information for project ${project}`,
    );
  }

  return result.project.rocketchats;
}

async function getSlackinfoForProject(project) {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationSlack {
      webhook
      channel
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        slacks: notifications(type: SLACK) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.slacks) {
    throw new ProjectNotFound(
      `Cannot find slack information for project ${project}`,
    );
  }

  return result.project.slacks;
}

async function getEmailInfoForProject(
  project,
) {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationEmail {
      emailAddress
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        emails: notifications(type: EMAIL) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.emails) {
    throw new ProjectNotFound(
      `Cannot find email information for project ${project}`,
    );
  }

  return result.project.emails;
}

async function getActiveSystemForProject(
  project,
  task,
) {
  const field = `activeSystems${capitalize(task)}`;
  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}"){
        ${field}
        branches
        pullrequests
      }
    }
  `);

  if (!result || !result.project) {
    throw new ProjectNotFound(
      `Cannot find active-systems information for project ${project}`,
    );
  }

  if (!result.project[field]) {
    throw new NoActiveSystemsDefined(
      `Cannot find active system for task ${task} in project ${project}`,
    );
  }

  return result.project;
}

async function getEnvironmentByName(
  name,
  projectId,
) {
  const result = await graphqlapi.query(`
    {
      environmentByName(name: "${name}", project:${projectId}) {
        id,
        name,
        route,
        routes,
        deployType,
        environmentType,
        openshiftProjectName,
        updated,
        created,
        deleted,
      }
    }
  `);

  if (!result || !result.environmentByName) {
    throw new EnvironmentNotFound(
      `Cannot find environment for projectId ${projectId}, name ${name}\n${
        result.environmentByName
      }`,
    );
  }

  return result;
}

async function getDeploymentByName(
  openshiftProjectName,
  deploymentName,
) {
  const result = await graphqlapi.query(`
    {
      environment:environmentByOpenshiftProjectName( openshiftProjectName: "${openshiftProjectName}") {
        id
        name
        openshiftProjectName
        project {
          id
          name
        }
        deployments(name: "${deploymentName}") {
          id
          name
          uiLink
        }
      }
    }
  `);

  if (!result || !result.environment) {
    throw new EnvironmentNotFound(
      `Cannot find deployment ${deploymentName} by projectName ${projectName}\n${
        result.environment
      }`,
    );
  }

  return result;
}

async function getEnvironmentByOpenshiftProjectName(
  openshiftProjectName,
) {
  const result = await graphqlapi.query(`
    {
      environmentByOpenshiftProjectName(openshiftProjectName: "${openshiftProjectName}") {
        id,
        name,
        project {
          name
        }
      }
    }
  `);

  if (!result || !result.environmentByOpenshiftProjectName) {
    throw new EnvironmentNotFound(
      `Cannot find environment for OpenshiftProjectName ${openshiftProjectName}\n${
        result.environmentByOpenshiftProjectName
      }`,
    );
  }

  return result;
}

const addOrUpdateEnvironment = (
  name,
  projectId,
  deployType,
  deployBaseRef,
  environmentType,
  openshiftProjectName,
  deployHeadRef = null,
  deployTitle = null,
) =>
  graphqlapi.mutate(
    `
($name: String!, $project: Int!, $deployType: DeployType!, $deployBaseRef: String!, $deployHeadRef: String, $deployTitle: String, $environmentType: EnvType!, $openshiftProjectName: String!) {
  addOrUpdateEnvironment(input: {
    name: $name,
    project: $project,
    deployType: $deployType,
    deployBaseRef: $deployBaseRef,
    deployHeadRef: $deployHeadRef,
    deployTitle: $deployTitle,
    environmentType: $environmentType,
    openshiftProjectName: $openshiftProjectName
  }) {
    id
    name
    project {
      name
    }
    deployType
    environmentType
    openshiftProjectName
    envVariables {
      name
      value
      scope
    }
  }
}
`,
    {
      name,
      project: projectId,
      deployType,
      deployBaseRef,
      deployHeadRef,
      deployTitle,
      environmentType,
      openshiftProjectName,
    },
  );

const updateEnvironment = (
  environmentId,
  patch,
) =>
  graphqlapi.query(`
    mutation {
      updateEnvironment(input: {
        id: ${environmentId},
        patch: ${patch}
      }) {
        id
        name
      }
    }
  `);

async function deleteEnvironment(
  name,
  project,
  execute = true,
) {
  return graphqlapi.mutate(
    `
  ($name: String!, $project: String!, $execute: Boolean) {
    deleteEnvironment(input: {
      name: $name
      project: $project
      execute: $execute
    })
  }
  `,
    {
      name,
      project,
      execute,
    },
  );
}

const getOpenShiftInfoForProject = (project) =>
  graphqlapi.query(`
    {
      project:projectByName(name: "${project}"){
        id
        openshift  {
          name
          consoleUrl
          token
          projectUser
          routerPattern
        }
        gitUrl
        privateKey
        subfolder
        openshiftProjectPattern
        productionEnvironment
        productionRoutes
        productionAlias
        standbyProductionEnvironment
        standbyRoutes
        standbyAlias
        envVariables {
          name
          value
          scope
        }
      }
    }
`);

const getOpenShiftInfoForProjectWithGroupEnvVars = (project) =>
  graphqlapi.query(`
    {
      project:projectByName(name: "${project}"){
        id
        openshift  {
          name
          consoleUrl
          token
          projectUser
          routerPattern
        }
        gitUrl
        privateKey
        subfolder
        openshiftProjectPattern
        productionEnvironment
        envVariables {
          name
          value
          scope
        }
        groups {
          id
          name
          ... on Group {
            envVariables {
              id
              name
              scope
              value
            }
          }
        }
      }
    }
`);

const getEnvironmentsForProject = (project) =>
  graphqlapi.query(`
  {
    project:projectByName(name: "${project}"){
      developmentEnvironmentsLimit
      productionEnvironment
      environments(includeDeleted:false) { name, environmentType }
    }
  }
`);

const getProductionEnvironmentForProject = (project) =>
  graphqlapi.query(`
    {
      project:projectByName(name: "${project}"){
        productionEnvironment
      }
    }
`);

const setEnvironmentServices = (
  environment,
  services,
) =>
  graphqlapi.mutate(
    `
  ($environment: Int!, $services: [String]!) {
    setEnvironmentServices(input: {
      environment: $environment
      services: $services
    }) {
      id
      name
    }
  }
  `,
    { environment, services },
  );

const deploymentFragment = graphqlapi.createFragment(`
fragment on Deployment {
  id
  name
  status
  created
  started
  completed
  remoteId
  environment {
    name
  }
}
`);

const getDeploymentByRemoteId = (id) =>
  graphqlapi.query(
    `
  query deploymentByRemoteId($id: String!) {
    deploymentByRemoteId(id: $id) {
      ...${deploymentFragment}
    }
  }
`,
    { id },
  );

const addDeployment = (
  name,
  status,
  created,
  environment,
  remoteId = null,
  id = null,
  started = null,
  completed = null,
) =>
  graphqlapi.mutate(
    `
  ($name: String!, $status: DeploymentStatusType!, $created: String!, $environment: Int!, $id: Int, $remoteId: String, $started: String, $completed: String) {
    addDeployment(input: {
        name: $name
        status: $status
        created: $created
        environment: $environment
        id: $id
        remoteId: $remoteId
        started: $started
        completed: $completed
    }) {
      ...${deploymentFragment}
    }
  }
`,
    {
      name,
      status,
      created,
      environment,
      id,
      remoteId,
      started,
      completed,
    },
  );

  const addTask = (
    name,
    status,
    created,
    environment,
    remoteId = null,
    id = null,
    started = null,
    completed = null,
    service = null,
    command = null,
    execute = false,
  ) =>
    graphqlapi.mutate(
      `
    ($name: String!, $status: TaskStatusType!, $created: String!, $environment: Int!, $id: Int, $remoteId: String, $started: String, $completed: String, $service: String, $command: String, $execute: Boolean) {
      addTask(input: {
          name: $name
          status: $status
          created: $created
          environment: $environment
          id: $id
          remoteId: $remoteId
          started: $started
          completed: $completed
          service: $service
          command: $command
          execute: $execute
      }) {
        ...${taskFragment}
      }
    }
  `,
      {
        name,
        status,
        created,
        environment,
        id,
        remoteId,
        started,
        completed,
        service,
        command,
        execute,
      },
    );

const updateDeployment = (
  id,
  patch,
) =>
  graphqlapi.mutate(
    `
  ($id: Int!, $patch: UpdateDeploymentPatchInput!) {
    updateDeployment(input: {
      id: $id
      patch: $patch
    }) {
      ...${deploymentFragment}
    }
  }
`,
    { id, patch },
  );

const taskFragment = graphqlapi.createFragment(`
fragment on Task {
  id
  name
  status
  created
  started
  completed
  remoteId
  environment {
    name
  }
}
`);

const updateTask = (id, patch) =>
  graphqlapi.mutate(
    `
  ($id: Int!, $patch: UpdateTaskPatchInput!) {
    updateTask(input: {
      id: $id
      patch: $patch
    }) {
      ...${taskFragment}
    }
  }
`,
    { id, patch },
  );

const sanitizeGroupName = R.pipe(R.replace(/[^a-zA-Z0-9-]/g, '-'), R.toLower);
const sanitizeProjectName = R.pipe(R.replace(/[^a-zA-Z0-9-]/g, '-'), R.toLower);

const getProjectsByGroupName = groupName => graphqlapi.query(
  `query groupByName($name: String!) {
    groupByName(name: $name) {
      id
      name
      projects {
        id
        name
        gitUrl
      }
    }
  }`,
  { name: groupName }
);

const getGroupMembersByGroupName = groupName => graphqlapi.query(
  `query groupByName($name: String!) {
    groupByName(name: $name) {
      id
      name
      members {
        user {
          id
          email
        }
        role
      }
    }
  }`,
  { name: groupName }
);

module.exports = {
  addGroup,
  addGroupWithParent,
  updateGroup,
  deleteGroup,
  getUserBySshKey,
  addUser,
  addBackup,
  deleteBackup,
  updateRestore,
  getAllEnvironmentBackups,
  getEnvironmentBackups,
  updateUser,
  deleteUser,
  addUserToGroup,
  removeUserFromGroup,
  addSshKey,
  deleteSshKey,
  addProject,
  updateProject,
  deleteProject,
  getProjectsByGitUrl,
  getProjectByName,
  getMicrosoftTeamsInfoForProject,
  getRocketChatInfoForProject,
  getSlackinfoForProject,
  getEmailInfoForProject,
  getActiveSystemForProject,
  getOpenShiftInfoForProject,
  getOpenShiftInfoForProjectWithGroupEnvVars,
  getEnvironmentByName,
  getProductionEnvironmentForProject,
  getEnvironmentsForProject,
  getDeploymentByName,
  addOrUpdateEnvironment,
  updateEnvironment,
  deleteEnvironment,
  setEnvironmentServices,
  getDeploymentByRemoteId,
  addDeployment,
  addTask,
  updateDeployment,
  getEnvironmentByOpenshiftProjectName,
  updateTask,
  addGroupToProject,
  removeGroupFromProject,
  sanitizeGroupName,
  sanitizeProjectName,
  getProjectsByGroupName,
  getGroupMembersByGroupName,
};
