import * as R from 'ramda';
import {
  connect,
  AmqpConnectionManager,
  ChannelWrapper
} from 'amqp-connection-manager';
import { ConfirmChannel, ConsumeMessage } from 'amqplib';
import { logger } from './local-logging';
import {
  getActiveSystemForProject,
  getEnvironmentsForProject,
  getOpenShiftInfoForProject,
  getBillingGroupForProject,
  addOrUpdateEnvironment,
  getEnvironmentByName,
  addDeployment
} from './api';
import sha1 from 'sha1';
import crypto from 'crypto';
import moment from 'moment';

interface MessageConsumer {
  (msg: ConsumeMessage): Promise<void>;
}

interface RetryHandler {
  (
    msg: ConsumeMessage,
    error: Error,
    retryCount: number,
    retryExpirationSecs: number
  ): void;
}

interface DeathHandler {
  (msg: ConsumeMessage, error: Error): void;
}

export let sendToLagoonTasks = function(
  task: string,
  payload?: any
) {
  // TODO: Actually do something here?
  return payload && undefined;
};

export let sendToLagoonTasksMonitor = function sendToLagoonTasksMonitor(
  task: string,
  payload?: any
) {
  // TODO: Actually do something here?
  return payload && undefined;
};

// TODO: This is weird, why do we need an empty default connection? Or is there
// a better way to type this?
const defaultConnection: AmqpConnectionManager = {
  // Default function for Event
  removeListener: (() => {}) as any,
  off: (() => {}) as any,
  removeAllListeners: (() => {}) as any,
  setMaxListeners: (() => {}) as any,
  getMaxListeners: (() => {}) as any,
  listeners: (() => {}) as any,
  rawListeners: (() => {}) as any,
  emit: (() => {}) as any,
  eventNames: (() => {}) as any,
  listenerCount: (() => {}) as any,

  // Default functions for AmqpConnectionManager
  addListener: (() => {}) as any,
  on: (() => {}) as any,
  once: (() => {}) as any,
  prependListener: (() => {}) as any,
  prependOnceListener: (() => {}) as any,
  createChannel: (() => {}) as any,
  isConnected: (() => {}) as any,
  close: (() => {}) as any
};

export let connection: AmqpConnectionManager = defaultConnection;
const rabbitmqHost = process.env.RABBITMQ_HOST || 'broker';
const rabbitmqUsername = process.env.RABBITMQ_USERNAME || 'guest';
const rabbitmqPassword = process.env.RABBITMQ_PASSWORD || 'guest';

const taskPrefetch = process.env.TASK_PREFETCH_COUNT ? Number(process.env.TASK_PREFETCH_COUNT) : 2;
const taskMonitorPrefetch = process.env.TASKMONITOR_PREFETCH_COUNT ? Number(process.env.TASKMONITOR_PREFETCH_COUNT) : 1;

// these are required for the builddeploydata creation
const CI = process.env.CI || "false"
const registry = process.env.REGISTRY || "registry.lagoon.svc:5000"
const lagoonGitSafeBranch = process.env.LAGOON_GIT_SAFE_BRANCH || "master"
const lagoonVersion = process.env.LAGOON_VERSION
const lagoonEnvironmentType = process.env.LAGOON_ENVIRONMENT_TYPE || "development"
const overwriteOCBuildDeployDindImage = process.env.OVERWRITE_OC_BUILD_DEPLOY_DIND_IMAGE
const overwriteKubectlBuildDeployDindImage = process.env.OVERWRITE_KUBECTL_BUILD_DEPLOY_DIND_IMAGE
const overwriteActiveStandbyTaskImage = process.env.OVERWRITE_ACTIVESTANDBY_TASK_IMAGE
const jwtSecret = process.env.JWTSECRET || "super-secret-string"

class UnknownActiveSystem extends Error {
  constructor(message) {
    super(message);
    this.name = 'UnknownActiveSystem';
  }
}

class NoNeedToDeployBranch extends Error {
  constructor(message) {
    super(message);
    this.name = 'NoNeedToDeployBranch';
  }
}

class NoNeedToRemoveBranch extends Error {
  constructor(message) {
    super(message);
    this.name = 'NoNeedToRemoveBranch';
  }
}

class CannotDeleteProductionEnvironment extends Error {
  constructor(message) {
    super(message);
    this.name = 'CannotDeleteProductionEnvironment';
  }
}

class EnvironmentLimit extends Error {
  constructor(message) {
    super(message);
    this.name = 'EnvironmentLimit';
  }
}

export const initSendToLagoonTasks = function() {
  connection = connect(
    [`amqp://${rabbitmqUsername}:${rabbitmqPassword}@${rabbitmqHost}`],
    // @ts-ignore
    { json: true }
  );

  connection.on('connect', ({ url }) =>
    logger.verbose('lagoon-tasks: Connected to %s', url, {
      action: 'connected',
      url
    })
  );
  connection.on('disconnect', params =>
    // @ts-ignore
    logger.error('lagoon-tasks: Not connected, error: %s', params.err.code, {
      action: 'disconnected',
      reason: params
    })
  );

  const channelWrapperTasks: ChannelWrapper = connection.createChannel({
    setup(channel: ConfirmChannel) {
      return Promise.all([
        // Our main Exchange for all lagoon-tasks
        channel.assertExchange('lagoon-tasks', 'direct', { durable: true }),

        channel.assertExchange('lagoon-tasks-delay', 'x-delayed-message', {
          durable: true,
          arguments: { 'x-delayed-type': 'fanout' }
        }),
        channel.bindExchange('lagoon-tasks', 'lagoon-tasks-delay', ''),

        // Exchange for task monitoring
        channel.assertExchange('lagoon-tasks-monitor', 'direct', {
          durable: true
        }),

        channel.assertExchange(
          'lagoon-tasks-monitor-delay',
          'x-delayed-message',
          { durable: true, arguments: { 'x-delayed-type': 'fanout' } }
        ),
        channel.bindExchange(
          'lagoon-tasks-monitor',
          'lagoon-tasks-monitor-delay',
          ''
        )
      ]);
    }
  });

  sendToLagoonTasks = async (
    task: string,
    payload: any
  ): Promise<string> => {
    try {
      const buffer = Buffer.from(JSON.stringify(payload));
      await channelWrapperTasks.publish('lagoon-tasks', task, buffer, {
        persistent: true
      });
      logger.debug(
        `lagoon-tasks: Successfully created task '${task}'`,
        payload
      );
      return `lagoon-tasks: Successfully created task '${task}': ${JSON.stringify(
        payload
      )}`;
    } catch (error) {
      logger.error('lagoon-tasks: Error send to lagoon-tasks exchange', {
        payload,
        error
      });
      throw error;
    }
  };

  sendToLagoonTasksMonitor = async (
    task: string,
    payload: any
  ): Promise<string> => {
    try {
      const buffer = Buffer.from(JSON.stringify(payload));
      await channelWrapperTasks.publish('lagoon-tasks-monitor', task, buffer, {
        persistent: true
      });
      logger.debug(
        `lagoon-tasks-monitor: Successfully created monitor '${task}'`,
        payload
      );
      return `lagoon-tasks-monitor: Successfully created task monitor '${task}': ${JSON.stringify(
        payload
      )}`;
    } catch (error) {
      logger.error(
        'lagoon-tasks-monitor: Error send to lagoon-tasks-monitor exchange',
        {
          payload,
          error
        }
      );
      throw error;
    }
  };
}

export const createTaskMonitor = async function(task: string, payload: any) {
  return sendToLagoonTasksMonitor(task, payload);
}

// makes strings "safe" if it is to be used in something dns related
const makeSafe = string => string.toLocaleLowerCase().replace(/[^0-9a-z-]/g,'-')

// This is used to send the required information directly to the message queue
// for the controllers to consume
// @TODO: make sure if it fails, it does so properly
const getOperatorBuildData = async function(deployData: any) {
  const {
    projectName,
    branchName,
    sha,
    type,
    pullrequestTitle,
    headBranchName: headBranch,
    headSha,
    baseBranchName: baseBranch,
    baseSha,
    promoteSourceEnvironment
  } = deployData;

  const project = await getActiveSystemForProject(projectName, 'Deploy');
  // const environments = await getEnvironmentsForProject(projectName);

  var environmentName = makeSafe(branchName)

  const result = await getOpenShiftInfoForProject(projectName);
  const projectOpenShift = result.project
  const billingGroupResult = await getBillingGroupForProject(projectName);
  const projectBillingGroup = billingGroupResult.project

  var overlength = 58 - projectName.length;
  if ( environmentName.length > overlength ) {
    var hash = sha1(environmentName).substring(0,4)
    environmentName = environmentName.substring(0, overlength-5)
    environmentName = environmentName.concat('-' + hash)
  }

  var environmentType = 'development'
  if (
    projectOpenShift.productionEnvironment === environmentName
    || projectOpenShift.standbyProductionEnvironment === environmentName
  ) {
    environmentType = 'production'
  }
  var gitSha = sha as string
  var projectTargetName = projectOpenShift.openshift.name
  var openshiftProject = projectOpenShift.openshiftProjectPattern ? projectOpenShift.openshiftProjectPattern.replace('${environment}',environmentName).replace('${project}', projectName) : `${projectName}-${environmentName}`
  var deployPrivateKey = projectOpenShift.privateKey
  var gitUrl = projectOpenShift.gitUrl
  var projectProductionEnvironment = projectOpenShift.productionEnvironment
  var projectStandbyEnvironment = projectOpenShift.standbyProductionEnvironment
  var subfolder = projectOpenShift.subfolder || ""
  var routerPattern = projectOpenShift.openshift.routerPattern ? projectOpenShift.openshift.routerPattern.replace('${environment}',environmentName).replace('${project}', projectName) : ""
  var prHeadBranch = headBranch || ""
  var prHeadSha = headSha || ""
  var prBaseBranch = baseBranch || ""
  var prBaseSha = baseSha || ""
  var prPullrequestTitle = pullrequestTitle || ""
  var prPullrequestNumber = branchName.replace('pr-','')
  var graphqlEnvironmentType = environmentType.toUpperCase()
  var graphqlGitType = type.toUpperCase()
  var openshiftPromoteSourceProject = promoteSourceEnvironment ? `${projectName}-${makeSafe(promoteSourceEnvironment)}` : ""
  // A secret which is the same across all Environments of this Lagoon Project
  var projectSecret = crypto.createHash('sha256').update(`${projectName}-${projectOpenShift.id}-${projectTargetName}-${jwtSecret}`).digest('hex');
  var alertContactHA = ""
  var alertContactSA = ""
  var monitoringConfig = JSON.parse(projectOpenShift.openshift.monitoringConfig) || "invalid"
  if (monitoringConfig != "invalid"){
    alertContactHA = monitoringConfig.uptimerobot.alertContactHA || ""
    alertContactSA = monitoringConfig.uptimerobot.alertContactSA || ""
  }
  var availability = projectOpenShift.availability || "STANDARD"

  var alertContact = ""
  if (alertContactHA != undefined && alertContactSA != undefined){
    if (availability == "HIGH") {
      alertContact = alertContactHA
    } else {
      alertContact = alertContactSA
    }
  } else {
    alertContact = "unconfigured"
  }
  const billingGroup = projectBillingGroup.groups.find(i => i.type == "billing" ) || ""
  var uptimeRobotStatusPageId = billingGroup.uptimeRobotStatusPageId || ""

  var branchData: any = {};
  var pullrequestData: any = {};
  var promoteData: any = {};

  switch (type) {
    case "branch":
      // if we have a sha given, we use that, if not we fall back to the branch (which needs be prefixed by `origin/`
      var gitRef = gitSha ? gitSha : `origin/${branchName}`
      var deployBaseRef = branchName
      var deployHeadRef = null
      var deployTitle = null
      branchData = {
        branch: {
          name: branchName,
        },
      };
      break;
    case "pullrequest":
      var gitRef = gitSha
      var deployBaseRef = prBaseBranch
      var deployHeadRef = prHeadBranch
      var deployTitle = prPullrequestTitle
      pullrequestData = {
        pullrequest: {
          headBranch: prHeadBranch,
          headSha: prHeadSha,
          baseBranch: prBaseBranch,
          baseSha: prBaseSha,
          title: prPullrequestTitle,
          number: prPullrequestNumber,
        },
      };
      break;
    case "promote":
      var gitRef = `origin/${promoteSourceEnvironment}`
      var deployBaseRef = promoteSourceEnvironment
      var deployHeadRef = null
      var deployTitle = null
      promoteData = {
        promote: {
          sourceEnvironment: promoteSourceEnvironment,
          sourceProject: openshiftPromoteSourceProject,
        }
      };
      break;
  }

  // @TODO: openshiftProject here can't be generated on the cluster side (it should be) but the addOrUpdate mutation doesn't allow for openshiftProject to be optional
  // maybe need to have this generate a random uid initially?
  let environment;
  try {
    environment = await addOrUpdateEnvironment(branchName, projectOpenShift.id, graphqlGitType, deployBaseRef, graphqlEnvironmentType, openshiftProject, deployHeadRef, deployTitle)
    logger.info(`${openshiftProject}: Created/Updated Environment in API`)
  } catch (err) {
    logger.error(err)
    throw new Error
  }

  const randBuildId = Math.random().toString(36).substring(7);
  const buildName = `lagoon-build-${randBuildId}`;

  let deployment;
  try {
    const now = moment.utc();
    const apiEnvironment = await getEnvironmentByName(branchName, projectOpenShift.id);
    deployment = await addDeployment(buildName, "NEW", now.format('YYYY-MM-DDTHH:mm:ss'), apiEnvironment.environmentByName.id);
  } catch (error) {
    logger.error(`Could not save deployment for project ${projectOpenShift.id}. Message: ${error}`);
  }

  let buildImage = {}
  // During CI we want to use the OpenShift Registry for our build Image and use the OpenShift registry for the base Images
  // Since the Operator could eventually support openshift, we can handle which image to supply here
  if (CI == "true") {
    switch (project.activeSystemsDeploy) {
      case 'lagoon_openshiftBuildDeploy':
        buildImage = "172.17.0.1:5000/lagoon/oc-build-deploy-dind:latest"
        break;
      default:
        // default to the kubectl builddeploy dind since the controllers and kubernetes use the same underlying process
        buildImage = "172.17.0.1:5000/lagoon/kubectl-build-deploy-dind:latest"
    }
  } else if (overwriteOCBuildDeployDindImage) {
    // allow to overwrite the image we use via OVERWRITE_OC_BUILD_DEPLOY_DIND_IMAGE env variable
    // this needs to be added to the `api` deployment/pods to be used
    switch (project.activeSystemsDeploy) {
      case 'lagoon_openshiftBuildDeploy':
        buildImage = overwriteOCBuildDeployDindImage
        break;
    }
  } else if (overwriteKubectlBuildDeployDindImage) {
    // allow to overwrite the image we use via OVERWRITE_KUBECTL_BUILD_DEPLOY_DIND_IMAGE env variable
    // this needs to be added to the `api` deployment/pods to be used
    switch (project.activeSystemsDeploy) {
      case 'lagoon_controllerBuildDeploy':
      case 'lagoon_kubernetesBuildDeploy':
        buildImage = overwriteKubectlBuildDeployDindImage
        break;
    }
  } else if (lagoonEnvironmentType == 'production') {
    // we are a production environment, use the amazeeio/ image with our current lagoon version
    switch (project.activeSystemsDeploy) {
      case 'lagoon_openshiftBuildDeploy':
        buildImage = `amazeeio/oc-build-deploy-dind:${lagoonVersion}`
        break;
      default:
          // default to the kubectl builddeploy dind since the controllers and kubernetes use the same underlying process
        buildImage = `amazeeio/kubectl-build-deploy-dind:${lagoonVersion}`
    }
  } else {
    // we are a development enviornment, use the amazeeiolagoon image with the same branch name
    buildImage = `amazeeiolagoon/kubectl-build-deploy-dind:${lagoonGitSafeBranch}`
    switch (project.activeSystemsDeploy) {
      case 'lagoon_openshiftBuildDeploy':
        buildImage = `amazeeiolagoon/oc-build-deploy-dind:${lagoonGitSafeBranch}`
        break;
      default:
          // default to the kubectl builddeploy dind since the controllers and kubernetes use the same underlying process
        buildImage = `amazeeiolagoon/kubectl-build-deploy-dind:${lagoonGitSafeBranch}`
    }
  }

  var gitRef = gitSha ? gitSha : `origin/${branchName}`

  // encode some values so they get sent to the controllers nicely
  const sshKeyBase64 = new Buffer(deployPrivateKey.replace(/\\n/g, "\n")).toString('base64')
  const envVars = new Buffer(JSON.stringify(environment.addOrUpdateEnvironment.envVariables)).toString('base64')
  const projectVars = new Buffer(JSON.stringify(projectOpenShift.envVariables)).toString('base64')

  // this is what will be returned and sent to the controllers via message queue, it is the lagoonbuild controller spec
  var buildDeployData: any = {
    metadata: {
      name: buildName,
      namespace: "lagoon",
    },
    spec: {
      build: {
        type: type,
        image: buildImage,
        ci: CI,
      },
      ...branchData,
      ...pullrequestData,
      ...promoteData,
      gitReference: gitRef,
      project: {
        name: projectName,
        gitUrl: gitUrl,
        uiLink: deployment.addDeployment.uiLink,
        environment: environmentName,
        environmentType: environmentType,
        productionEnvironment: projectProductionEnvironment,
        standbyEnvironment: projectStandbyEnvironment,
        subfolder: subfolder,
        routerPattern: routerPattern,
        deployTarget: projectTargetName,
        projectSecret: projectSecret,
        key: sshKeyBase64,
        registry: registry,
        monitoring: {
          contact: alertContact,
          statuspageID: uptimeRobotStatusPageId,
        },
        variables: {
          project: projectVars,
          environment: envVars,
        },
      },
    }
  };
  return buildDeployData;
}

export const createDeployTask = async function(deployData: any) {
  const {
    projectName,
    branchName,
    // sha,
    type,
    pullrequestTitle
  } = deployData;

  const project = await getActiveSystemForProject(projectName, 'Deploy');
  const environments = await getEnvironmentsForProject(projectName);

  // environments =
  //  { project:
  //     { environment_deployments_limit: 1,
  //       production_environment: 'master',
  //       environments: [ { name: 'develop', environment_type: 'development' }, [Object] ] } }

  if (typeof project.activeSystemsDeploy === 'undefined') {
    throw new UnknownActiveSystem(
      `No active system for tasks 'deploy' in for project ${projectName}`
    );
  }

  switch (project.activeSystemsDeploy) {
    case 'lagoon_openshiftBuildDeploy':
    case 'lagoon_kubernetesBuildDeploy':
    case 'lagoon_controllerBuildDeploy':
      // we want to limit production environments, without making it configurable currently
      var productionEnvironmentsLimit = 2;

      // we want to make sure we can deploy the `production` env, and also the env defined as standby
      if (
        environments.project.productionEnvironment === branchName ||
        environments.project.standbyProductionEnvironment === branchName
      ) {
        // get a list of production environments
        const prod_environments = environments.project.environments
          .filter(e => e.environmentType === 'production')
          .map(e => e.name);
        logger.debug(
          `projectName: ${projectName}, branchName: ${branchName}, existing environments are `,
          prod_environments
        );

        if (prod_environments.length >= productionEnvironmentsLimit) {
          if (prod_environments.find(i => i === branchName)) {
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, environment already exists, no environment limits considered`
            );
          } else {
            throw new EnvironmentLimit(
              `'${branchName}' would exceed the configured limit of ${productionEnvironmentsLimit} production environments for project ${projectName}`
            );
          }
        }
      } else {
        // get a list of non-production environments
        const dev_environments = environments.project.environments
          .filter(e => e.environmentType === 'development')
          .map(e => e.name);
        logger.debug(
          `projectName: ${projectName}, branchName: ${branchName}, existing environments are `,
          dev_environments
        );

        if (
          environments.project.developmentEnvironmentsLimit !== null &&
          dev_environments.length >=
            environments.project.developmentEnvironmentsLimit
        ) {
          if (dev_environments.find(i => i === branchName)) {
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, environment already exists, no environment limits considered`
            );
          } else {
            throw new EnvironmentLimit(
              `'${branchName}' would exceed the configured limit of ${environments.project.developmentEnvironmentsLimit} development environments for project ${projectName}`
            );
          }
        }
      }

      if (type === 'branch') {
        switch (project.branches) {
          case undefined:
          case null:
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, no branches defined in active system, assuming we want all of them`
            );
            switch (project.activeSystemsDeploy) {
              case 'lagoon_openshiftBuildDeploy':
                return sendToLagoonTasks('builddeploy-openshift', deployData);
              case 'lagoon_kubernetesBuildDeploy':
                return sendToLagoonTasks('builddeploy-kubernetes', deployData);
              case 'lagoon_controllerBuildDeploy':
                // controllers uses a different message than the other services, so we need to source it here
                const buildDeployData = await getOperatorBuildData(deployData);
                return sendToLagoonTasks(buildDeployData.spec.project.deployTarget+':builddeploy', buildDeployData);
              default:
                throw new UnknownActiveSystem(
                  `Unknown active system '${project.activeSystemsDeploy}' for task 'deploy' in for project ${projectName}`
                );
            }
          case 'true':
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, all branches active, therefore deploying`
            );
            switch (project.activeSystemsDeploy) {
              case 'lagoon_openshiftBuildDeploy':
                return sendToLagoonTasks('builddeploy-openshift', deployData);
              case 'lagoon_kubernetesBuildDeploy':
                return sendToLagoonTasks('builddeploy-kubernetes', deployData);
              case 'lagoon_controllerBuildDeploy':
                  // controllers uses a different message than the other services, so we need to source it here
                  const buildDeployData = await getOperatorBuildData(deployData);
                  return sendToLagoonTasks(buildDeployData.spec.project.deployTarget+':builddeploy', buildDeployData);
              default:
                throw new UnknownActiveSystem(
                  `Unknown active system '${project.activeSystemsDeploy}' for task 'deploy' in for project ${projectName}`
                );
            }
          case 'false':
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, branch deployments disabled`
            );
            throw new NoNeedToDeployBranch('Branch deployments disabled');
          default: {
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, regex ${project.branches}, testing if it matches`
            );
            const branchRegex = new RegExp(project.branches);
            if (branchRegex.test(branchName)) {
              logger.debug(
                `projectName: ${projectName}, branchName: ${branchName}, regex ${project.branches} matched branchname, starting deploy`
              );
              switch (project.activeSystemsDeploy) {
                case 'lagoon_openshiftBuildDeploy':
                  return sendToLagoonTasks('builddeploy-openshift', deployData);
                case 'lagoon_kubernetesBuildDeploy':
                  return sendToLagoonTasks(
                    'builddeploy-kubernetes',
                    deployData
                  );
                case 'lagoon_controllerBuildDeploy':
                    // controllers uses a different message than the other services, so we need to source it here
                    const buildDeployData = await getOperatorBuildData(deployData);
                    return sendToLagoonTasks(buildDeployData.spec.project.deployTarget+':builddeploy', buildDeployData);
                default:
                  throw new UnknownActiveSystem(
                    `Unknown active system '${project.activeSystemsDeploy}' for task 'deploy' in for project ${projectName}`
                  );
              }
            }
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, regex ${project.branches} did not match branchname, not deploying`
            );
            throw new NoNeedToDeployBranch(
              `configured regex '${project.branches}' does not match branchname '${branchName}'`
            );
          }
        }
      } else if (type === 'pullrequest') {
        switch (project.pullrequests) {
          case undefined:
          case null:
            logger.debug(
              `projectName: ${projectName}, pullrequest: ${branchName}, no pullrequest defined in active system, assuming we want all of them`
            );
            switch (project.activeSystemsDeploy) {
              case 'lagoon_openshiftBuildDeploy':
                return sendToLagoonTasks('builddeploy-openshift', deployData);
              case 'lagoon_kubernetesBuildDeploy':
                return sendToLagoonTasks('builddeploy-kubernetes', deployData);
              case 'lagoon_controllerBuildDeploy':
                  // controllers uses a different message than the other services, so we need to source it here
                  const buildDeployData = await getOperatorBuildData(deployData);
                  return sendToLagoonTasks(buildDeployData.spec.project.deployTarget+':builddeploy', buildDeployData);
              default:
                throw new UnknownActiveSystem(
                  `Unknown active system '${
                    project.activeSystemsDeploy
                  }' for task 'deploy' in for project ${projectName}`,
                );
            }
          case 'true':
            logger.debug(
              `projectName: ${projectName}, pullrequest: ${branchName}, all pullrequest active, therefore deploying`
            );
            switch (project.activeSystemsDeploy) {
              case 'lagoon_openshiftBuildDeploy':
                return sendToLagoonTasks('builddeploy-openshift', deployData);
              case 'lagoon_kubernetesBuildDeploy':
                return sendToLagoonTasks('builddeploy-kubernetes', deployData);
              case 'lagoon_controllerBuildDeploy':
                  // controllers uses a different message than the other services, so we need to source it here
                  const buildDeployData = await getOperatorBuildData(deployData);
                  return sendToLagoonTasks(buildDeployData.spec.project.deployTarget+':builddeploy', buildDeployData);
              default:
                throw new UnknownActiveSystem(
                  `Unknown active system '${
                    project.activeSystemsDeploy
                  }' for task 'deploy' in for project ${projectName}`,
                );
            }
          case 'false':
            logger.debug(
              `projectName: ${projectName}, pullrequest: ${branchName}, pullrequest deployments disabled`
            );
            throw new NoNeedToDeployBranch('PullRequest deployments disabled');
          default: {
            logger.debug(
              `projectName: ${projectName}, pullrequest: ${branchName}, regex ${project.pullrequests}, testing if it matches PR Title '${pullrequestTitle}'`
            );

            const branchRegex = new RegExp(project.pullrequests);
            if (branchRegex.test(pullrequestTitle)) {
              logger.debug(
                `projectName: ${projectName}, pullrequest: ${branchName}, regex ${project.pullrequests} matched PR Title '${pullrequestTitle}', starting deploy`
              );
              switch (project.activeSystemsDeploy) {
                case 'lagoon_openshiftBuildDeploy':
                  return sendToLagoonTasks('builddeploy-openshift', deployData);
                case 'lagoon_kubernetesBuildDeploy':
                  return sendToLagoonTasks('builddeploy-kubernetes', deployData);
                case 'lagoon_controllerBuildDeploy':
                    // controllers uses a different message than the other services, so we need to source it here
                    const buildDeployData = await getOperatorBuildData(deployData);
                    return sendToLagoonTasks(buildDeployData.spec.project.deployTarget+':builddeploy', buildDeployData);
                default:
                  throw new UnknownActiveSystem(
                    `Unknown active system '${
                      project.activeSystemsDeploy
                    }' for task 'deploy' in for project ${projectName}`,
                  );
              }
            }
            logger.debug(
              `projectName: ${projectName}, branchName: ${branchName}, regex ${project.pullrequests} did not match PR Title, not deploying`
            );
            throw new NoNeedToDeployBranch(
              `configured regex '${project.pullrequests}' does not match PR Title '${pullrequestTitle}'`
            );
          }
        }
      }
      break;
    default:
      throw new UnknownActiveSystem(
        `Unknown active system '${project.activeSystemsDeploy}' for task 'deploy' in for project ${projectName}`
      );
  }
}

export const createPromoteTask = async function(promoteData: any) {
  const {
    projectName
    // branchName,
    // promoteSourceEnvironment,
    // type,
  } = promoteData;

  const project = await getActiveSystemForProject(projectName, 'Promote');

  if (typeof project.activeSystemsPromote === 'undefined') {
    throw new UnknownActiveSystem(
      `No active system for tasks 'deploy' in for project ${projectName}`
    );
  }

  switch (project.activeSystemsPromote) {
    case 'lagoon_openshiftBuildDeploy':
      return sendToLagoonTasks('builddeploy-openshift', promoteData);

    default:
      throw new UnknownActiveSystem(
        `Unknown active system '${project.activeSystemsPromote}' for task 'deploy' in for project ${projectName}`
      );
  }
}

export const createRemoveTask = async function(removeData: any) {
  const {
    projectName,
    branch,
    branchName,
    pullrequestNumber,
    pullrequestTitle,
    forceDeleteProductionEnvironment,
    type
  } = removeData;

  // Load all environments that currently exist (and are not deleted).
  const allEnvironments = await getEnvironmentsForProject(projectName);

  // Check to see if we are deleting a production environment, and if so,
  // ensure the flag is set to allow this.
  if (
    branch === allEnvironments.project.productionEnvironment ||
    (allEnvironments.project.standbyProductionEnvironment &&
      branch === allEnvironments.project.standbyProductionEnvironment)
  ) {
    if (forceDeleteProductionEnvironment !== true) {
      throw new CannotDeleteProductionEnvironment(
        `'${branch}' is defined as the production environment for ${projectName}, refusing to remove.`
      );
    }
  }

  const project = await getActiveSystemForProject(projectName, 'Remove');

  if (typeof project.activeSystemsRemove === 'undefined') {
    throw new UnknownActiveSystem(
      `No active system for tasks 'remove' in for project ${projectName}`
    );
  }

  switch (project.activeSystemsRemove) {
    case 'lagoon_openshiftRemove':
      if (type === 'branch') {
        // Check to ensure the environment actually exists.
        let foundEnvironment = false;
        allEnvironments.project.environments.forEach(function(
          environment,
          index
        ) {
          if (environment.name === branch) {
            foundEnvironment = true;
          }
        });

        if (!foundEnvironment) {
          logger.debug(
            `projectName: ${projectName}, branchName: ${branch}, no environment found.`
          );
          throw new NoNeedToRemoveBranch(
            'Branch environment does not exist, no need to remove anything.'
          );
        }

        logger.debug(
          `projectName: ${projectName}, branchName: ${branchName}. Removing branch environment.`
        );
        return sendToLagoonTasks('remove-openshift', removeData);
      } else if (type === 'pullrequest') {
        // Work out the branch name from the PR number.
        let branchName = 'pr-' + pullrequestNumber;
        removeData.branchName = 'pr-' + pullrequestNumber;

        // Check to ensure the environment actually exists.
        let foundEnvironment = false;
        allEnvironments.project.environments.forEach(function(
          environment,
          index
        ) {
          if (environment.name === branchName) {
            foundEnvironment = true;
          }
        });

        if (!foundEnvironment) {
          logger.debug(
            `projectName: ${projectName}, pullrequest: ${branchName}, no pullrequest found.`
          );
          throw new NoNeedToRemoveBranch(
            'Pull Request environment does not exist, no need to remove anything.'
          );
        }

        logger.debug(
          `projectName: ${projectName}, pullrequest: ${branchName}. Removing pullrequest environment.`
        );
        return sendToLagoonTasks('remove-openshift', removeData);
      } else if (type === 'promote') {
        return sendToLagoonTasks('remove-openshift', removeData);
      }
      break;

    case 'lagoon_kubernetesRemove':
      if (type === 'branch') {
        // Check to ensure the environment actually exists.
        let foundEnvironment = false;
        allEnvironments.project.environments.forEach(function(
          environment,
          index
        ) {
          if (environment.name === branch) {
            foundEnvironment = true;
          }
        });

        if (!foundEnvironment) {
          logger.debug(
            `projectName: ${projectName}, branchName: ${branch}, no environment found.`
          );
          throw new NoNeedToRemoveBranch(
            'Branch environment does not exist, no need to remove anything.'
          );
        }

        logger.debug(
          `projectName: ${projectName}, branchName: ${branchName}. Removing branch environment.`
        );
        return sendToLagoonTasks('remove-kubernetes', removeData);
      } else if (type === 'pullrequest') {
        // Work out the branch name from the PR number.
        let branchName = 'pr-' + pullrequestNumber;
        removeData.branchName = 'pr-' + pullrequestNumber;

        // Check to ensure the environment actually exists.
        let foundEnvironment = false;
        allEnvironments.project.environments.forEach(function(
          environment,
          index
        ) {
          if (environment.name === branchName) {
            foundEnvironment = true;
          }
        });

        if (!foundEnvironment) {
          logger.debug(
            `projectName: ${projectName}, pullrequest: ${branchName}, no pullrequest found.`
          );
          throw new NoNeedToRemoveBranch(
            'Pull Request environment does not exist, no need to remove anything.'
          );
        }

        logger.debug(
          `projectName: ${projectName}, pullrequest: ${branchName}. Removing pullrequest environment.`
        );
        return sendToLagoonTasks('remove-kubernetes', removeData);
      } else if (type === 'promote') {
        return sendToLagoonTasks('remove-kubernetes', removeData);
      }
      break;

    // handle removals using the controllers, send the message to our specific target cluster queue
    case 'lagoon_controllerRemove':
      const result = await getOpenShiftInfoForProject(projectName);
      const deployTarget = result.project.openshift.name
      if (type === 'branch') {
        // Check to ensure the environment actually exists.
        let foundEnvironment = false;
        allEnvironments.project.environments.forEach(function(
          environment,
          index
        ) {
          if (environment.name === branch) {
            foundEnvironment = true;
          }
        });

        if (!foundEnvironment) {
          logger.debug(
            `projectName: ${projectName}, branchName: ${branch}, no environment found.`
          );
          throw new NoNeedToRemoveBranch(
            'Branch environment does not exist, no need to remove anything.'
          );
        }

        logger.debug(
          `projectName: ${projectName}, branchName: ${branchName}. Removing branch environment.`
        );
        // use the targetname as the routing key with the action
        return sendToLagoonTasks(deployTarget+":remove", removeData);
      } else if (type === 'pullrequest') {
        // Work out the branch name from the PR number.
        let branchName = 'pr-' + pullrequestNumber;
        removeData.branchName = 'pr-' + pullrequestNumber;

        // Check to ensure the environment actually exists.
        let foundEnvironment = false;
        allEnvironments.project.environments.forEach(function(
          environment,
          index
        ) {
          if (environment.name === branchName) {
            foundEnvironment = true;
          }
        });

        if (!foundEnvironment) {
          logger.debug(
            `projectName: ${projectName}, pullrequest: ${branchName}, no pullrequest found.`
          );
          throw new NoNeedToRemoveBranch(
            'Pull Request environment does not exist, no need to remove anything.'
          );
        }

        logger.debug(
          `projectName: ${projectName}, pullrequest: ${branchName}. Removing pullrequest environment.`
        );
        return sendToLagoonTasks(deployTarget+":remove", removeData);
      } else if (type === 'promote') {
        return sendToLagoonTasks(deployTarget+":remove", removeData);
      }
      break;

    default:
      throw new UnknownActiveSystem(
        `Unknown active system '${project.activeSystemsRemove}' for task 'remove' in for project ${projectName}`
      );
  }
}

// creates the restore job configuration for use in the misc task
const restoreConfig = (name, backupId, safeProjectName) => {
  let config = {
    apiVersion: 'backup.appuio.ch/v1alpha1',
    kind: 'Restore',
    metadata: {
      name
    },
    spec: {
      snapshot: backupId,
      restoreMethod: {
        s3: {},
      },
      backend: {
        s3: {
          bucket: `baas-${safeProjectName}`
        },
        repoPasswordSecretRef: {
          key: 'repo-pw',
          name: 'baas-repo-pw'
        },
      },
    },
  };

  return config;
};

// creates the route/ingress migration config
const migrateIngress = (destinationNamespace, sourceNamespace) => {
  const randId = Math.random().toString(36).substring(7);
  const migrateName = `ingress-migrate-${randId}`;
  let config = {
    apiVersion: 'dioscuri.amazee.io/v1',
    kind: 'IngressMigrate',
    metadata: {
      name: migrateName,
      annotations: {
          'dioscuri.amazee.io/migrate':'true'
      }
    },
    spec: {
      destinationNamespace: destinationNamespace,
      activeEnvironment: sourceNamespace,
    },
  };

  return config;
};

export const createTaskTask = async function(taskData: any) {
  const { project } = taskData;

  const projectSystem = await getActiveSystemForProject(project.name, 'Task');

  if (typeof projectSystem.activeSystemsTask === 'undefined') {
    throw new UnknownActiveSystem(
      `No active system for 'task' for project ${project.name}`
    );
  }

  switch (projectSystem.activeSystemsTask) {
    case 'lagoon_openshiftJob':
      return sendToLagoonTasks('job-openshift', taskData);

    case 'lagoon_kubernetesJob':
      return sendToLagoonTasks('job-kubernetes', taskData);

    case 'lagoon_controllerJob':
      // since controllers queues are named, we have to send it to the right tasks queue
      // do that here
      const result = await getOpenShiftInfoForProject(project.name);
      const deployTarget = result.project.openshift.name
      return sendToLagoonTasks(deployTarget+":jobs", taskData);

    default:
      throw new UnknownActiveSystem(
        `Unknown active system '${projectSystem.activeSystemsTask}' for 'task' for project ${project.name}`
      );
  }
}

export const createMiscTask = async function(taskData: any) {
  const {
    key,
    data: { project }
  } = taskData;

  const data = await getActiveSystemForProject(project.name, 'Misc');

  let updatedKey = key;
  let taskId = '';
  switch (data.activeSystemsMisc) {
    case 'lagoon_openshiftMisc':
      updatedKey = `openshift:${key}`;
      taskId = 'misc-openshift';
      break;
    case 'lagoon_kubernetesMisc':
      updatedKey = `kubernetes:${key}`;
      taskId = 'misc-kubernetes';
      break;
    case 'lagoon_controllerMisc':
      // handle any controller based misc tasks
      updatedKey = `kubernetes:${key}`;
      taskId = 'misc-kubernetes';
      // determine the deploy target (openshift/kubernetes) for the task to go to
      const result = await getOpenShiftInfoForProject(project.name);
      const projectOpenShift = result.project
      var deployTarget = projectOpenShift.openshift.name
      // this is the json structure for sending a misc task to the controller
      // there are some additional bits that can be adjusted, and these are done in the switch below on `updatedKey`
      var miscTaskData: any = {
        misc: {},
        key: updatedKey,
        environment: {
          name: taskData.data.environment.name,
          openshiftProjectName: taskData.data.environment.openshiftProjectName
        },
        project: {
          name: taskData.data.project.name
        },
        task: taskData.data.task,
        advancedTask: {}
      }
      switch (updatedKey) {
        case 'kubernetes:restic:backup:restore':
          // Handle setting up the configuration for a restic restoration task
          const restoreName = `restore-${R.slice(0, 7, taskData.data.backup.backupId)}`;
          // generate the restore CRD
          const restoreConf = restoreConfig(restoreName, taskData.data.backup.backupId, makeSafe(taskData.data.project.name))
          // base64 encode it
          const restoreBytes = new Buffer(JSON.stringify(restoreConf).replace(/\\n/g, "\n")).toString('base64')
          miscTaskData.misc.miscResource = restoreBytes
          break;
        case 'kubernetes:route:migrate':
          // handle setting up the task configuration for running the active/standby switch
          // this uses the `advanced task` system in the controllers
          // first generate the migration CRD
          const migrateConf = migrateIngress(
            makeSafe(taskData.data.productionEnvironment.openshiftProjectName),
            makeSafe(taskData.data.environment.openshiftProjectName))
          // generate out custom json payload to send to the advanced task
          var jsonPayload: any = {
            productionEnvironment: taskData.data.productionEnvironment.name,
            standbyEnvironment: taskData.data.environment.name,
            crd: migrateConf
          }
          // encode it
          const jsonPayloadBytes = new Buffer(JSON.stringify(jsonPayload).replace(/\\n/g, "\n")).toString('base64')
          // set the task data up
          miscTaskData.advancedTask.JSONPayload = jsonPayloadBytes
          // use this image to run the task
          let taskImage = ""
          // choose which task image to use
          if (CI == "true") {
            taskImage = "172.17.0.1:5000/lagoon/task-activestandby:latest"
          } else if (overwriteActiveStandbyTaskImage) {
            // allow to overwrite the image we use via OVERWRITE_ACTIVESTANDBY_TASK_IMAGE env variable
            taskImage = overwriteActiveStandbyTaskImage
          } else if (lagoonEnvironmentType == 'production') {
            taskImage = `amazeeio/task-activestandby:${lagoonVersion}`
          } else {
            // we are a development enviornment, use the amazeeiolagoon image with the same branch name
            taskImage = `amazeeiolagoon/task-activestandby:${lagoonGitSafeBranch}`
          }
          miscTaskData.advancedTask.runnerImage = taskImage
          // miscTaskData.advancedTask.runnerImage = "shreddedbacon/runner:latest"
          break;
        case 'kubernetes:build:cancel':
          // build cancellation is just a standard unmodified message
          miscTaskData.misc = taskData.data.build
          break;
        default:
          miscTaskData.misc = taskData.data.build
          break;
      }
      // send the task to the queue
      return sendToLagoonTasks(deployTarget+':misc', miscTaskData);
    default:
      break;
  }

  return sendToLagoonTasks(taskId, { ...taskData, key: updatedKey });
}

export const consumeTasks = async function(
  taskQueueName: string,
  messageConsumer: MessageConsumer,
  retryHandler: RetryHandler,
  deathHandler: DeathHandler
) {
  const onMessage = async (msg: ConsumeMessage) => {
    try {
      await messageConsumer(msg);
      channelWrapperTasks.ack(msg);
    } catch (error) {
      // We land here if the messageConsumer has an error that it did not itslef handle.
      // This is how the consumer informs us that we it would like to retry the message in a couple of seconds

      const retryCount = msg.properties.headers['x-retry']
        ? msg.properties.headers['x-retry'] + 1
        : 1;

      if (retryCount > 3) {
        channelWrapperTasks.ack(msg);
        deathHandler(msg, error);
        return;
      }

      const retryDelaySecs = 10 ** retryCount;
      const retryDelayMilisecs = retryDelaySecs * 1000;

      try {
        retryHandler(msg, error, retryCount, retryDelaySecs);
      } catch (retryError) {
        // intentionally empty as we don't want to fail and not requeue our message just becase the retryHandler fails
        logger.info(
          `lagoon-tasks: retryHandler for ${taskQueueName} failed with ${retryError}, will continue to retry the message anyway.`
        );
      }

      // copying options from the original message
      const retryMsgOptions = {
        appId: msg.properties.appId,
        timestamp: msg.properties.timestamp,
        contentType: msg.properties.contentType,
        deliveryMode: msg.properties.deliveryMode,
        headers: {
          ...msg.properties.headers,
          'x-delay': retryDelayMilisecs,
          'x-retry': retryCount
        },
        persistent: true
      };

      // publishing a new message with the same content as the original message but into the `lagoon-tasks-delay` exchange,
      // which will send the message into the original exchange `lagoon-tasks` after waiting the x-delay time.
      channelWrapperTasks.publish(
        'lagoon-tasks-delay',
        msg.fields.routingKey,
        msg.content,
        retryMsgOptions
      );

      // acknologing the existing message, we cloned it and is not necessary anymore
      channelWrapperTasks.ack(msg);
    }
  };

  const channelWrapperTasks = connection.createChannel({
    setup(channel: ConfirmChannel) {
      return Promise.all([
        channel.assertQueue(`lagoon-tasks:${taskQueueName}`, { durable: true }),
        channel.bindQueue(
          `lagoon-tasks:${taskQueueName}`,
          'lagoon-tasks',
          taskQueueName
        ),
        channel.prefetch(taskPrefetch),
        channel.consume(`lagoon-tasks:${taskQueueName}`, onMessage, {
          noAck: false
        })
      ]);
    }
  });
}

export const consumeTaskMonitor = async function(
  taskMonitorQueueName: string,
  messageConsumer: MessageConsumer,
  deathHandler: DeathHandler
) {
  const onMessage = async (msg: ConsumeMessage) => {
    try {
      await messageConsumer(msg);
      channelWrapperTaskMonitor.ack(msg);
    } catch (error) {
      // We land here if the messageConsumer has an error that it did not itslef handle.
      // This is how the consumer informs us that we it would like to retry the message in a couple of seconds

      const retryCount = msg.properties.headers['x-retry']
        ? msg.properties.headers['x-retry'] + 1
        : 1;

      if (retryCount > 750) {
        channelWrapperTaskMonitor.ack(msg);
        deathHandler(msg, error);
        return;
      }

      let retryDelaySecs = 5;

      if (error.delayFn) {
        retryDelaySecs = error.delayFn(retryCount);
      }

      const retryDelayMilisecs = retryDelaySecs * 1000;

      // copying options from the original message
      const retryMsgOptions = {
        appId: msg.properties.appId,
        timestamp: msg.properties.timestamp,
        contentType: msg.properties.contentType,
        deliveryMode: msg.properties.deliveryMode,
        headers: {
          ...msg.properties.headers,
          'x-delay': retryDelayMilisecs,
          'x-retry': retryCount
        },
        persistent: true
      };

      // publishing a new message with the same content as the original message but into the `lagoon-tasks-delay` exchange,
      // which will send the message into the original exchange `lagoon-tasks` after waiting the x-delay time.
      channelWrapperTaskMonitor.publish(
        'lagoon-tasks-monitor-delay',
        msg.fields.routingKey,
        msg.content,
        retryMsgOptions
      );

      // acknologing the existing message, we cloned it and is not necessary anymore
      channelWrapperTaskMonitor.ack(msg);
    }
  };

  const channelWrapperTaskMonitor = connection.createChannel({
    setup(channel: ConfirmChannel) {
      return Promise.all([
        channel.assertQueue(`lagoon-tasks-monitor:${taskMonitorQueueName}`, {
          durable: true
        }),
        channel.bindQueue(
          `lagoon-tasks-monitor:${taskMonitorQueueName}`,
          'lagoon-tasks-monitor',
          taskMonitorQueueName
        ),
        channel.prefetch(taskMonitorPrefetch),
        channel.consume(
          `lagoon-tasks-monitor:${taskMonitorQueueName}`,
          onMessage,
          { noAck: false }
        )
      ]);
    }
  });
}
