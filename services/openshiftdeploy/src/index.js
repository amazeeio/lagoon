// @flow

require("babel-polyfill");

import sleep from "es7-sleep";
import Lokka from 'lokka';
import Transport from 'lokka-transport-http';
import { logger, initLogger } from '@amazeeio/amazeeio-local-logging';
import amqp from 'amqp-connection-manager';
import jenkinsLib from 'jenkins'
import { sendToAmazeeioLogs, initSendToAmazeeioLogs } from '@amazeeio/amazeeio-logs';


// Initialize the logging mechanism
initLogger();
initSendToAmazeeioLogs();

const amazeeioapihost = process.env.AMAZEEIO_API_HOST || "https://api.amazeeio.cloud"
const rabbitmqhost = process.env.RABBITMQ_HOST || "localhost"

const ocBuildDeployImageLocation = process.env.OC_BUILD_DEPLOY_IMAGE_LOCATION || "dockerhub"
const dockerRunParam = process.env.DOCKER_RUN_PARARM || ""
const ocBuildDeployBranch = process.env.BRANCH || "master"

const connection = amqp.connect([`amqp://${rabbitmqhost}`], {json: true});

const amazeeioAPI = new Lokka({
  transport: new Transport(`${amazeeioapihost}/graphql`)
});

connection.on('connect', ({ url }) => logger.verbose('Connected to %s', url));
connection.on('disconnect', params => logger.error('Not connected, error: %s', params.err.code, { reason: params }));

const channelWrapper = connection.createChannel({
    setup: function(channel) {
        return Promise.all([
            channel.assertQueue('amazeeio-tasks:deploy-openshift', {durable: true}),
            channel.prefetch(2),
            channel.consume('amazeeio-tasks:deploy-openshift', onMessage, {noAck: false}),
        ])
    }
});


var onMessage = async function(msg) {
  var payload = JSON.parse(msg.content.toString())

  const {
    siteGroupName,
    branchName,
    sha
  } = payload

  logger.verbose(`Received DeployOpenshift task for sitegroup ${siteGroupName}, branch ${branchName}`);

  const siteGroupOpenShift = await amazeeioAPI.query(`
    {
      siteGroup:siteGroupByName(name: "${siteGroupName}"){
        openshift
        client {
          deployPrivateKey
        }
        gitUrl
      }
    }
  `)

  let jenkinsUrl

  try {
    var safeBranchname = branchName.replace('/','-')
    var gitSha = sha
    var openshiftConsole = siteGroupOpenShift.siteGroup.openshift.console
    var openshiftRegistry =siteGroupOpenShift.siteGroup.openshift.registry
    var openshiftToken = siteGroupOpenShift.siteGroup.openshift.token || ""
    var openshiftUsername = siteGroupOpenShift.siteGroup.openshift.username || ""
    var openshiftPassword = siteGroupOpenShift.siteGroup.openshift.password || ""
    var openshiftTemplate = siteGroupOpenShift.siteGroup.openshift.template
    var openshiftFolder = siteGroupOpenShift.siteGroup.openshift.folder || "."
    var openshiftNamingPullRequests = typeof siteGroupOpenShift.siteGroup.openshift.naming !== 'undefined' ? siteGroupOpenShift.siteGroup.openshift.naming.branch : "${sitegroup}-${branch}" || "${sitegroup}-${branch}"
    var openshiftProject = siteGroupOpenShift.siteGroup.openshift.project || siteGroupOpenShift.siteGroup.siteGroupName
    var openshiftRessourceAppName = openshiftNamingPullRequests.replace('${branch}', safeBranchname).replace('${sitegroup}', siteGroupName).replace('_','-')
    var deployPrivateKey = siteGroupOpenShift.siteGroup.client.deployPrivateKey
    var gitUrl = siteGroupOpenShift.siteGroup.gitUrl
    var routerPattern = siteGroupOpenShift.siteGroup.openshift.router_pattern || "${sitegroup}.${branch}.appuio.amazee.io"
    var openshiftRessourceRouterUrl = routerPattern.replace('${branch}', safeBranchname).replace('${sitegroup}', siteGroupName).replace('_','-')

    if (siteGroupOpenShift.siteGroup.openshift.jenkins) {
      jenkinsUrl = siteGroupOpenShift.siteGroup.openshift.jenkins
    } else {
      jenkinsUrl = process.env.JENKINS_URL || "https://amazee:amazee4ever$1@ci-popo.amazeeio.cloud"
    }

  } catch(err) {
    logger.warn(`Error while loading information for sitegroup ${siteGroupName}: ${err}`)
    channelWrapper.ack(msg)
    return
  }

  logger.info(`Will deploy OpenShift Resources with app name ${openshiftRessourceAppName} on ${openshiftConsole}`);

  try {
    await deployOpenShift(siteGroupName, branchName, safeBranchname, gitSha, openshiftRessourceAppName, openshiftRessourceRouterUrl, openshiftConsole, openshiftRegistry, openshiftToken, openshiftUsername, openshiftPassword, openshiftProject, openshiftTemplate, openshiftFolder, deployPrivateKey, gitUrl, jenkinsUrl)
  }
  catch(error) {
    logger.error(`Error deploying OpenShift Resources with app name ${openshiftRessourceAppName} on ${openshiftConsole}. The error was: ${error}`)
    sendToAmazeeioLogs('error', siteGroupName, "", "task:deploy-openshift:error",  {},
`ERROR: Deploying with label \`${openshiftRessourceAppName}\`:
\`\`\`
${error}
\`\`\``
    )
    channelWrapper.ack(msg)
    return
  }
  logger.info(`Deployed OpenShift Resources with app name ${openshiftRessourceAppName} on ${openshiftConsole}`);
  channelWrapper.ack(msg)
}

async function deployOpenShift(siteGroupName, branchName, safeBranchname, gitSha, openshiftRessourceAppName, openshiftRessourceRouterUrl, openshiftConsole, openshiftRegistry, openshiftToken, openshiftUsername, openshiftPassword, openshiftProject, openshiftTemplate, openshiftFolder, deployPrivateKey, gitUrl, jenkinsUrl) {
  var folderxml =
  `<?xml version='1.0' encoding='UTF-8'?>
  <com.cloudbees.hudson.plugins.folder.Folder plugin="cloudbees-folder@5.13">
    <actions/>
    <description></description>
    <properties/>
    <views>
      <hudson.model.AllView>
        <owner class="com.cloudbees.hudson.plugins.folder.Folder" reference="../../.."/>
        <name>All</name>
        <filterExecutors>false</filterExecutors>
        <filterQueue>false</filterQueue>
        <properties class="hudson.model.View$PropertyList"/>
      </hudson.model.AllView>
    </views>
    <viewsTabBar class="hudson.views.DefaultViewsTabBar"/>
    <healthMetrics/>
    <icon class="com.cloudbees.hudson.plugins.folder.icons.StockFolderIcon"/>
  </com.cloudbees.hudson.plugins.folder.Folder>
  `

  let ocBuildDeploystage
  let ocBuildDeployImageName
  if (ocBuildDeployImageLocation == "dockerhub") {
    ocBuildDeployImageName = `amazeeio/oc-build-deploy:${ocBuildDeployBranch}`
    ocBuildDeploystage =
    `
      stage ('oc-build-deploy docker pull') {
        sh '''
          docker pull ${ocBuildDeployImageName}
        '''
      }
    `
  } else if (ocBuildDeployImageLocation == "absolute") {
    ocBuildDeployImageName = `oc-build-deploy`
    ocBuildDeploystage =
    `
      stage ('oc-build-deploy docker build') {
        sh '''
          docker build -t ${ocBuildDeployImageName} /docker-oc-build-deploy
        '''
      }
    `
  } else {
    ocBuildDeployImageName = `oc-build-deploy-${ocBuildDeployBranch}`
    ocBuildDeploystage =
    `
      stage ('oc-build-deploy git checkout') {
        git branch: '${ocBuildDeployBranch}', changelog: false, poll: false, url: '${ocBuildDeployImageLocation}', credentialsId: 'amazeeio-github-bearer-token'
      }

      stage ('oc-build-deploy docker build') {
        sh '''
          docker build -t ${ocBuildDeployImageName} .
        '''
      }
    `
  }

  // If we don't have an OpenShift token, start an amazeeio/oc container which will log us in and then get the token.
  let getTokenStage
  if (openshiftToken == "") {
    getTokenStage =
    `
      stage ('get oc token') {
        env.OPENSHIFT_TOKEN = sh script: 'docker run --rm -e OPENSHIFT_USERNAME="${openshiftUsername}" -e OPENSHIFT_PASSWORD="${openshiftPassword}" -e OPENSHIFT_CONSOLE="${openshiftConsole}" amazeeio/oc oc whoami -t', returnStdout: true
        env.OPENSHIFT_TOKEN = env.OPENSHIFT_TOKEN.trim()
      }
    `
  } else {
    getTokenStage =
    `
      stage ('get oc token') {
        env.OPENSHIFT_TOKEN = "${openshiftToken}"
      }
    `
  }

  var shortName = `${safeBranchname}-${siteGroupName}`.substring(0, 24).replace(/[^a-z0-9]+$/, '').replace('_','-')
  var buildName = gitSha ? gitSha.substring(0, 7) : branchName
  // Deciding which git REF we would like deployed, if we have a sha given, we use that, if not we fall back to the branch (which needs be prefixed by `origin/`)
  var gitRef = gitSha ? gitSha : `origin/${branchName}`
  var jobdsl =
  `
node {
  currentBuild.displayName = "#$BUILD_ID - ${buildName}"
  env.IMAGE = env.BUILD_TAG.toLowerCase().replaceAll('%2f','-').replaceAll('/','-')

  ${ocBuildDeploystage}

  ${getTokenStage}

  stage ('Deploy') {
    println( [[name: 'jobname', value: "\${env.JOB_NAME}"], [name: 'buildnumber', value: "\${env.BUILD_NUMBER}"]] )

    def response = httpRequest url:'http://jobwatch:3000/job', httpMode:'POST', customHeaders: [[name: 'jobname', value: "\${env.JOB_NAME}"], [name: 'buildnumber', value: "\${env.BUILD_NUMBER}"]]
    println("Status: "+response.status)
    println("Content: "+response.content)
    println("after")

    sh """docker run --rm \\
    ${dockerRunParam} \\
    -e GIT_REPO="${gitUrl}" \\
    -e GIT_REF="${gitRef}" \\
    -e OPENSHIFT_CONSOLE="${openshiftConsole}" \\
    -e OPENSHIFT_REGISTRY="${openshiftRegistry}" \\
    -e OPENSHIFT_TOKEN="\${env.OPENSHIFT_TOKEN}" \\
    -e OPENSHIFT_PROJECT="${openshiftProject}" \\
    -e OPENSHIFT_ROUTER_URL="${openshiftRessourceRouterUrl}" \\
    -e OPENSHIFT_TEMPLATE="${openshiftTemplate}" \\
    -e OPENSHIFT_FOLDER="${openshiftFolder}" \\
    -e SSH_PRIVATE_KEY="${deployPrivateKey}" \\
    -e TAG="${safeBranchname}" \\
    -e BRANCH="${branchName}" \\
    -e IMAGE=\${env.IMAGE} \\
    -e NAME="${openshiftRessourceAppName}" \\
    -e SHORT_NAME="${shortName}" \\
    -e SITEGROUP="${siteGroupName}" \\
    -v $WORKSPACE:/git \\
    -v /var/run/docker.sock:/var/run/docker.sock \\
    ${ocBuildDeployImageName}"""
  }

  // Using openshiftVerifyDeployment which will monitor the current deployment and only continue when it is done.
  stage ('OpenShift: deployment') {
    env.SKIP_TLS = true
    openshiftVerifyDeployment apiURL: "${openshiftConsole}", authToken: env.OPENSHIFT_TOKEN, depCfg: "${openshiftRessourceAppName}", namespace: "${openshiftProject}", replicaCount: '', verbose: 'false', verifyReplicaCount: 'false', waitTime: '15', waitUnit: 'min', SKIP_TLS: true
  }

}

  `

  var jobxml =
  `<?xml version='1.0' encoding='UTF-8'?>
  <flow-definition plugin="workflow-job@2.7">
    <actions/>
    <description>${openshiftRessourceAppName}</description>
    <keepDependencies>false</keepDependencies>
    <properties>
      <org.jenkinsci.plugins.workflow.job.properties.DisableConcurrentBuildsJobProperty/>
    </properties>
    <definition class="org.jenkinsci.plugins.workflow.cps.CpsFlowDefinition" plugin="workflow-cps@2.21">
      <script>${jobdsl}</script>
      <sandbox>true</sandbox>
    </definition>
    <triggers/>
    <quietPeriod>0</quietPeriod>
  </flow-definition>
  `

  var foldername = `${siteGroupName}`

  var jobname = `${foldername}/deploy-${openshiftRessourceAppName}`

  const jenkins = jenkinsLib({ baseUrl: `${jenkinsUrl}`, promisify: true});

  // First check if the Folder exists (hint: Folders are also called "job" in Jenkins)
  if (await jenkins.job.exists(foldername)) {
    // Folder exists, update current config.
    await jenkins.job.config(foldername, folderxml)
  } else {
    // Folder does not exist, create it.
    await jenkins.job.create(foldername, folderxml)
  }

  if (await jenkins.job.exists(jobname)) {
    // Update existing job
    logger.verbose("Job '%s' already existed, updating", jobname)
    await jenkins.job.config(jobname, jobxml)
  } else {
    // Job does not exist yet, create new one
    logger.verbose("New Job '%s' created", jobname)
    await jenkins.job.create(jobname, jobxml)
  }

  logger.verbose(`Queued job build: ${jobname}`)
  let jenkinsJobBuildResponse = await jenkins.job.build(jobname)


  let getJenkinsJobID = async jenkinsJobBuildResponse => {
    while (true) {
      let jenkinsQueueItem = await jenkins.queue.item(jenkinsJobBuildResponse)
      if (jenkinsQueueItem.blocked == false) {
        if (jenkinsQueueItem.executable) {
          return jenkinsQueueItem.executable.number
        } else {
          logger.warn(`weird response from Jenkins. Trying again in 2 Secs. Reponse was: ${JSON.stringify(jenkinsQueueItem)}`)
          await sleep(2000);
        }
      } else {
        logger.verbose(`Job Build blocked, will try in 5 secs. Reason: ${jenkinsQueueItem.why}`)
        await sleep(5000);
      }
    }
  }

  let jenkinsJobID = await getJenkinsJobID(jenkinsJobBuildResponse)
  let logMessage
  if (gitSha) {
    logMessage = `\`${branchName}\` (${buildName})`
  } else {
    logMessage = `\`${branchName}\``
  }

  logger.verbose(`Running job build: ${jobname}, job id: ${jenkinsJobID}`)

  sendToAmazeeioLogs('start', siteGroupName, "", "task:deploy-openshift:start", {},
    `*[${siteGroupName}]* ${logMessage}`
  )

  let log = jenkins.build.logStream(jobname, jenkinsJobID)

  return new Promise((resolve, reject) => {
    log.on('data', text => {
      logger.silly(text)
    });

    log.on('error', error =>  {
      sendToAmazeeioLogs('error', siteGroupName, "", "task:deploy-openshift:error",  {},
  `*[${siteGroupName}]* ${logMessage} ERROR:
  \`\`\`
  ${error}
  \`\`\``
      )
      logger.error(error)
      throw error
    });

    log.on('end', async () => {
      const result = await jenkins.build.get(jobname, jenkinsJobID)
      if (result.result === "SUCCESS") {
        sendToAmazeeioLogs('success', siteGroupName, "", "task:deploy-openshift:finished",  {},
          `*[${siteGroupName}]* ${logMessage} ${openshiftRessourceRouterUrl}`
        )
        logger.verbose(`Finished job build: ${jobname}, job id: ${jenkinsJobID}`)
      } else {
        sendToAmazeeioLogs('error', siteGroupName, "", "task:deploy-openshift:error",  {}, `*[${siteGroupName}]* ${logMessage} ERROR`)
        logger.error(`Finished FAILURE job build: ${jobname}, job id: ${jenkinsJobID}`)
      }
      resolve()
    });
  })
}
