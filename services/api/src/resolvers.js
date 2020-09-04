const GraphQLDate = require('graphql-iso-date');
const GraphQLJSON = require('graphql-type-json');

const {
  getAllProblems,
  getProblemsByEnvironmentId,
  addProblem,
  deleteProblem,
  deleteProblemsFromSource,
  addProblemsFromSource,
  getProblemSources,
  getProblemHarborScanMatches,
  addProblemHarborScanMatch,
  deleteProblemHarborScanMatch,
} = require('./resources/problem/resolvers');

const {
  getFactsByEnvironmentId,
  addFact,
  deleteFact,
} = require('./resources/fact/resolvers');

const {
  SeverityScoreType
} = require('./resources/problem/types');

const {
  getLagoonVersion,
} = require('./resources/lagoon/resolvers');

const {
  getDeploymentsByEnvironmentId,
  getDeploymentByRemoteId,
  addDeployment,
  deleteDeployment,
  updateDeployment,
  cancelDeployment,
  deployEnvironmentLatest,
  deployEnvironmentBranch,
  deployEnvironmentPullrequest,
  deployEnvironmentPromote,
  switchActiveStandby,
  deploymentSubscriber,
  getDeploymentUrl
} = require('./resources/deployment/resolvers');

const {
  getTasksByEnvironmentId,
  getTaskByRemoteId,
  addTask,
  deleteTask,
  updateTask,
  taskDrushArchiveDump,
  taskDrushSqlDump,
  taskDrushCacheClear,
  taskDrushCron,
  taskDrushSqlSync,
  taskDrushRsyncFiles,
  taskDrushUserLogin,
  taskSubscriber,
} = require('./resources/task/resolvers');

const {
  getFilesByTaskId,
  uploadFilesForTask,
  deleteFilesForTask,
} = require('./resources/file/resolvers');

const {
  addOrUpdateEnvironment,
  addOrUpdateEnvironmentStorage,
  getEnvironmentByName,
  getEnvironmentById,
  getEnvironmentByOpenshiftProjectName,
  getEnvironmentHoursMonthByEnvironmentId,
  getEnvironmentStorageByEnvironmentId,
  getEnvironmentStorageMonthByEnvironmentId,
  getEnvironmentHitsMonthByEnvironmentId,
  getEnvironmentByDeploymentId,
  getEnvironmentByTaskId,
  getEnvironmentByBackupId,
  getEnvironmentServicesByEnvironmentId,
  setEnvironmentServices,
  deleteEnvironment,
  getEnvironmentsByProjectId,
  updateEnvironment,
  getAllEnvironments,
  userCanSshToEnvironment,
  getEnvironmentUrl
} = require('./resources/environment/resolvers');

const {
  addNotificationMicrosoftTeams,
  addNotificationRocketChat,
  addNotificationSlack,
  addNotificationToProject,
  deleteNotificationMicrosoftTeams,
  deleteNotificationRocketChat,
  deleteNotificationSlack,
  getNotificationsByProjectId,
  removeNotificationFromProject,
  updateNotificationMicrosoftTeams,
  updateNotificationRocketChat,
  updateNotificationSlack,
  addNotificationEmail,
  updateNotificationEmail,
  deleteNotificationEmail,
} = require('./resources/notification/resolvers');

const {
  addOpenshift,
  deleteOpenshift,
  getAllOpenshifts,
  getOpenshiftByProjectId,
  updateOpenshift,
} = require('./resources/openshift/resolvers');

const {
  deleteProject,
  addProject,
  getProjectByName,
  getProjectByGitUrl,
  getProjectByEnvironmentId,
  getProjectsByMetadata,
  getAllProjects,
  updateProject,
  getProjectUrl,
  updateProjectMetadata,
  removeProjectMetadataByKey
} = require('./resources/project/resolvers');

const {
  getUserSshKeys,
  addSshKey,
  updateSshKey,
  deleteSshKey,
  deleteSshKeyById,
} = require('./resources/sshKey/resolvers');

const {
  getMe,
  getUserBySshKey,
  addUser,
  updateUser,
  deleteUser,
} = require('./resources/user/resolvers');

const {
  getAllGroups,
  getGroupsByProjectId,
  getGroupsByUserId,
  getGroupByName,
  addGroup,
  addBillingGroup,
  updateBillingGroup,
  addProjectToBillingGroup,
  updateProjectBillingGroup,
  removeProjectFromBillingGroup,
  getAllProjectsInGroup,
  getBillingGroupCost,
  getAllBillingGroupsCost,
  getAllProjectsByGroupId,
  updateGroup,
  deleteGroup,
  addUserToGroup,
  removeUserFromGroup,
  addGroupsToProject,
  removeGroupsFromProject,
} = require('./resources/group/resolvers');

const {
  addBillingModifier,
  updateBillingModifier,
  deleteBillingModifier,
  deleteAllBillingModifiersByBillingGroup,
  getBillingModifiers,
  getAllModifiersByGroupId
} = require('./resources/billing/resolvers');

const {
  addBackup,
  getBackupsByEnvironmentId,
  deleteBackup,
  addRestore,
  getRestoreByBackupId,
  updateRestore,
  backupSubscriber,
} = require('./resources/backup/resolvers');

const {
  getEnvVarsByProjectId,
  getEnvVarsByEnvironmentId,
  addEnvVariable,
  deleteEnvVariable,
} = require('./resources/env-variables/resolvers');

const resolvers = {
  GroupRole: {
    GUEST: 'guest',
    REPORTER: 'reporter',
    DEVELOPER: 'developer',
    MAINTAINER: 'maintainer',
    OWNER: 'owner',
  },
  Project: {
    notifications: getNotificationsByProjectId,
    openshift: getOpenshiftByProjectId,
    environments: getEnvironmentsByProjectId,
    envVariables: getEnvVarsByProjectId,
    groups: getGroupsByProjectId,
  },
  GroupInterface: {
    __resolveType(group) {
      switch (group.type) {
        case 'billing':
          return 'BillingGroup';
        default:
          return 'Group';
      }
    },
  },
  Group: {
    projects: getAllProjectsByGroupId,
  },
  BillingGroup: {
    projects: getAllProjectsByGroupId,
    modifiers: getAllModifiersByGroupId,
  },
  Environment: {
    project: getProjectByEnvironmentId,
    deployments: getDeploymentsByEnvironmentId,
    tasks: getTasksByEnvironmentId,
    hoursMonth: getEnvironmentHoursMonthByEnvironmentId,
    storages: getEnvironmentStorageByEnvironmentId,
    storageMonth: getEnvironmentStorageMonthByEnvironmentId,
    hitsMonth: getEnvironmentHitsMonthByEnvironmentId,
    backups: getBackupsByEnvironmentId,
    envVariables: getEnvVarsByEnvironmentId,
    services: getEnvironmentServicesByEnvironmentId,
    problems: getProblemsByEnvironmentId,
    facts: getFactsByEnvironmentId,
  },
  Deployment: {
    environment: getEnvironmentByDeploymentId,
    uiLink: getDeploymentUrl,
  },
  Task: {
    environment: getEnvironmentByTaskId,
    files: getFilesByTaskId,
  },
  Notification: {
    __resolveType(obj) {
      switch (obj.type) {
        case 'slack':
          return 'NotificationSlack';
        case 'rocketchat':
          return 'NotificationRocketChat';
        case 'microsoftteams':
          return 'NotificationMicrosoftTeams';
        case 'email':
          return 'NotificationEmail';
        default:
          return null;
      }
    },
  },
  User: {
    sshKeys: getUserSshKeys,
    groups: getGroupsByUserId,
  },
  Backup: {
    restore: getRestoreByBackupId,
    environment: getEnvironmentByBackupId,
  },
  Query: {
    me: getMe,
    lagoonVersion: getLagoonVersion,
    userBySshKey: getUserBySshKey,
    projectByGitUrl: getProjectByGitUrl,
    projectByName: getProjectByName,
    groupByName: getGroupByName,
    problemSources: getProblemSources,
    environmentByName: getEnvironmentByName,
    environmentById: getEnvironmentById,
    environmentByOpenshiftProjectName: getEnvironmentByOpenshiftProjectName,
    userCanSshToEnvironment,
    deploymentByRemoteId: getDeploymentByRemoteId,
    taskByRemoteId: getTaskByRemoteId,
    allProjects: getAllProjects,
    allOpenshifts: getAllOpenshifts,
    allEnvironments: getAllEnvironments,
    allProblems: getAllProblems,
    allGroups: getAllGroups,
    allProjectsInGroup: getAllProjectsInGroup,
    billingGroupCost: getBillingGroupCost,
    allBillingGroupsCost: getAllBillingGroupsCost,
    allBillingModifiers: getBillingModifiers,
    allProblemHarborScanMatchers: getProblemHarborScanMatches,
    projectsByMetadata: getProjectsByMetadata
  },
  Mutation: {
    addProblem,
    addProblemHarborScanMatch,
    deleteProblem,
    deleteProblemsFromSource,
    deleteProblemHarborScanMatch,
    addFact,
    deleteFact,
    addOrUpdateEnvironment,
    updateEnvironment,
    deleteEnvironment,
    addOrUpdateEnvironmentStorage,
    addNotificationSlack,
    updateNotificationSlack,
    deleteNotificationSlack,
    addNotificationRocketChat,
    updateNotificationRocketChat,
    deleteNotificationRocketChat,
    addNotificationMicrosoftTeams,
    updateNotificationMicrosoftTeams,
    deleteNotificationMicrosoftTeams,
    addNotificationEmail,
    updateNotificationEmail,
    deleteNotificationEmail,
    addNotificationToProject,
    removeNotificationFromProject,
    addOpenshift,
    updateOpenshift,
    deleteOpenshift,
    addProject,
    updateProject,
    deleteProject,
    updateProjectMetadata,
    removeProjectMetadataByKey,
    addSshKey,
    updateSshKey,
    deleteSshKey,
    deleteSshKeyById,
    addUser,
    updateUser,
    deleteUser,
    addDeployment,
    deleteDeployment,
    updateDeployment,
    cancelDeployment,
    addBackup,
    deleteBackup,
    addRestore,
    updateRestore,
    addEnvVariable,
    deleteEnvVariable,
    addTask,
    taskDrushArchiveDump,
    taskDrushSqlDump,
    taskDrushCacheClear,
    taskDrushCron,
    taskDrushSqlSync,
    taskDrushRsyncFiles,
    taskDrushUserLogin,
    deleteTask,
    updateTask,
    setEnvironmentServices,
    uploadFilesForTask,
    deleteFilesForTask,
    deployEnvironmentLatest,
    deployEnvironmentBranch,
    deployEnvironmentPullrequest,
    deployEnvironmentPromote,
    switchActiveStandby,
    addGroup,
    addBillingGroup,
    updateBillingGroup,
    deleteBillingGroup: deleteGroup,
    addProjectToBillingGroup,
    updateProjectBillingGroup,
    removeProjectFromBillingGroup,
    updateGroup,
    deleteGroup,
    addUserToGroup,
    removeUserFromGroup,
    addGroupsToProject,
    removeGroupsFromProject,
    addBillingModifier,
    updateBillingModifier,
    deleteBillingModifier,
    deleteAllBillingModifiersByBillingGroup,
  },
  Subscription: {
    backupChanged: backupSubscriber,
    deploymentChanged: deploymentSubscriber,
    taskChanged: taskSubscriber,
  },
  Date: GraphQLDate,
  JSON: GraphQLJSON,
  SeverityScore: SeverityScoreType,
};

module.exports = resolvers;
