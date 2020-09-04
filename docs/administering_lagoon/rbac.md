# Role-Based Access Control \(RBAC\)

Version 1.0 of Lagoon changed how you access your projects! Access to your project is handled via groups, with projects assigned to one or multiple groups. Users are added to groups with a role. Groups can also be nested within sub-groups. This change provides a lot more flexibility and the possibility to recreate real world teams within Lagoon.

## Roles

When assigning a user to a group, you need to provide a group role for that user inside this group. Each one of the 5 current existing group roles gives the user different permissions to the group and projects assigned to the group. Here are the platform-wide roles and the group roles that are currently found in Lagoon:

### Platform-Wide Roles

#### Platform-Wide Admin

The platform-wide admin has access to everything across all of Lagoon. That includes dangerous mutations like deleting all projects. Use very, _very,_ **very** carefully.

#### Platform-Wide Owner

The platform-wide owner has access to every Lagoon group, like the group owner role, and can be used if you need a user that needs access to everything but you don't want to assign the user to every group.

### Group Roles

#### Owner

The owner role can do everything within a group and its associated projects. They can add and manage users of a group. Be careful with this role, as it can delete projects and production environments!

#### Maintainer

The maintainer role can do everything within a group and its associated projects except deleting the project itself or the production environment. They can add and manage users of a group.

#### Developer

The developer role has SSH access only to development environments. This role cannot access, update or delete the production environment. They can run a sync task with the production environment as a source, but not as the destination. Cannot manage users of a group.

!!!hint
    IMPORTANT: This role does not prevent the deployment of the production environment as a deployment is triggered via a Git push! You need to make sure that your Git server prevents these users from pushing into the branch defined as production environment.


#### Reporter

The reporter role has view access only. They cannot access any environments via SSH or make modifications to them. They can run cache-clear tasks. This role is mostly used for stakeholders to have access to Lagoon UI and logging.

#### Guest

The guest role has the same privileges as the reporter role listed above.

Here is a table that lists the roles and the access they have:

💡 _Tip: Scroll to the right to see the whole table!_

### Lagoon 1.0.0 RBAC Permission Matrix

|  |  |  |  | All Projects | and Groups |  |  |  |  |  |  |
| :--- | :--- | :--- | :--- | ---: | :--- | :--- | :--- | :--- | :--- | :--- | :--- |
| **Name** | **Resource** | **Scope** | **Attributes** | **Platform-Wide Admin** | **Platform-Wide Owner** | **Owner** | **Maintainer** | **Developer** | **Reporter** | **Guest** | **Self** |
| addBackup | backup | add | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deleteBackup | backup | delete | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| getBackupsByEnvironmentId | backup | view | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
|  | deployment | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| addEnvVariable \(to Project\) | env\_var | project:add | projectID | Yes | Yes | Yes | No | No | No | No |  |
| addEnvVariable \(to Environment\) | env\_var | environment:add:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| addEnvVariable \(to Environment\) | env\_var | environment:add:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deleteEnvVariable | env\_var | delete | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| getEnvVarsByProjectId | env\_var | project:view | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| getEnvVarsByEnvironmentId | env\_var | environment:view:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| getEnvVarsByEnvironmentId | env\_var | environment:view:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| addOrUpdateEnvironment | environment | addOrUpdate:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| addOrUpdateEnvironment | environment | addOrUpdate:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| updateEnvironment | environment | update:development | projectID | Yes | Yes | Yes | Yes | Yes |  |  |  |
| updateEnvironment | environment | update:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deleteEnvironment | environment | delete:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deleteEnvironment | environment | delete:production | projectID | Yes | Yes | Yes | No | No | No | No |  |
| addOrUpdateEnvironmentStorage | environment | storage |  | Yes | Yes |  |  |  |  |  |  |
| addDeployment | environment | deploy:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| addDeployment | environment | deploy:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deleteDeployment | deployment | delete | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| updateDeployment | deployment | update | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| setEnvironmentServices | environment | update:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| setEnvironmentServices | environment | update:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deployEnvironmentLatest | environment | deploy:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deployEnvironmentLatest | environment | deploy:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deployEnvironmentBranch | environment | deploy:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deployEnvironmentBranch | environment | deploy:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deployEnvironmentPullrequest | environment | deploy:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deployEnvironmentPullrequest | environment | deploy:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deployEnvironmentPromote | environment | deploy:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deployEnvironmentPromote | environment | deploy:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| getEnvironmentsByProjectId | environment | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| getEnvironmentStorageMonthByEnvironmentId | environment | storage |  | Yes |  |  |  |  |  |  |  |
| getEnvironmentHoursMonthByEnvironmentId | environment | storage |  | Yes |  |  |  |  |  |  |  |
| getEnvironmentHitsMonthByEnvironmentId | environment | storage |  | Yes |  |  |  |  |  |  |  |
| getEnvironmentServicesByEnvironmentId | environment | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| addGroup | group | add |  | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| updateGroup | group | update | groupID | Yes | Yes | Yes | Yes | No | No | No |  |
| deleteGroup | group | delete | groupID | Yes | Yes | Yes | Yes | No | No | No |  |
| addUserToGroup | group | addUser | groupID | Yes | Yes | Yes | Yes | No | No | No |  |
| removeUserFromGroup | group | removeUser | groupID | Yes | Yes | Yes | Yes | No | No | No |  |
| addNotificationSlack | notification | add |  | Yes | Yes |  |  |  |  |  |  |
| updateNotificationSlack | notification | update |  | Yes | Yes |  |  |  |  |  |  |
| deleteNotificationSlack | notification | delete |  | Yes | Yes |  |  |  |  |  |  |
| addNotificationRocketChat | notification | add |  | Yes | Yes |  |  |  |  |  |  |
| updateNotificationRocketChat | notification | update |  | Yes | Yes |  |  |  |  |  |  |
| deleteNotificationRocketChat | notification | delete |  | Yes | Yes |  |  |  |  |  |  |
| getNotificationsByProjectId | notification | view | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| addOpenshift | openshift | add |  | Yes | Yes |  |  |  |  |  |  |
| updateOpenshift | openshift | update |  | Yes | Yes |  |  |  |  |  |  |
| deleteOpenshift | openshift | delete |  | Yes | Yes |  |  |  |  |  |  |
| getAllOpenshifts | openshift | viewAll |  | Yes |  |  |  |  |  |  |  |
| getOpenshiftByProjectId | openshift | view | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| addNotificationToProject | project | addNotification | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| removeNotificationFromProject | project | removeNotification | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| addProject | project | add |  | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| updateProject | project | update | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| deleteProject | project | delete | projectID | Yes | Yes | Yes | No | No | No | No |  |
| addGroupsToProject | project | addGroup | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| removeGroupsFromProject | project | removeGroup | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| getAllProjects | project | viewAll |  | Yes | Yes |  |  |  |  |  |  |
| getProjectByEnvironmentId | project | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| getProjectByGitUrl | project | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| getProjectByName | project | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| addRestore | restore | add | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| updateRestore | restore | update | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| addSshKey | ssh\_key | add | userId | Yes | Yes |  |  |  |  |  | Yes |
| updateSshKey | ssh\_key | update | userId | Yes | Yes |  |  |  |  |  | Yes |
| deleteSshKey | ssh\_key | delete | userId | Yes | Yes |  |  |  |  |  | Yes |
| getUserSshKeys | ssh\_key | view:user | userID | Yes | Yes |  |  |  |  |  | Yes |
| addTask | task | add:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| addTask | task | add:production | projectID | Yes | Yes | Yes | Yes | No | No | No |  |
| taskDrushArchiveDump | task | drushArchiveDump:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushArchiveDump | task | drushArchiveDump:production | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushSqlDump | task | drushSqlDump:development | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushSqlDump | task | drushSqlDump:production | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushCacheClear | task | drushCacheClear:development | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| taskDrushCacheClear | task | drushCacheClear:production | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| taskDrushCron | task | drushCron:development | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| taskDrushCron | task | drushCron:production | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| taskDrushUserLogin | task | drushUserLogin:destination:production | EnvironmentID | Yes | Yes | Yes | Yes | No | No | No |  |
| taskDrushUserLogin | task | drushUserLogin:destination:development | EnvironmentID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushSqlSync | task | drushSqlSync:source:development | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushSqlSync | task | drushSqlSync:source:production | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushSqlSync | task | drushSqlSync:destination:production | ProjectID | Yes | Yes | Yes | Yes | No | No | No |  |
| taskDrushSqlSync | task | drushSqlSync:destination:development | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushRsyncFiles | task | drushRsync:source:development | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushRsyncFiles | task | drushRsync:source:production | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| taskDrushRsyncFiles | task | drushRsync:destination:production | ProjectID | Yes | Yes | Yes | Yes | No | No | No |  |
| taskDrushRsyncFiles | task | drushRsync:destination:development | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deleteTask | task | delete | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| updateTask | task | update | ProjectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| uploadFilesForTask | task | update | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| deleteFilesForTask | task | delete | projectID | Yes | Yes | Yes | Yes | Yes | No | No |  |
| getFilesByTaskId | task | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| getTasksByEnvironmentId | task | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| getTaskByRemoteId | task | view | projectID | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| addUser | user | add |  | Yes | Yes | Yes | Yes | Yes | Yes | Yes |  |
| updateUser | user | update | userId | Yes | Yes |  |  |  |  |  | Yes |
| deleteUser | user | delete | userId | Yes | Yes |  |  |  |  |  | Yes |
| getProjectByEnvironmentId | project | viewPrivateKey | projectID | Yes | Yes | Yes | No | No | No | No |  |
| getProjectByGitUrl | project | viewPrivateKey | projectID | Yes | Yes | Yes | No | No | No | No |  |
| getProjectByName | project | viewPrivateKey | projectID | Yes | Yes | Yes | No | No | No | No |  |
