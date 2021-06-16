const { gql } = require('./util/gql');

// TODO: Split up this file

// TODO: Re-enable Prettier after the problem with escaping interpolation in
// embedded GraphQL in JS is fixed and new version released.
// Ref: https://github.com/prettier/prettier/issues/4974
// prettier-ignore
const typeDefs = gql`
  scalar Upload
  scalar Date
  scalar JSON

  enum SshKeyType {
    SSH_RSA
    SSH_ED25519
  }

  enum DeployType {
    BRANCH
    PULLREQUEST
    PROMOTE
  }

  enum EnvType {
    PRODUCTION
    DEVELOPMENT
  }

  enum NotificationType {
    SLACK
    ROCKETCHAT
    MICROSOFTTEAMS
    EMAIL
  }

  enum NotificationContentType {
    DEPLOYMENT
    PROBLEM
  }

  enum DeploymentStatusType {
    NEW
    PENDING
    RUNNING
    CANCELLED
    ERROR
    FAILED
    COMPLETE
  }

  enum EnvVariableType {
    PROJECT
    ENVIRONMENT
  }

  enum EnvVariableScope {
    BUILD
    RUNTIME
    GLOBAL
    CONTAINER_REGISTRY
    INTERNAL_CONTAINER_REGISTRY
  }

  enum TaskStatusType {
    ACTIVE
    SUCCEEDED
    FAILED
  }

  enum RestoreStatusType {
    PENDING
    SUCCESSFUL
    FAILED
  }

  enum EnvOrderType {
    NAME
    UPDATED
  }

  enum ProjectOrderType {
    NAME
    CREATED
  }

  enum ProjectAvailability {
    STANDARD
    HIGH
    POLYSITE
  }

  enum GroupRole {
    GUEST
    REPORTER
    DEVELOPER
    MAINTAINER
    OWNER
  }

  enum Currency {
    AUD
    EUR
    GBP
    USD
    CHF
    ZAR
  }

  enum ProblemSeverityRating {
    NONE
    UNKNOWN
    NEGLIGIBLE
    LOW
    MEDIUM
    HIGH
    CRITICAL
  }

  scalar SeverityScore

  type Problem {
    id: Int
    environment: Environment
    severity: ProblemSeverityRating
    severityScore: SeverityScore
    identifier: String
    service: String
    source: String
    associatedPackage: String
    description: String
    links: String
    version: String
    fixedVersion: String
    data: String
    created: String
    deleted: String
  }

  type ProblemHarborScanMatch {
    id: Int
    name: String
    description: String
    defaultLagoonProject: String
    defaultLagoonEnvironment: String
    defaultLagoonService: String
    regex: String
  }

  input AddProblemHarborScanMatchInput {
    name: String!
    description: String!
    defaultLagoonProject: String
    defaultLagoonEnvironment: String
    defaultLagoonService: String
    regex: String!
  }

  input DeleteProblemHarborScanMatchInput {
    id: Int!
  }

  input AddProblemInput {
    id: Int
    environment: Int!
    severity: ProblemSeverityRating
    severityScore: SeverityScore
    identifier: String!
    service: String
    source: String!
    associatedPackage: String
    description: String
    links: String
    version: String
    fixedVersion: String
    data: String!
    created: String
  }

  input BulkProblem {
    severity: ProblemSeverityRating
    severityScore: SeverityScore
    identifier: String
    data: String
  }

  input DeleteProblemInput {
    environment: Int!
    identifier: String!
    service: String
  }

  input DeleteProblemsFromSourceInput {
    environment: Int!
    source: String!
    service: String!
  }

  type Fact {
    id: Int
    environment: Environment
    name: String
    value: String
    source: String
    description: String
  }

  input AddFactInput {
    id: Int
    environment: Int!
    name: String!
    value: String!
    source: String!
    description: String!
  }

  input AddFactsInput {
    facts: [AddFactInput]!
  }

  input UpdateFactInputValue {
    environment: Int!
    name: String!
    value: String!
    source: String!
    description: String
  }

  input UpdateFactInput {
    environment: Int!
    patch: UpdateFactInputValue!
  }

  input DeleteFactInput {
    environment: Int!
    name: String!
  }

  input DeleteFactsFromSourceInput {
    environment: Int!
    source: String!
  }

  type File {
    id: Int
    filename: String
    download: String
    created: String
  }

  type SshKey {
    id: Int
    name: String
    keyValue: String
    keyType: String
    keyFingerprint: String
    created: String
  }

  type User {
    id: String
    email: String
    firstName: String
    lastName: String
    comment: String
    gitlabId: Int
    sshKeys: [SshKey]
    groups: [GroupInterface]
  }

  type GroupMembership {
    user: User
    role: GroupRole
  }

  interface GroupInterface {
    id: String
    name: String
    type: String
    groups: [GroupInterface]
    members: [GroupMembership]
    projects: [Project]
  }

  type Group implements GroupInterface {
    id: String
    name: String
    type: String
    groups: [GroupInterface]
    members: [GroupMembership]
    projects: [Project]
  }

  type BillingGroup implements GroupInterface {
    id: String
    name: String
    type: String
    groups: [GroupInterface]
    members: [GroupMembership]
    projects: [Project]
    currency: String
    billingSoftware: String
    modifiers: [BillingModifier]
    uptimeRobotStatusPageId: String
  }

  type Openshift {
    id: Int
    name: String
    consoleUrl: String
    token: String
    routerPattern: String
    projectUser: String
    sshHost: String
    sshPort: String
    created: String
    monitoringConfig: JSON
  }

  type Kubernetes {
    id: Int
    name: String
    consoleUrl: String
    token: String
    routerPattern: String
    projectUser: String
    sshHost: String
    sshPort: String
    created: String
    monitoringConfig: JSON
  }

  type NotificationMicrosoftTeams {
    id: Int
    name: String
    webhook: String
    contentType: String
    notificationSeverityThreshold: ProblemSeverityRating
  }

  type NotificationRocketChat {
    id: Int
    name: String
    webhook: String
    channel: String
    contentType: String
    notificationSeverityThreshold: ProblemSeverityRating
  }

  type NotificationSlack {
    id: Int
    name: String
    webhook: String
    channel: String
    contentType: String
    notificationSeverityThreshold: ProblemSeverityRating
  }

  type NotificationEmail {
    id: Int
    name: String
    emailAddress: String
    contentType: String
    notificationSeverityThreshold: ProblemSeverityRating
  }

  type UnassignedNotification {
    id: Int
    name: String
    type: String
    contentType: String
    notificationSeverityThreshold: ProblemSeverityRating
  }

  union Notification = NotificationRocketChat | NotificationSlack | NotificationMicrosoftTeams | NotificationEmail

  """
  Lagoon Project (like a git repository)
  """
  type Project {
    """
    ID of project
    """
    id: Int
    """
    Name of project
    """
    name: String
    """
    Git URL, needs to be SSH Git URL in one of these two formats
    - git@172.17.0.1/project1.git
    - ssh://git@172.17.0.1:2222/project1.git
    """
    gitUrl: String
    """
    Project Availability STANDARD|HIGH
    """
    availability: ProjectAvailability
    """
    SSH Private Key for Project
    Will be used to authenticate against the Git Repo of the Project
    Needs to be in single string separated by \`\n\`, example:
    \`\`\`
    -----BEGIN RSA PRIVATE KEY-----\nMIIJKQIBAAKCAgEA+o[...]P0yoL8BoQQG2jCvYfWh6vyglQdrDYx/o6/8ecTwXokKKh6fg1q\n-----END RSA PRIVATE KEY-----
    \`\`\`
    """
    privateKey: String
    """
    Set if the .lagoon.yml should be found in a subfolder
    Usefull if you have multiple Lagoon projects per Git Repository
    """
    subfolder: String
    """
    Notifications that should be sent for this project
    """
    notifications(type: NotificationType, contentType: NotificationContentType, notificationSeverityThreshold: ProblemSeverityRating): [Notification]
    """
    Which internal Lagoon System is responsible for deploying
    Currently only 'lagoon_controllerBuildDeploy' exists
    """
    activeSystemsDeploy: String
    """
    Which internal Lagoon System is responsible for promoting
    Currently only 'lagoon_controllerBuildDeploy' exists
    """
    activeSystemsPromote: String
    """
    Which internal Lagoon System is responsible for promoting
    Currently only 'lagoon_controllerRemove' exists
    """
    activeSystemsRemove: String
    """
    Which internal Lagoon System is responsible for tasks
    Currently only 'lagoon_controllerJob' exists
    """
    activeSystemsTask: String
    """
    Which internal Lagoon System is responsible for miscellaneous tasks
    Currently only 'lagoon_controllerMisc' exists
    """
    activeSystemsMisc: String
    """
    Which branches should be deployed, can be one of:
    - \`true\` - all branches are deployed
    - \`false\` - no branches are deployed
    - REGEX - regex of all branches that should be deployed, example: \`^(main|staging)$\`
    """
    branches: String
    """
    Which Pull Requests should be deployed, can be one of:
    - \`true\` - all pull requests are deployed
    - \`false\` - no pull requests are deployed
    - REGEX - regex of all Pull Request titles that should be deployed, example: \`[BUILD]\`
    """
    pullrequests: String
    """
    Which environment(the name) should be marked as the production environment.
    *Important:* If you change this, you need to deploy both environments (the current and previous one) that are affected in order for the change to propagate correctly
    """
    productionEnvironment: String
    """
    Routes that are attached to the active environment
    """
    productionRoutes: String
    """
    The drush alias to use for the active production environment
    *Important:* This is mainly used for drupal, but could be used for other services potentially
    """
    productionAlias: String
    """
    Which environment(the name) should be marked as the production standby environment.
    *Important:* This is used to determine which environment should be marked as the standby production environment
    """
    standbyProductionEnvironment: String
    """
    Routes that are attached to the standby environment
    """
    standbyRoutes: String
    """
    The drush alias to use for the standby production environment
    *Important:* This is mainly used for drupal, but could be used for other services potentially
    """
    standbyAlias: String
    """
    Should this project have auto idling enabled (\`1\` or \`0\`)
    """
    autoIdle: Int
    """
    Should storage for this environment be calculated (\`1\` or \`0\`)
    """
    storageCalc: Int
    """
    Should the Problems UI be available for this Project (\`1\` or \`0\`)
    """
    problemsUi: Int
    """
    Should the Facts UI be available for this Project (\`1\` or \`0\`)
    """
    factsUi: Int
    """
    Reference to OpenShift Object this Project should be deployed to
    """
    openshift: Openshift
    """
    Pattern of OpenShift Project/Namespace that should be generated, default: \`$\{project}-$\{environmentname}\`
    """
    openshiftProjectPattern: String
    """
    Reference to Kubernetes Object this Project should be deployed to
    """
    kubernetes: Kubernetes
    """
    Pattern of Kubernetes Namespace that should be generated, default: \`$\{project}-$\{environmentname}\`
    """
    kubernetesNamespacePattern: String
    """
    How many environments can be deployed at one timeout
    """
    developmentEnvironmentsLimit: Int
    """
    Name of the OpenShift Project/Namespace
    """
    openshiftProjectName: String
    """
    Deployed Environments for this Project
    """
    environments(
      """
      Filter by Environment Type
      """
      type: EnvType
      """
      Include deleted Environments (by default deleted environment are hidden)
      """
      includeDeleted: Boolean
    ): [Environment]
    """
    Creation Timestamp of Project
    """
    created: String
    """
    Environment variables available during build-time and run-time
    """
    envVariables: [EnvKeyValue]
    """
    Which groups are directly linked to project
    """
    groups: [GroupInterface]
    """
    Metadata key/values stored against a project
    """
    metadata: JSON
  }

  """
  Lagoon Environment (for each branch, pullrequest there is an individual environment)
  """
  type Environment {
    """
    Internal ID of this Environment
    """
    id: Int
    """
    Name of this Environment
    """
    name: String
    """
    Reference to the Project Object
    """
    project: Project
    """
    Which Deployment Type this environment is, can be \`branch\`, \`pullrequest\`, \`promote\`
    """
    deployType: String
    """
    The version control base ref for deployments (e.g., branch name, tag, or commit id)
    """
    deployBaseRef: String
    """
    The version control head ref for deployments (e.g., branch name, tag, or commit id)
    """
    deployHeadRef: String
    """
    The title of the last deployment (PR title)
    """
    deployTitle: String
    """
    Should this environment have auto idling enabled (\`1\` or \`0\`)
    """
    autoIdle: Int
    """
    Which Environment Type this environment is, can be \`production\`, \`development\`
    """
    environmentType: String
    """
    Name of the OpenShift Project/Namespace this environment is deployed into
    """
    openshiftProjectName: String
    """
    Name of the Kubernetes Namespace this environment is deployed into
    """
    kubernetesNamespaceName: String
    """
    Unix Timestamp of the last time this environment has been updated
    """
    updated: String
    """
    Unix Timestamp if the creation time
    """
    created: String
    """
    Unix Timestamp of when this project has been deleted
    """
    deleted: String
    """
    Reference to EnvironmentHoursMonth API Object, which returns how many hours this environment ran in a specific month
    """
    hoursMonth(month: Date): EnvironmentHoursMonth
    """
    Reference to EnvironmentStorage API Object, which shows the Storage consumption of this environment per day
    """
    storages: [EnvironmentStorage]
    """
    Reference to EnvironmentStorageMonth API Object, which returns how many storage per day this environment used in a specific month
    """
    storageMonth(month: Date): EnvironmentStorageMonth
    """
    Reference to EnvironmentHitsMonth API Object, which returns how many hits this environment generated in a specific month
    """
    hitsMonth(month: Date): EnvironmentHitsMonth
    """
    Environment variables available during build-time and run-time
    """
    envVariables: [EnvKeyValue]
    route: String
    routes: String
    monitoringUrls: String
    deployments(name: String): [Deployment]
    backups(includeDeleted: Boolean): [Backup]
    tasks(id: Int): [Task]
    services: [EnvironmentService]
    problems(severity: [ProblemSeverityRating], source: [String]): [Problem]
    facts: [Fact]
  }

  type EnvironmentHitsMonth {
    total: Int
  }

  type EnvironmentStorage {
    id: Int
    environment: Environment
    persistentStorageClaim: String
    bytesUsed: Float
    updated: String
  }

  type EnvironmentStorageMonth {
    month: String
    bytesUsed: Float
  }

  type EnvironmentHoursMonth {
    month: String
    hours: Int
  }

  type EnvironmentService {
    id: Int
    name: String
  }

  type Backup {
    id: Int
    environment: Environment
    source: String
    backupId: String
    created: String
    deleted: String
    restore: Restore
  }

  type Restore {
    id: Int
    backupId: String
    status: String
    restoreLocation: String
    created: String
  }

  type Deployment {
    id: Int
    name: String
    status: String
    created: String
    started: String
    completed: String
    environment: Environment
    remoteId: String
    buildLog: String
    """
    The Lagoon URL
    """
    uiLink: String
  }

  type EnvKeyValue {
    id: Int
    scope: String
    name: String
    value: String
  }

  type Task {
    id: Int
    name: String
    status: String
    created: String
    started: String
    completed: String
    environment: Environment
    service: String
    command: String
    remoteId: String
    logs: String
    files: [File]
  }

  type BillingModifier {
    id: Int
    group: BillingGroup
    startDate: String
    endDate: String
    discountFixed: Float
    discountPercentage: Float
    extraFixed: Float
    extraPercentage: Float
    min: Float
    max: Float
    customerComments: String
    adminComments: String
    weight: Int
  }

  input DeleteEnvironmentInput {
    name: String!
    project: String!
    execute: Boolean
  }

  input MetadataKeyValue {
    key: String!
    value: String
  }

  input UpdateMetadataInput {
    id: Int!
    patch: MetadataKeyValue!
  }

  input RemoveMetadataInput {
    id: Int!
    key: String!
  }


  type Query {
    """
    Returns the current user
    """
    me: User
    """
    Returns User Object by a given sshKey
    """
    userBySshKey(sshKey: String!): User
    """
    Returns Project Object by a given name
    """
    projectByName(name: String!): Project
    """
    Returns Group Object by a given name
    """
    groupByName(name: String!): GroupInterface
    """
    Returns Project Object by a given gitUrl (only the first one if there are multiple)
    """
    projectByGitUrl(gitUrl: String!): Project
    environmentByName(name: String!, project: Int!): Environment
    environmentById(id: Int!): Environment
    """
    Returns Environment Object by a given openshiftProjectName
    """
    environmentByOpenshiftProjectName(
      openshiftProjectName: String!
    ): Environment
    """
    Returns Environment Object by a given kubernetesNamespaceName
    """
    environmentByKubernetesNamespaceName(
      kubernetesNamespaceName: String!
    ): Environment
    userCanSshToEnvironment(
      openshiftProjectName: String
      kubernetesNamespaceName: String
    ): Environment
    deploymentByRemoteId(id: String): Deployment
    taskByRemoteId(id: String): Task
    taskById(id: Int): Task
    """
    Returns all Project Objects matching given filters (all if no filter defined)
    """
    allProjects(createdAfter: String, gitUrl: String, order: ProjectOrderType): [Project]
    """
    Returns all Project Objects matching metadata filters
    """
    projectsByMetadata(metadata: [MetadataKeyValue]): [Project]
    """
    Returns all OpenShift Objects
    """
    allOpenshifts: [Openshift]
    """
    Returns all Kubernetes Objects
    """
    allKubernetes: [Kubernetes]
    """
    Returns all Environments matching given filter (all if no filter defined)
    """
    allEnvironments(createdAfter: String, type: EnvType, order: EnvOrderType): [Environment]
    """
    Returns all Problems matching given filter (all if no filter defined)
    """
    allProblems(source: [String], project: Int, environment: Int, envType: [EnvType], identifier: String, severity: [ProblemSeverityRating]): [Problem]
    problemSources: [String]
    """
    Returns all Groups matching given filter (all if no filter defined)
    """
    allGroups(name: String, type: String): [GroupInterface]
    """
    Returns all projects in a given group
    """
    allProjectsInGroup(input: GroupInput): [Project]
    """
    Returns the costs for a given billing group
    """
    billingGroupCost(input: GroupInput, month: String!): JSON
    """
    Returns the costs for all billing groups
    """
    allBillingGroupsCost(month: String!): JSON
    """
    Returns the Billing Group Modifiers for a given Billing Group (all modifiers for the Billing Group will be returned if the month is not provided)
    """
    allBillingModifiers(input: GroupInput!, month: String): [BillingModifier]
    """
    Returns LAGOON_VERSION
    """
    lagoonVersion: JSON
    """
    Returns all ProblemHarborScanMatchers
    """
    allProblemHarborScanMatchers: [ProblemHarborScanMatch]
  }

  # Must provide id OR name
  input ProjectInput {
    id: Int
    name: String
  }

  # Must provide id OR name and project
  input EnvironmentInput {
    id: Int
    name: String
    project: ProjectInput
  }

  # Must provide id OR name and environment
  input DeploymentInput {
    id: Int
    name: String
    environment: EnvironmentInput
  }

  input AddSshKeyInput {
    id: Int
    name: String!
    keyValue: String!
    keyType: SshKeyType!
    user: UserInput!
  }

  input DeleteSshKeyInput {
    name: String!
  }

  input DeleteSshKeyByIdInput {
    id: Int!
  }

  input AddProjectInput {
    id: Int
    name: String!
    gitUrl: String!
    subfolder: String
    openshift: Int
    openshiftProjectPattern: String
    kubernetes: Int
    kubernetesNamespacePattern: String
    activeSystemsDeploy: String
    activeSystemsPromote: String
    activeSystemsRemove: String
    activeSystemsTask: String
    activeSystemsMisc: String
    branches: String
    pullrequests: String
    productionEnvironment: String!
    productionRoutes: String
    productionAlias: String
    standbyProductionEnvironment: String
    standbyRoutes: String
    standbyAlias: String
    availability: ProjectAvailability
    autoIdle: Int
    storageCalc: Int
    developmentEnvironmentsLimit: Int
    privateKey: String
    problemsUi: Int
    factsUi: Int
  }

  input AddEnvironmentInput {
    id: Int
    name: String!
    project: Int!
    deployType: DeployType!
    deployBaseRef: String!
    deployHeadRef: String
    deployTitle: String
    environmentType: EnvType!
    openshiftProjectName: String
    kubernetesNamespaceName: String
  }

  input AddOrUpdateEnvironmentStorageInput {
    environment: Int!
    persistentStorageClaim: String!
    bytesUsed: Int!
    """
    Date in format 'YYYY-MM-DD'
    """
    updated: String
  }

  input AddBackupInput {
    id: Int
    environment: Int!
    source: String!
    backupId: String!
    created: String!
  }

  input DeleteBackupInput {
    backupId: String!
  }

  input AddRestoreInput {
    id: Int
    status: RestoreStatusType
    restoreLocation: String
    created: String
    execute: Boolean
    backupId: String!
  }

  input UpdateRestoreInput {
    backupId: String!
    patch: UpdateRestorePatchInput!
  }

  input UpdateRestorePatchInput {
    status: RestoreStatusType
    created: String
    restoreLocation: String
  }


  input AddDeploymentInput {
    id: Int
    name: String!
    status: DeploymentStatusType!
    created: String!
    started: String
    completed: String
    environment: Int!
    remoteId: String
  }

  input DeleteDeploymentInput {
    id: Int!
  }

  input UpdateDeploymentPatchInput {
    name: String
    status: DeploymentStatusType
    created: String
    started: String
    completed: String
    environment: Int
    remoteId: String
  }

  input UpdateDeploymentInput {
    id: Int!
    patch: UpdateDeploymentPatchInput!
  }

  input CancelDeploymentInput {
    deployment: DeploymentInput!
  }

  input TaskInput {
    id: Int
    name: String!
    status: TaskStatusType
    created: String
    started: String
    completed: String
    environment: Int!
    service: String
    command: String
    remoteId: String
    execute: Boolean
  }

  input DeleteTaskInput {
    id: Int!
  }

  input UpdateTaskPatchInput {
    name: String
    status: TaskStatusType
    created: String
    started: String
    completed: String
    environment: Int
    service: String
    command: String
    remoteId: String
  }

  input UpdateTaskInput {
    id: Int!
    patch: UpdateTaskPatchInput!
  }

  input AddOpenshiftInput {
    id: Int
    name: String!
    consoleUrl: String!
    token: String
    routerPattern: String
    projectUser: String
    sshHost: String
    sshPort: String
    monitoringConfig: JSON
  }

  input AddKubernetesInput {
    id: Int
    name: String!
    consoleUrl: String!
    token: String
    routerPattern: String
    projectUser: String
    sshHost: String
    sshPort: String
    monitoringConfig: JSON
  }

  input DeleteOpenshiftInput {
    name: String!
  }

  input DeleteKubernetesInput {
    name: String!
  }

  input AddNotificationMicrosoftTeamsInput {
    name: String!
    webhook: String!
  }
  input AddNotificationEmailInput {
    name: String!
    emailAddress: String!
  }

  input AddNotificationRocketChatInput {
    name: String!
    webhook: String!
    channel: String!
  }

  input AddNotificationSlackInput {
    name: String!
    webhook: String!
    channel: String!
  }

  input DeleteNotificationMicrosoftTeamsInput {
    name: String!
  }
  input DeleteNotificationEmailInput {
    name: String!
  }

  input DeleteNotificationRocketChatInput {
    name: String!
  }

  input DeleteNotificationSlackInput {
    name: String!
  }

  input AddNotificationToProjectInput {
    project: String!
    notificationType: NotificationType!
    notificationName: String!
    contentType: NotificationContentType
    notificationSeverityThreshold: ProblemSeverityRating
  }

  input RemoveNotificationFromProjectInput {
    project: String!
    notificationType: NotificationType!
    notificationName: String!
  }

  input AddUserInput {
    email: String!
    firstName: String
    lastName: String
    comment: String
    gitlabId: Int
  }

  input UpdateUserPatchInput {
    email: String
    firstName: String
    lastName: String
    comment: String
    gitlabId: Int
  }

  input UpdateUserInput {
    user: UserInput!
    patch: UpdateUserPatchInput!
  }

  input DeleteUserInput {
    user: UserInput!
  }

  input DeleteProjectInput {
    project: String!
  }

  input UpdateProjectPatchInput {
    name: String
    gitUrl: String
    availability: ProjectAvailability
    privateKey: String
    subfolder: String
    activeSystemsDeploy: String
    activeSystemsRemove: String
    activeSystemsTask: String
    activeSystemsMisc: String
    activeSystemsPromote: String
    branches: String
    productionEnvironment: String
    productionRoutes: String
    productionAlias: String
    standbyProductionEnvironment: String
    standbyRoutes: String
    standbyAlias: String
    autoIdle: Int
    storageCalc: Int
    pullrequests: String
    openshift: Int
    openshiftProjectPattern: String
    kubernetes: Int
    kubernetesNamespacePattern: String
    developmentEnvironmentsLimit: Int
    problemsUi: Int
    factsUi: Int
  }

  input UpdateProjectInput {
    id: Int!
    patch: UpdateProjectPatchInput!
  }

  input UpdateOpenshiftPatchInput {
    name: String
    consoleUrl: String
    token: String
    routerPattern: String
    projectUser: String
    sshHost: String
    sshPort: String
    monitoringConfig: JSON
  }

  input UpdateOpenshiftInput {
    id: Int!
    patch: UpdateOpenshiftPatchInput!
  }

  input UpdateKubernetesPatchInput {
    name: String
    consoleUrl: String
    token: String
    routerPattern: String
    projectUser: String
    sshHost: String
    sshPort: String
    monitoringConfig: JSON
  }

  input UpdateKubernetesInput {
    id: Int!
    patch: UpdateKubernetesPatchInput!
  }

  input UpdateNotificationMicrosoftTeamsPatchInput {
    name: String
    webhook: String
    channel: String
  }
  input UpdateNotificationEmailPatchInput {
    name: String
    emailAddress: String
  }

  input UpdateNotificationRocketChatPatchInput {
    name: String
    webhook: String
    channel: String
  }

  input UpdateNotificationSlackPatchInput {
    name: String
    webhook: String
    channel: String
  }

  input UpdateNotificationMicrosoftTeamsInput {
    name: String!
    patch: UpdateNotificationMicrosoftTeamsPatchInput
  }
  input UpdateNotificationEmailInput {
    name: String!
    patch: UpdateNotificationEmailPatchInput
  }

  input UpdateNotificationRocketChatInput {
    name: String!
    patch: UpdateNotificationRocketChatPatchInput
  }

  input UpdateNotificationSlackInput {
    name: String!
    patch: UpdateNotificationSlackPatchInput
  }

  input UpdateSshKeyPatchInput {
    name: String
    keyValue: String
    keyType: SshKeyType
  }

  input UpdateSshKeyInput {
    id: Int!
    patch: UpdateSshKeyPatchInput!
  }

  input UpdateEnvironmentPatchInput {
    project: Int
    deployType: DeployType
    deployBaseRef: String
    deployHeadRef: String
    deployTitle: String
    environmentType: EnvType
    openshiftProjectName: String
    kubernetesNamespaceName: String
    route: String
    routes: String
    monitoringUrls: String
    autoIdle: Int
    """
    Timestamp in format 'YYYY-MM-DD hh:mm:ss'
    """
    created: String
  }

  input UpdateEnvironmentInput {
    id: Int!
    patch: UpdateEnvironmentPatchInput
  }

  input EnvVariableInput {
    id: Int
    type: EnvVariableType
    typeId: Int!
    scope: EnvVariableScope
    name: String!
    value: String!
  }

  input DeleteEnvVariableInput {
    id: Int!
  }

  input SetEnvironmentServicesInput {
    environment: Int!
    services: [String]!
  }

  input UploadFilesForTaskInput {
    task: Int!,
    files: [Upload]!,
  }

  input DeleteFilesForTaskInput {
    id: Int!
  }

  input DeployEnvironmentLatestInput {
    environment: EnvironmentInput!
  }

  input DeployEnvironmentBranchInput {
    project: ProjectInput!
    branchName: String!
    branchRef: String
  }

  input DeployEnvironmentPullrequestInput {
    project: ProjectInput!
    number: Int!
    title: String!
    baseBranchName: String!
    baseBranchRef: String!
    headBranchName: String!
    headBranchRef: String!
  }

  input DeployEnvironmentPromoteInput {
    sourceEnvironment: EnvironmentInput!
    project: ProjectInput!
    destinationEnvironment: String!
  }

  input switchActiveStandbyInput {
    project: ProjectInput!
  }

  input GroupInput {
    id: String
    name: String
  }

  input AddGroupInput {
    name: String!
    parentGroup: GroupInput
  }

  input AddBillingModifierInput {
    """
    The existing billing group for this modifier
    """
    group: GroupInput!
    """
    The date this modifier should start to be applied - Format: YYYY-MM-DD
    """
    startDate: String!
    """
    The date this modifer will expire - Format: YYYY-MM-DD
    """
    endDate: String!
    """
    The amount that the total monthly bill should be discounted - Format (Float)
    """
    discountFixed: Float
    """
    The percentage the total monthly bill should be discounted - Format (0-100)
    """
    discountPercentage: Float
    """
    The amount of exta cost that should be added to the total- Format (Float)
    """
    extraFixed: Float
    """
    The percentage the total monthly bill should be added - Format (0-100)
    """
    extraPercentage: Float
    """
    The minimum amount of the invoice applied to the total- Format (Float)
    """
    min: Float
    """
    The maximum amount of the invoice applied to the total- Format (Float)
    """
    max: Float
    """
    Customer comments are visible to the customer
    """
    customerComments: String
    """
    Admin comments will not be visible to the customer.
    """
    adminComments: String!
    """
    The order this modifer should be applied
    """
    weight: Int
  }

  input BillingModifierPatchInput {
    group: GroupInput
    startDate: String
    endDate: String
    discountFixed: Float
    discountPercentage: Float
    extraFixed: Float
    extraPercentage: Float
    min: Float
    max: Float
    customerComments: String
    adminComments: String
    weight: Int
  }

  input UpdateBillingModifierInput {
    id: Int!
    patch: BillingModifierPatchInput!
  }

  input DeleteBillingModifierInput {
    id: Int!
  }

  input UpdateGroupPatchInput {
    name: String
  }

  input UpdateGroupInput {
    group: GroupInput!
    patch: UpdateGroupPatchInput!
  }

  input DeleteGroupInput {
    group: GroupInput!
  }

  input UserInput {
    id: String
    email: String
  }

  input UserGroupInput {
    user: UserInput!
    group: GroupInput!
  }

  input UserGroupRoleInput {
    user: UserInput!
    group: GroupInput!
    role: GroupRole!
  }

  input ProjectGroupsInput {
    project: ProjectInput!
    groups: [GroupInput!]!
  }

  input BillingGroupInput {
    name: String!
    currency: Currency!
    billingSoftware: String
    uptimeRobotStatusPageId: String
  }

  input ProjectBillingGroupInput {
    group: GroupInput!
    project: ProjectInput!
  }

  input UpdateBillingGroupPatchInput {
    name: String!
    currency: Currency
    billingSoftware: String
    uptimeRobotStatusPageId: String
  }

  input UpdateBillingGroupInput {
    group: GroupInput!
    patch: UpdateBillingGroupPatchInput!
  }

  type Mutation {
    """
    Add Environment or update if it is already existing
    """
    addOrUpdateEnvironment(input: AddEnvironmentInput!): Environment
    updateEnvironment(input: UpdateEnvironmentInput!): Environment
    deleteEnvironment(input: DeleteEnvironmentInput!): String
    deleteAllEnvironments: String
    """
    Add or update Storage Information for Environment
    """
    addOrUpdateEnvironmentStorage(
      input: AddOrUpdateEnvironmentStorageInput!
    ): EnvironmentStorage
    addNotificationSlack(input: AddNotificationSlackInput!): NotificationSlack
    updateNotificationSlack(
      input: UpdateNotificationSlackInput!
    ): NotificationSlack
    deleteNotificationSlack(input: DeleteNotificationSlackInput!): String
    deleteAllNotificationSlacks: String
    addNotificationRocketChat(
      input: AddNotificationRocketChatInput!
    ): NotificationRocketChat
    updateNotificationRocketChat(
      input: UpdateNotificationRocketChatInput!
    ): NotificationRocketChat
    deleteNotificationRocketChat(
      input: DeleteNotificationRocketChatInput!
    ): String
    deleteAllNotificationRocketChats: String
    addNotificationMicrosoftTeams(
      input: AddNotificationMicrosoftTeamsInput!
    ): NotificationMicrosoftTeams
    updateNotificationMicrosoftTeams(
      input: UpdateNotificationMicrosoftTeamsInput!
    ): NotificationMicrosoftTeams
    deleteNotificationMicrosoftTeams(
      input: DeleteNotificationMicrosoftTeamsInput!
    ): String
    deleteAllNotificationMicrosoftTeams: String
    addNotificationEmail(
      input: AddNotificationEmailInput!
    ): NotificationEmail
    updateNotificationEmail(
      input: UpdateNotificationEmailInput!
    ): NotificationEmail
    deleteNotificationEmail(
      input: DeleteNotificationEmailInput!
    ): String
    deleteAllNotificationEmails: String
    """
    Connect previous created Notification to a Project
    """
    addNotificationToProject(input: AddNotificationToProjectInput!): Project
    removeNotificationFromProject(
      input: RemoveNotificationFromProjectInput!
    ): Project
    removeAllNotificationsFromAllProjects: String
    addOpenshift(input: AddOpenshiftInput!): Openshift
    updateOpenshift(input: UpdateOpenshiftInput!): Openshift
    deleteOpenshift(input: DeleteOpenshiftInput!): String
    deleteAllOpenshifts: String
    addKubernetes(input: AddKubernetesInput!): Kubernetes
    updateKubernetes(input: UpdateKubernetesInput!): Kubernetes
    deleteKubernetes(input: DeleteKubernetesInput!): String
    deleteAllKubernetes: String
    addProject(input: AddProjectInput!): Project
    updateProject(input: UpdateProjectInput!): Project
    deleteProject(input: DeleteProjectInput!): String
    deleteAllProjects: String
    addSshKey(input: AddSshKeyInput!): SshKey
    updateSshKey(input: UpdateSshKeyInput!): SshKey
    deleteSshKey(input: DeleteSshKeyInput!): String
    deleteSshKeyById(input: DeleteSshKeyByIdInput!): String
    deleteAllSshKeys: String
    removeAllSshKeysFromAllUsers: String
    addUser(input: AddUserInput!): User
    updateUser(input: UpdateUserInput!): User
    deleteUser(input: DeleteUserInput!): String
    deleteAllUsers: String
    addDeployment(input: AddDeploymentInput!): Deployment
    deleteDeployment(input: DeleteDeploymentInput!): String
    updateDeployment(input: UpdateDeploymentInput): Deployment
    cancelDeployment(input: CancelDeploymentInput!): String
    addBackup(input: AddBackupInput!): Backup
    addProblem(input: AddProblemInput!): Problem
    addProblemHarborScanMatch(input: AddProblemHarborScanMatchInput!): ProblemHarborScanMatch
    deleteProblem(input: DeleteProblemInput!): String
    deleteProblemsFromSource(input: DeleteProblemsFromSourceInput!): String
    deleteProblemHarborScanMatch(input: DeleteProblemHarborScanMatchInput!): String
    addFact(input: AddFactInput!): Fact
    addFacts(input: AddFactsInput!): [Fact]
    deleteFact(input: DeleteFactInput!): String
    deleteFactsFromSource(input: DeleteFactsFromSourceInput!): String
    deleteBackup(input: DeleteBackupInput!): String
    deleteAllBackups: String
    addRestore(input: AddRestoreInput!): Restore
    updateRestore(input: UpdateRestoreInput!): Restore
    addEnvVariable(input: EnvVariableInput!): EnvKeyValue
    deleteEnvVariable(input: DeleteEnvVariableInput!): String
    addTask(input: TaskInput!): Task
    taskDrushArchiveDump(environment: Int!): Task
    taskDrushSqlDump(environment: Int!): Task
    taskDrushCacheClear(environment: Int!): Task
    taskDrushCron(environment: Int!): Task
    taskDrushSqlSync(
      sourceEnvironment: Int!
      destinationEnvironment: Int!
    ): Task
    taskDrushRsyncFiles(
      sourceEnvironment: Int!
      destinationEnvironment: Int!
    ): Task
    taskDrushUserLogin(environment: Int!): Task
    deleteTask(input: DeleteTaskInput!): String
    updateTask(input: UpdateTaskInput): Task
    setEnvironmentServices(input: SetEnvironmentServicesInput!): [EnvironmentService]
    uploadFilesForTask(input: UploadFilesForTaskInput!): Task
    deleteFilesForTask(input: DeleteFilesForTaskInput!): String
    deployEnvironmentLatest(input: DeployEnvironmentLatestInput!): String
    deployEnvironmentBranch(input: DeployEnvironmentBranchInput!): String
    deployEnvironmentPullrequest(input: DeployEnvironmentPullrequestInput!): String
    deployEnvironmentPromote(input: DeployEnvironmentPromoteInput!): String
    switchActiveStandby(input: switchActiveStandbyInput!): Task
    addGroup(input: AddGroupInput!): GroupInterface
    updateGroup(input: UpdateGroupInput!): GroupInterface
    deleteGroup(input: DeleteGroupInput!): String
    deleteAllGroups: String
    addUserToGroup(input: UserGroupRoleInput!): GroupInterface
    removeUserFromGroup(input: UserGroupInput!): GroupInterface
    addGroupsToProject(input: ProjectGroupsInput): Project
    addBillingGroup(input: BillingGroupInput!): BillingGroup
    updateBillingGroup(input: UpdateBillingGroupInput!): BillingGroup
    deleteBillingGroup(input: DeleteGroupInput!): String
    addProjectToBillingGroup(input: ProjectBillingGroupInput): Project
    updateProjectBillingGroup(input: ProjectBillingGroupInput): Project
    removeProjectFromBillingGroup(input: ProjectBillingGroupInput): Project
    removeGroupsFromProject(input: ProjectGroupsInput!): Project
    updateProjectMetadata(input: UpdateMetadataInput!): Project
    removeProjectMetadataByKey(input: RemoveMetadataInput!): Project
    addBillingModifier(input: AddBillingModifierInput!): BillingModifier
    updateBillingModifier(input: UpdateBillingModifierInput!): BillingModifier
    deleteBillingModifier(input: DeleteBillingModifierInput!): String
    deleteAllBillingModifiersByBillingGroup(input: GroupInput!): String
  }

  type Subscription {
    backupChanged(environment: Int!): Backup
    deploymentChanged(environment: Int!): Deployment
    taskChanged(environment: Int!): Task
  }
`;

module.exports = typeDefs;
