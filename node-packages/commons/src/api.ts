import { Lokka } from 'lokka';
import { Transport } from './lokka-transport-http-retry';
import { propOr, replace, toUpper, pipe, toLower } from 'ramda';
import { createJWTWithoutUserId } from './jwt';
import { logger } from './local-logging';

interface Project {
  slack: any;
  name: string;
  openshift: any;
}

interface GroupPatch {
  name?: string;
}

interface UserPatch {
  email?: string;
  firstName?: string;
  lastName?: string;
  comment?: string;
  gitlabId?: number;
}

interface ProjectPatch {
  name?: string;
  gitUrl?: string;
  subfolder?: string;
  activesystemsdeploy?: string;
  activesystemsremove?: string;
  branches?: string;
  productionenvironment?: string;
  autoidle?: number;
  storagecalc?: number;
  pullrequests?: string;
  openshift?: number;
  openshiftprojectpattern?: string;
  productionRoutes?: string;
  standbyRoutes?: string;
  productionEnvironment?: string;
  standbyProductionEnvironment?: string;
}

interface DeploymentPatch {
  name?: number;
  status?: string;
  created?: string;
  started?: string;
  completed?: string;
  environment?: number;
  remoteId?: string;
}

interface TaskPatch {
  name?: number;
  status?: string;
  created?: string;
  started?: string;
  completed?: string;
  environment?: number;
  remoteId?: string;
}

interface RestorePatch {
  status?: string;
  created?: string;
  restoreLocation?: string;
}

enum EnvType {
  PRODUCTION = 'production',
  DEVELOPMENT = 'development'
}

const { JWTSECRET, JWTAUDIENCE } = process.env;
const API_HOST = propOr('http://api:3000', 'API_HOST', process.env);

if (JWTSECRET == null) {
  logger.warn(
    'No JWTSECRET env variable set... this will cause api requests to fail'
  );
}

if (JWTAUDIENCE == null) {
  logger.warn(
    'No JWTAUDIENCE env variable set... this may cause api requests to fail'
  );
}

const apiAdminToken = createJWTWithoutUserId({
  payload: {
    role: 'admin',
    iss: 'lagoon-commons',
    aud: JWTAUDIENCE || 'api.amazee.io'
  },
  jwtSecret: JWTSECRET || ''
});

const options = {
  headers: {
    Authorization: `Bearer ${apiAdminToken}`
  },
  timeout: 60000
};

const transport = new Transport(`${API_HOST}/graphql`, options);

export const graphqlapi = new Lokka({ transport });

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

export const addGroup = (name: string): Promise<any> =>
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
      name
    }
  );

export const addGroupWithParent = (
  name: string,
  parentGroupName: string
): Promise<any> =>
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
      parentGroupName
    }
  );

export const addBackup = (
  id: number = null,
  environment: number,
  source: string,
  backupId: string,
  created: string
): Promise<any> =>
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
      created
    }
  );

export const deleteBackup = (backupId: string): Promise<any> =>
  graphqlapi.mutate(
    `
  ($backupId: String!) {
    deleteBackup(input: {
      backupId: $backupId
    })
  }
  `,
    { backupId }
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

export const updateRestore = (
  backupId: string,
  patch: RestorePatch
): Promise<any> =>
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
    { backupId, patch }
  );

export const getEnvironmentBackups = (
  openshiftProjectName: string
): Promise<any[]> =>
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
`,
    { openshiftProjectName }
  );

export const updateGroup = (name: string, patch: GroupPatch): Promise<any> =>
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
    { name, patch }
  );

export const deleteGroup = (name: string): Promise<any> =>
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
    { name }
  );

export const getUserBySshKey = (sshKey: string): Promise<any> =>
  graphqlapi.query(
    `
  query userBySshKey($sshKey: String!) {
    userBySshKey(sshKey: $sshKey) {
      ...${userFragment}
    }
  }
`,
    { sshKey }
  );

export const addUser = (
  email: string,
  firstName: string = null,
  lastName: string = null,
  comment: string = null,
  gitlabId: number = null
): Promise<any> =>
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
      gitlabId
    }
  );

export const updateUser = (email: string, patch: UserPatch): Promise<any> =>
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
    { email, patch }
  );

export const deleteUser = (email: string): Promise<any> =>
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
    { email }
  );

export const addUserToGroup = (
  userEmail: string,
  groupName: string,
  role: string
): Promise<any> =>
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
    { userEmail, groupName, role }
  );

export const addGroupToProject = (
  project: string,
  group: string
): Promise<any> =>
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
    { project, group }
  );

export const removeGroupFromProject = (
  project: string,
  group: string
): Promise<any> =>
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
    { project, group }
  );

export const removeUserFromGroup = (
  userEmail: string,
  groupName: string
): Promise<any> =>
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
    { userEmail, groupName }
  );

export const addSshKey = (
  id: number = null,
  name: string,
  keyValue: string,
  keyType: string,
  userEmail: string
): Promise<any> =>
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
      keyType
    }
  );

export const deleteSshKey = (name: string): Promise<any> =>
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

export const addProject = (
  name: string,
  gitUrl: string,
  openshift: number,
  productionenvironment: string,
  id: number = null
): Promise<any> =>
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
      id
    }
  );

export const updateProject = (
  id: number,
  patch: ProjectPatch
): Promise<any> =>
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
    { id, patch }
  );

export const deleteProject = (name: string): Promise<any> =>
  graphqlapi.mutate(
    `
  ($name: String!) {
    deleteProject(input: {
      project: $name
    })
  }
  `,
    { name }
  );

export async function getProjectsByGitUrl(gitUrl: string): Promise<Project[]> {
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

export async function getProjectByName(project: string): Promise<any> {
  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        ...${projectFragment}
      }
    }
  `);

  if (!result || !result.project) {
    throw new ProjectNotFound(`Cannot find project ${project}`);
  }

  return result.project;
}

export const allProjectsInGroup = (groupInput: {
  id?: string;
  name?: string;
}): Promise<any[]> =>
  graphqlapi.query(
    `
    query($groupInput: GroupInput!) {
      allProjectsInGroup(input: $groupInput) {
        ...${projectFragment}
      }
    }
  `,
    {
      groupInput
    }
  );

export async function getMicrosoftTeamsInfoForProject(
  project: string, contentType = 'DEPLOYMENT'
): Promise<any[]> {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationMicrosoftTeams {
      webhook
      contentType
      notificationSeverityThreshold
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        microsoftTeams: notifications(type: MICROSOFTTEAMS, contentType: ${contentType}) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.microsoftTeams) {
    throw new ProjectNotFound(
      `Cannot find Microsoft Teams information for project ${project}`
    );
  }

  return result.project.microsoftTeams;
}

export async function getRocketChatInfoForProject(
  project: string, contentType = 'DEPLOYMENT'
): Promise<any[]> {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationRocketChat {
      webhook
      channel
      contentType
      notificationSeverityThreshold
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        rocketchats: notifications(type: ROCKETCHAT, contentType: ${contentType}) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.rocketchats) {
    throw new ProjectNotFound(
      `Cannot find rocketchat information for project ${project}`
    );
  }

  return result.project.rocketchats;
}

export async function getSlackinfoForProject(
  project: string, contentType = 'DEPLOYMENT'
): Promise<Project> {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationSlack {
      webhook
      channel
      contentType
      notificationSeverityThreshold
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        slacks: notifications(type: SLACK, contentType: ${contentType}) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.slacks) {
    throw new ProjectNotFound(
      `Cannot find slack information for project ${project}`
    );
  }

  return result.project.slacks;
}

export async function getEmailInfoForProject(
  project: string, contentType = 'DEPLOYMENT'
): Promise<any[]> {
  const notificationsFragment = graphqlapi.createFragment(`
    fragment on NotificationEmail {
      emailAddress
      contentType
      notificationSeverityThreshold
    }
  `);

  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}") {
        emails: notifications(type: EMAIL, contentType: ${contentType}) {
          ...${notificationsFragment}
        }
      }
    }
  `);

  if (!result || !result.project || !result.project.emails) {
    throw new ProjectNotFound(
      `Cannot find email information for project ${project}`
    );
  }

  return result.project.emails;
}

interface GetActiveSystemForProjectResult {
  branches: string;
  pullrequests: string;
  activeSystemsDeploy: string;
  activeSystemsPromote: string;
  activeSystemsRemove: string;
  activeSystemsTask: string;
  activeSystemsMisc: string;
}

export async function getActiveSystemForProject(
  project: string,
  task: 'Deploy' | 'Promote' | 'Remove' | 'Task' | 'Misc'
): Promise<GetActiveSystemForProjectResult> {
  const field = `activeSystems${task}`;
  const result = await graphqlapi.query(`
    {
      project:projectByName(name: "${project}"){
        activeSystemsDeploy
        activeSystemsPromote
        activeSystemsRemove
        activeSystemsTask
        activeSystemsMisc
        branches
        pullrequests
      }
    }
  `);

  if (!result || !result.project) {
    throw new ProjectNotFound(
      `Cannot find active-systems information for project ${project}`
    );
  }

  if (!result.project[field]) {
    throw new NoActiveSystemsDefined(
      `Cannot find active system for task ${task} in project ${project}`
    );
  }

  return result.project;
}

export async function getEnvironmentByName(
  name: string,
  projectId: number
): Promise<any> {
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
      `Cannot find environment for projectId ${projectId}, name ${name}\n${result.environmentByName}`
    );
  }

  return result;
}


export async function getEnvironmentById(
  id: number
): Promise<any> {
  const result = await graphqlapi.query(`
    {
      environmentById(id: ${id}) {
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

  if (!result || !result.environmentById) {
    throw new EnvironmentNotFound(
      `Cannot find environment for id ${id}\n${result.environmentById}`
    );
  }

  return result;
}

export async function getDeploymentByName(
  openshiftProjectName: string,
  deploymentName: string,
): Promise<any> {
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
      `Cannot find deployment ${deploymentName} by projectName ${openshiftProjectName}\n${
        result.environment
      }`,
    );
  }

  return result;
}

export async function getEnvironmentByOpenshiftProjectName(
  openshiftProjectName: string
): Promise<any[]> {
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
      `Cannot find environment for OpenshiftProjectName ${openshiftProjectName}\n${result.environmentByOpenshiftProjectName}`
    );
  }

  return result;
}

export const addOrUpdateEnvironment = (
  name: string,
  projectId: number,
  deployType: string,
  deployBaseRef: string,
  environmentType: string,
  openshiftProjectName: string,
  deployHeadRef: string = null,
  deployTitle: string = null
): Promise<any> =>
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
      openshiftProjectName
    }
  );

export const updateEnvironment = (
  environmentId: number,
  patch: string
): Promise<any> =>
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

export async function deleteEnvironment(
  name: string,
  project: string,
  execute: boolean = true
): Promise<any> {
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
      execute
    }
  );
}

export const getOpenShiftInfoForProject = (project: string): Promise<any> =>
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
          monitoringConfig
        }
        availability
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

export const getBillingGroupForProject = (project: string): Promise<any> =>
  graphqlapi.query(`
    {
      project:projectByName(name: "${project}"){
        groups {
          ... on BillingGroup {
            type
            uptimeRobotStatusPageId
          }
        }
      }
    }
`);

interface GetEnvironentsForProjectEnvironmentResult {
  name: string;
  environmentType: EnvType;
}

interface GetEnvironentsForProjectProjectResult {
  developmentEnvironmentsLimit: number;
  productionEnvironment: string;
  standbyProductionEnvironment: string;
  environments: GetEnvironentsForProjectEnvironmentResult[];
}

interface GetEnvironentsForProjectResult {
  project: GetEnvironentsForProjectProjectResult
}

export const getEnvironmentsForProject = (
  project: string
): Promise<GetEnvironentsForProjectResult> =>
  graphqlapi.query(`
  {
    project:projectByName(name: "${project}"){
      developmentEnvironmentsLimit
      productionEnvironment
      environments(includeDeleted:false) { name, environmentType }
    }
  }
`);

export const setEnvironmentServices = (
  environment: number,
  services: string[]
): Promise<any> =>
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
    { environment, services }
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
  uiLink
  environment {
    name
  }
}
`);

export const getDeploymentByRemoteId = (id: string): Promise<any> =>
  graphqlapi.query(
    `
  query deploymentByRemoteId($id: String!) {
    deploymentByRemoteId(id: $id) {
      ...${deploymentFragment}
    }
  }
`,
    { id }
  );

export const addDeployment = (
  name: string,
  status: string,
  created: string,
  environment: number,
  remoteId: string = null,
  id: number = null,
  started: string = null,
  completed: string = null
): Promise<any> =>
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
      completed
    }
  );

  export const addTask = (
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

export const updateDeployment = (
  id: number,
  patch: DeploymentPatch
): Promise<any> =>
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
    { id, patch }
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

export const updateTask = (id: number, patch: TaskPatch): Promise<any> =>
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
    { id, patch }
  );

export const sanitizeGroupName = pipe(
  replace(/[^a-zA-Z0-9-]/g, '-'),
  toLower
);
export const sanitizeProjectName = pipe(
  replace(/[^a-zA-Z0-9-]/g, '-'),
  toLower
);

export const getProjectsByGroupName = groupName =>
  graphqlapi.query(
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

export const getGroupMembersByGroupName = groupName =>
  graphqlapi.query(
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

export const addBulkProblems = async ({
  problems
}) => {

  let mutation_query_str = `mutation addBulkProblems {`;

  problems.map((p, i) => {
    mutation_query_str += `
    problem${i}: addProblem(input: {
      environment: ${p.environment},
      identifier: "${p.identifier}",
      source: "${p.source}",
      data: ${JSON.stringify(p.data).replace(/"/g, '\"')},
      severity: ${p.severity},
      severityScore: ${p.severityScore},
      service: "${p.service}",
      associatedPackage: "${p.associatedPackage}",
      description: ${JSON.stringify(p.description).replace(/"/g, '\"')},
      version: "${p.version}",
      fixedVersion: "${p.fixedVersion}",
      links: "${p.links}"
    }) {
      id
      environment {
        id
      }
      identifier
      severity
      source
      severityScore
      data
      description
      associatedPackage
      version
      fixedVersion
      links
    }`;
  });

  mutation_query_str += `
  }`

  return await graphqlapi.query(mutation_query_str);
};

export const addProblem = ({
  id = null,
  environment,
  identifier,
  severity,
  source,
  severityScore,
  data,
  service,
  associatedPackage,
  description,
  version,
  fixedVersion,
  links
}) => {
  return graphqlapi.mutate(
  `($id: Int,
    $environment: Int!,
    $identifier: String!,
    $severity: ProblemSeverityRating!,
    $source: String!,
    $severityScore: SeverityScore,
    $data: String!,
    $service: String,
    $associatedPackage: String,
    $description: String,
    $version: String,
    $fixedVersion: String,
    $links: String) {
    addProblem(input: {
      id: $id
      environment: $environment
      identifier: $identifier
      severity: $severity
      source: $source
      severityScore: $severityScore
      data: $data
      service: $service
      associatedPackage: $associatedPackage
      description: $description
      version: $version
      fixedVersion: $fixedVersion
      links: $links
    }) {
      id
      environment {
        id
      }
      identifier
      severity
      source
      severityScore
      data
      associatedPackage
      description
      version
      fixedVersion
      links
    }
  }`,
  {
    id,
    environment,
    identifier,
    severity,
    source,
    severityScore,
    data,
    service,
    associatedPackage,
    description,
    version,
    fixedVersion,
    links
  },
)};

export const deleteProblemsFromSource = (
  environment,
  source,
  service
) => {
  return graphqlapi.mutate(
    `($environment: Int!, $source: String!, $service: String!) {
      deleteProblemsFromSource(input: {environment: $environment, source: $source, service: $service })
    }
    `,
    {
      environment,
      source,
      service
    }
  )};

const problemFragment = graphqlapi.createFragment(`
fragment on Problem {
  id
  severity
  severityScore
  identifier
  service
  source
  associatedPackage
  description
  links
  version
  fixedVersion
  data
  created
  deleted
}
`);

export const getProblemsforProjectEnvironment = async (
  environmentName,
  project
) => {
  const response = await graphqlapi.query(
    `query getProject($environmentName: String!, $project: Int!) {
      environmentByName(name: $environmentName, project: $project) {
        id
        name
        problems {
          ...${problemFragment}
        }
      }
    }`
  ,
  {
    environmentName,
    project
  });
  return response.environmentByName.problems;
};

export const getProblemHarborScanMatches = () => graphqlapi.query(
    `query getProblemHarborScanMatches {
      allProblemHarborScanMatchers {
        id
        name
        description
        defaultLagoonProject
        defaultLagoonEnvironment
        defaultLagoonService
        regex
      }
    }`
);
